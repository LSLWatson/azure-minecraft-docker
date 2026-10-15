#!/usr/bin/env pwsh
#Requires -Version 7
param(
    [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
    [string]$DeploymentName = "minecraft-bedrock"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "functions.ps1")
Set-DeploymentContext -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
$functionNames = @(Get-DeploymentOutput "function_name")
if ($functionNames.Count -eq 0) { throw "No monitoring functions found in deployment outputs." }
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "bedrock-functions-$([guid]::NewGuid())"
$null = New-Item $temporary -ItemType Directory
try {
    $publish = Join-Path $temporary "publish"
    dotnet publish (Join-Path $PSScriptRoot ".." "functions" "functions.csproj") --configuration Release --output $publish --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw "Monitoring function build failed ($LASTEXITCODE)." }
    $zip = Join-Path $temporary "functions.zip"
    Compress-Archive -Path (Join-Path $publish "*") -DestinationPath $zip
    foreach ($name in $functionNames) {
        Write-Host "Publishing monitoring code to '$name'..."
        $null = Invoke-AzCli -Arguments @("functionapp", "deployment", "source", "config-zip", "--resource-group", $ResourceGroup,
            "--name", $name, "--src", $zip, "--subscription", (Get-DeploymentOutput "subscription_guid"), "--output", "none")
    }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
