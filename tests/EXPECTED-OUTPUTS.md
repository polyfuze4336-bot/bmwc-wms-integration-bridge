# BMWC → WMS Bridge — Expected Outputs Reference

This document describes the exact observable output at every platform layer for each demo scenario. Use it during preparation and to verify the environment is behaving correctly before a customer session.

---

## Layer Map

```
[BMWC Caller]
     ↓  HTTPS POST /bmwc/orders
[APIM]                          ← Layer 1: Rate limiting, IP filter, correlation injection
     ↓  HTTP forward to trigger URL
[Logic App: bmwc-rest-ingress]  ← Layer 2: Schema validation, UTC normalisation, enqueue
     ↓  Service Bus SDK
[Service Bus: wms-inbound]      ← Layer 3: Durable queue, duplicate detection, DLQ
     ↓  peek-lock
[Logic App: wms-soap-dispatcher]← Layer 4: Liquid transform JSON→SOAP, HTTP call to WMS
     ↓  SOAP 1.1 over HTTPS
[WMS / Mock]                    ← Layer 5: CreateOrder operation
     ↑  SOAP response
[Log Analytics / App Insights]  ← Layer 6: Structured telemetry, KQL queries, alerts
```

---

## Scenario 1 — Success Path (Standard Order)

### Layer 1 — APIM

| Observable | Expected value |
|---|---|
| HTTP response status | `202 Accepted` |
| `Content-Type` | `application/json` |
| `X-Correlation-ID` response header | Echoes the value sent by caller (or a GUID injected by APIM if omitted) |
| Response body | `{ "accepted": true, "orderId": "ORD-2026-SGP-001", "correlationId": "...", "message": "Order accepted for processing" }` |
| APIM gateway log (`ApiManagementGatewayLogs`) | `ResponseCode: 202`, `BackendResponseCode: 202`, `ApimSubscriptionId: bmwc-demo-subscription` |

### Layer 2 — Logic App: bmwc-rest-ingress

| Observable | Expected value |
|---|---|
| Run status | **Succeeded** |
| Run duration | < 3 seconds |
| Schema validation action | Succeeded (no output — passes through if valid) |
| `Compose_Metadata` action output | `{ "correlationId": "...", "enqueuedAtUtc": "2026-04-10T02:00:00Z", "source": "BMWC", "schemaVersion": "1.0", "workflowRunId": "..." }` |
| `Send_to_Service_Bus` action | Succeeded |
| FlowState app setting `Workflows.bmwc-rest-ingress.FlowState` | `Enabled` |

### Layer 3 — Service Bus

| Observable | Expected value |
|---|---|
| Queue: `wms-inbound` Active Message Count | Increments by 1 (briefly; drops to 0 after dispatcher picks up) |
| Message `MessageId` | `ORD-2026-SGP-001` |
| Message `CorrelationId` | Matches `X-Correlation-ID` header |
| Message body `orderDate` | `2026-04-10T02:00:00Z` (UTC) |
| Message body `_meta.enqueuedAtUtc` | Within 1–2 seconds of submission |
| Duplicate detection window | 10 minutes from first enqueue |

### Layer 4 — Logic App: wms-soap-dispatcher

| Observable | Expected value |
|---|---|
| Run status | **Succeeded** |
| `Receive_Message` action | Succeeded — message body shows JSON canonical envelope |
| `Transform_JSON_to_SOAP` (Liquid) action | Succeeded — output is valid SOAP 1.1 XML |
| `Call_WMS_CreateOrder` HTTP action | Succeeded — HTTP 200 |
| `Call_WMS_CreateOrder` request body | Full SOAP envelope with `<wms:ExternalOrderId>ORD-2026-SGP-001</wms:ExternalOrderId>` |
| `Complete_Message` action | Succeeded — message removed from queue |

### Layer 5 — WMS / Mock

| Observable | Expected value |
|---|---|
| HTTP request received | `POST /WMSService.svc` with `SOAPAction: http://wms.legacy.corp/v1/CreateOrder` |
| HTTP response status | `200 OK` |
| SOAP response `<wms:Status>` | `SUCCESS` |
| SOAP response `<wms:WmsOrderId>` | `WMS-<timestamp>-<random>` (e.g. `WMS-1744250401000-347`) |
| Mock stdout log | `{ "event": "WMS_MOCK_RECEIVED", "orderId": "ORD-2026-SGP-001", ... }` |

### Layer 6 — Log Analytics (AppTraces)

Run these KQL queries to verify:

```kusto
// ── Enqueue confirmation ──────────────────────────────────────────────────────
AppTraces
| where Properties.event == "ENQUEUE_SUCCESS"
| where Properties.orderId == "ORD-2026-SGP-001"
| project TimeGenerated, Properties.correlationId, Properties.enqueuedAtUtc
```
Expected: 1 row.

```kusto
// ── WMS dispatch confirmation ─────────────────────────────────────────────────
AppTraces
| where Properties.event == "WMS_DISPATCH_SUCCESS"
| where Properties.orderId == "ORD-2026-SGP-001"
| project TimeGenerated, Properties.wmsOrderId, Properties.completedAtUtc, Properties.correlationId
```
Expected: 1 row. `wmsOrderId` populated with the WMS-assigned reference.

