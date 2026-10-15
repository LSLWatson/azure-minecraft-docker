#!/usr/bin/env pwsh
#Requires -Version 7
param(
    [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
    [string]$DeploymentName = "minecraft-bedrock",
    [string]$InputFile,
    [string]$OutputFile = (Join-Path $PSScriptRoot ".." "infra" "dashboard.custom.json"),
    [switch]$Force
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "functions.ps1")
if ((Test-Path $OutputFile) -and !$Force) { throw "'$OutputFile' already exists; use -Force to replace it." }
if ($InputFile) {
    $dashboard = Get-Content $InputFile -Raw | ConvertFrom-Json -AsHashtable
    $properties = $dashboard.properties ?? $dashboard
} else {
    Set-DeploymentContext -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
    $dashboard = Invoke-AzCli -Arguments @("resource", "show", "--ids", (Get-DeploymentOutput "dashboard_id"), "--output", "json") -Json
    $properties = $dashboard.properties
}
if (!$properties.Contains("lenses") -or !$properties.Contains("metadata")) { throw "Input is not valid portal dashboard properties." }
$properties | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputFile -Encoding utf8
Write-Host "Saved '$OutputFile'. Set dashboardProperties = loadJsonContent('./dashboard.custom.json') in the Bicep parameter file. Resource IDs remain specific to this environment."
