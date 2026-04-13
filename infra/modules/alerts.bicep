// ─────────────────────────────────────────────────────────────────────────────
// Alerts — BMWC WMS Bridge
// Six alert rules covering Logic App failures, WMS SOAP faults, DLQ activity,
// end-to-end latency, queue depth, and APIM error rate.
// All log-based alerts query the shared Log Analytics workspace.
// ─────────────────────────────────────────────────────────────────────────────

param environmentName string
param logicAppId string
param workspaceId string

@description('Optional Action Group resource ID. When provided, all alert rules notify this group. Wire post-deployment via: Azure Portal → Monitor → Action Groups.')
param actionGroupId string = ''

// Reusable actions block — applied to every alert rule when an action group is configured
var metricAlertActions = empty(actionGroupId) ? [] : [{ actionGroupId: actionGroupId }]
var queryAlertActions  = empty(actionGroupId) ? {} : { actionGroups: [actionGroupId] }

// ── Alert 1: Logic App run failures (metric) ──────────────────────────────────
// Triggers when more than 5 Logic App workflow runs fail in any 5-minute window.
// Covers all three workflows (bmwc-rest-ingress, wms-soap-dispatcher, dlq-monitor).
resource alertLogicAppRunsFailed 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-la-runsfailed-${environmentName}'
  location: 'global'
  properties: {
    description: 'BMWC WMS Bridge — Logic App workflow run failure rate exceeds 20% in a 5-minute window. Check wms-soap-dispatcher run history and WMS connectivity.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.Web/sites'
    targetResourceRegion: resourceGroup().location
    scopes: [logicAppId]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'FailedRunRate'
          metricName: 'WorkflowRunsFailureRate'
          operator: 'GreaterThan'
          threshold: 20
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
    actions: metricAlertActions
  }
}

// ── Alert 2: DLQ messages present (log query) ─────────────────────────────────
// Any DLQ_ALERT_SUMMARY event emitted by dlq-monitor with dlqMessageCount > 0.
// dlq-monitor runs every 15 minutes; this alert fires within the next eval window.
resource alertDlqMessagesPresent 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: 'alert-dlq-present-${environmentName}'
  location: resourceGroup().location
  properties: {
    description: 'BMWC WMS Bridge — Dead-letter queue has messages. Orders may be blocked. Check wms-soap-dispatcher failures and WMS availability.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    scopes: [workspaceId]
    criteria: {
      allOf: [
        {
          query: '''AppTraces
| where Properties.event == "DLQ_ALERT_SUMMARY"
| extend dlqCount = toint(Properties.dlqMessageCount)
| where dlqCount > 0
| summarize MaxDlq = max(dlqCount) by bin(TimeGenerated, 5m)'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: queryAlertActions
  }
}

// ── Alert 3: WMS SOAP faults spiking (log query) ──────────────────────────────
// Fires when 3 or more WMS_SOAP_FAULT events land in a 10-minute window.
// Indicates a WMS business-rule rejection (bad SKU, duplicate order, etc.)
// rather than a connectivity failure.
resource alertWmsSoapFaultSpike 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: 'alert-wms-soapfault-${environmentName}'
  location: resourceGroup().location
  properties: {
    description: 'BMWC WMS Bridge — Multiple WMS SOAP faults in 10 minutes. Check faultcode/faultstring in Log Analytics for root cause (invalid SKU, warehouse code, etc.).'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [workspaceId]
    criteria: {
      allOf: [
        {
          query: '''AppTraces
| where Properties.event == "WMS_SOAP_FAULT"
| summarize FaultCount = count() by bin(TimeGenerated, 5m)
| where FaultCount >= 3'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: queryAlertActions
  }
}

// ── Alert 4: End-to-end dispatch latency p95 exceeds 3 minutes (log query) ────
// Measures time from _meta.enqueuedAtUtc (SB enqueue) to completedAtUtc (WMS ack).
// p95 > 180s suggests WMS slowness or retry storms building up.
resource alertE2ELatencyHigh 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: 'alert-e2e-latency-${environmentName}'
  location: resourceGroup().location
  properties: {
    description: 'BMWC WMS Bridge — p95 dispatch latency exceeds 3 minutes. WMS may be slow or retrying. Review wms-soap-dispatcher exponential retry counts.'
    enabled: true
    severity: 3
    evaluationFrequency: 'PT10M'
    windowSize: 'PT30M'
    scopes: [workspaceId]
    criteria: {
      allOf: [
        {
          query: '''AppTraces
| where Properties.event == "WMS_DISPATCH_SUCCESS"
| extend enqueuedAt   = todatetime(Properties.enqueuedAtUtc)
| extend completedAt  = todatetime(Properties.completedAtUtc)
| extend latencySec   = datetime_diff("second", completedAt, enqueuedAt)
| summarize p95Latency = percentile(latencySec, 95) by bin(TimeGenerated, 10m)
| where p95Latency > 180'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: queryAlertActions
  }
}

// ── Alert 5: Enqueue failures — ingress cannot write to Service Bus (log query) ─
// ENQUEUE_FAILED events mean BMWC callers received a 500. Orders were not queued.
resource alertEnqueueFailed 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: 'alert-enqueue-failed-${environmentName}'
  location: resourceGroup().location
  properties: {
    description: 'BMWC WMS Bridge — Orders could not be enqueued to Service Bus. BMWC callers received HTTP 500. Check Service Bus connectivity and Logic App run history.'
    enabled: true
    severity: 1   // Critical — data not captured
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [workspaceId]
    criteria: {
      allOf: [
        {
          query: '''AppTraces
| where Properties.event == "ENQUEUE_FAILED"
| summarize FailCount = count() by bin(TimeGenerated, 1m)
| where FailCount >= 1'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: queryAlertActions
  }
}

// ── Alert 6: APIM 5xx rate exceeds 10% of requests (log query) ───────────────
// High 5xx rate from APIM usually means Logic App is down or Service Bus is full.
resource alertApim5xxRate 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: 'alert-apim-5xx-${environmentName}'
  location: resourceGroup().location
  properties: {
    description: 'BMWC WMS Bridge — APIM error rate (5xx) has exceeded 10% of requests in the last 5 minutes. Check Logic App ingress workflow availability.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [workspaceId]
    criteria: {
      allOf: [
        {
          query: '''ApiManagementGatewayLogs
| where ResponseCode >= 500
| summarize ErrorCount = count(), TotalCount = count() by bin(TimeGenerated, 1m)
| extend ErrorRate = toreal(ErrorCount) / toreal(TotalCount) * 100
| where ErrorRate > 10 and TotalCount >= 5'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: queryAlertActions
  }
}
