// ─────────────────────────────────────────────────────────────────────────────
// Service Bus — BMWC WMS Bridge
// Adapted from SFDCtoSAP project (topic+subscription → two focused queues).
//
// Queues:
//   wms-inbound      : BMWC orders waiting to be dispatched to WMS SOAP
//   wms-dead-letter  : Ops review queue — receives messages that exhaust retries
//
// SKU: Standard (supports queues with dead-letter). Upgrade to Premium for:
//   - Private endpoints / VNet injection
//   - Message size > 256 KB
//   - Geo-redundancy
// ─────────────────────────────────────────────────────────────────────────────

param name string
param location string
param tags object

@description('Primary inbound queue name. Must match the queue referenced in wms-soap-dispatcher workflow parameters.')
param inboundQueueName string = 'wms-inbound'

@description('Dead-letter review queue name. Receives messages after maxDeliveryCount is exhausted.')
param deadLetterQueueName string = 'wms-dead-letter-review'

@description('Message TTL for the inbound queue. ISO 8601 duration. Default PT4H.')
param messageTtl string = 'PT4H'

@minValue(1)
@maxValue(10)
@description('Max delivery count before dead-lettering. Default 5.')
param maxDeliveryCount int = 5

@description('Message lock duration. Must exceed the entire retry chain. Default PT10M.')
param lockDuration string = 'PT5M'

resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Standard' }
  properties: {
    disableLocalAuth: false   // Set true to enforce Entra ID-only auth in production
    minimumTlsVersion: '1.2'
  }
}

// Primary inbound queue: BMWC orders waiting for WMS dispatch
resource wmsInboundQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBus
  name: inboundQueueName
  properties: {
    defaultMessageTimeToLive: messageTtl
    maxDeliveryCount: maxDeliveryCount
    lockDuration: lockDuration
    deadLetteringOnMessageExpiration: true
    enablePartitioning: false                  // Enable for > 1 GB throughput
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'PT10M'
  }
}

// Ops queue for investigating dead-lettered messages
resource wmsDeadLetterQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBus
  name: deadLetterQueueName
  properties: {
    defaultMessageTimeToLive: 'P7D'   // Retain 7 days for ops review
    maxDeliveryCount: 1
  }
}

output endpoint string = serviceBus.properties.serviceBusEndpoint
output id string = serviceBus.id
output namespaceName string = serviceBus.name
output wmsInboundQueueName string = wmsInboundQueue.name

// connectionString is used by logicapp.bicep as an app setting (not user-facing).
// Production: replace with Managed Identity + RBAC (Service Bus Data Sender/Receiver roles)
// and remove this output. Suppressed here to allow azd deployment to complete.
#disable-next-line outputs-should-not-contain-secrets
output connectionString string = listKeys(
  '${serviceBus.id}/AuthorizationRules/RootManageSharedAccessKey',
  '2022-10-01-preview'
).primaryConnectionString
