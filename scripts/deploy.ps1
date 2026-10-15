#!/usr/bin/env pwsh
#Requires -Version 7
param(
    [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
    [string]$DeploymentName = "minecraft-bedrock",
    [string]$ParameterFile = (Join-Path $PSScriptRoot ".." "infra" "config.bicepparam"),
    [ValidateSet("Build", "WhatIf", "Apply")][string]$Mode = "WhatIf",
    [switch]$ApproveChanges,
    [switch]$SkipFunctionPublish
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "functions.ps1")
$template = Join-Path $PSScriptRoot ".." "infra" "main.bicep"
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "bedrock-deploy-$([guid]::NewGuid())"
$null = New-Item $temporary -ItemType Directory
try {
    $compiled = Join-Path $temporary "main.json"
    $compiledParameters = Join-Path $temporary "parameters.json"
    $null = Invoke-AzCli -Arguments @("bicep", "build", "--file", $template, "--outfile", $compiled)
    if (!(Test-Path $ParameterFile -PathType Leaf)) { throw "Parameter file '$ParameterFile' is missing. Copy infra/config.example.bicepparam or run export_existing.ps1." }
    if ([IO.Path]::GetExtension($ParameterFile) -eq ".bicepparam") {
        $null = Invoke-AzCli -Arguments @("bicep", "build-params", "--file", $ParameterFile, "--outfile", $compiledParameters)
    } elseif ([IO.Path]::GetExtension($ParameterFile) -eq ".json") {
        Copy-Item $ParameterFile $compiledParameters
    } else { throw "ParameterFile must be .bicepparam or ARM parameters .json." }
    $parameters = Get-Content $compiledParameters -Raw | ConvertFrom-Json -AsHashtable
    $definition = Get-Content $compiled -Raw | ConvertFrom-Json -AsHashtable
    $script:DeploymentResourceGroup = $ResourceGroup
    Test-DeploymentParameters $parameters.parameters $definition
    if ($Mode -eq "Build") { Write-Host "Bicep template and parameters compiled; configuration is valid."; return }
    Set-DeploymentContext -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
    AzLogin
    $null = Invoke-AzCli -Arguments @("group", "show", "--name", $ResourceGroup, "--output", "none")
    $arguments = @("--resource-group", $ResourceGroup, "--name", $DeploymentName, "--mode", "Incremental",
        "--template-file", $compiled, "--parameters", "@$compiledParameters")
    $null = Invoke-AzCli -Arguments (@("deployment", "group", "validate") + $arguments + @("--output", "none"))
    # ResourceIdOnly deliberately avoids displaying resolved mount keys or connection strings.
    $preview = Invoke-AzCli -Arguments (@("deployment", "group", "what-if") + $arguments +
        @("--result-format", "ResourceIdOnly", "--no-pretty-print", "--output", "json")) -Json
    if ($preview.status -ne "Succeeded") { throw "Azure what-if did not succeed: $($preview.error.message)" }
    $preview.changes | Select-Object changeType, resourceId | Format-Table -AutoSize
    if (@($preview.changes | Where-Object changeType -eq "Delete").Count -gt 0) {
        throw "What-if proposes deletion. This deployment path never approves resource deletion."
    }
    if ($Mode -eq "WhatIf") { return }
    if (!$ApproveChanges) {
        $decision = Read-Host "Type the resource group name '$ResourceGroup' to apply the displayed changes"
        if ($decision -cne $ResourceGroup) { throw "Deployment cancelled." }
    }
    if (!$SkipFunctionPublish -and !(Get-Command dotnet -ErrorAction SilentlyContinue)) { throw ".NET SDK is required to publish monitoring code." }
    $null = Invoke-AzCli -Arguments (@("deployment", "group", "create") + $arguments + @("--output", "none"))
    Set-DeploymentContext -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
    if (@(Get-DeploymentOutput "minecraft").Count -gt 0) {
        if (!$SkipFunctionPublish) {
            & (Join-Path $PSScriptRoot "deploy_functions.ps1") -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
        }
        $null = WaitFor-MinecraftServer
    } else {
        Write-Host "No Bedrock instances configured; only shared infrastructure was deployed. Omitted existing instances remain in Azure."
    }
    Write-Host "Deployment '$DeploymentName' completed. Dashboard: $(Get-DeploymentOutput 'dashboard_url')"
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
