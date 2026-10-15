#Requires -Version 7
$script:DeploymentResourceGroup = $env:AZURE_RESOURCE_GROUP
$script:DeploymentContextName = if ($env:AZURE_DEPLOYMENT_NAME) { $env:AZURE_DEPLOYMENT_NAME } else { "minecraft-bedrock" }
$script:DeploymentOutputs = $null
$script:BedrockEnvironmentKeys = @("EULA", "VERSION", "SERVER_NAME", "GAMEMODE", "DIFFICULTY", "ALLOW_CHEATS", "ONLINE_MODE",
    "LEVEL_NAME", "LEVEL_SEED", "LEVEL_TYPE", "VIEW_DISTANCE", "TICK_DISTANCE", "PLAYER_IDLE_TIMEOUT", "MAX_THREADS",
    "DEFAULT_PLAYER_PERMISSION_LEVEL", "TEXTUREPACK_REQUIRED", "CONTENT_LOG_FILE_ENABLED", "CONTENT_LOG_CONSOLE_OUTPUT_ENABLED",
    "CHAT_RESTRICTION", "MC_PACK", "FORCE_WORLD_COPY", "FORCE_PACK_COPY")

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json)
    $result = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI '$($Arguments[0]) $($Arguments[1])' failed with exit code $LASTEXITCODE."
    }
    if ($Json) {
        return ($result | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    }
    return $result
}

function AzLogin {
    if ($env:AZURE_SUBSCRIPTION_ID) {
        $null = Invoke-AzCli -Arguments @("account", "set", "--subscription", $env:AZURE_SUBSCRIPTION_ID)
    }
    $account = & az account show --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Sign in with az login and select the intended subscription before continuing." }
    $account = $account | ConvertFrom-Json
    if ($env:AZURE_TENANT_ID -and $account.tenantId -ne $env:AZURE_TENANT_ID) {
        throw "The active Azure tenant does not match AZURE_TENANT_ID."
    }
}

function Set-DeploymentContext {
    param(
        [string]$ResourceGroup = $script:DeploymentResourceGroup,
        [string]$DeploymentName = $script:DeploymentContextName
    )
    if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
        throw "Specify -ResourceGroup or set AZURE_RESOURCE_GROUP."
    }
    if ([string]::IsNullOrWhiteSpace($DeploymentName)) { throw "Specify a deployment name." }
    $script:DeploymentResourceGroup = $ResourceGroup
    $script:DeploymentContextName = $DeploymentName
    $script:DeploymentOutputs = $null
}

function Get-DeploymentOutputs {
    if ($null -eq $script:DeploymentOutputs) {
        Set-DeploymentContext
        AzLogin
        $deployment = Invoke-AzCli -Arguments @("deployment", "group", "show", "--resource-group", $script:DeploymentResourceGroup,
            "--name", $script:DeploymentContextName, "--output", "json") -Json
        if ($deployment.properties.provisioningState -ne "Succeeded" -or !$deployment.properties.outputs) {
            throw "Deployment '$script:DeploymentContextName' has no successful outputs. Complete the deployment or select another successful deployment."
        }
        $script:DeploymentOutputs = $deployment.properties.outputs
    }
    return $script:DeploymentOutputs
}

function Get-DeploymentOutput {
    param([Parameter(Mandatory)][string]$OutputVariable)
    $outputs = Get-DeploymentOutputs
    if (!$outputs.Contains($OutputVariable)) { throw "Deployment output '$OutputVariable' is missing." }
    return $outputs[$OutputVariable].value
}

function Get-MinecraftConfig {
    $config = @{}
    foreach ($instance in @(Get-DeploymentOutput "minecraft")) {
        $config[$instance.configuration_name] = $instance
    }
    if ($config.Count -eq 0) { throw "No Minecraft instances found in deployment outputs." }
    return $config
}

