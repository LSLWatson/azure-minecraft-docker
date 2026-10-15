@description('Existing DNS zone name.')
param zoneName string
@description('Vanity CNAME record name.')
param recordName string
@description('ACI public DNS hostname.')
param target string
@description('Metadata tags.')
param tags object

resource zone 'Microsoft.Network/dnsZones@2018-05-01' existing = { name: zoneName }
resource cname 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: zone
  name: recordName
  properties: { TTL: 300, CNAMERecord: { cname: target }, metadata: tags }
}
