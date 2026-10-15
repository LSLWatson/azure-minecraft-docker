@description('Azure region.')
param location string
@description('Log Analytics workspace name.')
param workspaceName string
@description('World storage account name.')
param storageAccountName string
@description('Primary container ID, or the resource group ID if no instances.')
param primaryContainerId string
@description('Resource suffix.')
param resourceSuffix string
@description('Environment label.')
param environment string
@description('Optional dashboard properties exported from the portal.')
param customProperties object
@description('Resource tags.')
param tags object

var playerQuery = string([loadTextContent('../../kusto/player-status.csl')])
var connectionQuery = string([loadTextContent('../../kusto/connection-events.csl')])
var queries = replace(
  replace(loadTextContent('../assets/dashboard.template.json'), '\${player_status_query}', substring(playerQuery, 1, max(0, length(playerQuery) - 2))),
  '\${connection_events_query}', substring(connectionQuery, 1, max(0, length(connectionQuery) - 2))
)
var resourceNames = replace(replace(replace(queries, '\${primary_container_id}', primaryContainerId), '\${storage_account}', storageAccountName), '\${resource_group_id}', resourceGroup().id)
var groups = replace(replace(resourceNames, '\${resource_group}-loganalytics', workspaceName), '\${resource_group}', resourceGroup().name)
var subscriptionNames = replace(replace(groups, '\${subscription_id}', subscription().id), '\${subscription_guid}', subscription().subscriptionId)
var labels = replace(replace(replace(replace(subscriptionNames, '\${location}', location), '\${suffix}', resourceSuffix), '\${workspace}', environment), '\${environment}', environment)
var template = json(labels)
resource dashboard 'Microsoft.Portal/dashboards@2020-09-01-preview' = {
  name: '${resourceGroup().name}-dashboard'
  location: location
  tags: union(tags, { 'hidden-title': 'Minecraft Bedrock (${environment})' })
  properties: empty(customProperties) ? { lenses: template.lenses, metadata: template.metadata } : customProperties
}
output id string = dashboard.id
