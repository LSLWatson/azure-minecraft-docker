#Requires -Version 7
$ErrorActionPreference = "Stop"
$temporary = Join-Path ([IO.Path]::GetTempPath()) "bedrock-adoption-test-$([guid]::NewGuid())"
$null = New-Item $temporary -ItemType Directory
$global:BedrockAdoptionFixture = $false
$global:AdoptionOperations = [System.Collections.Generic.List[string]]::new()
$groupId = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/Minecraft-test-abcd"

function global:az {
    $global:LASTEXITCODE = 0
    $operation = $args[0..([Math]::Min(3, $args.Count - 1))] -join " "
    $global:AdoptionOperations.Add($operation)
    switch -Regex ($operation) {
        '^account show' { return '{"tenantId":"00000000-0000-0000-0000-000000000002"}' }
        '^group show' {
            return (@{ id = $groupId; location = "westeurope"; tags = @{ environment = "dev"; suffix = "abcd" } } | ConvertTo-Json -Depth 10)
        }
        '^resource list' {
            return (@(
                @{ type = "Microsoft.ContainerInstance/containerGroups"; name = "minecraft-test-abcd-primary"; id = "$groupId/providers/Microsoft.ContainerInstance/containerGroups/minecraft-test-abcd-primary" },
                @{ type = "Microsoft.Storage/storageAccounts"; name = "minecraftstorabcd" },
                @{ type = "Microsoft.Storage/storageAccounts"; name = "mcfunctionstorage" },
                @{ type = "Microsoft.Web/sites"; name = "Minecraft-test-abcd-primary-ping-test" }
            ) | ConvertTo-Json -Depth 10)
        }
        '^container show' {
            $image = if ($global:BedrockAdoptionFixture) { "itzg/minecraft-bedrock-server:latest" } else { "itzg/minecraft-server:latest" }
            $share = if ($global:BedrockAdoptionFixture) { "minecraft-aci-bedrock-data-abcd" } else { "minecraft-aci-data-abcd" }
            return (@{
                name = "minecraft-test-abcd-primary"
                tags = @{ "configuration-name" = "primary" }
                ipAddress = @{ dnsNameLabel = "minecraft-test-abcd-primary" }
                containers = @(@{ name = "minecraft"; image = $image; volumeMounts = @(@{ name = "data"; mountPath = "/data" });
                    environmentVariables = @(
                        @{ name = "ALLOW_LIST_USERS"; value = "Gamertag With Spaces:2535453759792258" },
                        @{ name = "OPS"; value = "2535453759792258" },
                        @{ name = "LEVEL_NAME"; value = "Existing world" },
                        @{ name = "MAX_PLAYERS"; value = "4" }
                    ) })
                volumes = @(@{ name = "data"; azureFile = @{ storageAccountName = "minecraftstorabcd"; shareName = $share; storageAccountKey = "MOUNT_KEY_MUST_NOT_EXPORT" } })
            } | ConvertTo-Json -Depth 20)
        }
        '^storage account show' {
            return '{"location":"westeurope","tags":{"suffix":"abcd"}}'
        }
        '^storage share-rm list' {
            $share = if ($global:BedrockAdoptionFixture) { "minecraft-aci-bedrock-data-abcd" } else { "minecraft-aci-data-abcd" }
            return (@(@{ name = $share }) | ConvertTo-Json -Depth 3 -AsArray)
        }
        '^functionapp config appsettings list' {
            return "DefaultEndpointsProtocol=https;AccountName=mcfunctionstorage;AccountKey=FUNCTION_KEY_MUST_NOT_EXPORT;EndpointSuffix=core.windows.net"
        }
        '^role assignment list' { return "[]" }
        default { throw "Exporter attempted an unexpected or mutating Azure operation: $operation" }
    }
}

try {
    foreach ($bedrock in @($false, $true)) {
        $global:BedrockAdoptionFixture = $bedrock
        $file = Join-Path $temporary "adopted-$bedrock.json"
        & (Join-Path $PSScriptRoot ".." "scripts" "export_existing.ps1") -ResourceGroup "Minecraft-test-abcd" -OutputFile $file
        $raw = Get-Content $file -Raw
        $parameters = ($raw | ConvertFrom-Json -AsHashtable).parameters
        if ($raw -match "MUST_NOT_EXPORT") { throw "Exporter leaked a storage key." }
        if ($parameters.createStorageAccount.value -or $parameters.storageAccountName.value -ne "minecraftstorabcd") {
            throw "Exporter must reference existing world storage."
        }
        $config = $parameters.minecraftConfig.value[0]
        if ($config.createFunctionStorageAccount -or !$config.adoptFunction -or $config.functionStorageAccountName -ne "mcfunctionstorage") {
            throw "Existing monitoring storage and settings must be preserved."
        }
        if ($bedrock) {
            if ($config.createDataShare -or $config.environmentVariables.LEVEL_NAME -ne "Existing world" -or
                $parameters.minecraftUsers.value[0] -ne "Gamertag With Spaces:2535453759792258") { throw "Existing Bedrock worlds/players must be preserved." }
        } elseif (!$config.createDataShare -or $config.dataShareName -eq "minecraft-aci-data-abcd") {
            throw "Java adoption must select a separate Bedrock world share."
        }
    }
    Write-Host "Read-only Azure adoption, world/function storage preservation and key-exclusion fixtures passed."
} finally {
    Remove-Item Function:\az
    Remove-Variable BedrockAdoptionFixture, AdoptionOperations -Scope Global
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
