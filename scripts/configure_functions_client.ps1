#!/usr/bin/env pwsh
#Requires -Version 7
param(
    [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
    [string]$DeploymentName = "minecraft-bedrock",
    [string]$ConfigurationName = "primary"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "functions.ps1")
Set-DeploymentContext -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
$minecraft = Get-MinecraftInstance $ConfigurationName
$settings = Invoke-AzCli -Arguments @("functionapp", "config", "appsettings", "list", "--resource-group", $ResourceGroup,
    "--name", $minecraft.function_name, "--output", "json") -Json
$values = @{}
foreach ($setting in $settings) { $values[$setting.name] = $setting.value }
$values["MINECRAFT_FQDN"] = $minecraft.minecraft_server_fqdn
$values["MINECRAFT_PORT"] = "$($minecraft.minecraft_server_port)"
$file = Join-Path $PSScriptRoot ".." "functions" "local.settings.json"
@{ IsEncrypted = $false; Values = $values } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding utf8
Write-Warning "Saved real Azure app settings to '$file'. Keep this ignored file private and remove it when no longer needed."
