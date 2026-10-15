# Multiple Bedrock instances

Each `minecraftConfig` entry creates a separate ACI group, public endpoint, persistent world share, monitoring function, and optional start/stop schedules and backup protection.

```bicep
using './main.bicep'

param minecraftConfig = [
  {
    name: 'primary'
    maxPlayers: 4
    vanityHostnamePrefix: 'minecraft'
    environmentVariables: { GAMEMODE: 'survival', LEVEL_NAME: 'Survival world' }
  }
  {
    name: 'creative'
    maxPlayers: 4
    vanityHostnamePrefix: 'creative'
    environmentVariables: { GAMEMODE: 'creative', LEVEL_NAME: 'Creative world' }
  }
]
```

Instance names and explicit container/share/function/DNS names must be unique. Use distinct `vanityHostnamePrefix` values with custom DNS. Each instance can use the same ports because it has its own IP, but each remains limited to four concurrent players by ACI's five-port limit. Worlds are separate; Xbox allowlist/permission inputs apply to all instances.

The `minecraft` deployment output is an array indexed by `configuration_name`, with connection/container/share/function details. Management commands accept `-ConfigurationName`; deployment readiness checks visit every instance and fail if any is unreachable.

To adopt existing worlds, specify their exact `dataShareName` and `createDataShare=false`, and set the existing `storageAccountName` with `createStorageAccount=false`. Keep names stable; removing an entry from an incremental deployment does **not** delete or stop that instance or its schedules. Manage intentional retirement explicitly in Azure.
