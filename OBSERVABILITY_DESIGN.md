# BMWC → WMS Bridge — Observability Design

**Version**: 1.0  
**Date**: April 2026

---

## Table of Contents

1. [Logging Strategy](#1-logging-strategy)
2. [Structured Fields to Capture](#2-structured-fields-to-capture)
3. [Tracked Properties in Logic Apps](#3-tracked-properties-in-logic-apps)
4. [Log Analytics Query Examples](#4-log-analytics-query-examples)
5. [Azure Monitor Alert Rules](#5-azure-monitor-alert-rules)
6. [Dashboard Plan](#6-dashboard-plan)
7. [Operational Runbook Notes](#7-operational-runbook-notes)

---

## 1. Logging Strategy

### Three-tier logging model

Every request passes through three observable layers. Each produces independent log records tied together by a single `correlationId`.

```
Tier 1 — APIM Gateway (ApiManagementGatewayLogs)
  Logged by: Azure API Management diagnostics (Application Insights sink)
  What:      Every inbound HTTP request, response code, latency, IP, subscription
  Key field: CorrelationId header echoed from X-Correlation-ID

Tier 2 — Logic App Workflows (AppTraces + WorkflowRuntime tables)
  Logged by: Application Insights + Logic Apps diagnostics → Log Analytics
  What:      Per-run metadata + per-action structured JSON (Compose telemetry events)
  Key field: correlationId in customDimensions

Tier 3 — Service Bus (AzureMetrics)
  Logged by: Service Bus diagnostic settings → Log Analytics
  What:      Queue depth, message count, DLQ count, active messages
  Supplemented by: dlq-monitor workflow emitting DLQ_MESSAGE_DETECTED / DLQ_ALERT_SUMMARY
```

### Correlation — the single traceable thread

The `correlationId` is generated at the APIM boundary (from `X-Correlation-ID` header or APIM `RequestId`) and propagated every step of the way:

```
APIM request log: correlationId = X-Correlation-ID header value
    ↓
bmwc-rest-ingress: Init_CorrelationId variable
    → _meta.correlationId in Service Bus message body
    → userProperties.correlationId in Service Bus broker properties
    ↓
wms-soap-dispatcher: recovered from userProperties.correlationId
    → included in every telemetry Compose event
    → injected into WMS SOAP header (X-Correlation-ID)
    ↓
dlq-monitor: read from userProperties.correlationId on DLQ entries
    ↓
Log Analytics: query by correlationId returns all records for one order
```

A single Log Analytics query on `correlationId` reconstructs the complete journey — from APIM gateway log through to WMS SOAP response — for any individual order.

### Telemetry events emitted by workflows

Logic Apps Standard emits telemetry through Compose actions. The output of each Compose is captured in the run history (visible in Azure Portal → Logic Apps → Run History) and appears in `AppTraces` in Log Analytics via the Application Insights sink.

The full event set:

| Event name | Emitting workflow | Trigger |
|---|---|---|
| `ORDER_ENQUEUED` | `bmwc-rest-ingress` | Successful Service Bus send (implicit in run success) |
| `ENQUEUE_FAILED` | `bmwc-rest-ingress` | `Compose_EnqueueError_Telemetry` |
| `WMS_DISPATCH_SUCCESS` | `wms-soap-dispatcher` | `Compose_WMS_Success_Telemetry` |
| `WMS_SOAP_FAULT` | `wms-soap-dispatcher` | `Compose_SOAP_Fault_Telemetry` |
| `WMS_NON_200` | `wms-soap-dispatcher` | `Compose_WMS_Non200_Telemetry` |
| `WMS_CALL_FAILED` | `wms-soap-dispatcher` | `Compose_WMS_CallError_Telemetry` |
| `DLQ_MESSAGE_DETECTED` | `dlq-monitor` | `Compose_DLQ_Message_Log` (per message) |
| `DLQ_ALERT_SUMMARY` | `dlq-monitor` | `Compose_DLQ_Alert_Summary` |
| `DLQ_QUEUE_CLEAR` | `dlq-monitor` | `Compose_DLQ_Clear_Log` (heartbeat) |

---

## 2. Structured Fields to Capture

All telemetry Compose actions emit flat JSON objects — top-level properties only. This is intentional: Log Analytics parses them without `dynamic()` unwrapping, and each field is directly filterable in KQL.

### Core fields — present in every event

| Field | Type | Description |
|---|---|---|
| `event` | string | Machine-readable event name (see table above) |
| `correlationId` | UUID string | The single trace key — use this to join all records |
| `orderId` | string | BMWC order reference (= Service Bus `messageId`) |
| `workflowRunId` | string | Logic Apps run ID — links to run history in Azure Portal |

### Ingress fields (`bmwc-rest-ingress` events)

| Field | Type | Description |
|---|---|---|
| `customerId` | string | BMWC customer identifier |
| `warehouseCode` | string | Target WMS warehouse |
| `priority` | string | `STANDARD` / `URGENT` / `EXPEDITE` |
| `schemaVersion` | string | Message schema version |
| `enqueuedAtUtc` | ISO 8601 | When the message entered Service Bus |
| `failedAtUtc` | ISO 8601 | Present on `ENQUEUE_FAILED` |
| `errorCode` | string | Service Bus connector error code (on failure) |
| `errorMessage` | string | Service Bus connector error detail (on failure) |

### Dispatch fields (`wms-soap-dispatcher` events)

| Field | Type | Description |
|---|---|---|
| `sbMessageId` | string | Service Bus `messageId` (= `orderId`) — confirms message identity |
| `deliveryCount` | integer | How many times SB has delivered this message |
| `warehouseCode` | string | Target warehouse (from message body) |
| `priority` | string | Order priority (from message body) |
| `wmsStatusCode` | integer | HTTP status code from WMS SOAP endpoint |
| `soapAction` | string | SOAP operation name (`CreateOrder`) |
| `ingestRunId` | string | Run ID of the upstream `bmwc-rest-ingress` run |
| `enqueuedAtUtc` | ISO 8601 | Original enqueue time (from `_meta`) — base for latency calc |
| `completedAtUtc` | ISO 8601 | Present on `WMS_DISPATCH_SUCCESS` — use for latency |
| `faultedAtUtc` | ISO 8601 | Present on `WMS_SOAP_FAULT` |
| `failedAtUtc` | ISO 8601 | Present on `WMS_NON_200` / `WMS_CALL_FAILED` |

### WMS success fields (additional on `WMS_DISPATCH_SUCCESS`)

| Field | Type | Description |
|---|---|---|
| `wmsOrderId` | string | WMS-assigned order ID — the key for WMS status queries |
| `wmsStatus` | string | WMS status string (e.g. `ACCEPTED`) |
| `estimatedReady` | date string | WMS estimated ready date |

### WMS fault fields (additional on `WMS_SOAP_FAULT`)

| Field | Type | Description |
|---|---|---|
| `faultcode` | string | SOAP fault code (e.g. `wms:InvalidSKU`) |
| `faultstring` | string | Human-readable fault description |
| `wmsErrorCode` | string | WMS application-level error code from `detail` element |

### DLQ fields (`DLQ_MESSAGE_DETECTED`)

| Field | Type | Description |
|---|---|---|
| `sbMessageId` | string | Message ID (= original `orderId`) |
| `enqueuedTimeUtc` | ISO 8601 | When the message first entered `wms-inbound` |
| `deadLetterReason` | string | `MaxDeliveryCountExceeded` or `TTLExpiredException` |
| `deadLetterErrorDescription` | string | Last exception from the consumer |
| `deliveryCount` | integer | Final delivery count when dead-lettered |
| `totalDlqMessagesInBatch` | integer | Total DLQ depth seen in this monitor run |
| `queueName` | string | Source queue name |
| `monitorRunTimestampUtc` | ISO 8601 | When `dlq-monitor` ran |

### APIM fields (from `ApiManagementGatewayLogs`)

These are captured automatically by APIM diagnostics — no custom code needed.

| Field | Description |
|---|---|
| `CorrelationId` | From `X-Correlation-ID` header |
| `ResponseCode` | HTTP response sent to BMWC |
| `RequestUri` | Path and query (e.g. `/bmwc/orders`) |
| `DurationMs` | Full round-trip latency at APIM layer |
| `ClientIp` | Source IP (useful for IP allowlist audit) |
| `ApimSubscriptionName` | Which subscription key was used |
| `BackendResponseCode` | HTTP status from Logic App trigger |
| `Method` | HTTP verb |

---

## 3. Tracked Properties in Logic Apps

Logic Apps Standard captures Compose action outputs in run history automatically. To surface fields in the Logic Apps `WorkflowRuntime` table in Log Analytics (and make them queryable without parsing the JSON body), add `trackedProperties` to key actions.

### How to add tracked properties

In `workflow.json`, add a `trackedProperties` block to any action:

```json
"Compose_WMS_Success_Telemetry": {
  "type": "Compose",
  "runAfter": { ... },
  "trackedProperties": {
    "correlationId":  "@{variables('correlationId')}",
    "orderId":        "@{body('Parse_Order_Message')?['orderId']}",
    "event":          "WMS_DISPATCH_SUCCESS",
    "wmsOrderId":     "@{outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['wms:CreateOrderResponse']?['wms:WmsOrderId']}"
  },
  "inputs": { ... }
}
```

Tracked properties appear in the `WorkflowRuntime` table under `customDimensions` within seconds of the run completing. They can be queried even before the full `AppTraces` record is indexed.

### Recommended tracked properties per workflow

**`bmwc-rest-ingress` — on `Send_To_Service_Bus`:**
```json
{
  "correlationId":  "@{variables('correlationId')}",
  "orderId":        "@{body('Parse_BMWC_Order')?['orderId']}",
  "event":          "ORDER_ENQUEUED",
  "customerId":     "@{body('Parse_BMWC_Order')?['customerId']}",
  "warehouseCode":  "@{body('Parse_BMWC_Order')?['warehouseCode']}",
  "priority":       "@{coalesce(body('Parse_BMWC_Order')?['priority'], 'STANDARD')}"
}
```

**`wms-soap-dispatcher` — on `Compose_WMS_Success_Telemetry`:**
```json
{
  "correlationId":   "@{variables('correlationId')}",
  "orderId":         "@{body('Parse_Order_Message')?['orderId']}",
  "event":           "WMS_DISPATCH_SUCCESS",
  "wmsOrderId":      "@{outputs('Compose_Parse_WMS_Response')...}",
  "deliveryCount":   "@{variables('deliveryCount')}",
  "enqueuedAtUtc":   "@{body('Parse_Order_Message')?['_meta']?['enqueuedAtUtc']}"
}
```

**`wms-soap-dispatcher` — on `Compose_SOAP_Fault_Telemetry`:**
```json
{
  "correlationId":  "@{variables('correlationId')}",
  "orderId":        "@{body('Parse_Order_Message')?['orderId']}",
  "event":          "WMS_SOAP_FAULT",
  "faultcode":      "@{outputs('Compose_Parse_WMS_Response')...['faultcode']}",
  "deliveryCount":  "@{variables('deliveryCount')}"
}
```

---

## 4. Log Analytics Query Examples

All queries target the Log Analytics workspace (`log-bmwc-wms-{token}`). Open in Azure Portal → Log Analytics → Logs, or save as Functions for reuse.

---

### Query 1 — All records for a single order by correlation ID

Use this as the first query in any incident investigation. One `correlationId` → full journey.

```kusto
// Replace the GUID with the correlationId from the 202 Accepted response
let searchCorrelationId = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";

// --- APIM gateway record ---
ApiManagementGatewayLogs
| where CorrelationId == searchCorrelationId
| project TimeGenerated, Layer = "APIM", Event = "HTTP_REQUEST",
          Method, RequestUri, ResponseCode, DurationMs, ClientIp
| union (

// --- Logic App workflow events ---
AppTraces
| where isnotempty(Properties.correlationId)
| where tostring(Properties.correlationId) == searchCorrelationId
| project TimeGenerated, Layer = "LogicApp",
          Event          = tostring(Properties.event),
          OrderId        = tostring(Properties.orderId),
          WorkflowRunId  = tostring(Properties.workflowRunId),
          WmsOrderId     = tostring(Properties.wmsOrderId),
          DeliveryCount  = toint(Properties.deliveryCount),
          FaultCode      = tostring(Properties.faultcode),
          StatusCode     = toint(Properties.wmsStatusCode),
          Message        = Message
)
| order by TimeGenerated asc
```

**Expected output for a successful order:**

| Time | Layer | Event | Notes |
|---|---|---|---|
| T+0.0s | APIM | HTTP_REQUEST | 202 response, DurationMs ~800 |
| T+0.1s | LogicApp | ORDER_ENQUEUED | enqueued to wms-inbound |
| T+35s | LogicApp | WMS_DISPATCH_SUCCESS | wmsOrderId populated |

---

### Query 2 — Failed WMS SOAP calls with fault details

Use after a SOAP fault alert fires, or during a demo to show WMS error visibility.

```kusto
AppTraces
| where Properties.event in ("WMS_SOAP_FAULT", "WMS_NON_200", "WMS_CALL_FAILED")
| extend
    Event         = tostring(Properties.event),
    CorrelationId = tostring(Properties.correlationId),
    OrderId       = tostring(Properties.orderId),
    DeliveryCount = toint(Properties.deliveryCount),
    FaultCode     = tostring(Properties.faultcode),
    FaultString   = tostring(Properties.faultstring),
    WmsErrorCode  = tostring(Properties.wmsErrorCode),
    WmsStatusCode = toint(Properties.wmsStatusCode),
    FailureReason = tostring(Properties.failureReason),
    WorkflowRunId = tostring(Properties.workflowRunId)
| project TimeGenerated, Event, OrderId, CorrelationId, DeliveryCount,
          FaultCode, FaultString, WmsErrorCode, WmsStatusCode, FailureReason, WorkflowRunId
| order by TimeGenerated desc
| take 50
```

**To group by fault type (for pattern detection):**

```kusto
AppTraces
| where Properties.event == "WMS_SOAP_FAULT"
| summarize Count = count(), Orders = make_set(tostring(Properties.orderId))
    by FaultCode = tostring(Properties.faultcode),
       bin(TimeGenerated, 1h)
| order by TimeGenerated desc, Count desc
```

---

### Query 3 — Messages that reached the DLQ

Shows every dead-lettered order: its original enqueue time, delivery count, and the reason it was rejected.

```kusto
AppTraces
| where Properties.event == "DLQ_MESSAGE_DETECTED"
| extend
    OrderId          = tostring(Properties.orderId),
    CorrelationId    = tostring(Properties.correlationId),
    EnqueuedAt       = todatetime(Properties.enqueuedTimeUtc),
    DeadLetterReason = tostring(Properties.deadLetterReason),
    ErrorDescription = tostring(Properties.deadLetterErrorDescription),
    DeliveryCount    = toint(Properties.deliveryCount),
    WarehouseCode    = tostring(Properties.warehouseCode),
    Priority         = tostring(Properties.priority),
    QueueName        = tostring(Properties.queueName)
| project TimeGenerated, OrderId, CorrelationId, EnqueuedAt,
          DeadLetterReason, ErrorDescription, DeliveryCount,
          WarehouseCode, Priority, QueueName
| order by TimeGenerated desc
```

**To see current DLQ depth over time (trend chart):**

```kusto
AppTraces
| where Properties.event in ("DLQ_ALERT_SUMMARY", "DLQ_QUEUE_CLEAR")
| extend DlqCount = toint(Properties.dlqMessageCount)
| project TimeGenerated, DlqCount
| order by TimeGenerated asc
| render timechart
```

---

### Query 4 — End-to-end processing latency

Measures time from Service Bus enqueue (`enqueuedAtUtc` in `_meta`) to WMS acknowledgement (`completedAtUtc`). Only covers successful dispatches.

```kusto
AppTraces
| where Properties.event == "WMS_DISPATCH_SUCCESS"
| extend
    OrderId       = tostring(Properties.orderId),
    CorrelationId = tostring(Properties.correlationId),
    EnqueuedAt    = todatetime(Properties.enqueuedAtUtc),
    CompletedAt   = todatetime(Properties.completedAtUtc),
    WarehouseCode = tostring(Properties.warehouseCode),
    Priority      = tostring(Properties.priority),
    DeliveryCount = toint(Properties.deliveryCount)
| extend LatencySec = datetime_diff("second", CompletedAt, EnqueuedAt)
| project TimeGenerated, OrderId, CorrelationId, EnqueuedAt, CompletedAt,
          LatencySec, WarehouseCode, Priority, DeliveryCount
| order by TimeGenerated desc
```

**To see latency percentiles over time (use for SLA reporting):**

```kusto
AppTraces
| where Properties.event == "WMS_DISPATCH_SUCCESS"
| extend
    EnqueuedAt  = todatetime(Properties.enqueuedAtUtc),
    CompletedAt = todatetime(Properties.completedAtUtc)
| extend LatencySec = datetime_diff("second", CompletedAt, EnqueuedAt)
| summarize
    p50 = percentile(LatencySec, 50),
    p95 = percentile(LatencySec, 95),
    p99 = percentile(LatencySec, 99),
    AvgSec  = avg(LatencySec),
    MaxSec  = max(LatencySec),
    OrderCount = count()
    by bin(TimeGenerated, 15m)
| order by TimeGenerated asc
| render timechart
```

**Latency by priority** (for demo: shows URGENT orders completing faster if prioritisation is configured):

```kusto
AppTraces
| where Properties.event == "WMS_DISPATCH_SUCCESS"
| extend
    Priority    = tostring(Properties.priority),
    EnqueuedAt  = todatetime(Properties.enqueuedAtUtc),
    CompletedAt = todatetime(Properties.completedAtUtc)
| extend LatencySec = datetime_diff("second", CompletedAt, EnqueuedAt)
| summarize p95 = percentile(LatencySec, 95), Count = count() by Priority
```

**Bonus — combined success/failure rate by hour:**

```kusto
AppTraces
| where Properties.event in (
    "WMS_DISPATCH_SUCCESS", "WMS_SOAP_FAULT", "WMS_NON_200", "WMS_CALL_FAILED")
| extend Outcome = iff(Properties.event == "WMS_DISPATCH_SUCCESS", "Success", "Failure")
| summarize Count = count() by Outcome, bin(TimeGenerated, 1h)
| render columnchart
```

---

## 5. Azure Monitor Alert Rules

Six alert rules are deployed via [infra/modules/alerts.bicep](infra/modules/alerts.bicep):

| # | Alert name | Severity | Trigger | What it means |
|---|---|---|---|---|
| 1 | `alert-la-runsfailed-{env}` | 2 — Warning | > 5 Logic App run failures in 5 min | Workflow-level failures — check dispatcher + WMS |
| 2 | `alert-dlq-present-{env}` | 2 — Warning | Any `DLQ_ALERT_SUMMARY` with `dlqMessageCount > 0` | Orders stuck — need ops triage |
| 3 | `alert-wms-soapfault-{env}` | 2 — Warning | ≥ 3 `WMS_SOAP_FAULT` events in 10 min | WMS rejecting orders — check fault codes |
| 4 | `alert-e2e-latency-{env}` | 3 — Info | p95 dispatch latency > 3 minutes | WMS slow or retry storms building |
| 5 | `alert-enqueue-failed-{env}` | 1 — Critical | Any `ENQUEUE_FAILED` event | Data loss risk — callers received 500 |
| 6 | `alert-apim-5xx-{env}` | 2 — Warning | 5xx rate > 10% over ≥ 5 requests, 2 consecutive windows | Gateway-level failure — APIM to Logic App |

### Alert severity guidance

| Severity | Azure Monitor value | Action |
|---|---|---|
| Critical | 1 | Immediate — data loss risk or service completely down |
| Warning | 2 | Investigate within 30 minutes |
| Informational | 3 | Review at next ops checkpoint |

### Tuning thresholds for production

| Alert | Demo threshold | Recommended production threshold |
|---|---|---|
| DLQ present | > 0 | > 5 (some occasional failures are acceptable) |
| SOAP fault spike | ≥ 3 in 10 min | ≥ 10 in 10 min (tune to normal WMS error rate) |
| Latency p95 | > 180 s | > 300 s (WMS SLA-dependent) |
| APIM 5xx rate | > 10% over 5 requests | > 5% over 20 requests (reduce noise) |

### Action groups (wire after deployment)

Create an action group in Azure Portal → Monitor → Action Groups:

```bicep
resource actionGroupOpsTeam 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-bmwc-ops-${environmentName}'
  location: 'global'
  properties: {
    groupShortName: 'bmwc-ops'
    enabled: true
    emailReceivers: [
      {
        name: 'Integration Team'
        emailAddress: 'integration-ops@bmwc.example.com'
        useCommonAlertSchema: true
      }
    ]
    // Add Teams notification via Logic App webhook or webhook receiver
  }
}
```

Attach to all six alert rules by adding `actions: [{ actionGroupId: actionGroupOpsTeam.id }]` to each alert resource's `properties`.

---

## 6. Dashboard Plan

A single Azure Workbook covers all key operational views for the demo. Deploy via Azure Portal → Monitor → Workbooks → New, or save as a Workbook JSON template.

### Suggested layout (6 tiles, single scrollable page)

---

**Tile 1 — Health scorecard (top row, 3 KPI counters)**

| Counter | KQL basis |
|---|---|
| Orders enqueued (last 1 h) | `AppTraces \| where Properties.event == "ORDER_ENQUEUED" \| count` |
| Orders dispatched to WMS (last 1 h) | `AppTraces \| where Properties.event == "WMS_DISPATCH_SUCCESS" \| count` |
| Current DLQ depth | Latest `DLQ_ALERT_SUMMARY.dlqMessageCount` or `AzureMetrics DeadletteredMessages` |

---

**Tile 2 — Order success/failure rate (area chart, last 4 h)**

```kusto
AppTraces
| where Properties.event in (
    "WMS_DISPATCH_SUCCESS", "WMS_SOAP_FAULT", "WMS_NON_200", "WMS_CALL_FAILED", "ENQUEUE_FAILED")
| summarize Count = count() by
    Outcome = iff(Properties.event == "WMS_DISPATCH_SUCCESS", "Success", "Failure"),
    bin(TimeGenerated, 15m)
| render areachart
```

---

**Tile 3 — End-to-end latency (line chart, p50/p95/p99, last 4 h)**

```kusto
AppTraces
| where Properties.event == "WMS_DISPATCH_SUCCESS"
| extend LatencySec = datetime_diff("second",
    todatetime(Properties.completedAtUtc),
    todatetime(Properties.enqueuedAtUtc))
| summarize p50 = percentile(LatencySec, 50),
            p95 = percentile(LatencySec, 95),
            p99 = percentile(LatencySec, 99)
    by bin(TimeGenerated, 15m)
| render timechart
```

---

**Tile 4 — Recent failures (grid, last 2 h)**

```kusto
AppTraces
| where Properties.event in ("WMS_SOAP_FAULT", "WMS_NON_200", "WMS_CALL_FAILED", "ENQUEUE_FAILED")
| extend
    Event     = tostring(Properties.event),
    OrderId   = tostring(Properties.orderId),
    CorrId    = tostring(Properties.correlationId),
    Fault     = tostring(Properties.faultcode),
    RunId     = tostring(Properties.workflowRunId)
| project TimeGenerated, Event, OrderId, CorrId, Fault, RunId
| order by TimeGenerated desc
| take 20
```

---

**Tile 5 — DLQ depth trend (line chart, last 24 h)**

```kusto
AppTraces
| where Properties.event in ("DLQ_ALERT_SUMMARY", "DLQ_QUEUE_CLEAR")
| extend DlqCount = toint(Properties.dlqMessageCount)
| project TimeGenerated, DlqCount
| order by TimeGenerated asc
| render timechart
```

---

**Tile 6 — APIM request volume and error rate (two-line chart, last 4 h)**

```kusto
ApiManagementGatewayLogs
| summarize
    TotalRequests = count(),
    Errors5xx = countif(ResponseCode >= 500),
    Errors4xx = countif(ResponseCode >= 400 and ResponseCode < 500)
    by bin(TimeGenerated, 5m)
| extend ErrorRate = toreal(Errors5xx) / toreal(TotalRequests) * 100
| project TimeGenerated, TotalRequests, Errors5xx, Errors4xx, ErrorRate
| render timechart
```

---

### Demo walk-through sequence for the dashboard

1. Submit a test order → watch **Tile 1** counters increment
2. Point to **Tile 3** — "latency is under 30 seconds including exponential retry headroom"
3. Kill the WMS mock → submit another order → watch **Tile 2** flip to Failure
4. Within 15 minutes, **Tile 5** shows DLQ depth rising
5. Restart WMS mock, re-enqueue from DLQ → Tile 2 returns to Success
6. Use Query 1 with the second order's `correlationId` → show full end-to-end trace

---

## 7. Operational Runbook Notes

### Scenario: "I see an alert — where do I start?"

**Step 1 — Get the correlationId**

```bash
# From APIM access log
az monitor log-analytics query \
  --workspace <workspace-id> \
  --analytics-query "ApiManagementGatewayLogs | where TimeGenerated > ago(1h) | where ResponseCode >= 500 | project TimeGenerated, CorrelationId, ResponseCode, DurationMs | order by TimeGenerated desc | take 10"
```

**Step 2 — Run Query 1** (full journey) with that `correlationId`. Identify which layer failed (APIM, ingress, dispatcher).

**Step 3 — Jump to logic app run history**  
Copy `workflowRunId` from the query result. Go to: Azure Portal → Logic Apps → `la-bmwc-wms-{token}` → Workflows → `wms-soap-dispatcher` → Run History → find by run ID.

---

### Success scenario

| Indicator | Value |
|---|---|
| APIM response | `202 Accepted` |
| `bmwc-rest-ingress` run status | `Succeeded` |
| Service Bus `wms-inbound` active count | Returns to 0 within 60 s |
| DLQ depth | 0 |
| `WMS_DISPATCH_SUCCESS` event | Present in `AppTraces` |
| Latency (p95) | < 45 s under normal WMS load |

**Table to show in demo**:

```kusto
AppTraces
| where Properties.event in ("ORDER_ENQUEUED", "WMS_DISPATCH_SUCCESS")
| extend
    OrderId   = tostring(Properties.orderId),
    CorrId    = tostring(Properties.correlationId),
    Event     = tostring(Properties.event),
    WmsRef    = tostring(Properties.wmsOrderId),
    Latency   = iff(Properties.event == "WMS_DISPATCH_SUCCESS",
                    tostring(datetime_diff("second",
                        todatetime(Properties.completedAtUtc),
                        todatetime(Properties.enqueuedAtUtc))),
                    "")
| project TimeGenerated, Event, OrderId, WmsRef, Latency, CorrId
| order by TimeGenerated desc
```

---

### Failure scenario: WMS unavailable

| Indicator | Value |
|---|---|
| APIM response | `202 Accepted` — order is queued; caller sees no failure |
| `wms-soap-dispatcher` run status | `Failed` (after HTTP retries exhaust) |
| Service Bus `deliveryCount` | Increments each retry cycle |
| `WMS_CALL_FAILED` event | Present in `AppTraces` |
| DLQ depth | Rises after 5 deliveries |
| Alert fired | `alert-la-runsfailed-{env}` + `alert-dlq-present-{env}` |

**Remediation query** — find all orders blocked by WMS outage:

```kusto
AppTraces
| where Properties.event == "WMS_CALL_FAILED"
| extend
    OrderId       = tostring(Properties.orderId),
    CorrelationId = tostring(Properties.correlationId),
    DeliveryCount = toint(Properties.deliveryCount),
    FailureReason = tostring(Properties.failureReason),
    FailedAt      = tostring(Properties.failedAtUtc)
| project TimeGenerated, OrderId, CorrelationId, DeliveryCount, FailureReason, FailedAt
| order by TimeGenerated desc
```

---

### Failure scenario: WMS SOAP fault (bad data)

| Indicator | Value |
|---|---|
| `wms-soap-dispatcher` run status | `Failed` (SOAP fault) |
| `WMS_SOAP_FAULT` event | `faultcode`, `faultstring`, `wmsErrorCode` populated |
| Message behaviour | Delivery count increments (retries) unless terminated as `Cancelled` |
| Alert fired | `alert-wms-soapfault-{env}` |

**Remediation query** — group by fault type to identify data quality issues:

```kusto
AppTraces
| where Properties.event == "WMS_SOAP_FAULT"
| summarize Count = count(), UniqueOrders = dcount(tostring(Properties.orderId))
    by FaultCode = tostring(Properties.faultcode),
       FaultString = tostring(Properties.faultstring)
| order by Count desc
```

Common fault code responses:

| Fault code | Likely cause | Action |
|---|---|---|
| `wms:InvalidSKU` | SKU not in WMS item master | Fix at source; settle message as `Cancelled` |
| `wms:InvalidWarehouse` | Warehouse code not provisioned in WMS | Verify `warehouseCode` in BMWC system |
| `wms:DuplicateOrder` | WMS already has this `orderId` | Check if BMWC re-submitted; may need to settle |
| `wms:InternalError` | WMS-side error | Retryable — leave to retry cycle |

---

### Failure scenario: Message reaches DLQ

| Indicator | Value |
|---|---|
| Alert fired | `alert-dlq-present-{env}` |
| `DLQ_ALERT_SUMMARY` event | `dlqMessageCount > 0` |
| `DLQ_MESSAGE_DETECTED` events | One per DLQ message, per monitor run |

**Step 1 — List DLQ messages:**

```kusto
AppTraces
| where Properties.event == "DLQ_MESSAGE_DETECTED"
| where TimeGenerated > ago(1h)
| extend
    OrderId     = tostring(Properties.orderId),
    CorrId      = tostring(Properties.correlationId),
    Reason      = tostring(Properties.deadLetterReason),
    Description = tostring(Properties.deadLetterErrorDescription),
    Warehouse   = tostring(Properties.warehouseCode)
| project TimeGenerated, OrderId, CorrId, Reason, Description, Warehouse
| order by TimeGenerated desc
```

**Step 2 — Run full journey query** (Query 1) on the `correlationId` to confirm the failure chain.

**Step 3 — Re-enqueue after WMS recovery:**

```powershell
# Re-enqueue from DLQ (run after WMS recovers)
az servicebus message send `
  --resource-group $rg `
  --namespace-name $sbNamespace `
  --queue-name wms-inbound `
  --body (az servicebus queue message browse --queue-name 'wms-inbound/$deadletterqueue' ... | ConvertFrom-Json).body `
  --message-id <original-orderId>
```

---

### Fast troubleshooting cheat sheet

```
Symptom                          First query to run
─────────────────────────────    ──────────────────────────────────────────
"My order didn't arrive at WMS"  Query 1 — journey by correlationId
"WMS returning errors"           Query 2 — failed SOAP calls + fault codes
"DLQ alert fired"                Query 3 — DLQ messages + deadLetterReason
"Orders seem slow"               Query 4 — latency percentiles + trend chart
"BMWC getting 500 errors"        AppTraces | where event == "ENQUEUE_FAILED"
"APIM returning 401"             ApiManagementGatewayLogs | where ResponseCode == 401
```
