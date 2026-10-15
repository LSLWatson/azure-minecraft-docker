#Requires -Version 7
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot ".." "scripts" "functions.ps1")
$root = Split-Path $PSScriptRoot -Parent
$infra = Join-Path $root "infra"
$temporary = Join-Path $infra ".test-$([guid]::NewGuid())"
$null = New-Item $temporary -ItemType Directory
function Assert-True ($Condition, $Message) { if (!$Condition) { throw $Message } }
function Assert-Fails ([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert-True $failed $Message
}
function Get-Resources ($Template) {
    if ($Template.resources -is [hashtable]) { return @($Template.resources.Values) }
    return @($Template.resources)
}
function Get-Templates ($Template) {
    $Template
    foreach ($resource in (Get-Resources $Template)) {
        if ($resource.type -eq "Microsoft.Resources/deployments") { Get-Templates $resource.properties.template }
    }
}

# Evaluate only the ARM functions used by the compiled port contract, not a parallel infrastructure implementation.
function Split-ArmArguments ([string]$Text) {
    $parts = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    $quoted = $false
    $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq "'") {
            if ($quoted -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
            $quoted = !$quoted
        }
        if (!$quoted) {
            if ($c -in @('(', '[')) { $depth++ }
            if ($c -in @(')', ']')) { $depth-- }
            if ($c -eq ',' -and $depth -eq 0) { $parts.Add($Text.Substring($start, $i - $start).Trim()); $start = $i + 1 }
        }
    }
    if ($Text.Trim()) { $parts.Add($Text.Substring($start).Trim()) }
    return ,$parts.ToArray()
}
function Get-ArmValue ($Value, $Template, $Parameters, [int]$CopyIndex = 0) {
    if ($Value -is [hashtable]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[$key] = Get-ArmValue $Value[$key] $Template $Parameters $CopyIndex }
        return ,$result
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { Get-ArmValue $_ $Template $Parameters $CopyIndex }) }
    if ($Value -isnot [string] -or !$Value.StartsWith('[')) { return ,$Value }
    return ,(Get-ArmExpression $Value.Substring(1, $Value.Length - 2) $Template $Parameters $CopyIndex)
}
function Get-ArmExpression ([string]$Text, $Template, $Parameters, [int]$CopyIndex = 0) {
    $Text = $Text.Trim()
    if ($Text -match "^-?[0-9]+$") { return [int]$Text }
    if ($Text.StartsWith("'") -and $Text.EndsWith("'")) { return $Text.Substring(1, $Text.Length - 2).Replace("''", "'") }
    $match = [regex]::Match($Text, '^(\w+)\(')
    if (!$match.Success) { throw "Unsupported ARM contract expression: $Text" }
    $name = $match.Groups[1].Value
    $depth = 1
    $quoted = $false
    $end = -1
    for ($i = $match.Length; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq "'") { $quoted = !$quoted }
        if (!$quoted) {
            if ($c -eq '(') { $depth++ }
            if ($c -eq ')') { $depth-- }
            if ($depth -eq 0) { $end = $i; break }
        }
    }
    if ($end -lt 0) { throw "Unbalanced ARM expression: $Text" }
    $arguments = [System.Collections.Generic.List[object]]::new()
    foreach ($part in (Split-ArmArguments $Text.Substring($match.Length, $end - $match.Length))) {
        $arguments.Add((Get-ArmExpression $part $Template $Parameters $CopyIndex))
    }
    $value = switch ($name) {
        "parameters" { $Parameters[$arguments[0]] }
        "variables" {
            if ($Template.variables.Contains($arguments[0])) { Get-ArmValue $Template.variables[$arguments[0]] $Template $Parameters $CopyIndex }
            else {
                $copy = @($Template.variables.copy | Where-Object name -eq $arguments[0])
                if ($copy.Count -ne 1) { throw "Unknown ARM variable '$($arguments[0])'." }
                $count = Get-ArmValue $copy[0].count $Template $Parameters
                $values = [System.Collections.Generic.List[object]]::new()
                for ($index = 0; $index -lt $count; $index++) { $values.Add((Get-ArmValue $copy[0].input $Template $Parameters $index)) }
                ,$values.ToArray()
            }
        }
        "length" { $arguments[0].Count }
        "range" { ,@([System.Linq.Enumerable]::Range($arguments[0], $arguments[1])) }
        "copyIndex" { $CopyIndex }
        "createArray" { ,$arguments.ToArray() }
        "createObject" {
            $object = @{}
            for ($index = 0; $index -lt $arguments.Count; $index += 2) { $object[$arguments[$index]] = $arguments[$index + 1] }
            $object
        }
        "concat" { ,@($arguments | ForEach-Object { foreach ($item in $_) { $item } }) }
        default { throw "Unsupported ARM function '$name' in port contract." }
    }
    $suffix = $Text.Substring($end + 1)
    if ($suffix.StartsWith('.')) { $value = $value[$suffix.Substring(1)] }
    elseif ($suffix.StartsWith('[') -and $suffix.EndsWith(']')) {
        $value = $value[(Get-ArmExpression $suffix.Substring(1, $suffix.Length - 2) $Template $Parameters $CopyIndex)]
    } elseif ($suffix) { throw "Unsupported ARM suffix '$suffix'." }
    return ,$value
}

