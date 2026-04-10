targetScope = 'subscription'

// ─────────────────────────────────────────────────────────────────────────────
// BMWC → WMS Bridge — Main Bicep Orchestrator
//
// Primary region  : Southeast Asia  (Singapore)    — location = southeastasia
// Secondary region: Malaysia South  (Kuala Lumpur) — location = malaysiasouth
//
// Deployment:
//   azd provision                                         (azd + azure.yaml)
//   az deployment sub create --template-file infra/main.bicep \
//     --parameters infra/main.parameters.prod-sg.json     (direct Bicep)
//
// Parameter files:
//   main.parameters.json        — azd template (env-var substitutions)
//   main.parameters.demo.json   — demo / PoC defaults  (Singapore)
//   main.parameters.prod-sg.json — production defaults (Singapore)
//   main.parameters.prod-my.json — production defaults (Malaysia South)
// ─────────────────────────────────────────────────────────────────────────────

// ── Identity and targeting ────────────────────────────────────────────────────
@minLength(1)
@maxLength(64)
@description('Environment label — drives all resource names and tags. Examples: dev, uat, prod-sg, prod-my.')
param environmentName string

@allowed(['southeastasia', 'malaysiasouth'])
@description('Deployment region. southeastasia = Singapore (primary); malaysiasouth = Malaysia South (secondary).')
param location string = 'southeastasia'

// ── APIM publisher ────────────────────────────────────────────────────────────
@description('APIM publisher email — required by Azure; visible in the developer portal.')
param apimPublisherEmail string = 'platform@contoso.com'

@description('APIM publisher display name — appears in the developer portal and alert emails.')
param apimPublisherName string = 'BMWC Integration Platform'

// ── WMS connectivity ──────────────────────────────────────────────────────────
@description('WMS SOAP service endpoint URL. Stored as Key Vault secret; NOT hard-coded in workflow JSON.')
param wmsSoapEndpoint string = 'http://wms-mock.internal:8080/WMSService.svc'

@secure()
@description('WMS API username. Stored as Key Vault secret wms-soap-username. Set via: azd env set WMS_USERNAME <value>')
param wmsUsername string = ''

@secure()
@description('WMS API password. Stored as Key Vault secret wms-soap-password. Set via: azd env set WMS_PASSWORD <value>')
param wmsPassword string = ''

// ── APIM security ─────────────────────────────────────────────────────────────
@description('CIDR ranges allowed to call the APIM gateway. Empty = allow all traffic (demo). Set to BMWC egress IP(s) in production.')
param allowedClientIps array = []

@minValue(1)
@maxValue(100)
@description('APIM diagnostics sampling percentage sent to Application Insights. Demo: 100. Production: 10 to reduce AI ingestion costs.')
param apimSamplingPercentage int = 100

@description('APIM rate-limit: max calls per subscription key per renewal period.')
param apimRateLimitCalls int = 100

@description('APIM rate-limit renewal window in seconds. Default 60 (1 minute).')
param apimRateLimitPeriod int = 60

@description('APIM quota: max calls per subscription key per quota period.')
param apimQuotaCalls int = 10000

@description('APIM quota period in seconds. Default 604800 (7 days).')
param apimQuotaPeriod int = 604800

// ── Service Bus ───────────────────────────────────────────────────────────────
@description('Name of the primary inbound queue. Must match the queue name in workflow JSON parameters.')
param inboundQueueName string = 'wms-inbound'

@description('Name of the ops dead-letter review queue.')
param deadLetterQueueName string = 'wms-dead-letter-review'

@description('Message TTL for the inbound queue. ISO 8601 duration. Default PT4H. Extend for overnight batch windows.')
param messageTtl string = 'PT4H'

@minValue(1)
@maxValue(10)
@description('Max delivery count before dead-lettering. Default 5. Use 3 to fail faster in production with tight WMS SLA.')
param maxDeliveryCount int = 5

@description('Service Bus message lock duration. Must exceed the worst-case exponential retry chain. Default PT10M (5.75 min chain + 4.25 min buffer).')
param sbLockDuration string = 'PT5M'

