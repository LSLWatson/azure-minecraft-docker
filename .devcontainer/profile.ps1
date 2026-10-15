#!/usr/bin/env pwsh
#Requires -Version 7
Write-Host "From the repository root, copy infra/config.example.bicepparam to infra/config.bicepparam."
Write-Host "Preview: ./scripts/deploy.ps1 -ResourceGroup <existing-group>"
Write-Host "Deploy:  ./scripts/deploy.ps1 -ResourceGroup <existing-group> -Mode Apply"
Write-Host "Use AZURE_RESOURCE_GROUP to select the group for management scripts."