try {
    $compiled = Join-Path $temporary "main.json"
    $diagnostics = & az bicep build --file (Join-Path $infra "main.bicep") --outfile $compiled 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "Bicep build failed: $diagnostics"
    Assert-True (!(($diagnostics -join "`n") -match 'Warning (BCP|[a-z-]+:)')) "Bicep diagnostics: $diagnostics"
    $template = Get-Content $compiled -Raw | ConvertFrom-Json -AsHashtable
    $templates = @(Get-Templates $template)
    $resources = @($templates | ForEach-Object { Get-Resources $_ })
    $instanceTemplate = @($templates | Where-Object { @(Get-Resources $_ | Where-Object type -eq "Microsoft.ContainerInstance/containerGroups").Count -gt 0 })[0]
    $container = @(Get-Resources $instanceTemplate | Where-Object type -eq "Microsoft.ContainerInstance/containerGroups")[0]
    $config = @{ maxPlayers = 4; serverPort = 19132; udpPortStart = 19140 }
    foreach ($players in 1..4) {
        $config.maxPlayers = $players
        $parameters = @{ config = $config }
        $groupPorts = Get-ArmValue $container.properties.ipAddress.ports $instanceTemplate $parameters
        $serverPorts = Get-ArmValue $container.properties.containers[0].properties.ports $instanceTemplate $parameters
        Assert-True ($groupPorts.Count -eq $players + 1 -and $serverPorts.Count -eq $players + 1) "Port count must be one TCP plus exactly $players UDP."
        Assert-True (@($groupPorts | Where-Object protocol -eq "TCP").Count -eq 1) "Exactly one signaling port is required."
        Assert-True (@($groupPorts | Where-Object { $_.protocol -eq "TCP" -and $_.port -eq 19132 }).Count -eq 1) "Incorrect signaling port."
        $udp = @($groupPorts | Where-Object protocol -eq "UDP" | ForEach-Object port)
        Assert-True (($udp -join ',') -eq ((19140..(19140 + $players - 1)) -join ',')) "Incorrect gameplay range."
        Assert-True (($serverPorts | ConvertTo-Json -Compress) -eq ($groupPorts | ConvertTo-Json -Compress)) "Group/container ports must match."
    }
    $config.serverPort = 25500
    $config.udpPortStart = 30000
    $custom = Get-ArmValue $container.properties.ipAddress.ports $instanceTemplate @{ config = $config }
    Assert-True (@($custom | Where-Object port -eq 25500).Count -eq 1 -and @($custom | Where-Object port -eq 30003).Count -eq 1) "Custom ports are not wired."
    Assert-True ($container.properties.containers[0].properties.livenessProbe.httpGet.path -eq "/v1/join") "Bedrock liveness probe is missing."
    Assert-True ($container.properties.volumes[0].azureFile.shareName -match "dataShareName") "Persistent data share must use the configured name."
    $command = Get-ArmValue $container.properties.containers[0].properties.command $instanceTemplate @{ config = $config }
    Assert-True ($command[2] -match 'getent ahostsv4') "Public-IP wrapper was not embedded."
    Assert-True ($template.outputs.minecraft.type -eq "array" -and $template.outputs.minecraft.copy.input -match "'configuration_name'") "Per-instance output shape changed."
    foreach ($name in $template.outputs.Keys) { Assert-True ($name -notmatch '(?i)key|secret|connection_string') "Secrets must not be output." }
    $schema = $template.definitions.MinecraftInstance.properties
    Assert-True ($schema.maxPlayers.minValue -eq 1 -and $schema.maxPlayers.maxValue -eq 4) "Player limit must also be enforced by ARM."
    $environmentSchema = $template.definitions[($schema.environmentVariables['$ref'] -split '/')[-1]]
    Assert-True ($environmentSchema.additionalProperties -eq $false -and !(Compare-Object @($environmentSchema.properties.Keys) $script:BedrockEnvironmentKeys)) "Environment validation drifted from Bicep."
    $storageTemplate = $template.resources.storage.properties.template
    $accounts = @(Get-Resources $storageTemplate | Where-Object type -eq "Microsoft.Storage/storageAccounts")
    Assert-True ($accounts.Count -eq 1 -and $accounts[0].condition -eq "[parameters('createAccount')]") "Adoption must not redeclare world storage."
    $shares = @(Get-Resources $storageTemplate | Where-Object type -eq "Microsoft.Storage/storageAccounts/fileServices/shares")
    Assert-True ($shares[0].condition -match "createDataShare") "Share adoption must not update existing shares."
    $backup = @($resources | Where-Object type -eq "Microsoft.RecoveryServices/vaults/backupPolicies")[0]
    Assert-True ($backup.properties.retentionPolicy.dailySchedule.retentionDuration.count -eq 30 -and
        $backup.properties.retentionPolicy.weeklySchedule.retentionDuration.count -eq 7 -and
        $backup.properties.retentionPolicy.monthlySchedule.retentionDuration.count -eq 12 -and
        $backup.properties.retentionPolicy.yearlySchedule.retentionDuration.count -eq 10) "Backup retention must be preserved."
    $workflow = @($resources | Where-Object type -eq "Microsoft.Logic/workflows")[0]
    Assert-True ($workflow.properties.definition.actions.ContainerOperation.inputs.authentication.type -eq "ManagedServiceIdentity") "Schedules must not use client secrets."
    Assert-True ($workflow.properties.definition.triggers -match 'Monday.+Tuesday.+Wednesday.+Thursday.+Friday') "Weekday schedule is missing."
    Assert-True ($workflow.properties.definition.triggers -match 'Weekend.+Saturday.+Sunday') "Conditional weekend schedule must remain wired."
    Assert-True ($workflow.properties.definition.triggers -match '2020-01-01T00:00:00') "Recurrences must not fire immediately on deployment."
    $functionTemplate = @($templates | Where-Object { @(Get-Resources $_ | Where-Object type -eq "Microsoft.Web/sites").Count -gt 0 })[0]
    $app = @(Get-Resources $functionTemplate | Where-Object type -eq "Microsoft.Web/sites")[0]
    Assert-True ($app.properties.siteConfig.linuxFxVersion -eq "DOTNET|8.0" -and $app.properties.httpsOnly) "Function runtime or HTTPS settings changed."
    $settingsExpression = $app.properties.siteConfig.appSettings | ConvertTo-Json -Depth 10
    Assert-True ($settingsExpression -match 'MINECRAFT_FQDN' -and $settingsExpression -match 'FUNCTIONS_INPROC_NET8_ENABLED') "Monitoring settings must be wired."
    $customAlert = @($resources | Where-Object { $_.type -eq "Microsoft.Insights/scheduledQueryRules" -and $_.name -match "custom-alert" })[0]
    $subject = $customAlert.properties.actions.actionProperties["Email.Subject"]
    Assert-True ($subject -match "customAlertSubject" -and $subject -match "'Custom alert'") "Custom email subjects and the default must be preserved."
    Assert-True ($template.resources.monitoring.properties.parameters.customAlertSubject.value -eq "[parameters('customAlertSubject')]") "Custom email subjects must reach the monitoring module."

    Set-DeploymentContext -ResourceGroup "minecraft-test"
    $fixtures = @(
        @{ Name = "default"; Body = ""; Valid = $true },
        @{ Name = "multiple"; Body = "param minecraftConfig = [{ name: 'primary', maxPlayers: 1 }, { name: 'creative', maxPlayers: 4, udpPortStart: 30000 }]"; Valid = $true },
        @{ Name = "empty"; Body = "param minecraftConfig = []"; Valid = $true },
        @{ Name = "boundary"; Body = "param minecraftConfig = [{ name: 'primary', maxPlayers: 1, udpPortStart: 65535 }]"; Valid = $true },
        @{ Name = "weekend-only"; Body = "param enableAutoStartStop = true`nparam minecraftConfig = [{ name: 'primary', startTime: '', startTimeWeekend: '09:00' }]"; Valid = $true },
        @{ Name = "players-high"; Body = "param minecraftConfig = [{ name: 'primary', maxPlayers: 5 }]"; Valid = $false },
        @{ Name = "players-zero"; Body = "param minecraftConfig = [{ name: 'primary', maxPlayers: 0 }]"; Valid = $false },
        @{ Name = "reserved"; Body = "param minecraftConfig = [{ name: 'primary', environmentVariables: { MAX_PLAYERS: '50' } }]"; Valid = $false },
        @{ Name = "java"; Body = "param minecraftConfig = [{ name: 'primary', environmentVariables: { TYPE: 'PAPER' } }]"; Valid = $false }
    )
    foreach ($fixture in $fixtures) {
        $file = Join-Path $temporary "$($fixture.Name).bicepparam"
        Set-Content $file ("using '../main.bicep'`n" + $fixture.Body)
        $parametersFile = Join-Path $temporary "$($fixture.Name).json"
        $previousExitCode = $LASTEXITCODE
        $result = & az bicep build-params --file $file --outfile $parametersFile 2>&1
        Assert-True (($LASTEXITCODE -eq 0) -eq $fixture.Valid) "Unexpected parameter compilation for $($fixture.Name): $result"
        # Expected compiler rejections must not become the pwsh -Command runner's exit status.
        $global:LASTEXITCODE = $previousExitCode
        if ($fixture.Valid) {
            $inputParameters = Get-Content $parametersFile -Raw | ConvertFrom-Json -AsHashtable
            Test-DeploymentParameters $inputParameters.parameters $template
        }
    }
    $valid = @{
        minecraftUsers = @{ value = @("Gamertag With Spaces:2535453759792258") }
        minecraftOps = @{ value = @("2535453759792258") }
        minecraftConfig = @{ value = @(@{ name = "primary"; allowOpsOnly = $true }) }
    }
    Test-DeploymentParameters $valid $template
    Assert-Fails { Test-DeploymentParameters @{ minecraftConfig = @{ value = @(@{ name = "primary"; maxPlayers = 2; udpPortStart = 65535 }) } } $template } "UDP overflow must fail."
    Assert-Fails { Test-DeploymentParameters @{ minecraftConfig = @{ value = @(@{ name = "primary" }, @{ name = "primary" }) } } $template } "Duplicate instances must fail."
    Assert-Fails { Test-DeploymentParameters @{ minecraftConfig = @{ value = @(@{ name = "primary"; startTime = "25:00" }) } } $template } "Invalid schedule times must fail."
    Assert-Fails { Test-DeploymentParameters @{ minecraftUsers = @{ value = @("Invalid:Gamertag:2535453759792258") } } $template } "Invalid gamertags must fail."
    Assert-Fails { Test-DeploymentParameters @{ minecraftOps = @{ value = @("PlayerName") } } $template } "Invalid XUIDs must fail."
    Assert-Fails { Test-DeploymentParameters @{ minecraftConfig = @{ value = @(@{ name = "primary"; allowOpsOnly = $true }) } } $template } "Empty operator-only configuration must fail."
    Assert-Fails { Test-DeploymentParameters @{ enableBackup = @{ value = "true" } } $template } "JSON parameters must enforce boolean types."
    Assert-Fails { Test-DeploymentParameters @{ minecraftConfig = @{ value = @(@{ name = "primary"; extra = "unsupported" }) } } $template } "JSON parameters must reject unknown instance properties."
    Write-Host "Bicep compilation, typed/JSON parameters, exact ports, adoption, monitoring, RBAC scheduling and backup contracts passed."
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