---

## Scenario 2 — Timezone Normalisation (UTC from GMT+8)

### Layer 2 — bmwc-rest-ingress (delta from Scenario 1)

| Observable | Expected value |
|---|---|
| Ingress input `orderDate` | `2026-04-10T10:00:00+08:00` |
| `Normalize_Timestamps` Compose expression output | `2026-04-10T02:00:00Z` |
| Service Bus message body `orderDate` | `2026-04-10T02:00:00Z` (UTC — offset stripped) |

### Layer 3 — Service Bus

| Observable | Expected value |
|---|---|
| Message body `orderDate` | `2026-04-10T02:00:00Z` — UTC, regardless of what the caller sent |
| Message body `requestedDeliveryDate` | `2026-04-10T10:00:00Z` (18:00+08:00 → UTC) |

### Layer 4 — wms-soap-dispatcher

| Observable | Expected value |
|---|---|
| SOAP `<wms:OrderDate>` | `2026-04-10T02:00:00Z` — UTC |
| SOAP `<wms:RequestedDeliveryDate>` | `2026-04-10T10:00:00Z` — UTC |

### Reporting layer (narrative — no infrastructure change needed)

> When displayed in a Power BI report or Azure Monitor Workbook with `datetime_local()` applied at GMT+8:
> - `2026-04-10T02:00:00Z` → **10:00 AM MYT, 10 April 2026**
> - `2026-04-10T10:00:00Z` → **6:00 PM MYT, 10 April 2026**
>
> The raw stored value does not change. GMT+8 rendering is a display-only transformation.

---

## Scenario 3 — Transient Failure & Retry

### Layer 2 — bmwc-rest-ingress

No change from Scenario 1. The ingress does not know the WMS is down — it enqueues successfully and returns 202.

### Layer 4 — wms-soap-dispatcher (while WMS is down)

| Observable | Expected value |
|---|---|
| `Call_WMS_CreateOrder` attempt 1 | Failed — connection refused / HTTP 500 |
| `Call_WMS_CreateOrder` attempt 2 | Failed — retried after 5 seconds |
| `Call_WMS_CreateOrder` attempt 3 | Failed — retried after 30 seconds |
| Run status after 3 attempts | **Failed** |
| Service Bus message delivery count | Increments by 1 per failed run (tracked by Service Bus) |
| Message lock renewal | Auto-renewed while Logic App is processing |
| Message visibility after run failure | Message becomes available again after lock expiry (30 seconds by default) |

### Layer 3 — Service Bus (after maxDeliveryCount = 5 exhausted)

| Observable | Expected value |
|---|---|
| `wms-inbound` Active Message Count | 0 (message moved to DLQ) |
| `wms-dead-letter-review` Active Message Count | +1 |
| Message `DeadLetterReason` | `MaxDeliveryCountExceeded` |
| Message `DeadLetterErrorDescription` | Details of last failure |

### After WMS restored

| Observable | Expected value |
|---|---|
| Service Bus | Lock expiry causes message to become available; dispatcher picks it up automatically |
| `wms-soap-dispatcher` run | Succeeds on next pickup |
| Log Analytics | `WMS_DISPATCH_SUCCESS` event appears |

---

## Scenario 4 — DLQ Consolidation

### Layer 4 — wms-soap-dispatcher (all 3 messages)

| Observable | Expected value |
|---|---|
| `Call_WMS_CreateOrder` response | HTTP 200 with SOAP Fault body |
| SOAP `<faultcode>` | `soap:Client.Validation` |
| SOAP `<faultstring>` | `Invalid item code SKU-X-999: item not found in warehouse WH-DLQ item master` |
| Logic App action outcome | Failed on HTTP parse (fault body treated as error) |

### Layer 3 — Service Bus

| Observable | Expected value |
|---|---|
| `wms-dead-letter-review` Active Message Count | 3 |
| Each message `DeadLetterReason` | `MaxDeliveryCountExceeded` |
| Each message body | Full original JSON — no data loss |

### Layer 6 — Log Analytics

```kusto
// ── WMS fault events for DLQ demo orders ─────────────────────────────────────
AppTraces
| where Properties.event == "WMS_SOAP_FAULT"
| where Properties.orderId startswith "ORD-2026-DLQ"
| project TimeGenerated, Properties.orderId, Properties.faultcode, Properties.faultstring
| order by TimeGenerated asc
```
Expected: 3 rows (one per order × up to 5 delivery attempts = up to 15 WMS_SOAP_FAULT rows).

```kusto
// ── DLQ summary from dlq-monitor ─────────────────────────────────────────────
AppTraces
| where Properties.event == "DLQ_ALERT_SUMMARY"
| project TimeGenerated, Properties.dlqMessageCount, Properties.queueName
```
Expected: 1 row with `dlqMessageCount = 3` (emitted by dlq-monitor within 15 minutes).

### Azure Monitor alert

