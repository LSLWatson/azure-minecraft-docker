@description('World storage account name.')
param name string
@description('Create a new account, or reference an existing account unchanged.')
param createAccount bool
@description('Normalized instance/share configuration.')
param shares array
@description('Azure region.')
param location string
@description('Resource tags.')
param tags object

// ACI SMB volumes require a storage key; this account cannot disable shared-key access.
resource account 'Microsoft.Storage/storageAccounts@2023-05-01' = if (createAccount) {
  name: name
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  tags: tags
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
resource existingAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: name }
resource files 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = if (createAccount) {
  parent: account
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: { enabled: true, days: 30 }
  }
}
resource existingFiles 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' existing = {
  parent: existingAccount
  name: 'default'
}
resource worldShares 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = [for share in shares: if (share.createDataShare) {
  parent: existingFiles
  name: share.dataShareName
  properties: { shareQuota: 50, enabledProtocols: 'SMB' }
  dependsOn: [account, files]
}]
resource lock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: '${name}-lock'
  scope: existingAccount
  properties: { level: 'CanNotDelete', notes: 'Protect persistent Minecraft world data.' }
  dependsOn: [account, worldShares]
}
output name string = name
