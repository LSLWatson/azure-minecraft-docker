#!/usr/bin/env pwsh
#Requires -Version 7
param(
    [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
    [string]$DeploymentName = "minecraft-bedrock",
    [switch]$Create
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "functions.ps1")
Set-DeploymentContext -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
$storageAccount = Get-DeploymentOutput "storage_account"
$shares = @(Get-DeploymentOutput "storage_data_share")
if ($shares.Count -eq 0) { throw "No world shares found in deployment outputs." }
# Keep the key out of process arguments and deployment outputs.
$previousKey = $env:AZURE_STORAGE_KEY
$previousConnection = $env:AZURE_STORAGE_CONNECTION_STRING
$previousSas = $env:AZURE_STORAGE_SAS_TOKEN
try {
    $env:AZURE_STORAGE_CONNECTION_STRING = $null
    $env:AZURE_STORAGE_SAS_TOKEN = $null
    $env:AZURE_STORAGE_KEY = Invoke-AzCli -Arguments @("storage", "account", "keys", "list", "--resource-group", $ResourceGroup,
        "--account-name", $storageAccount, "--query", "[0].value", "--output", "tsv")
    foreach ($share in $shares) {
        if ($Create) {
            $null = Invoke-AzCli -Arguments @("storage", "share", "snapshot", "--name", $share, "--account-name", $storageAccount, "--output", "none")
            Write-Host "Created a snapshot of '$share'."
        }
        Invoke-AzCli -Arguments @("storage", "share", "list", "--include-snapshots", "--account-name", $storageAccount,
            "--query", "[?name=='$share'].{Name:name,Snapshot:snapshot}", "--output", "table")
    }
} finally {
    $env:AZURE_STORAGE_KEY = $previousKey
    $env:AZURE_STORAGE_CONNECTION_STRING = $previousConnection
    $env:AZURE_STORAGE_SAS_TOKEN = $previousSas
}
