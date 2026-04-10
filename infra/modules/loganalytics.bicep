// ─────────────────────────────────────────────────────────────────────────────
// Log Analytics + Application Insights — BMWC WMS Bridge
// Provides the observability backbone for Logic App runs, APIM calls,
// and custom telemetry emitted by workflows.
// ─────────────────────────────────────────────────────────────────────────────

param name string
param appInsightsName string
param location string
param tags object

@minValue(30)
@maxValue(730)
@description('Log retention in days. Demo: 30. Production minimum: 90.')
param retentionInDays int = 30

@description('Daily ingestion cap in GB. -1 = unlimited (production). 1 = demo guard.')
param dailyQuotaGb int = 1

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    RetentionInDays: retentionInDays
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output workspaceId string = logAnalytics.id
output workspaceName string = logAnalytics.name
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output appInsightsConnectionString string = appInsights.properties.ConnectionString