function Get-MinecraftInstance {
    param([string]$ConfigurationName = "primary")
    $config = Get-MinecraftConfig
    if (!$config.ContainsKey($ConfigurationName)) { throw "Unknown Minecraft configuration '$ConfigurationName'." }
    return $config[$ConfigurationName]
}

function Test-BedrockConfiguration {
    param([Parameter(Mandatory)][hashtable]$Parameters)
    $users = @($Parameters.minecraftUsers.value ?? @())
    $ops = @($Parameters.minecraftOps.value ?? @())
    $members = @($Parameters.minecraftMembers.value ?? @())
    foreach ($user in $users) {
        if ($user -notmatch '^[^:,\r\n]+:[0-9]{16,}$') { throw "Allowlist entries must be Gamertag:XUID with a numeric Xbox XUID of at least 16 digits." }
    }
    foreach ($xuid in @($ops) + @($members)) {
        if ($xuid -notmatch '^[0-9]{16,}$') { throw "Operators and members must be numeric Xbox XUID strings of at least 16 digits." }
    }
    $allowedXuids = @($users | ForEach-Object { ($_ -split ':')[1] })
    foreach ($xuid in $ops) {
        if ($xuid -notin $allowedXuids) { throw "Operator $xuid needs a matching Gamertag:XUID allowlist entry." }
    }
    $configurations = @($Parameters.minecraftConfig.value ?? @(@{ name = "primary" }))
    $names = @()
    $containers = @()
    $shares = @()
    $functionNames = @()
    $functionStorageNames = @()
    $dnsLabels = @()
    $vanityLabels = @()
    foreach ($config in $configurations) {
        foreach ($key in $config.Keys) {
            if ($null -eq $config[$key]) { throw "Configuration '$($config.name)' has a null $key; omit it to use the default." }
        }
        if ($config.name -notmatch '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$' -or $config.name -in $names) {
            throw "Instance names must be unique lowercase letters, numbers and internal hyphens (1-32 characters)."
        }
        $names += $config.name
        $maxPlayers = $config.maxPlayers ?? 4
        $serverPort = $config.serverPort ?? 19132
        $udpStart = $config.udpPortStart ?? 19140
        foreach ($number in @($maxPlayers, $serverPort, $udpStart)) {
            if ($number -isnot [long] -and $number -isnot [int]) { throw "Player limits and ports must be integers." }
        }
        if ($maxPlayers -lt 1 -or $maxPlayers -gt 4) { throw "ACI supports only 1-4 Bedrock players per instance." }
        if ($serverPort -lt 1 -or $serverPort -gt 65535 -or $udpStart -lt 1 -or ($udpStart + $maxPlayers - 1) -gt 65535) {
            throw "TCP and UDP ports must fit within 1-65535."
        }
        foreach ($timeKey in @("startTime", "startTimeWeekend", "stopTime", "stopTimeWeekend")) {
            if ($config.Contains($timeKey) -and $config[$timeKey] -ne "" -and $config[$timeKey] -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') {
                throw "$timeKey must be HH:mm or empty to disable that schedule."
            }
        }
        if ($config.allowOpsOnly -and $ops.Count -eq 0) { throw "allowOpsOnly requires at least one operator." }
        $containerName = $config.containerName ?? "$script:DeploymentResourceGroup-bedrock-$($config.name)".ToLowerInvariant()
        $dnsLabel = $config.dnsNameLabel ?? $containerName
        foreach ($name in @($containerName, $dnsLabel)) {
            if ($name -notmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$') {
                throw "Container and DNS labels must be 1-63 lowercase letters, numbers and internal hyphens; supply explicit names for a long resource group name."
            }
        }
        if ($containerName -in $containers -or $dnsLabel -in $dnsLabels) { throw "Container names and DNS labels must be unique." }
        $containers += $containerName
        $dnsLabels += $dnsLabel
        $suffix = $Parameters.resourceSuffix.value ?? "sssssssssss"
        $defaultShare = if ($config.name -eq "primary") { "minecraft-aci-bedrock-data-$suffix" } else { "minecraft-aci-bedrock-$($config.name)-data-$suffix" }
        $shareName = $config.dataShareName ?? $defaultShare
        if ($shareName -notmatch '^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])$' -or $shareName -match '--' -or $shareName -in $shares) {
            throw "World share names must be unique valid Azure Files names (3-63 characters); supply dataShareName for a long instance name."
        }
        $shares += $shareName
        $functionName = $config.functionName ?? "$script:DeploymentResourceGroup-$($config.name)-ping-test".ToLowerInvariant()
        if ($functionName.Length -gt 60 -or $functionName -notmatch '^[a-z0-9][a-z0-9-]*[a-z0-9]$' -or $functionName -in $functionNames) {
            throw "Function names must be unique valid hostnames of at most 60 characters."
        }
        $functionNames += $functionName
        if ($config.functionStorageAccountName -and $config.functionStorageAccountName -notmatch '^[a-z0-9]{3,24}$') {
            throw "Function storage account names must contain 3-24 lowercase letters or numbers."
        }
        if ($config.functionStorageAccountName) {
            if ($config.functionStorageAccountName -in $functionStorageNames) { throw "Each monitoring function needs a distinct host storage account." }
            $functionStorageNames += $config.functionStorageAccountName
        }
        $vanityLabel = $config.vanityHostnamePrefix ?? $(if ($config.name -eq "primary") { "minecraft" } else { $config.name })
        if ($Parameters.vanityDnsZoneId.value -and ($vanityLabel -in $vanityLabels -or $vanityLabel -notmatch '^[a-z0-9][a-z0-9-]*$')) {
            throw "Vanity DNS prefixes must be unique valid labels."
        }
        $vanityLabels += $vanityLabel
        foreach ($key in ($config.environmentVariables ?? @{}).Keys) {
            if ($key -cnotin $script:BedrockEnvironmentKeys -or $config.environmentVariables[$key] -isnot [string]) {
                throw "Unsupported or reserved Bedrock environment variable '$key'. Use typed instance settings for networking, player limits and permissions."
            }
        }
    }
    if ($Parameters.storageAccountName.value -and $Parameters.storageAccountName.value -notmatch '^[a-z0-9]{3,24}$') {
        throw "World storage account names must contain 3-24 lowercase letters or numbers."
    }
    if ($Parameters.resourceSuffix.value -and $Parameters.resourceSuffix.value -notmatch '^[a-z0-9]{4,11}$') {
        throw "resourceSuffix must contain 4-11 lowercase letters or numbers."
    }
    foreach ($principal in @($Parameters.solutionContributors.value) + @($Parameters.solutionOperators.value) + @($Parameters.solutionReaders.value)) {
        if ($null -ne $principal -and $principal -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw "Access principal IDs must be GUIDs." }
    }
    if ($Parameters.vanityDnsZoneId.value -and $Parameters.vanityDnsZoneId.value -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/dnsZones/[^/]+$') {
        throw "vanityDnsZoneId must be an existing Azure DNS zone resource ID."
    }
}