| Observable | Expected value |
|---|---|
| Alert rule `alert-dlq-present-{env}` | **Fired** (if `dlqMessageCount > 0` is detected within evaluation window) |
| Alert state | Active |
| Notification | Email/SMS/Teams message to action group (if wired) |

---

## Scenario 5 — Invalid Request (Schema Validation)

### Layer 1 — APIM

| Observable | Expected value |
|---|---|
| HTTP response status | `400 Bad Request` |
| Response body | Logic App validation error JSON — references the failing field(s) |

### Layer 2 — bmwc-rest-ingress

| Observable | Expected value |
|---|---|
| Run status | **Failed** (or returned error — depends on trigger config) |
| Schema validation action | **Failed** with details: `Required property 'orderId' not found`; `Required property 'lines' not found` |

### Layer 3 — Service Bus

| Observable | Expected value |
|---|---|
| `wms-inbound` Active Message Count | **Unchanged** — no message written |

### Layer 4 — wms-soap-dispatcher

| Observable | Expected value |
|---|---|
| Run History | **No new run** — dispatcher was never triggered |

### Layer 5 — WMS

| Observable | Expected value |
|---|---|
| Mock stdout | No new log line — WMS was never called |

---

## Scenario 6 — Idempotency (Duplicate orderId)

### Layer 1 — APIM

| Observable | Expected value |
|---|---|
| HTTP response status | `202 Accepted` (same as first submission — ingress is unaware of duplication) |

### Layer 3 — Service Bus

| Observable | Expected value |
|---|---|
| `wms-inbound` Active Message Count | **Does not change** — duplicate silently dropped |
| Service Bus Duplicate Detection log | Not directly visible in Portal; observable via Metrics → Successful Messages vs Incoming Messages delta |

### Layer 4 — wms-soap-dispatcher

| Observable | Expected value |
|---|---|
| Run History | **No new run** after the duplicate submission |

### Layer 6 — Log Analytics

```kusto
// ── Confirm only one ENQUEUE_SUCCESS for this orderId ─────────────────────────
AppTraces
| where Properties.event == "ENQUEUE_SUCCESS"
| where Properties.orderId == "ORD-2026-SGP-001"
| summarize EnqueueCount = count()
```
Expected: `EnqueueCount = 1` — regardless of how many times the order was submitted within the dedup window.

---

## Complete End-to-End KQL Query Pack

Save these queries in the Log Analytics workspace as **Saved Queries → BMWC WMS Bridge**.

```kusto
// ── 1. All events for a specific order ───────────────────────────────────────
AppTraces
| where Properties.orderId == "ORD-2026-SGP-001"
| project TimeGenerated, Properties.event, Properties.correlationId, Properties.wmsOrderId
| order by TimeGenerated asc


// ── 2. End-to-end success rate (last 24h) ────────────────────────────────────
AppTraces
| where TimeGenerated > ago(24h)
| where Properties.event in ("ENQUEUE_SUCCESS", "WMS_DISPATCH_SUCCESS", "WMS_SOAP_FAULT", "ENQUEUE_FAILED")
| summarize Count = count() by tostring(Properties.event)
| order by Count desc


// ── 3. p95 dispatch latency (last 1h) ────────────────────────────────────────
AppTraces
| where TimeGenerated > ago(1h)
| where Properties.event == "WMS_DISPATCH_SUCCESS"
| extend enqueuedAt  = todatetime(Properties.enqueuedAtUtc)
| extend completedAt = todatetime(Properties.completedAtUtc)
| extend latencySec  = datetime_diff("second", completedAt, enqueuedAt)
| summarize p50 = percentile(latencySec, 50), p95 = percentile(latencySec, 95), p99 = percentile(latencySec, 99)


// ── 4. WMS faults with detail ─────────────────────────────────────────────────
AppTraces
| where TimeGenerated > ago(1h)
| where Properties.event == "WMS_SOAP_FAULT"
| project TimeGenerated, Properties.orderId, Properties.faultcode, Properties.faultstring, Properties.correlationId
| order by TimeGenerated desc


// ── 5. DLQ alert summaries ────────────────────────────────────────────────────
AppTraces
| where Properties.event == "DLQ_ALERT_SUMMARY"
| project TimeGenerated, Properties.dlqMessageCount, Properties.queueName
| order by TimeGenerated desc


// ── 6. APIM 5xx rate ─────────────────────────────────────────────────────────
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| summarize ErrorCount = countif(ResponseCode >= 500), TotalCount = count() by bin(TimeGenerated, 5m)
| extend ErrorRate = round(toreal(ErrorCount) / toreal(TotalCount) * 100, 2)
| project TimeGenerated, TotalCount, ErrorCount, ErrorRate
| order by TimeGenerated desc


// ── 7. Orders by warehouse (last 24h) ────────────────────────────────────────
AppTraces
| where TimeGenerated > ago(24h)
| where Properties.event == "ENQUEUE_SUCCESS"
| summarize Orders = count() by tostring(Properties.warehouseCode)
| order by Orders desc
```

---

*Expected outputs reference — BMWC → WMS Bridge POC — April 2026.*
