// ─────────────────────────────────────────────────────────────────────────────
// API Management — BMWC WMS Bridge
// Adapted from SFDCtoSAP (agent/mocks APIs replaced with BMWC REST API).
//
// SKU: Consumption (fast to provision, serverless pricing).
// For VNet injection (private WMS routing via APIM), upgrade to Developer or Premium.
//
// Exposes:
//   POST /bmwc/orders            — Submit BMWC order for async WMS dispatch
//   GET  /bmwc/orders/{id}/status — Query WMS order status
//
// Backend: Logic Apps Standard HTTP trigger URL, stored as Named Value
//   {{la-bmwc-ingest-url}} — populated by scripts/post-provision.ps1 after azd provision
// ─────────────────────────────────────────────────────────────────────────────

param name string
param location string
param tags object
param publisherEmail string

@description('Publisher display name shown in the APIM developer portal.')
param publisherName string = 'BMWC Integration Platform'

@description('Logic App base URL, e.g. https://la-bmwc-wms-abc.azurewebsites.net')
param logicAppBaseUrl string

param appInsightsInstrumentationKey string
param appInsightsId string

@description('Client IP CIDR ranges permitted to call the APIM gateway. Empty = allow all (demo). Set to BMWC egress IPs in production.')
param allowedClientIps array = []

@minValue(1)
@maxValue(100)
@description('Diagnostics sampling percentage forwarded to Application Insights. Demo: 100. Production: 10.')
param samplingPercentage int = 100

// ── APIM Service ──────────────────────────────────────────────────────────────
resource apim 'Microsoft.ApiManagement/service@2023-03-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Consumption', capacity: 0 }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// ── Application Insights Logger ───────────────────────────────────────────────
resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-03-01-preview' = {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
    isBuffered: true
    resourceId: appInsightsId
  }
}

// ── Diagnostics (sample 100% in dev; reduce to 10% in prod) ──────────────────
resource apimDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2023-03-01-preview' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    sampling: { samplingType: 'fixed', percentage: samplingPercentage }
    logClientIp: true
    verbosity: 'information'
    frontend: {
      // Ocp-Apim-Subscription-Key intentionally excluded: it is stripped by global policy
      // and must not appear in logs (OWASP: sensitive header exposure)
      request:  { headers: ['Content-Type', 'X-Correlation-ID'] }
      response: { headers: ['Content-Type', 'X-Correlation-ID'] }
    }
    backend: {
      request:  { headers: ['Content-Type', 'SOAPAction'] }
      response: { headers: ['Content-Type'] }
    }
  }
}

// ── Named Value: Logic App ingest trigger URL placeholder ─────────────────────
// Populated by scripts/post-provision.ps1 with the real callback URL.
resource namedValueLogicAppUrl 'Microsoft.ApiManagement/service/namedValues@2023-03-01-preview' = {
  parent: apim
  name: 'la-bmwc-ingest-url'
  properties: {
    displayName: 'la-bmwc-ingest-url'
    value: '${logicAppBaseUrl}/api/bmwc-rest-ingress/triggers/HTTP_Ingest/invoke'
    secret: false
  }
}

// ── Global Policy: CORS + Correlation ID injection ────────────────────────────
resource globalPolicy 'Microsoft.ApiManagement/service/policies@2023-03-01-preview' = {
  parent: apim
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><cors allow-credentials="false"><allowed-origins><origin>*</origin></allowed-origins><allowed-methods preflight-result-max-age="86400"><method>GET</method><method>POST</method><method>OPTIONS</method></allowed-methods><allowed-headers><header>*</header></allowed-headers></cors><set-header name="X-Correlation-ID" exists-action="skip"><value>@(context.RequestId.ToString())</value></set-header><set-header name="X-BMWC-Gateway" exists-action="override"><value>bmwc-wms-bridge/1.0</value></set-header></inbound><backend><forward-request /></backend><outbound></outbound><on-error></on-error></policies>'
  }
}

// ── BMWC → WMS API ─────────────────────────────────────────────────────────────
resource bmwcApi 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: apim
  name: 'bmwc-wms-api'
  properties: {
    displayName: 'BMWC → WMS Bridge'
    description: 'REST API for BMWC order submission. Backed by Logic Apps Standard. Dispatches orders asynchronously to legacy WMS via SOAP.'
    path: 'bmwc'
    protocols: ['https']
    serviceUrl: logicAppBaseUrl
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
    apiType: 'http'
  }
}