function Test-ParameterValue {
    param($Value, [hashtable]$Schema, [hashtable]$Definitions, [string]$Path)
    if ($Schema.Contains('$ref')) {
        $Schema = $Definitions[($Schema['$ref'] -split '/')[-1]]
    }
    if ($null -eq $Value) {
        if ($Schema.nullable) { return }
        throw "$Path cannot be null."
    }
    $valid = switch ($Schema.type) {
        "string" { $Value -is [string] }
        "int" { $Value -is [long] -or $Value -is [int] }
        "bool" { $Value -is [bool] }
        "array" { $Value -is [array] }
        "object" { $Value -is [hashtable] }
        default { throw "Unsupported parameter schema type '$($Schema.type)' for $Path." }
    }
    if (!$valid) { throw "$Path must be $($Schema.type)." }
    if ($Schema.Contains("allowedValues") -and $Value -cnotin $Schema.allowedValues) { throw "$Path is not an allowed value." }
    if ($Schema.Contains("minValue") -and $Value -lt $Schema.minValue) { throw "$Path is below its minimum." }
    if ($Schema.Contains("maxValue") -and $Value -gt $Schema.maxValue) { throw "$Path exceeds its maximum." }
    if ($Schema.Contains("minLength") -and $Value.Length -lt $Schema.minLength) { throw "$Path is too short." }
    if ($Schema.Contains("maxLength") -and $Value.Length -gt $Schema.maxLength) { throw "$Path is too long." }
    if ($Schema.type -eq "array" -and $Schema.Contains("items")) {
        foreach ($item in $Value) { Test-ParameterValue $item $Schema.items $Definitions "$Path[]" }
    }
    if ($Schema.type -eq "object" -and $Schema.Contains("properties")) {
        foreach ($name in $Value.Keys) {
            if ($Schema.properties.Contains($name)) { Test-ParameterValue $Value[$name] $Schema.properties[$name] $Definitions "$Path.$name" }
            elseif ($Schema.additionalProperties -eq $false) { throw "Unknown property $Path.$name." }
        }
        foreach ($name in $Schema.properties.Keys) {
            if (!$Value.Contains($name) -and !$Schema.properties[$name].nullable) { throw "$Path.$name is required." }
        }
    }
}

