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
Show-MinecraftLog -Tail -ConfigurationName $ConfigurationName