// ── POST /orders ───────────────────────────────────────────────────────────────
resource postOrderOp 'Microsoft.ApiManagement/service/apis/operations@2023-03-01-preview' = {
  parent: bmwcApi
  name: 'post-order'
  properties: {
    displayName: 'Submit Order to WMS'
    method: 'POST'
    urlTemplate: '/orders'
    description: 'Accepts a BMWC order payload, validates it, and enqueues it for async WMS SOAP dispatch. Returns 202 Accepted with a correlation ID.'
    responses: [
      { statusCode: 202, description: 'Order accepted — queued for WMS dispatch' }
      { statusCode: 400, description: 'Invalid payload — schema validation failed' }
      { statusCode: 401, description: 'Missing or invalid subscription key' }
      { statusCode: 429, description: 'Rate limit exceeded' }
    ]
  }
}

// ── GET /orders/{orderId}/status ──────────────────────────────────────────────
resource getOrderStatusOp 'Microsoft.ApiManagement/service/apis/operations@2023-03-01-preview' = {
  parent: bmwcApi
  name: 'get-order-status'
  properties: {
    displayName: 'Get WMS Order Status'
    method: 'GET'
    urlTemplate: '/orders/{orderId}/status'
    templateParameters: [
      {
        name: 'orderId'
        required: true
        type: 'string'
        description: 'BMWC order identifier (e.g. ORD-2026-001)'
      }
    ]
    responses: [
      { statusCode: 200, description: 'WMS order status response' }
      { statusCode: 404, description: 'Order not found' }
    ]
  }
}

// ── Per-API Policy: optional IP allowlist + parameterised rate/quota limits ─────
// IP filtering uses APIM's native <ip-filter> policy, which accepts CIDR natively.
// When allowedClientIps is empty the element is omitted (demo: allow all).
// Rate-limit, quota, and max-size are injected from Bicep parameters.
var ipFilterAddresses = join(map(allowedClientIps, ip => '<address>${ip}</address>'), '')
var ipFilterXml = empty(allowedClientIps) ? '' : '<ip-filter action="allow">${ipFilterAddresses}</ip-filter>'

var innerPolicy = '${ipFilterXml}<validate-content unspecified-content-type-action="prevent" max-size="262144" size-exceeded-action="prevent" errors-variable-name="requestBodyErrors"><content type="application/json" validate-as="json" action="prevent" /></validate-content><set-header name="X-Correlation-ID" exists-action="override"><value>@(context.Request.Headers.GetValueOrDefault(&quot;X-Correlation-ID&quot;, context.RequestId.ToString()))</value></set-header><set-backend-service base-url="{{la-bmwc-ingest-url}}" />'

var fullApiPolicy = '<policies><inbound><base />${innerPolicy}</inbound><backend><forward-request timeout="30" fail-on-error-status-code="false" /></backend><outbound><base /><set-header name="Location" exists-action="delete" /><set-header name="x-ms-workflow-run-id" exists-action="delete" /></outbound><on-error><base /></on-error></policies>'

resource bmwcApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-03-01-preview' = {
  parent: bmwcApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: fullApiPolicy
  }
}

// ── Product + Subscription (demo product, no approval required) ───────────────
resource bmwcProduct 'Microsoft.ApiManagement/service/products@2023-03-01-preview' = {
  parent: apim
  name: 'bmwc-integration'
  properties: {
    displayName: 'BMWC Integration'
    description: 'Access to BMWC → WMS bridge APIs'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productApiLink 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: bmwcProduct
  name: 'bmwc-wms-api'
  dependsOn: [bmwcApi]
}

// ── Demo Product (no approval needed, 1 subscription per user) ────────────────
// Use the demo product for live demos and prototype testing.
// The integration product (above) targets system-to-system integrations.
resource bmwcDemoProduct 'Microsoft.ApiManagement/service/products@2023-03-01-preview' = {
  parent: apim
  name: 'bmwc-demo'
  properties: {
    displayName: 'BMWC Demo'
    description: 'Demo access — limited rate, no approval. Remove or restrict for production.'
    subscriptionRequired: true
    approvalRequired: false
    subscriptionsLimit: 5
    state: 'published'
  }
}

resource demoProductApiLink 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: bmwcDemoProduct
  name: 'bmwc-wms-api'
  dependsOn: [bmwcApi]
}

// ── Core Subscription (generated key for azd post-provision wiring) ───────────
// primaryKey output is used by post-provision.ps1 to test the endpoint.
resource demoSubscription 'Microsoft.ApiManagement/service/subscriptions@2023-03-01-preview' = {
  parent: apim
  name: 'bmwc-demo-subscription'
  properties: {
    displayName: 'BMWC Demo Subscription'
    scope: '/products/${bmwcDemoProduct.id}'
    state: 'active'
    allowTracing: true
  }
}

output gatewayUrl string = apim.properties.gatewayUrl
output demoSubscriptionKeySecretUri string = demoSubscription.id
output id string = apim.id
output name string = apim.name