function Test-DeploymentParameters {
    param([hashtable]$Parameters, [hashtable]$Template)
    foreach ($name in $Parameters.Keys) {
        if (!$Template.parameters.Contains($name)) { throw "Unknown Bicep parameter '$name'." }
        if (!$Parameters[$name].Contains("value")) { throw "Parameter '$name' must have an explicit value." }
        Test-ParameterValue $Parameters[$name].value $Template.parameters[$name] $Template.definitions $name
    }
    Test-BedrockConfiguration $Parameters
}

function Get-BedrockServerStatus {
    param(
        [Parameter(Mandatory)][string]$ServerFQDN,
        [Parameter(Mandatory)][ValidateRange(1,65535)][int]$ServerPort,
        [ValidateRange(1,300)][int]$TimeoutSeconds = 5
    )
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try {
        $response = $client.GetAsync("http://${ServerFQDN}:${ServerPort}/v1/join").GetAwaiter().GetResult()
        try {
            $null = $response.EnsureSuccessStatusCode()
            $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            try { $status = $content | ConvertFrom-Json -ErrorAction Stop }
            catch [System.ArgumentException] { throw [System.IO.InvalidDataException]::new("Bedrock returned invalid JSON.", $_.Exception) }
            if ($status.name -isnot [string] -or $status.version -isnot [string] -or [string]::IsNullOrWhiteSpace($status.version) -or
                $status.protocol -isnot [long] -or $status.protocol -le 0 -or
                $status.players -isnot [long] -or $status.players -lt 0 -or
                $status.maxPlayers -isnot [long] -or $status.maxPlayers -lt 1 -or $status.players -gt $status.maxPlayers) {
                throw [System.IO.InvalidDataException]::new("Response is not valid Bedrock NetherNet server status.")
            }
            return $status
        } finally { $response.Dispose() }
    } finally { $client.Dispose() }
}

