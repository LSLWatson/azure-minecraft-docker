#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"
if (!(Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI is required in the Codespace image." }
if (!(Get-Command dotnet -ErrorAction SilentlyContinue)) { throw ".NET SDK is required in the Codespace image." }
az bicep install
if ($LASTEXITCODE -ne 0) { throw "Bicep installation failed." }
$template = Join-Path $PSScriptRoot "profile.ps1"
if (!(Test-Path $Profile)) {
    $null = New-Item -ItemType Directory -Force (Split-Path $Profile -Parent)
    Copy-Item $template $Profile
}
