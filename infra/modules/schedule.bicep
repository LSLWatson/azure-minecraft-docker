@description('Workflow name.')
param name string
@description('Target container group name.')
param containerName string
@description('ACI management operation.')
@allowed(['start', 'stop'])
param operation string
@description('Weekday HH:mm time.')
param weekdayTime string
@description('Weekend HH:mm time. Empty disables the weekend schedule.')
param weekendTime string
@description('Windows timezone name.')
param timezone string
@description('Azure region.')
param location string
@description('Log Analytics workspace name.')
param workspaceName string
@description('Narrowly scoped scheduling role definition ID.')
param roleId string
@description('Resource tags.')
param tags object

resource container 'Microsoft.ContainerInstance/containerGroups@2023-05-01' existing = { name: containerName }
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: workspaceName }
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${name}-identity'
  location: location
  tags: tags
}
resource permission 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, identity.id, roleId)
  scope: container
  properties: { principalId: identity.properties.principalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId }
}
resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identity.id}': {} } }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: union(empty(weekdayTime) ? {} : {
        Weekdays: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Week'
            interval: 1
            // An explicit past anchor schedules the next occurrence instead of running immediately on deployment.
            startTime: '2020-01-01T00:00:00'
            timeZone: timezone
            schedule: {
              weekDays: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
              hours: [int(first(split(weekdayTime, ':')))]
              minutes: [int(last(split(weekdayTime, ':')))]
            }
          }
        }
      }, empty(weekendTime) ? {} : {
        Weekend: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Week'
            interval: 1
            startTime: '2020-01-01T00:00:00'
            timeZone: timezone
            schedule: {
              weekDays: ['Saturday', 'Sunday']
              hours: [int(first(split(weekendTime, ':')))]
              minutes: [int(last(split(weekendTime, ':')))]
            }
          }
        }
      })
      actions: {
        ContainerOperation: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '${environment().resourceManager}${substring(container.id, 1)}/${operation}?api-version=2023-05-01'
            authentication: { type: 'ManagedServiceIdentity', identity: identity.id, audience: environment().resourceManager }
            retryPolicy: { type: 'exponential', count: 6, interval: 'PT10S', minimumInterval: 'PT10S', maximumInterval: 'PT5M' }
          }
          runAfter: {}
        }
      }
      outputs: {}
    }
  }
  dependsOn: [permission]
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${name}-logs'
  scope: workflow
  properties: { workspaceId: workspace.id, logs: [{ category: 'WorkflowRuntime', enabled: true }] }
}
output workflowId string = workflow.id
