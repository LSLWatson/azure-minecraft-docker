@description('Contributor principal IDs.')
param contributors string[]
@description('Operator principal IDs.')
param operators string[]
@description('Reader principal IDs.')
param readers string[]
@description('Existing role assignment GUIDs keyed by scope|principalId|roleDefinitionId.')
param roleAssignmentNames object

var contributorIds = union(map(contributors, principal => toLower(principal)), [])
var operatorIds = union(map(operators, principal => toLower(principal)), [])
var readerIds = union(map(readers, principal => toLower(principal)), [])

resource operatorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (!empty(operators)) {
  name: guid(resourceGroup().id, 'bedrock-operator')
  properties: {
    roleName: 'Bedrock operator (${resourceGroup().name})'
    description: 'Start/stop Bedrock containers and run the scheduled workflows.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: [
        'Microsoft.ContainerInstance/containerGroups/read'
        'Microsoft.ContainerInstance/containerGroups/start/action'
        'Microsoft.ContainerInstance/containerGroups/stop/action'
        'Microsoft.ContainerInstance/containerGroups/restart/action'
        'Microsoft.ContainerInstance/containerGroups/containers/exec/action'
        'Microsoft.Logic/workflows/read'
        'Microsoft.Logic/workflows/triggers/run/action'
        'Microsoft.Logic/workflows/runs/read'
        'Microsoft.Logic/workflows/runs/actions/read'
      ]
      notActions: []
    }]
  }
}
var roles = [
  { role: 'b24988ac-6180-42a0-ab88-20f7382dd24c', principals: contributorIds }
  { role: '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb', principals: contributorIds }
  { role: 'aba4ae5f-2193-4029-9191-0cb91df5e314', principals: union(operatorIds, readerIds) }
  { role: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1', principals: union(contributorIds, operatorIds, readerIds) }
  { role: 'acdd72a7-3385-48ef-bd42-f606fba81ae7', principals: union(operatorIds, readerIds) }
  { role: '00c29273-979b-4161-815c-10b084fb9324', principals: operatorIds }
  { role: '515c2055-d9d4-4321-b1b9-bd0c9a0f79fe', principals: operatorIds }
]
var assignments = flatten(map(roles, role => map(role.principals, principal => {
  principal: principal
  roleId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.role)
  key: '${resourceGroup().id}|${principal}|${subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.role)}'
})))
resource permissions 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for assignment in assignments: {
  name: roleAssignmentNames[?assignment.key] ?? guid(resourceGroup().id, assignment.principal, assignment.roleId)
  properties: { principalId: assignment.principal, roleDefinitionId: assignment.roleId }
}]
resource operationPermission 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principal in operatorIds: {
  name: guid(resourceGroup().id, principal, 'bedrock-operator')
  properties: { principalId: principal, roleDefinitionId: operatorRole!.id }
}]
