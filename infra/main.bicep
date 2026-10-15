targetScope = 'resourceGroup'

import { MinecraftInstance } from './types.bicep'

@description('Region of the ACI groups, storage and monitoring services.')
param location string = resourceGroup().location
@description('Environment label used for tags and vanity DNS suffixes.')
param environment string = 'dev'
@description('Stable resource suffix. Preserve it when adopting an existing deployment.')
@minLength(4)
@maxLength(11)
param resourceSuffix string = take(uniqueString(resourceGroup().id), 11)
@description('Existing world storage account name, or a globally unique name for a new account.')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'minecraftstor${resourceSuffix}'
@description('False references world storage without updating or recreating it.')
param createStorageAccount bool = true
@description('Bedrock instances. Existing container, function and share names can be supplied explicitly.')
param minecraftConfig MinecraftInstance[] = [{ name: 'primary' }]
@description('Xbox Gamertag:XUID allowlist entries. An empty enabled list denies all players.')
param minecraftUsers string[] = []
@description('Numeric Xbox XUIDs with operator permission.')
param minecraftOps string[] = []
@description('Numeric Xbox XUIDs with member permission.')
param minecraftMembers string[] = []
@description('Container/log timezone, using an IANA timezone name.')
param minecraftTimezone string = 'Europe/Amsterdam'
@description('Windows timezone name used by Logic Apps and backup policy.')
param timezone string = 'W. Europe Standard Time'
@description('Create start/stop Logic Apps using managed identity.')
param enableAutoStartStop bool = false
@description('Protect world shares with Azure Files snapshot backups.')
param enableBackup bool = false
@description('Optional existing Recovery Services vault name; defaults to the resource group naming convention.')
param backupVaultName string = '${resourceGroup().name}-backup'
@description('Optional existing backup policy name.')
param backupPolicyName string = '${backupVaultName}-nightly'
@description('Resource ID of an existing Azure DNS zone; empty disables vanity DNS.')
param vanityDnsZoneId string = ''
@description('Alert email and Azure mobile push receiver; empty disables this receiver.')
param provisionerEmailAddress string = ''
@description('New solution contributor principal IDs.')
param solutionContributors string[] = []
@description('New solution operator principal IDs.')
param solutionOperators string[] = []
@description('New solution reader principal IDs.')
param solutionReaders string[] = []
@description('Existing role assignment GUIDs keyed by scope|principalId|roleDefinitionId to avoid duplicate assignments.')
param roleAssignmentNames object = {}
@description('Optional custom log alert query.')
param customAlertQuery string = ''
@description('Custom log alert email subject; empty uses "Custom alert".')
param customAlertSubject string = ''
@description('Enable the optional custom log alert.')
param customAlertEnabled bool = false
@description('Optional portal dashboard properties exported from the portal.')
param dashboardProperties object = {}
@description('Additional resource tags.')
param tags object = {}

var commonTags = union(tags, {
  application: 'Minecraft'
  repository: 'azure-minecraft-docker'
  environment: environment
  suffix: resourceSuffix
  provisioner: 'bicep'
})
var instances = [for config in minecraftConfig: union({
  containerName: toLower('${resourceGroup().name}-bedrock-${config.name}')
  dnsNameLabel: config.?containerName ?? toLower('${resourceGroup().name}-bedrock-${config.name}')
  dataShareName: config.name == 'primary' ? 'minecraft-aci-bedrock-data-${resourceSuffix}' : 'minecraft-aci-bedrock-${config.name}-data-${resourceSuffix}'
  createDataShare: true
  functionName: toLower('${resourceGroup().name}-${config.name}-ping-test')
  functionStorageAccountName: 'mcfn${take(uniqueString(resourceGroup().id, config.name), 20)}'
  createFunctionStorageAccount: true
  adoptFunction: false
  image: 'itzg/minecraft-bedrock-server'
  imageTag: 'latest'
  maxPlayers: 4
  serverPort: 19132
  udpPortStart: 19140
  allowListEnabled: true
  allowOpsOnly: false
  environmentVariables: {}
  startTime: '07:00'
  startTimeWeekend: config.?startTime ?? '07:00'
  stopTime: '00:01'
  stopTimeWeekend: config.?stopTime ?? '00:01'
  vanityHostnamePrefix: config.name == 'primary' ? 'minecraft' : config.name
}, config)]