// ── Log Analytics ─────────────────────────────────────────────────────────────
@minValue(30)
@maxValue(730)
@description('Log Analytics workspace data retention in days. Demo: 30. Production minimum: 90.')
param logRetentionDays int = 30

@description('Log Analytics daily ingestion cap in GB. -1 = unlimited (recommended for production). Default 1 protects demo accounts from unexpected cost.')
param logDailyQuotaGb int = 1

// ── Logic Apps App Service Plan ───────────────────────────────────────────────
@minValue(1)
@maxValue(20)
@description('Maximum elastic worker count for the WS1 App Service Plan. Demo: 3. Production: set based on observed concurrency.')
param maxElasticWorkers int = 3

// ── Key Vault hardening ───────────────────────────────────────────────────────
@minValue(7)
@maxValue(90)
@description('Key Vault soft-delete retention in days. Demo: 7 (minimum). Production: 90.')
param kvSoftDeleteRetentionDays int = 7

@description('Enable Key Vault purge protection. Prevents accidental permanent deletion. Set true in production.')
param kvEnablePurgeProtection bool = true

// ── Derived values ────────────────────────────────────────────────────────────
// resourceToken is a short stable suffix that keeps names globally unique without being too long.
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

var tags = {
  'azd-env-name': environmentName
  project:        'bmwc-wms-bridge'
  workload:       'integration'
  region:         location
  environment:    environmentName
}

// ── Resource Group ─────────────────────────────────────────────────────────────
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name:     'rg-bmwc-wms-${environmentName}'
  location: location
  tags:     tags
}

// ── 1. Networking ─────────────────────────────────────────────────────────────
// Creates VNet (10.10.0.0/16) with three subnets + NSGs:
//   snet-logicapp          (10.10.1.0/24) — delegated to App Service; Logic Apps outbound VNet integration
//   snet-private-endpoints (10.10.2.0/24) — Key Vault PE (+ SB PE when upgraded to Premium)
//   snet-wms-mock          (10.10.3.0/24) — demo WMS mock container; remove in production
module vnet 'modules/vnet.bicep' = {
  scope: rg
  name:  'vnet'
  params: {
    name:     'vnet-bmwc-wms-${resourceToken}'
    location: location
    tags:     tags
  }
}

// ── 2. Observability ──────────────────────────────────────────────────────────
// Log Analytics workspace (workspace-based Application Insights sink).
// All telemetry — APIM gateway logs, Logic App traces, custom workflow events —
// converges in this single workspace for unified KQL querying.
module logAnalytics 'modules/loganalytics.bicep' = {
  scope: rg
  name:  'loganalytics'
  params: {
    name:            'log-bmwc-wms-${resourceToken}'
    appInsightsName: 'appi-bmwc-wms-${resourceToken}'
    location:        location
    tags:            tags
    retentionInDays: logRetentionDays
    dailyQuotaGb:    logDailyQuotaGb
  }
}

// ── 3. Key Vault ──────────────────────────────────────────────────────────────
// Stores WMS credentials and endpoint URL.
// Logic App accesses secrets via Key Vault References (no plaintext in app settings).
// Network ACLs: Deny by default; allow only from snet-logicapp (service endpoint).
module keyVault 'modules/keyvault.bicep' = {
  scope: rg
  name:  'keyvault'
  params: {
    name:                    'kv-bmwc-${resourceToken}'
    location:                location
    tags:                    tags
    wmsSoapEndpoint:         wmsSoapEndpoint
    wmsUsername:             wmsUsername
    wmsPassword:             wmsPassword
    logicAppSubnetId:        vnet.outputs.logicAppSubnetId
    softDeleteRetentionDays: kvSoftDeleteRetentionDays
    enablePurgeProtection:   kvEnablePurgeProtection
  }
}

