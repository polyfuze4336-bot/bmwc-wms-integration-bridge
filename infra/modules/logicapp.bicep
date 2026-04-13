// ─────────────────────────────────────────────────────────────────────────────
// Logic Apps Standard — BMWC WMS Bridge
//
// Provisions:
//   - Storage Account (Logic Apps runtime state + blob triggers)
//   - App Service Plan (Workflow Standard WS1)
//   - Logic App Standard site (System-Assigned Managed Identity)
//   - VNet integration (regional, outbound) for private WMS access
//   - Key Vault reference app settings for WMS credentials
//   - Role assignment: grants Logic App MI "Key Vault Secrets User"
// ─────────────────────────────────────────────────────────────────────────────

param name string
param planName string
param resourceToken string     // unique suffix for storage account naming
param location string
param tags object

param aseId string  // Resource ID of the ASEv3 hosting environment (Microsoft.Web/hostingEnvironments)

@secure()
param serviceBusConnectionString string

param appInsightsConnectionString string
param keyVaultName string

@description('Inbound Service Bus queue name. Must match the servicebus.bicep inboundQueueName parameter.')
param inboundQueueName string = 'wms-inbound'

// ── Storage Account (Logic Apps runtime requirement) ──────────────────────────
// Name: max 24 chars, lowercase alphanumeric only
var storageAccountName = take('stla${resourceToken}', 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false  // Azure Policy: identity-based access only; MI role assignments below
  }
}

// ── App Service Plan (IsolatedV2 on ASEv3) ───────────────────────────────────
// I1v2 is the smallest Isolated tier. The plan is pinned to the ASEv3 via
// hostingEnvironmentProfile. Elastic scaling is not applicable to Isolated plans;
// scale out by increasing 'capacity' or adding autoscale rules post-provision.
resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'I1v2'
    tier: 'IsolatedV2'
    capacity: 1
  }
  properties: {
    hostingEnvironmentProfile: {
      id: aseId
    }
  }
}

// ── Logic App Standard ────────────────────────────────────────────────────────
resource logicApp 'Microsoft.Web/sites@2022-03-01' = {
  name: name
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      appSettings: [
        { name: 'APP_KIND', value: 'workflowApp' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet' }  // Microsoft now requires 'dotnet' for all Standard logic apps

        // Storage — identity-based (no shared key; Azure Policy enforced)
        // ASEv3 uses NFS mounts for home directory instead of SMB/Azure Files, so
        // allowSharedKeyAccess: false on the storage account is fully supported here.
        // Blob, queue, and table access all use credentialType=managedIdentity.
        //
        // Note: credentialType=managedIdentity (NOT credential=managedIdentity).
        // The Logic Apps Edge component validates 'credentialType'; 'credential' is rejected.
        { name: 'AzureWebJobsStorage__accountName', value: storageAccount.name }
        { name: 'AzureWebJobsStorage__credentialType', value: 'managedIdentity' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
        { name: 'WEBSITE_SKIP_CONTENTSHARE_VALIDATION', value: '1' }

        // Observability
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'SCALE_CONTROLLER_LOGGING_ENABLED', value: 'AppInsights:Verbose' }

        // Service Bus (used by built-in connector in connections.json)
        { name: 'ServiceBus__connectionString', value: serviceBusConnectionString }
        { name: 'ServiceBus__inboundQueueName', value: inboundQueueName }

        // WMS credentials via Key Vault References (no plaintext)
        {
          name: 'WMS__SoapEndpoint'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=wms-soap-endpoint)'
        }
        {
          name: 'WMS__Username'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=wms-soap-username)'
        }
        {
          name: 'WMS__Password'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=wms-soap-password)'
        }

        // Workflow enable/disable per workflow — all three active workflows
        { name: 'Workflows.RuntimeConfiguration.RetentionInDays', value: '30' }
        { name: 'Workflows.bmwc-rest-ingress.FlowState',   value: 'Enabled' }
        { name: 'Workflows.wms-soap-dispatcher.FlowState', value: 'Enabled' }
        { name: 'Workflows.dlq-monitor.FlowState',         value: 'Enabled' }
      ]
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      netFrameworkVersion: 'v6.0'
    }
    // No VNet integration configuration needed: on ASEv3 the Logic App is inside
    // the VNet by default (the ASE subnet provides the isolation boundary).
  }
}

// ── Role Assignments: Storage Account (MI-only access) ───────────────────────
// Required because allowSharedKeyAccess: false — Azure Policy enforced.
// Logic App MI must have these 4 roles to access blobs, queues, tables, and file share.

resource storageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicApp.id, 'storage-blob-owner')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicApp.id, 'storage-queue-contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicApp.id, 'storage-table-contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageFilePrivilegedContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicApp.id, 'storage-file-privileged')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69566ab7-960f-475b-8e7c-b3118f30c6bd')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Role Assignment: Key Vault Secrets User ────────────────────────────────────
// Grants the Logic App Managed Identity read-access to Key Vault secrets.
// Built-in role: Key Vault Secrets User (4633458b-17de-408a-b874-0445c86b69e6)
resource kvSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, logicApp.id, 'kv-secrets-user')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output id string = logicApp.id
output name string = logicApp.name
output baseUrl string = 'https://${logicApp.properties.defaultHostName}'
output principalId string = logicApp.identity.principalId
