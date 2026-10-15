#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Send a Bedrock console command (defaults to listing players)
#> 
#Requires -Version 7

### Arguments
param ( 
    [string]$ResourceGroup=$env:AZURE_RESOURCE_GROUP,
    [string]$DeploymentName="minecraft-bedrock",
    [parameter(mandatory=$false)][string]$Command="list",
    [parameter(mandatory=$false)][switch]$ShowLog,
    [parameter(mandatory=$false)][int]$SleepSeconds=0,
    [parameter(mandatory=$false)][switch]$StartServer=$false,
    [parameter(mandatory=$false)][string]$ConfigurationName="primary"    
)
. (Join-Path $PSScriptRoot functions.ps1)
Set-DeploymentContext -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName

Execute-MinecraftCommand -Command $Command -ShowLog:$ShowLog -SleepSeconds $SleepSeconds -StartServer:$StartServer -ConfigurationName $ConfigurationName