// ── 4. Service Bus ────────────────────────────────────────────────────────────
// Standard SKU namespace with two queues:
//   wms-inbound          — primary async buffer; peek-lock consumed by wms-soap-dispatcher
//   wms-dead-letter-review — ops queue; receives messages after maxDeliveryCount exhausted
module serviceBus 'modules/servicebus.bicep' = {
  scope: rg
  name:  'servicebus'
  params: {
    name:                'sb-bmwc-wms-${resourceToken}'
    location:            location
    tags:                tags
    inboundQueueName:    inboundQueueName
    deadLetterQueueName: deadLetterQueueName
    messageTtl:          messageTtl
    maxDeliveryCount:    maxDeliveryCount
    lockDuration:        sbLockDuration
  }
}

// ── 5. Logic Apps Standard ────────────────────────────────────────────────────
// WS1 App Service Plan (WorkflowStandard) with regional VNet integration.
// Outbound traffic routed through snet-logicapp → allows private WMS and PE access.
// System-Assigned Managed Identity granted Key Vault Secrets User role at RG scope.
module logicApp 'modules/logicapp.bicep' = {
  scope: rg
  name:  'logicapp'
  params: {
    name:                        'la-bmwc-wms-${resourceToken}'
    planName:                    'asp-bmwc-wms-${resourceToken}'
    resourceToken:               resourceToken
    location:                    location
    tags:                        tags
    logicAppSubnetId:            vnet.outputs.logicAppSubnetId
    appInsightsConnectionString: logAnalytics.outputs.appInsightsConnectionString
    serviceBusConnectionString:  serviceBus.outputs.connectionString
    keyVaultName:                keyVault.outputs.name
    maxElasticWorkers:           maxElasticWorkers
    inboundQueueName:            inboundQueueName
  }
}

// ── 6. API Management ─────────────────────────────────────────────────────────
// Consumption SKU — serverless APIM; no VNet injection at this tier.
// For private APIM (inbound from BMWC on-prem), upgrade to Developer or Premium
// and add a vnet.bicep subnet + APIM VNet integration params.
module apim 'modules/apim.bicep' = {
  scope: rg
  name:  'apim'
  params: {
    name:                          'apim-bmwc-wms-${resourceToken}'
    location:                      location
    tags:                          tags
    publisherEmail:                apimPublisherEmail
    publisherName:                 apimPublisherName
    logicAppBaseUrl:               logicApp.outputs.baseUrl
    appInsightsInstrumentationKey: logAnalytics.outputs.appInsightsInstrumentationKey
    appInsightsId:                 logAnalytics.outputs.appInsightsId
    allowedClientIps:              allowedClientIps
    samplingPercentage:            apimSamplingPercentage
    rateLimitCalls:                apimRateLimitCalls
    rateLimitPeriod:               apimRateLimitPeriod
    quotaCalls:                    apimQuotaCalls
    quotaPeriod:                   apimQuotaPeriod
  }
}

// ── 7. Azure Monitor Alerts ───────────────────────────────────────────────────
// Six alert rules: LA run failures, DLQ present, SOAP fault spike,
// end-to-end latency, enqueue failures, APIM 5xx rate.
module alerts 'modules/alerts.bicep' = {
  scope: rg
  name:  'alerts'
  params: {
    environmentName: environmentName
    logicAppId:      logicApp.outputs.id
    workspaceId:     logAnalytics.outputs.workspaceId
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
// All outputs are consumed by azd environment and post-provision.ps1.
output RESOURCE_GROUP_NAME   string = rg.name
output APIM_GATEWAY_URL      string = apim.outputs.gatewayUrl
output APIM_NAME             string = apim.outputs.name
output LOGIC_APP_NAME        string = logicApp.outputs.name
output LOGIC_APP_BASE_URL    string = logicApp.outputs.baseUrl
output SERVICE_BUS_ENDPOINT  string = serviceBus.outputs.endpoint
output INBOUND_QUEUE_NAME    string = serviceBus.outputs.wmsInboundQueueName
output KEY_VAULT_URI         string = keyVault.outputs.uri
output APP_INSIGHTS_CONN_STR string = logAnalytics.outputs.appInsightsConnectionString
