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

param logicAppSubnetId string  // Subnet delegated to Microsoft.Web/serverFarms

@secure()
param serviceBusConnectionString string

param appInsightsConnectionString string
param keyVaultName string

@minValue(1)
@maxValue(20)
@description('Maximum elastic worker count for the WS1 plan. Demo: 3. Production: tune to measured concurrency.')
param maxElasticWorkers int = 3

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
    allowSharedKeyAccess: true   // Required by Logic Apps runtime; disable after UAMI support
  }
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// ── App Service Plan (Workflow Standard) ─────────────────────────────────────
resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  kind: 'elastic'
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: maxElasticWorkers
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
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'node' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION', value: '~18' }

        // Storage (Logic Apps runtime + content share)
        { name: 'AzureWebJobsStorage', value: storageConnectionString }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: storageConnectionString }
        { name: 'WEBSITE_CONTENTSHARE', value: toLower(name) }

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
    // Regional VNet integration: all outbound traffic routed through VNet
    virtualNetworkSubnetId: logicAppSubnetId
    vnetRouteAllEnabled: true
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