module storage './modules/storage.bicep' = {
  name: 'bedrock-storage'
  params: {
    name: storageAccountName
    createAccount: createStorageAccount
    shares: instances
    location: location
    tags: commonTags
  }
}
module monitoring './modules/monitoring.bicep' = {
  name: 'bedrock-monitoring'
  params: {
    location: location
    tags: commonTags
    provisionerEmailAddress: provisionerEmailAddress
    customAlertQuery: customAlertQuery
    customAlertSubject: customAlertSubject
    customAlertEnabled: customAlertEnabled
  }
}
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${resourceGroup().name}-minecraft-identity'
  location: location
  tags: commonTags
}
resource schedulerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (enableAutoStartStop) {
  name: guid(resourceGroup().id, 'bedrock-scheduler')
  properties: {
    roleName: 'Bedrock scheduler (${resourceGroup().name})'
    description: 'Start and stop Bedrock containers without a service principal secret.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: ['Microsoft.ContainerInstance/containerGroups/read', 'Microsoft.ContainerInstance/containerGroups/start/action', 'Microsoft.ContainerInstance/containerGroups/stop/action']
      notActions: []
    }]
  }
}
module servers './modules/instance.bicep' = [for instance in instances: {
  name: 'bedrock-${instance.name}'
  params: {
    config: instance
    location: location
    environment: environment
    storageAccountName: storage.outputs.name
    identityId: identity.id
    workspaceName: monitoring.outputs.workspaceName
    insightsName: monitoring.outputs.insightsName
    actionGroupId: monitoring.outputs.actionGroupId
    functionPlanId: monitoring.outputs.functionPlanId
    minecraftUsers: minecraftUsers
    minecraftOps: minecraftOps
    minecraftMembers: minecraftMembers
    minecraftTimezone: minecraftTimezone
    enableAutoStartStop: enableAutoStartStop
    schedulerRoleId: enableAutoStartStop ? schedulerRole!.id : ''
    timezone: timezone
    vanityDnsZoneId: vanityDnsZoneId
    tags: commonTags
  }
}]
module backup './modules/backup.bicep' = if (enableBackup) {
  name: 'bedrock-backup'
  params: {
    location: location
    storageAccountName: storage.outputs.name
    shareNames: [for instance in instances: instance.dataShareName]
    vaultName: backupVaultName
    policyName: backupPolicyName
    timezone: timezone
    workspaceName: monitoring.outputs.workspaceName
    tags: commonTags
  }
}
module access './modules/access.bicep' = {
  name: 'bedrock-access'
  params: {
    contributors: solutionContributors
    operators: solutionOperators
    readers: solutionReaders
    roleAssignmentNames: roleAssignmentNames
  }
}
module dashboard './modules/dashboard.bicep' = {
  name: 'bedrock-dashboard'
  params: {
    location: location
    workspaceName: monitoring.outputs.workspaceName
    storageAccountName: storage.outputs.name
    primaryContainerId: empty(instances) ? resourceGroup().id : servers[0].outputs.details.container_group_id
    resourceSuffix: resourceSuffix
    environment: environment
    customProperties: dashboardProperties
    tags: commonTags
  }
}

// Management scripts index this array by configuration_name.
output minecraft array = [for (instance, index) in instances: union({
  configuration_name: instance.name
}, servers[index].outputs.details)]
output resource_group string = resourceGroup().name
output resource_group_id string = resourceGroup().id
output subscription_guid string = subscription().subscriptionId
output storage_account string = storage.outputs.name
output storage_data_share array = [for instance in instances: instance.dataShareName]
output function_name array = [for (instance, index) in instances: servers[index].outputs.details.function_name]
output container_group_id array = [for (instance, index) in instances: servers[index].outputs.details.container_group_id]
output minecraft_server_fqdn array = [for (instance, index) in instances: servers[index].outputs.details.minecraft_server_fqdn]
output minecraft_server_port array = [for instance in instances: instance.serverPort]
output minecraft_server_udp_ports array = [for instance in instances: range(instance.udpPortStart, instance.maxPlayers)]
output log_analytics_workspace_guid string = monitoring.outputs.workspaceGuid
output backup_vault string = enableBackup ? backupVaultName : ''
output backup_policy string = enableBackup ? backupPolicyName : ''
output resource_suffix string = resourceSuffix
output environment string = environment
output location string = location
output dashboard_id string = dashboard.outputs.id
output dashboard_url string = 'https://portal.azure.com/#@/dashboard/arm${dashboard.outputs.id}'
output schedule_ids array = [for (instance, index) in instances: servers[index].outputs.scheduleIds]
