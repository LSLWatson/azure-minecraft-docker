@description('Azure region; must match world storage.')
param location string
@description('World storage account name.')
param storageAccountName string
@description('World shares to protect.')
param shareNames string[]
@description('Recovery Services vault name.')
param vaultName string
@description('Backup policy name.')
param policyName string
@description('Windows backup timezone.')
param timezone string
@description('Log Analytics workspace name.')
param workspaceName string
@description('Resource tags.')
param tags object

resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = {
  name: vaultName
  location: location
  tags: tags
  sku: { name: 'RS0', tier: 'Standard' }
  properties: {
    securitySettings: { softDeleteSettings: { softDeleteState: 'Enabled', softDeleteRetentionPeriodInDays: 14 } }
  }
}
var backupTimes = ['2020-01-01T03:00:00Z']
resource policy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = {
  parent: vault
  name: policyName
  properties: {
    backupManagementType: 'AzureStorage'
    workLoadType: 'AzureFileShare'
    timeZone: timezone
    schedulePolicy: { schedulePolicyType: 'SimpleSchedulePolicy', scheduleRunFrequency: 'Daily', scheduleRunTimes: backupTimes }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: { retentionTimes: backupTimes, retentionDuration: { count: 30, durationType: 'Days' } }
      weeklySchedule: { daysOfTheWeek: ['Monday'], retentionTimes: backupTimes, retentionDuration: { count: 7, durationType: 'Weeks' } }
      monthlySchedule: {
        retentionScheduleFormatType: 'Weekly'
        retentionScheduleWeekly: { daysOfTheWeek: ['Monday', 'Sunday'], weeksOfTheMonth: ['First', 'Last'] }
        retentionTimes: backupTimes
        retentionDuration: { count: 12, durationType: 'Months' }
      }
      yearlySchedule: {
        retentionScheduleFormatType: 'Weekly'
        monthsOfYear: ['January']
        retentionScheduleWeekly: { daysOfTheWeek: ['Monday'], weeksOfTheMonth: ['First'] }
        retentionTimes: backupTimes
        retentionDuration: { count: 10, durationType: 'Years' }
      }
    }
  }
}
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: storageAccountName }
resource registration 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2024-04-01' = {
  name: '${vault.name}/Azure/storagecontainer;Storage;${resourceGroup().name};${storage.name}'
  properties: { backupManagementType: 'AzureStorage', containerType: 'StorageContainer', sourceResourceId: storage.id }
}
resource protectedShares 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = [for share in shareNames: {
  parent: registration
  name: 'AzureFileShare;${share}'
  properties: {
    protectedItemType: 'AzureFileShareProtectedItem'
    sourceResourceId: storage.id
    policyId: policy.id
    // Supported by Microsoft's Azure Files backup quickstart; absent from published Bicep types.
    #disable-next-line BCP037
    isInlineInquiry: true
  }
}]
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: workspaceName }
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${vault.name}-logs'
  scope: vault
  properties: {
    workspaceId: workspace.id
    logs: [for category in ['AddonAzureBackupAlerts', 'AddonAzureBackupJobs', 'AddonAzureBackupPolicy', 'AddonAzureBackupProtectedInstance', 'AddonAzureBackupStorage', 'AzureBackupReport', 'CoreAzureBackup']: {
      category: category
      enabled: true
    }]
  }
}
