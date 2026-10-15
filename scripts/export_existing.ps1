#!/usr/bin/env pwsh
#Requires -Version 7
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$StorageAccountName,
    [string]$OutputFile = (Join-Path $PSScriptRoot ".." "infra" "adopted.parameters.json"),
    [switch]$Force
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "functions.ps1")
if ((Test-Path $OutputFile) -and !$Force) { throw "'$OutputFile' already exists; use -Force to replace it." }
AzLogin
$group = Invoke-AzCli -Arguments @("group", "show", "--name", $ResourceGroup, "--output", "json") -Json
$resources = @(Invoke-AzCli -Arguments @("resource", "list", "--resource-group", $ResourceGroup, "--output", "json") -Json)
$containers = @()
foreach ($resource in $resources | Where-Object type -eq "Microsoft.ContainerInstance/containerGroups") {
    $container = Invoke-AzCli -Arguments @("container", "show", "--ids", $resource.id, "--output", "json") -Json
    if (@($container.containers | Where-Object name -eq "minecraft").Count -gt 0) { $containers += $container }
}
$bedrock = @($containers | Where-Object { @($_.containers | Where-Object { $_.image -match 'bedrock' }).Count -gt 0 })
if (!$StorageAccountName) {
    $mountedAccounts = @($containers | ForEach-Object { $_.volumes } | Where-Object { $_.azureFile } |
        ForEach-Object { $_.azureFile.storageAccountName } | Sort-Object -Unique)
    if ($mountedAccounts.Count -eq 1) { $StorageAccountName = $mountedAccounts[0] }
    else {
        $accounts = @($resources | Where-Object { $_.type -eq "Microsoft.Storage/storageAccounts" -and $_.name -like "minecraftstor*" })
        if ($accounts.Count -ne 1) { throw "Cannot identify a unique world storage account. Supply -StorageAccountName." }
        $StorageAccountName = $accounts[0].name
    }
}
$account = Invoke-AzCli -Arguments @("storage", "account", "show", "--name", $StorageAccountName, "--resource-group", $ResourceGroup, "--output", "json") -Json
$suffix = $account.tags.suffix ?? $group.tags.suffix
if (!$suffix -and $StorageAccountName -match '^minecraftstor([a-z0-9]{4,11})$') { $suffix = $Matches[1] }
if (!$suffix) { throw "No stable resource suffix found. Create a parameter file with the existing storage account and explicit share names." }
$shares = @(Invoke-AzCli -Arguments @("storage", "share-rm", "list", "--storage-account", $StorageAccountName, "--resource-group", $ResourceGroup, "--output", "json") -Json)
$configs = @()
$users = @()
$ops = @()
$members = @()
$minecraftTimezone = $null
if ($bedrock.Count -eq 0) {
    # Java worlds are not compatible; preserve their share and create a separate Bedrock share.
    $share = "minecraft-aci-bedrock-data-$suffix"
    $configs += @{ name = "primary"; dataShareName = $share; createDataShare = $share -notin @($shares.name) }
    Write-Warning "No Bedrock container found. The exported deployment references existing storage and uses a separate Bedrock share. Existing non-Bedrock resources are not deleted."
} else {
    foreach ($container in $bedrock) {
        $name = $container.tags["configuration-name"]
        if (!$name -and $container.name -match '-bedrock-(.+)$') { $name = $Matches[1] }
        if (!$name) { throw "Cannot determine the configuration name for '$($container.name)'." }
        $server = @($container.containers | Where-Object name -eq "minecraft")[0]
        $mount = @($server.volumeMounts | Where-Object mountPath -eq "/data")[0]
        $volume = @($container.volumes | Where-Object name -eq $mount.name)[0]
        if (!$volume.azureFile -or $volume.azureFile.storageAccountName -ne $StorageAccountName) {
            throw "Instance '$name' does not mount /data from the selected storage account."
        }
        $settings = @{}
        foreach ($setting in $server.environmentVariables) {
            if ($setting.value) { $settings[$setting.name] = $setting.value }
        }
        if ($settings.TZ) {
            if ($minecraftTimezone -and $minecraftTimezone -ne $settings.TZ) { throw "Instances have different container timezones; configure a shared minecraftTimezone before exporting." }
            $minecraftTimezone = $settings.TZ
        }
        $userList = @($settings.ALLOW_LIST_USERS -split ',' | Where-Object { $_ })
        $operatorList = @($settings.OPS -split ',' | Where-Object { $_ })
        $memberList = @($settings.MEMBERS -split ',' | Where-Object { $_ })
        if ($configs.Count -gt 0 -and ((Compare-Object $users $userList) -or (Compare-Object $ops $operatorList) -or (Compare-Object $members $memberList))) {
            throw "Instances have different allowlists or permissions. This solution uses shared player inputs; reconcile them before exporting."
        }
        $users = $userList
        $ops = $operatorList
        $members = $memberList
        $image = $server.image
        $imageTag = ""
        $lastSlash = $image.LastIndexOf('/')
        $colon = $image.LastIndexOf(':')
        if ($colon -gt $lastSlash) { $imageTag = $image.Substring($colon + 1); $image = $image.Substring(0, $colon) }
        $envSettings = @{}
        foreach ($key in $script:BedrockEnvironmentKeys) { if ($settings.Contains($key)) { $envSettings[$key] = $settings[$key] } }
        $configs += @{
            name = $name
            containerName = $container.name.ToLowerInvariant()
            dnsNameLabel = $container.ipAddress.dnsNameLabel
            dataShareName = $volume.azureFile.shareName
            createDataShare = $false
            image = $image
            imageTag = $imageTag
            maxPlayers = if ($settings.MAX_PLAYERS) { [int]$settings.MAX_PLAYERS } else { 4 }
            serverPort = if ($settings.SERVER_PORT) { [int]$settings.SERVER_PORT } else { 19132 }
            udpPortStart = if ($settings.SERVER_UDP_PORT_START) { [int]$settings.SERVER_UDP_PORT_START } else { 19140 }
            allowListEnabled = $settings.ALLOW_LIST -ne "false"
            environmentVariables = $envSettings
        }
    }
}
foreach ($config in $configs) {
    $appName = "$ResourceGroup-$($config.name)-ping-test"
    $app = @($resources | Where-Object { $_.type -eq "Microsoft.Web/sites" -and $_.name -ieq $appName })
    if ($app.Count -eq 1) {
        # Read settings in memory to discover the account, never export the connection string.
        $connection = Invoke-AzCli -Arguments @("functionapp", "config", "appsettings", "list", "--resource-group", $ResourceGroup,
            "--name", $app[0].name, "--query", "[?name=='AzureWebJobsStorage'].value | [0]", "--output", "tsv")
        if ($connection -notmatch '(?:^|;)AccountName=([^;]+)(?:;|$)') { throw "Cannot identify storage for '$appName'." }
        $config.functionName = $app[0].name.ToLowerInvariant()
        $config.functionStorageAccountName = $Matches[1]
        if ($config.functionStorageAccountName -notin @($resources | Where-Object type -eq "Microsoft.Storage/storageAccounts" | ForEach-Object name)) {
            throw "Function storage '$($config.functionStorageAccountName)' is not in the selected resource group."
        }
        $config.createFunctionStorageAccount = $false
        $config.adoptFunction = $true
        $connection = $null
    }
}
$vaults = @($resources | Where-Object type -eq "Microsoft.RecoveryServices/vaults")
if ($vaults.Count -gt 1) { throw "Multiple backup vaults found; configure backups manually." }
$parameters = @{
    location = @{ value = $account.location }
    environment = @{ value = $group.tags.environment ?? $group.tags.workspace ?? "dev" }
    resourceSuffix = @{ value = $suffix }
    storageAccountName = @{ value = $StorageAccountName }
    createStorageAccount = @{ value = $false }
    minecraftConfig = @{ value = $configs }
    minecraftUsers = @{ value = $users }
    minecraftOps = @{ value = $ops }
    minecraftMembers = @{ value = $members }
    minecraftTimezone = @{ value = $minecraftTimezone ?? "Europe/Amsterdam" }
    provisionerEmailAddress = @{ value = $group.tags["provisioner-email"] ?? $account.tags["provisioner-email"] ?? "" }
    enableAutoStartStop = @{ value = $false }
    enableBackup = @{ value = $vaults.Count -eq 1 }
}
if ($vaults.Count -eq 1) {
    $vaultName = $vaults[0].name
    $policies = @(Invoke-AzCli -Arguments @("backup", "policy", "list", "--resource-group", $ResourceGroup, "--vault-name", $vaultName,
        "--query", "[?properties.backupManagementType=='AzureStorage']", "--output", "json") -Json)
    if ($policies.Count -ne 1) { throw "Cannot identify a unique Azure Files backup policy; configure backups manually." }
    $parameters.backupVaultName = @{ value = $vaultName }
    $parameters.backupPolicyName = @{ value = $policies[0].name }
    if ($policies[0].properties.timeZone) { $parameters.timezone = @{ value = $policies[0].properties.timeZone } }
}
$assignments = @(Invoke-AzCli -Arguments @("role", "assignment", "list", "--scope", $group.id, "--all", "--output", "json") -Json)
$assignmentNames = @{}
foreach ($assignment in $assignments) {
    $assignmentNames["$($assignment.scope)|$($assignment.principalId)|$($assignment.roleDefinitionId)"] = $assignment.name
}
$parameters.roleAssignmentNames = @{ value = $assignmentNames }
Set-DeploymentContext -ResourceGroup $ResourceGroup
Test-BedrockConfiguration $parameters
@{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = $parameters
} | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputFile -Encoding utf8
Write-Host "Saved '$OutputFile'. Review players, DNS, schedules, access and backup settings before what-if. No Azure resources were changed."
Write-Warning "Incremental deployment retains resources not declared in Bicep, including old containers, API connections and schedules. Disable obsolete schedules before enabling new ones."
