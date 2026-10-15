@description('Function app name.')
param name string
@description('Function host storage account name.')
param storageName string
@description('False references existing function storage unchanged.')
param createStorage bool
@description('Preserve deployment and content-share settings on an existing function app.')
param adoptFunction bool
@description('Azure region.')
param location string
@description('Linux Consumption plan ID.')
param planId string
@description('Application Insights name.')
param insightsName string
@description('Log Analytics workspace name.')
param workspaceName string
@description('Bedrock signaling hostname.')
param host string
@description('Bedrock signaling TCP port.')
param port int
@description('Resource tags.')
param tags object

resource newStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (createStorage) {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Allow' }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: {
        blob: { enabled: true, keyType: 'Account' }
        file: { enabled: true, keyType: 'Account' }
      }
    }
  }
}
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: storageName }
resource insights 'Microsoft.Insights/components@2020-02-02' existing = { name: insightsName }
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: workspaceName }
var storageConnection = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
var existingSettings = adoptFunction ? list('${resourceId('Microsoft.Web/sites', name)}/config/appsettings', '2023-12-01').properties : {}
var settings = union(existingSettings, {
  AzureWebJobsStorage: storageConnection
  WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageConnection
  WEBSITE_CONTENTSHARE: existingSettings.?WEBSITE_CONTENTSHARE ?? take(toLower('${name}-content'), 63)
  FUNCTIONS_EXTENSION_VERSION: '~4'
  FUNCTIONS_WORKER_RUNTIME: 'dotnet'
  FUNCTIONS_INPROC_NET8_ENABLED: '1'
  APPLICATIONINSIGHTS_CONNECTION_STRING: insights.properties.ConnectionString
  MINECRAFT_FQDN: host
  MINECRAFT_PORT: string(port)
})
resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: name
  location: location
  kind: 'functionapp,linux'
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: planId
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      linuxFxVersion: 'DOTNET|8.0'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: map(items(settings), item => { name: item.key, value: string(item.value) })
    }
  }
  dependsOn: [newStorage]
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Function_Logs'
  scope: app
  properties: {
    workspaceId: workspace.id
    logs: [{ category: 'FunctionAppLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
output name string = app.name
