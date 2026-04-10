// ─────────────────────────────────────────────────────────────────────────────
// Key Vault — BMWC WMS Bridge
// Stores WMS SOAP endpoint, credentials, and any future secrets.
// Logic App accesses secrets via Key Vault References (app settings).
// RBAC-enabled; Logic App Managed Identity is granted Secrets User in main.bicep.
// ─────────────────────────────────────────────────────────────────────────────

param name string
param location string
param tags object

@description('WMS SOAP service endpoint URL — stored as a secret, not hard-coded in workflow.')
param wmsSoapEndpoint string

@secure()
@description('WMS API username. Set via azd env set WMS_USERNAME. Stored in Key Vault as wms-soap-username.')
param wmsUsername string = ''

@secure()
@description('WMS API password. Set via azd env set WMS_PASSWORD. Stored in Key Vault as wms-soap-password.')
param wmsPassword string = ''

@description('Resource ID of the Logic Apps VNet integration subnet. Locks Key Vault access to VNet-only traffic.')
param logicAppSubnetId string

@minValue(7)
@maxValue(90)
@description('Soft-delete retention in days. Demo: 7 (minimum). Production: 90.')
param softDeleteRetentionDays int = 7

@description('Purge protection prevents permanent deletion of the vault. Set true in production.')
param enablePurgeProtection bool = false

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionDays
    enablePurgeProtection: enablePurgeProtection
    networkAcls: {
      // 'Deny' by default — only the Logic Apps subnet (via service endpoint) and
      // Azure-internal traffic (Key Vault References resolution) are allowed.
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          // snet-logicapp has Microsoft.KeyVault service endpoint enabled.
          // Traffic from Logic Apps outbound VNet integration flows through this subnet.
          id: logicAppSubnetId
          ignoreMissingVnetServiceEndpoint: false
        }
      ]
      ipRules: []
    }
  }
}

resource secretWmsEndpoint 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'wms-soap-endpoint'
  properties: {
    value: wmsSoapEndpoint
    contentType: 'text/plain'
  }
}

resource secretWmsUsername 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'wms-soap-username'
  properties: {
    value: wmsUsername
    contentType: 'text/plain'
  }
}

// IMPORTANT: wmsPassword must be supplied via a secure parameter — never hard-code here.
// Supply via: azd env set WMS_PASSWORD <value>  or  parameter file with @secure() reference.
resource secretWmsPassword 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'wms-soap-password'
  properties: {
    value: wmsPassword
    contentType: 'text/plain'
  }
}

output id string = keyVault.id
output name string = keyVault.name
output uri string = keyVault.properties.vaultUri
