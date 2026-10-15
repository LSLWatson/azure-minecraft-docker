# Minecraft Bedrock on Azure Container Instances

[Bicep](infra/main.bicep) deploys [itzg/minecraft-bedrock-server](https://github.com/itzg/docker-minecraft-bedrock-server) on Azure Container Instances (ACI), with persistent Azure Files worlds, a portal dashboard, alerts, optional scheduled start/stop, and optional Azure Files backups. Deployment and management use Azure CLI and named Azure deployment outputs. Terraform, its state/backend, Java containers, Java plugins and RCON are no longer part of the solution.

## Networking and player limit

Current Bedrock Dedicated Server releases use [NetherNet](https://mojang.github.io/bedrock-protocol-docs/guides/nether-net-onboarding-guide/):

| Purpose | Default ports |
|---------|---------------|
| Signaling and server status | TCP 19132 |
| Gameplay | UDP 19140-19143 |

ACI has a [hard limit of five exposed ports per IP](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-resource-and-quota-limits#unchangeable-hard-limits). Each instance therefore supports **one to four concurrent players**, configured with `maxPlayers`, with one UDP port per player. Increasing CPU or memory does not lift this limit. Older RakNet-only releases are not supported.

At startup, a wrapper resolves the ACI public DNS name and advertises the **inbound** IP and UDP range, not the potentially different outbound IP. It then runs the image's normal entrypoint. The ACI hostname uses the predictable `Unsecure` DNS label policy; optional vanity DNS is supported.

## Deployment

Prerequisites: Azure CLI with Bicep CLI 0.41 or newer, PowerShell 7, .NET 8 SDK (or a newer SDK supporting it), and resource-group Owner permissions for locks/custom roles/role assignments. An existing custom DNS zone also needs record-write permission. The deployment script publishes monitoring code using Azure CLI; Functions Core Tools v4 is only needed for local function development.

```powershell
az login
az account set --subscription <subscription-id>
az bicep install
```

### Your existing Azure deployment

Discover existing resource names directly from Azure, without a state file:

```powershell
.\scripts\export_existing.ps1 -ResourceGroup <existing-resource-group>
.\scripts\deploy.ps1 -ResourceGroup <existing-resource-group> -ParameterFile .\infra\adopted.parameters.json
```

The exporter is **read-only in Azure**. Review the resulting local parameter file, especially players, world shares, DNS, schedules, access and backup settings. It references the existing world storage account without redeclaring it. Existing Bedrock shares are referenced unchanged; if only Java is present, a separate Bedrock share is selected or created. Java worlds are not converted. Existing function storage/content settings are preserved where a monitoring function is found. An empty allowlist denies every player.

The exporter deliberately leaves new schedules disabled and does not infer custom DNS/access preferences. Existing Azure role assignments are retained; assignment GUIDs are recorded so you can add the corresponding principal arrays without duplicate assignments.

**Incremental deployment does not delete omitted resources.** Old Java containers/shares, API connections, service principals and schedules remain until explicitly removed or disabled in Azure. The same applies when an optional Bicep feature is turned off. Disable obsolete schedules before enabling replacement schedules; don't assume a `false` flag turns off already-deployed workflows. No automatic teardown, world deletion or backup purge is provided.

### A new deployment

Create/select a resource group and configure a local parameter file:

```powershell
az group create --name minecraft-bedrock-dev --location westeurope
Copy-Item .\infra\config.example.bicepparam .\infra\config.bicepparam
.\scripts\deploy.ps1 -ResourceGroup minecraft-bedrock-dev
```

The default action validates and previews changes without applying them. The preview displays resource IDs/change types, not resolved mount keys or connection strings. Review the parameter file alongside it; use the Azure portal for detailed resource comparison if needed.

After reviewing the preview:

```powershell
.\scripts\deploy.ps1 -ResourceGroup <resource-group> -ParameterFile <parameter-file> -Mode Apply
```

Apply previews again, requires typing the group name, uses **Incremental** mode, publishes the monitoring function, and checks Bedrock signaling readiness. `-ApproveChanges` explicitly bypasses the interactive confirmation for approved automation. `-SkipFunctionPublish` is for infrastructure-only changes; publish separately with `deploy_functions.ps1` when necessary. A container configuration change can restart it; plan for gameplay downtime even when persistent world storage is unchanged.

Keep the storage account, suffix and per-instance share names stable between deployments. For adoption use `createStorageAccount=false` and `createDataShare=false` for existing worlds; these are references, not storage replacements. `createFunctionStorageAccount=false` and `adoptFunction=true` preserve existing monitoring storage and deployment settings. Storage and world shares must be in the selected group and region.

The named deployment defaults to `minecraft-bedrock`. Management scripts accept `-ResourceGroup` and `-DeploymentName`; `AZURE_RESOURCE_GROUP` selects the default group. Dot-sourced helpers also honor `AZURE_DEPLOYMENT_NAME`. If a deployment fails and has no outputs, resolve it or select an earlier successful deployment rather than guessing resource names.

## Configuration

The default `minecraftConfig` creates a `primary` instance. Pin the server release with `VERSION` and the independent Docker image version with `imageTag`.

```bicep
using './main.bicep'

param minecraftConfig = [
  {
    name: 'primary'
    maxPlayers: 4
    environmentVariables: {
      VERSION: 'LATEST'
      SERVER_NAME: 'Our Bedrock server'
      LEVEL_NAME: 'Bedrock level'
      GAMEMODE: 'creative'
      DIFFICULTY: 'easy'
    }
  }
]
param minecraftUsers = ['Example Player:2535453759792258']
param minecraftOps = ['2535453759792258']
```

Use your own Xbox gamertags and numeric XUIDs. Allowlist entries require `Gamertag:XUID`; operators/members require XUID strings of at least 16 digits. Operators also need matching allowlist entries. `allowOpsOnly=true` restricts a server's allowlist to operators and requires at least one operator.

The allowlist is enabled by default: an empty `minecraftUsers` **denies all players**. Set `allowListEnabled=false` deliberately to allow other authenticated players. `ONLINE_MODE` defaults to true. `VERSION=LATEST` updates the server at container startup.

Configure networking and permissions through typed instance settings (`serverPort`, `udpPortStart`, `maxPlayers`, `allowListEnabled`, `allowOpsOnly`), not environment overrides. [types.bicep](infra/types.bicep) lists supported Bedrock environment settings; reserved settings and Java variables are rejected. Parameters and additional validation reject invalid player limits, overflowing UDP ranges, duplicate names, invalid schedule times and invalid player IDs.

`enableAutoStartStop` uses managed identities with narrowly scoped ACI start/stop permission, not a client secret or API connection. Per-instance `startTime`, `stopTime`, `startTimeWeekend`, `stopTimeWeekend` are `HH:mm`; empty disables that schedule. Weekends default to weekday times. `timezone` is a Windows timezone for schedules/backups; `minecraftTimezone` is an IANA container timezone.

`vanityDnsZoneId` references an existing Azure DNS zone. `vanityHostnamePrefix` is unique per instance; non-production environments append `environment` to the record name. `enableBackup` enables Azure Files snapshot protection with daily/weekly/monthly/yearly retention and backup diagnostics. The vault now enables soft delete. If initial share discovery fails, wait for Azure registration and retry the same incremental deployment; do not delete backup data to force discovery.

Contributor/operator/reader principal arrays provide Azure RBAC access, independently of Xbox game permissions. Monitoring includes memory/CPU alerts, failed-container events, inaccessible-server alerts, optional custom log alerts, ARM-role notifications and optional email/mobile push via `provisionerEmailAddress`.

Set `customAlertQuery` to create a custom log alert and `customAlertEnabled=true` to enable it. `customAlertSubject` overrides its email subject; an empty value uses "Custom alert".

### Changing or importing a world

Worlds live in the persistent share under `worlds/<LEVEL_NAME>`. Change `environmentVariables.LEVEL_NAME` and apply to select another folder; an absent folder creates a new world. `LEVEL_SEED` only affects newly generated worlds, so changing the seed alone does not regenerate an existing world.

To import a Bedrock map, stop the target ACI group, extract the `.mcworld` archive, and upload it with the Azure portal or Storage Explorer into `worlds/<LEVEL_NAME>`. That folder should directly contain `level.dat` and `db`, without an extra directory level. Set that `LEVEL_NAME` and redeploy/restart. Existing world folders remain, so you can switch back by restoring their names. Behavior/resource packs can be stored in `/data`; Java plugins/modpacks are not supported.

See [multi-instance.md](multi-instance.md) for separate worlds and per-instance naming.

## Connecting and management

Inspect the connection details:

```powershell
az deployment group show --resource-group <resource-group> --name minecraft-bedrock --query properties.outputs.minecraft.value
$env:AZURE_RESOURCE_GROUP = '<resource-group>'
.\scripts\start_minecraft_cli.ps1 -Command "list" -ShowLog
.\scripts\tail_minecraft_log.ps1 -ConfigurationName primary
.\scripts\manage_snapshots.ps1 -Create
```

In a Bedrock client, choose **Play > Servers > Add Server**, then enter the hostname and signaling port (default 19132). Some consoles do not offer custom-server entry.

Console commands use `send-command`; results appear in container logs. Examples include `say Server restarting soon` and `gamerule dofiretick false`. There is no RCON session.

The ACI liveness probe and external monitor query `http://<host>:<port>/v1/join`. The monitor validates Bedrock JSON and emits `TestResult`/`Connected` telemetry. This verifies signaling/server responsiveness, **not UDP gameplay**; confirm that using a real Bedrock client after deployment. Player/dashboard queries parse gamertags with spaces and separate container instances.

The default portal dashboard retains storage, monitoring, player, backup and scheduling panels. To preserve portal customizations, run `templatize_dashboard.ps1` and set `dashboardProperties = loadJsonContent('./dashboard.custom.json')` in the parameter file. Exported custom properties contain environment-specific resource IDs.

## Platform security constraints

The selected public ACI architecture requires public game ports and publicly reachable Azure Files storage. [ACI SMB mounts require a storage account key and do not support managed-identity authentication](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-volume-azure-files). Linux Consumption function content storage also uses a runtime-generated key connection string and public endpoints. These are deliberate platform exceptions, not credentials to commit or output. New accounts require HTTPS/TLS 1.2, disable anonymous blob access and use infrastructure encryption; existing accounts are referenced without mutation.

Deployment outputs never expose keys. Snapshot operations hold keys temporarily in an environment variable, not CLI arguments. `configure_functions_client.ps1` explicitly writes real app settings to the ignored `functions/local.settings.json`; keep it private. Local parameter files/custom dashboards are ignored. Restrict Azure monitoring access because logs contain player identifiers.

Standard LRS storage and a Y1 Consumption monitoring plan retain the original low-cost design; they are not zone-redundant. Generic web-app policies for multiple always-on instances, HTTP health routes and incoming client certificates do not directly fit this timer-only Consumption function. Static scanners also have limited coverage of symbolic ARM templates and runtime module parameters; their output is not a substitute for live Azure validation or a subscription security assessment.

## CI and local checks

```powershell
az bicep build --file .\infra\main.bicep --stdout
pwsh -File .\tests\infra.tests.ps1
pwsh -File .\tests\scripts.tests.ps1
pwsh -File .\tests\adoption.tests.ps1
dotnet test .\tests\functions\functions.tests.csproj
```

CI performs offline Bicep/parameter/ARM-contract, management/startup and monitor checks without Azure credentials. Infrastructure fixtures assert both accepted and rejected parameters, then restore the prior native exit status so expected compiler rejections do not fail CI's PowerShell wrapper. The separate deployment workflow is **manual only**, defaults to preview, uses GitHub-to-Azure OIDC, and never destroys infrastructure. Configure `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` as GitHub environment variables and require approval on your production environment. A workflow parameter file must be reviewed and present in the checkout; do not commit sensitive settings.
