@description('Azure region.')
param location string
@description('Resource tags.')
param tags object
@description('Optional alert email/mobile push recipient.')
param provisionerEmailAddress string
@description('Optional custom log alert query.')
param customAlertQuery string
@description('Custom log alert email subject; empty uses "Custom alert".')
param customAlertSubject string
@description('Enable custom alert.')
param customAlertEnabled bool

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${resourceGroup().name}-loganalytics'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 365 }
}
resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${resourceGroup().name}-insights'
  location: location
  kind: 'web'
  tags: tags
  properties: { Application_Type: 'web', WorkspaceResourceId: workspace.id }
}
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${resourceGroup().name}-functions'
  location: location
  kind: 'linux'
  tags: tags
  sku: { name: 'Y1', tier: 'Dynamic' }
  properties: { reserved: true }
}
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${resourceGroup().name}-arm-alert-group'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'bedrock'
    enabled: true
    armRoleReceivers: [
      { name: 'Contributor', roleId: 'b24988ac-6180-42a0-ab88-20f7382dd24c', useCommonAlertSchema: true }
      { name: 'Reader', roleId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7', useCommonAlertSchema: true }
    ]
    emailReceivers: empty(provisionerEmailAddress) ? [] : [
      { name: 'provisioner-email', emailAddress: provisionerEmailAddress, useCommonAlertSchema: true }
    ]
    azureAppPushReceivers: empty(provisionerEmailAddress) ? [] : [
      { name: 'provisioner-mobile', emailAddress: provisionerEmailAddress }
    ]
  }
}
resource failedAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${resourceGroup().name}-container-failed-alert'
  location: location
  tags: tags
  properties: {
    enabled: true
    severity: 2
    scopes: [workspace.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    skipQueryValidation: true
    criteria: { allOf: [
      { query: loadTextContent('../../kusto/container-failed.csl'), timeAggregation: 'Count', operator: 'GreaterThan', threshold: 0 }
    ] }
    actions: { actionGroups: [actionGroup.id] }
  }
}
resource customAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (!empty(customAlertQuery)) {
  name: '${resourceGroup().name}-custom-alert'
  location: location
  tags: tags
  properties: {
    enabled: customAlertEnabled
    severity: 1
    scopes: [workspace.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    skipQueryValidation: true
    criteria: { allOf: [
      { query: customAlertQuery, timeAggregation: 'Count', operator: 'GreaterThan', threshold: 0 }
    ] }
    actions: {
      actionGroups: [actionGroup.id]
      actionProperties: {
        'Email.Subject': empty(customAlertSubject) ? 'Custom alert' : customAlertSubject
      }
    }
  }
}
output workspaceName string = workspace.name
output workspaceGuid string = workspace.properties.customerId
output insightsName string = insights.name
output actionGroupId string = actionGroup.id
output functionPlanId string = plan.id