function WaitFor-MinecraftServer {
    param(
        [ValidateRange(1,3600)][int]$Timeout = 300,
        [ValidateRange(1,1000)][int]$MaxTries = 50,
        [ValidateRange(1,300)][int]$Interval = 10,
        [switch]$StartServer,
        [string]$ConfigurationName
    )
    $config = Get-MinecraftConfig
    $names = if ($ConfigurationName) { @($ConfigurationName) } else { $config.Keys }
    foreach ($name in $names) {
        if (!$config.ContainsKey($name)) { throw "Unknown Minecraft configuration '$name'." }
        $minecraft = $config[$name]
        if ($StartServer) {
            $state = Invoke-AzCli -Arguments @("container", "show", "--ids", $minecraft.container_group_id, "--query",
                "containers[0].instanceView.currentState.state", "--output", "tsv")
            if ($state -notin @("Running", "Waiting")) {
                $null = Invoke-AzCli -Arguments @("container", "start", "--ids", $minecraft.container_group_id, "--output", "none")
            }
        }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $attempts = 0
        do {
            $attempts++
            $status = $null
            try {
                $remaining = [Math]::Max(1, [Math]::Ceiling($Timeout - $timer.Elapsed.TotalSeconds))
                $status = Get-BedrockServerStatus -ServerFQDN $minecraft.minecraft_server_fqdn -ServerPort $minecraft.minecraft_server_port -TimeoutSeconds ([Math]::Min(5, $remaining))
            } catch [System.Net.Http.HttpRequestException], [System.Threading.Tasks.TaskCanceledException], [System.IO.InvalidDataException] {
                Write-Warning "Bedrock status check failed: $($_.Exception.Message)"
            }
            if (!$status -and $timer.Elapsed.TotalSeconds -lt $Timeout -and $attempts -lt $MaxTries) {
                Start-Sleep -Seconds ([Math]::Min($Interval, [Math]::Max(0, $Timeout - $timer.Elapsed.TotalSeconds)))
            }
        } while (!$status -and $timer.Elapsed.TotalSeconds -lt $Timeout -and $attempts -lt $MaxTries)
        if (!$status) { throw "Bedrock did not respond at $($minecraft.minecraft_server_connection) after $attempts attempts." }
        Write-Host "Bedrock $($status.version) at $($minecraft.minecraft_server_connection) ($($status.players)/$($status.maxPlayers) players)."
    }
    return $true
}

function Execute-MinecraftCommand {
    param(
        [string]$Command = "list", [switch]$ShowLog,
        [ValidateRange(0,3600)][int]$SleepSeconds = 0,
        [switch]$StartServer, [string]$ConfigurationName = "primary"
    )
    $null = WaitFor-MinecraftServer -StartServer:$StartServer -ConfigurationName $ConfigurationName
    $minecraft = Get-MinecraftInstance $ConfigurationName
    $null = Invoke-AzCli -Arguments @("container", "exec", "--ids", $minecraft.container_group_id,
        "--container-name", "minecraft", "--exec-command", "send-command $Command")
    if ($ShowLog) { Show-MinecraftLog -ConfigurationName $ConfigurationName }
    if ($SleepSeconds -gt 0) {
        Start-Sleep -Seconds $SleepSeconds
        if ($ShowLog) { Show-MinecraftLog -ConfigurationName $ConfigurationName }
    }
}

function Send-MinecraftMessage {
    param([Parameter(Mandatory)][string]$Message, [switch]$ShowLog, [int]$SleepSeconds = 0, [string]$ConfigurationName = "primary")
    Execute-MinecraftCommand -Command "say $Message" -ShowLog:$ShowLog -SleepSeconds $SleepSeconds -ConfigurationName $ConfigurationName
}

function Show-MinecraftLog {
    param([switch]$Tail, [string]$ConfigurationName = "primary")
    $minecraft = Get-MinecraftInstance $ConfigurationName
    $arguments = @("container", "logs", "--ids", $minecraft.container_group_id, "--container-name", "minecraft")
    if ($Tail) { $arguments += "--follow" }
    Invoke-AzCli -Arguments $arguments
}

function Get-OnlineUsers {
    param([ValidateSet("json", "tsv", "table")][string]$Format = "tsv")
    $query = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) "kusto" "online-players.csl") -Raw
    Invoke-AzCli -Arguments @("monitor", "log-analytics", "query", "--workspace", (Get-DeploymentOutput "log_analytics_workspace_guid"),
        "--analytics-query", $query, "--query", "[].Player", "--output", $Format)
}
