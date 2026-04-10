# BMWC → WMS Bridge — Service Bus Design

**Version**: 1.0  
**Date**: April 2026  
**SKU**: Azure Service Bus Standard

---

## Table of Contents

1. [Queue Naming Conventions](#1-queue-naming-conventions)
2. [Message Metadata — Broker Properties](#2-message-metadata--broker-properties)
3. [Retry and Lock Renewal Considerations](#3-retry-and-lock-renewal-considerations)
4. [Duplicate Detection Recommendations](#4-duplicate-detection-recommendations)
5. [Poison Message Handling](#5-poison-message-handling)
6. [DLQ Operational Guidance](#6-dlq-operational-guidance)
7. [Logic App Integration — Write and Consume](#7-logic-app-integration--write-and-consume)
8. [Test Scenarios](#8-test-scenarios)

---

## 1. Queue Naming Conventions

### Queue inventory

| Queue name | Bicep resource | Purpose | Retention | Location |
|---|---|---|---|---|
| `wms-inbound` | `wmsInboundQueue` | Primary work queue — BMWC orders pending WMS dispatch | 4 h TTL | Explicit |
| `wms-inbound/$deadletterqueue` | (built-in sub-queue) | Automatic dead-letter for exhausted or expired messages | 14 days (platform) | Built-in sub-queue |
| `wms-dead-letter-review` | `wmsDeadLetterQueue` | Ops review queue — receives copied DLQ messages for team investigation | 7 days | Explicit |

`wms-dead-letter-review` is a **separate operational queue** that ops tooling can write to after human triage. It is not wired automatically — do not treat it as a second DLQ. The platform `wms-inbound/$deadletterqueue` is the authoritative dead-letter destination and is read by the `dlq-monitor` workflow.

### Naming rules

```
{target-system}-{stage}
  wms-inbound              ← orders entering the WMS pipeline
  wms-dead-letter-review   ← ops copy queue for remediation artefacts

Future queues follow the same pattern:
  wms-cancellations        ← if WMS adds CancelOrder WSDL operation
  wms-status-updates       ← if WMS pushes async status callbacks
  erp-inbound              ← if ERP integration is added
```

**Conventions enforced:**
- All lowercase, hyphen-separated
- Prefix is the target system (`wms-`), not the source (`bmwc-`) — the queue belongs to the WMS pipeline, not to BMWC
- The stage (`inbound`, `outbound`, `retry`, `review`) follows the system prefix
- No environment suffix in the name — the namespace name carries the environment token (`sb-bmwc-wms-dev`, `sb-bmwc-wms-prod`)

### Namespace naming

```
sb-{project}-{env}
Examples:
  sb-bmwc-wms-dev
  sb-bmwc-wms-uat
  sb-bmwc-wms-prod
```

---

## 2. Message Metadata — Broker Properties

Each message entering `wms-inbound` carries two layers of metadata: **broker properties** (system-level, indexed by Service Bus) and **user properties** (application-level, queryable via filters).

### Broker properties set by the sender

| Property | Value | Purpose |
|---|---|---|
| `MessageId` | `orderId` (e.g. `ORD-2026-SGP-001`) | Idempotency key — drives duplicate detection |
| `ContentType` | `application/json` | Consumer schema hint; MIME type of `contentData` |
| `Label` / `Subject` | `BMWC.Order.v1` | Message classifier — consumers can filter by label; version suffix enables schema evolution |
| `TimeToLive` | `PT4H` (inherited from queue) | Sets `ExpiresAtUtc` — auto-DLQs if not consumed within 4 h |

**`MessageId = orderId`** is the single most important property. Service Bus uses it for duplicate detection, and ops tooling can use it to locate a specific message without knowing the internal broker sequence number.

### User properties (application metadata)

Set in the `userProperties` block of the Logic Apps Standard Service Bus connector:

| Property | Type | Value | Source |
|---|---|---|---|
| `correlationId` | string | UUID from `X-Correlation-ID` or generated | APIM inbound → bmwc-rest-ingress |
| `orderId` | string | BMWC order reference | Request body |
| `customerId` | string | BMWC customer ID | Request body |
| `warehouseCode` | string | Target WMS warehouse | Request body |
| `priority` | string | `STANDARD` / `URGENT` / `EXPEDITE` | Request body (default: `STANDARD`) |
| `schemaVersion` | string | `1.0` | Hardcoded in ingress workflow |

User properties are **indexed by Service Bus** for server-side filtering — a consumer can subscribe to only `warehouseCode = 'WH-SIN'` messages without reading the full body. They are also exposed in DLQ entries, enabling triage without deserialising the body.

### Message body structure (canonical envelope)

The JSON content enqueued by `bmwc-rest-ingress` is the **enriched canonical message** — the original BMWC order plus a `_meta` block injected by the integration layer:

```json
{
  "orderId":       "ORD-2026-SGP-001",
  "customerId":    "CUST-BMWC-001",
  "warehouseCode": "WH-SIN",
  "orderDate":     "2026-04-09T02:00:00Z",
  "priority":      "STANDARD",
  "lines": [
    { "lineNo": 1, "sku": "SKU-W-001", "quantity": 50, "uom": "EA" }
  ],
  "shipTo": {
    "name": "BMWC Assembly Plant 1",
    "address1": "Lot 5, Jalan Jubli Perak",
    "city": "Shah Alam",
    "country": "MY"
  },
  "_meta": {
    "correlationId":  "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "enqueuedAtUtc":  "2026-04-09T02:00:01Z",
    "source":         "BMWC",
    "schemaVersion":  "1.0",
    "workflowRunId":  "08585012345678901234567890ABCDEF"
  }
}
```

The `_meta` block is the **authoritative trace envelope**. Downstream workflows must read `_meta.correlationId` rather than re-derive it. `workflowRunId` links back to the `bmwc-rest-ingress` run in Logic Apps run history.

### What is NOT stored in the message

- WMS credentials (`_auth`) — injected at dispatch time from Key Vault; never persisted in Service Bus
- APIM subscription key — stripped by APIM global policy before reaching Logic Apps
- HTTP headers beyond `X-Correlation-ID` — not propagated into the SB message body

---

## 3. Retry and Lock Renewal Considerations

### Message lock duration

The `wms-inbound` queue is configured with `lockDuration: PT5M` (5 minutes). This is the time `wms-soap-dispatcher` holds exclusive ownership of a message before Service Bus assumes the consumer is dead and releases the lock for redelivery.

**The 5-minute budget covers:**
- Base64 decode + JSON parse: < 1 s
- Liquid SOAP transform: < 1 s
- WMS HTTP call (with up to 3 exponential retries): worst case ~3–4 min (15s + 30s + 60s + 60s timeout)
- SOAP fault parse + telemetry compose: < 1 s

**Total worst-case: ~4 min** — within the 5-minute lock.

> **If the WMS is completely unreachable**, the HTTP action will attempt 3 retries over ~3–4 minutes and then fail the action. The Logic Apps run fails → the lock expires naturally → Service Bus increments the delivery count and redelivers. This is the intended behaviour — **do not use lock renewal** for this pattern.

### Lock renewal — when to use it

Lock renewal (`RenewMessageLock`) is relevant only when your processing is known to exceed `lockDuration`. It is **not needed** here because:

1. `wms-soap-dispatcher` fails fast on WMS error (it does not poll or wait indefinitely)
2. The 5-minute lock gives adequate headroom for the exponential retry chain
3. If processing does exceed 5 minutes, allowing the lock to expire is the correct signal for Service Bus to redeliver — it avoids hiding a hung run

If the WMS WSDL is extended to include long-running operations (e.g. batch ordering with multi-second WMS processing), increase `lockDuration` to `PT10M` in the Bicep before introducing lock renewal.

### Logic Apps retry policy on the HTTP action

`Call_WMS_SOAP_Endpoint` uses `exponential` retry with:

```
count:           3        (3 retries after the initial attempt = 4 total calls)
interval:        PT15S    (first wait)
minimumInterval: PT5S
maximumInterval: PT1H     (cap — prevents unbounded waits)
```

**Retry timing (worst case, all retries exhaust):**

```
t=0      Initial call    → WMS timeout (60 s)
t=60     Wait 15 s
t=75     Retry 1         → WMS timeout (60 s)
t=135    Wait 30 s
t=165    Retry 2         → WMS timeout (60 s)
t=225    Wait 60 s
t=285    Retry 3         → WMS timeout (60 s)
t=345    Action fails    → run fails → lock expires → SB redelivers
```

This is ~5.75 minutes — marginally beyond the 5-minute lock. **Recommendation**: increase `lockDuration` to `PT10M` to ensure the lock covers the full exponential chain. Update `servicebus.bicep`:

```bicep
lockDuration: 'PT10M'   // covers 4 x 60s WMS call + 3 retries + headroom
```

### Delivery count increment mechanics

Service Bus increments `DeliveryCount` when:
- The lock expires (consumer did not complete or abandon)
- The consumer explicitly abandons the message (`Abandon`)
- A Logic Apps run terminates with `Failed` status

It does **not** increment when:
- The run terminates with `Cancelled` status — use this for non-retryable WMS business faults (e.g. `wms:InvalidSKU`) to avoid burning delivery count on known-bad data

### Handling WMS maintenance windows

During a planned WMS maintenance window, messages accumulate in `wms-inbound` with no consumer progressing them. Because `lockDuration = PT5M`, locks expire and messages stay unlocked. The `wms-soap-dispatcher` trigger will pick up the same message again once the maintenance window ends and the workflow runs again.

**Key point**: No operator intervention is needed during a WMS outage as long as:
1. The TTL (`PT4H`) is longer than the outage window, OR
2. The TTL is extended (see Section 6 for the CLI command)

If a maintenance window exceeds 4 hours, extend the TTL before work begins:

```bash
az servicebus queue update \
  --resource-group <rg> \
  --namespace-name <sb-namespace> \
  --name wms-inbound \
  --default-message-time-to-live PT24H
```

---

## 4. Duplicate Detection Recommendations

### Configuration

```bicep
requiresDuplicateDetection: true
duplicateDetectionHistoryTimeWindow: 'PT10M'
```

`messageId = orderId` (set in `Send_To_Service_Bus` in `bmwc-rest-ingress`).

### How it works

When `bmwc-rest-ingress` sends a message, Service Bus stores the `MessageId` in a ring buffer for 10 minutes. If the same `MessageId` arrives again within that window, Service Bus silently discards it and returns HTTP 201 to the sender — **no error, no exception in the Logic App**. The duplicate is absorbed without the consumer ever seeing it.

### The 10-minute window: rationale and limits

10 minutes is chosen to cover:
- APIM timeout retry by the BMWC client (if the 202 was not received due to a transient network issue)
- Logic Apps cold-start scenario (first run after idle warms up in 5–10 s; at high submission rate, a BMWC client might retry faster than APIM delivers the 202)

**What 10 minutes does NOT cover:**
- BMWC submitting the same order hours or days later (human error re-submission)
- Orders with a different `orderId` for the same business order (BMWC system bug generating duplicate IDs)

For longer idempotency windows (same-day protection), implement a secondary check at the Logic Apps level:
- On `Parse_Order_Message` in `wms-soap-dispatcher`, query a Table Storage or Cosmos DB "processed orders" table for the `orderId`
- If found with status `WMS_ACCEPTED`, short-circuit and complete the message without calling WMS

This catches duplicates that arrive after the 10-minute SB window closes.

### Avoid: non-stable MessageId values

Do not use `guid()`, `utcNow()`, or workflow run IDs as `MessageId`. They change on every call, making duplicate detection ineffective. The only correct value is a **stable identifier from the originating system** — `orderId` in this case.

### Schema versioning and deduplication

If the schema version changes (e.g. `1.0` → `2.0`) and both schemas for the same `orderId` exist in flight, they will be deduplicated — the second one is dropped even if the body is different. Coordinate schema migrations so no order crosses a schema version boundary while in-flight in the queue.

---

## 5. Poison Message Handling

### What counts as a poison message

A message is "poisonous" when it cannot be processed successfully regardless of how many times it is retried. Causes fall into two categories:

**Structural poison (malformed data):**
- `contentData` is not valid base64 → `base64ToString()` throws → run fails
- Decoded content is not valid JSON → `ParseJson` fails → run fails
- Required field missing (e.g. `orderId`, `lines`) → downstream action fails → run fails
- `lines` is an empty array → Liquid `{% for %}` loop emits no `<OrderLine>` elements → WMS rejects with `wms:EmptyOrder` SOAP fault → non-retryable

**Transient poison (recoverable with time):**
- WMS unreachable → exponential retries exhaust → run fails → SB redelivers
- WMS returns HTTP 500 → retried → if consistently failing, becomes structural after 5 deliveries
- Lock expires before processing completes → SB redelivers (not a true poison message — just slow)

### Delivery count threshold

The queue is configured with `maxDeliveryCount: 5`. After 5 failed deliveries, Service Bus moves the message to the built-in dead-letter sub-queue (`wms-inbound/$deadletterqueue`) and stamps it with:

| DLQ property | Value |
|---|---|
| `DeadLetterReason` | `MaxDeliveryCountExceeded` |
| `DeadLetterErrorDescription` | The last exception message from the consumer |

### Distinguishing non-retryable faults in code

When `wms-soap-dispatcher` detects a **known non-retryable SOAP fault** (e.g. `wms:InvalidSKU`, `wms:DuplicateOrder`), the correct action is to **terminate the run as `Cancelled`** rather than `Failed`:

```json
"Terminate_SOAP_Fault": {
  "type": "Terminate",
  "inputs": {
    "runStatus": "Cancelled",
    "runError": {
      "code": "WMS_SOAP_FAULT",
      "message": "@{...fault details...}"
    }
  }
}
```

**Why `Cancelled`**: A `Cancelled` termination causes the Logic Apps Service Bus trigger to **complete (settle) the message** — it is removed from the queue and its delivery count is not incremented. This prevents burning all 5 retry slots on a message that will never succeed no matter how many times it is retried.

**Use `Failed` for retryable errors**: When the run terminates as `Failed`, the lock expires and delivery count increments. Use this for transient errors (WMS timeout, network error, HTTP 500) where a later retry has a reasonable chance of succeeding.

### Decision table

| Situation | Terminate status | Outcome |
|---|---|---|
| WMS SOAP fault: `wms:InvalidSKU` | `Cancelled` | Message settled (removed), no retry |
| WMS SOAP fault: `wms:InternalError` | `Failed` | Lock expires, SB redelivers |
| WMS HTTP 500 (all retries exhausted) | `Failed` | Lock expires, SB redelivers |
| WMS HTTP 503 / timeout | `Failed` | Lock expires, SB redelivers |
| JSON parse failure | `Failed` | Lock expires, redelivers until DLQ |
| `orderId` missing after 5 retries | DLQ | Ops notified via dlq-monitor |

### Alerting on delivery count

The `Init_DeliveryCount` variable in `wms-soap-dispatcher` captures `triggerBody()?['deliveryCount']`. Add a condition after initialisation to emit a high-priority alert when `deliveryCount >= 3`:

```json
"Check_High_Delivery_Count": {
  "type": "Condition",
  "runAfter": { "Init_DeliveryCount": ["Succeeded"] },
  "expression": {
    "and": [{ "greaterOrEquals": ["@variables('deliveryCount')", 3] }]
  },
  "actions": {
    "Compose_Retry_Warning_Telemetry": {
      "type": "Compose",
      "inputs": {
        "event":         "HIGH_DELIVERY_COUNT",
        "deliveryCount": "@variables('deliveryCount')",
        "orderId":       "@variables('sbMessageId')",
        "correlationId": "@variables('correlationId')",
        "message":       "Message approaching DLQ threshold"
      }
    }
  },
  "else": { "actions": {} }
}
```

This gives ops an early warning before the message crosses the DLQ threshold.

---

## 6. DLQ Operational Guidance

### Sub-queue address

```
wms-inbound/$deadletterqueue
```

The `dlq-monitor` workflow reads from this address using Service Bus peek (non-destructive). Messages remain locked in the DLQ until explicitly completed or moved by an operator.

### DLQ entry anatomy

Each DLQ entry contains all original broker properties plus two additional system properties:

| Property | Source |
|---|---|
| Original `MessageId` (= `orderId`) | From the original message |
| Original user properties | `correlationId`, `customerId`, `warehouseCode`, etc. |
| `DeadLetterReason` | Set by Service Bus: `MaxDeliveryCountExceeded` or `TTLExpiredException` |
| `DeadLetterErrorDescription` | Last exception/error from the consumer |
| `EnqueuedTimeUtc` | When the message first entered `wms-inbound` |
| `DeadLetterEnqueuedTime` | When the message was moved to DLQ |

### DLQ monitoring — current implementation

`dlq-monitor` runs every 15 minutes on a recurrence trigger. It:
1. Peeks up to 10 messages from `wms-inbound/$deadletterqueue`
2. Logs each message's `orderId`, `correlationId`, `deadLetterReason`, and `deadLetterErrorDescription`
3. Sets `alertNeeded = true` if count exceeds `DlqAlertThreshold` parameter (default: 1)
4. Emits a summary telemetry Compose action — the `Placeholder_Send_Notification` stub needs wiring to Teams or email (see below)

### Wiring the notification stub

Replace `Placeholder_Send_Notification` with a Teams connector action or Logic Apps Standard HTTP call to an email service:

**Teams webhook example:**
```json
"Notify_Teams_DLQ_Alert": {
  "type": "Http",
  "inputs": {
    "method": "POST",
    "uri": "@parameters('TeamsWebhookUrl')",
    "headers": { "Content-Type": "application/json" },
    "body": {
      "type": "message",
      "attachments": [{
        "contentType": "application/vnd.microsoft.card.adaptive",
        "content": {
          "type": "AdaptiveCard",
          "body": [{
            "type": "TextBlock",
            "text": "⚠️ BMWC→WMS DLQ Alert: @{variables('dlqMessageCount')} message(s) dead-lettered in wms-inbound",
            "weight": "Bolder"
          }]
        }
      }]
    }
  }
}
```

### Remediation playbook

**Step 1 — Identify root cause**

```bash
# List DLQ messages and their dead-letter reasons
az servicebus queue message browse \
  --resource-group <rg> \
  --namespace-name <sb-namespace> \
  --queue-name wms-inbound/$deadletterqueue \
  --count 10
```

Or query Log Analytics:
```kusto
traces
| where message contains "DISPATCH_FAILED" or message contains "SOAP_FAULT"
| extend orderId = tostring(customDimensions.orderId)
| extend reason = tostring(customDimensions.deadLetterReason)
| order by timestamp desc
```

**Step 2 — Classify the failure**

| Root cause | Action |
|---|---|
| WMS was down during TTL window | Re-enqueue to `wms-inbound` after WMS recovers |
| Malformed body (bad JSON) | Fix at source (BMWC system); do not re-enqueue the corrupted message |
| WMS SOAP fault (business error) | Investigate WMS item master / warehouse codes; fix data and re-enqueue |
| Duplicate order that should not have been sent | Discard from DLQ; investigate BMWC upstream deduplication |

**Step 3 — Re-enqueue valid messages**

```bash
# Download the message body from DLQ
az servicebus message receive \
  --resource-group <rg> \
  --namespace-name <sb-namespace> \
  --queue-name "wms-inbound/\$deadletterqueue" \
  --max-message-count 1

# Re-send to wms-inbound after saving the body to order-body.json
az servicebus message send \
  --resource-group <rg> \
  --namespace-name <sb-namespace> \
  --queue-name wms-inbound \
  --body @order-body.json \
  --message-id <the-original-orderId>
```

> Re-sending with the original `messageId` (= `orderId`) is safe within the duplicate detection window **only if the original message was consumed** from the main queue. If re-queuing due to TTL expiry (the original was never consumed), use the same `orderId` — duplicate detection will allow it because the original expired, not settled.

**Step 4 — Archive and complete from DLQ**

After re-enqueueing or discarding, receive and complete the DLQ copy to drain it:

```bash
az servicebus message receive \
  --resource-group <rg> \
  --namespace-name <sb-namespace> \
  --queue-name "wms-inbound/\$deadletterqueue" \
  --peak-lock true
# Use the lockToken from the response to complete:
az servicebus message complete \
  --lock-token <lockToken> ...
```

### Azure Monitor alert for DLQ depth

Set this alert in addition to the `dlq-monitor` workflow — it fires without requiring the Logic App to be running:

```bicep
resource dlqDepthAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-wms-inbound-dlq'
  properties: {
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [{
        name: 'DLQDepth'
        metricName: 'DeadletteredMessages'
        dimensions: [{ name: 'QueueName', operator: 'Include', values: ['wms-inbound'] }]
        operator: 'GreaterThan'
        threshold: 0
        timeAggregation: 'Maximum'
        criterionType: 'StaticThresholdCriterion'
      }]
    }
    severity: 2
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
  }
}
```

---

## 7. Logic App Integration — Write and Consume

### 7a. Ingress workflow — `bmwc-rest-ingress` (Writer)

**Pattern**: Fire-and-forget. The workflow validates, enriches, and enqueues, then returns `202 Accepted` without waiting for WMS response.

```
HTTP POST (APIM) → Validate schema → Init correlationId → Normalise timestamp
→ Parse body → Compose enriched message (with _meta) → Send to Service Bus
→ 202 Accepted
```

**Key settings on `Send_To_Service_Bus`:**

```json
"message": {
  "contentData":   "@string(outputs('Compose_Enriched_Message'))",
  "contentType":   "application/json",
  "messageId":     "@{body('Parse_BMWC_Order')?['orderId']}",
  "label":         "BMWC.Order.v1",
  "userProperties": {
    "correlationId":  "@{variables('correlationId')}",
    "orderId":        "@{body('Parse_BMWC_Order')?['orderId']}",
    "customerId":     "@{body('Parse_BMWC_Order')?['customerId']}",
    "warehouseCode":  "@{body('Parse_BMWC_Order')?['warehouseCode']}",
    "priority":       "@{coalesce(body('Parse_BMWC_Order')?['priority'], 'STANDARD')}",
    "schemaVersion":  "1.0"
  }
}
```

**On send failure**: `Scope_EnqueueFailure` catches `Failed / TimedOut / Skipped` on `Send_To_Service_Bus` and returns `500` to APIM. BMWC knows the message was **not** queued and must retry with the same `orderId`.

**Connection**: `serviceBus` named connection in `connections.json`, bound to the Service Bus namespace via Managed Identity (RBAC role: `Azure Service Bus Data Sender`).

### 7b. Dispatcher workflow — `wms-soap-dispatcher` (Consumer)

**Pattern**: Competing consumers. Logic Apps Standard runs up to 3 elastic worker instances, each capable of concurrently picking messages from `wms-inbound`.

**Trigger type**: `receiveQueueMessages` (peek-lock)

```
Peek-lock acquired → Decode base64 body → Parse JSON → Merge auth credentials
→ Liquid SOAP transform → Call WMS SOAP (with exponential retry)
→ [WMS success] Parse response → Telemetry → Complete message (implicit on run success)
→ [WMS SOAP fault] Telemetry → Terminate(Cancelled) [non-retryable] 
                              or Terminate(Failed) [retryable]
→ [HTTP error] Run fails → Lock expires → SB redelivers (up to maxDeliveryCount=5)
```

**Message settlement in Logic Apps Standard**:
- Run succeeds → Service Bus connector **completes** the message (removes from queue)
- Run fails or times out → Lock expires → Service Bus **redelivers** (delivery count +1)
- Run terminates as `Cancelled` → connector **completes** the message (no retry)
- Run terminates as `Abandoned` → connector **abandons** the message (delivery count +1)

**Concurrency**: Logic Apps Standard allows multiple concurrent trigger invocations. Each worker holds its own independent lock on a different message. This means multiple orders are processed simultaneously — safe because each order is independent.

**Connection**: Same `serviceBus` connection, RBAC role: `Azure Service Bus Data Receiver` (in addition to `Data Sender` for the other workflow).

**Body decoding**: The built-in Service Bus connector delivers `contentData` as base64. `Decode_Message_Body` uses:
```
@base64ToString(triggerBody()?['contentData'])
```
This is mandatory — omitting it causes `ParseJson` to fail on every message.

### 7c. DLQ monitor — `dlq-monitor` (Observer)

**Pattern**: Scheduled peek — non-destructive. Does not settle messages.

**Entity name**: `@{concat(parameters('ServiceBusQueueName'), '/$deadletterqueue')}`
→ resolves to `wms-inbound/$deadletterqueue`

**Operation**: `peekMessages` (not `receiveQueueMessages`) — takes no lock, leaves messages untouched.

**Max count**: 10 per run. If DLQ depth exceeds 10, subsequent runs will surface the next batch.

**Connection**: RBAC role: `Azure Service Bus Data Receiver` is sufficient for peek.

### 7d. Connection configuration

`connections.json` (Logic Apps Standard, stateful workflows):

```json
{
  "serviceBus": {
    "api": {
      "id": "/subscriptions/.../providers/Microsoft.Web/locations/.../managedApis/servicebus"
    },
    "connection": {
      "id": "/subscriptions/.../resourceGroups/.../providers/Microsoft.Web/connections/serviceBus"
    },
    "authentication": {
      "type": "ManagedServiceIdentity"
    }
  }
}
```

`parameters.json` resolves `ServiceBusQueueName`:

```json
{
  "ServiceBusQueueName": {
    "value": "wms-inbound"
  }
}
```

---

## 8. Test Scenarios

### Scenario 1 — WMS unavailable (planned or unplanned outage)

**What to simulate**: Stop the WMS mock service (`mocks/wms-soap-mock`) or configure an unreachable endpoint via `WmsSoapEndpoint` parameter.

**Expected behaviour:**

| Step | Expected |
|---|---|
| BMWC submits order | `202 Accepted` — message enqueued to `wms-inbound` |
| `wms-soap-dispatcher` picks up message | `Call_WMS_SOAP_Endpoint` fails (connection refused or timeout) |
| Retry 1 (after 15 s) | Fails |
| Retry 2 (after 30 s) | Fails |
| Retry 3 (after 60 s) | Fails |
| Action fails | Run fails → lock expires (PT5M from first pickup) |
| Service Bus | Delivery count = 1 → message returned to queue |
| Pattern repeats | Continued WMS outage → delivery count increments each cycle |
| After 5 deliveries | `wms-inbound/$deadletterqueue` receives the message |
| After 15 min | `dlq-monitor` alerts |

**Verification:**
```bash
# Watch delivery count climb in real time
az servicebus queue show \
  --resource-group <rg> \
  --namespace-name <sb-namespace> \
  --name wms-inbound \
  --query properties.activeMessageCount
```

**Recovery steps:**
1. Restart WMS mock
2. Extend TTL if it expired: `PT24H`
3. Re-enqueue from DLQ if needed (see Section 6 playbook)
4. `wms-soap-dispatcher` picks up the re-enqueued message and succeeds

**Pass criteria**: No data loss; message is either in `wms-inbound` (active) or `wms-inbound/$deadletterqueue` (if TTL expired); can be recovered and delivered to WMS after outage ends.

---

### Scenario 2 — Malformed payload

**What to simulate**: Submit a request body containing invalid JSON in the `contentData`, or submit a payload missing a required field (e.g. omit `lines`).

**Sub-scenario A — Schema rejected at APIM/Logic App trigger**:
Omit `orderId` from the POST body.

| Step | Expected |
|---|---|
| BMWC submits order without `orderId` | `400 Bad Request` from Logic Apps schema validation |
| APIM | Propagates 400 with structured JSON error |
| Service Bus | No message enqueued — never reaches the queue |

No Service Bus involvement. The validation is at the trigger level (`EnableSchemaValidation`).

**Sub-scenario B — Corrupted after enqueue** (e.g. ops team manually enqueues a bad message to test DLQ):
Inject a message with non-base64 or invalid JSON content.

| Step | Expected |
|---|---|
| `wms-soap-dispatcher` peeks the message | |
| `Decode_Message_Body` | Succeeds (any bytes are valid base64 input) |
| `Parse_Order_Message` | **Fails** — JSON parse error |
| Run fails | Lock expires → SB redelivers |
| After 5 redeliveries | Message → `wms-inbound/$deadletterqueue` |
| DLQ entry | `DeadLetterReason: MaxDeliveryCountExceeded`, `DeadLetterErrorDescription: JSON parse error` |

**Verification**: Check DLQ entry — `DeadLetterErrorDescription` should reference `InvalidJsonException` or similar. User properties on the DLQ entry will be empty (they're set by the sender, so will still be present if the message was manually injected with properties).

**Pass criteria**: Bad message reaches DLQ in ≤ 5 × (lock_duration + next_pickup_delay). Does not block good messages behind it (queue is not ordered in that way — each consumer picks independently).

---

### Scenario 3 — Transient timeout

**What to simulate**: Configure the WMS mock to respond slowly (> 30 s HTTP timeout), or add a `Thread.Sleep` to the mock's `CreateOrder` handler for the first 2 calls.

**Expected behaviour:**

| Step | Expected |
|---|---|
| `Call_WMS_SOAP_Endpoint` | HTTP action times out on first attempt |
| Retry 1 | WMS mock responds slowly again → timeout |
| Retry 2 | WMS mock responds normally → `200 OK` |
| `Check_WMS_HTTP_Status` | Passes |
| `Check_SOAP_Fault` | No fault → `Compose_WMS_Success_Telemetry` |
| Message | **Completed** (settled) — no redelivery |

**Why this works**: Logic Apps Standard retry policy on HTTP actions retries independently at the action level — it does not fail the run or release the lock. The run continues normally until the action succeeds or retries exhaust.

**Variation — all retries fail (WMS slow throughout)**:
- After 3 retries, action fails → run fails → lock expires → delivery count +1
- If WMS recovers on the next pickup, delivery 2 succeeds

**Pass criteria**: Successful delivery to WMS on any retry; `deliveryCount` in telemetry shows the number of attempts; no message loss.

---

### Scenario 4 — Repeated failure causing DLQ transition

**What to simulate**: Configure WMS mock to always return HTTP 500 or always time out. Submit a normal, well-formed order.

**Expected behaviour (full 5-delivery lifecycle):**

| Delivery | Event | Delivery count after |
|---|---|---|
| 1 | `wms-soap-dispatcher` picks up message; WMS HTTP 500; 3 retries fail; run fails | 1 |
| 2 | Picked up again (lock expired from delivery 1); same failure | 2 |
| 3 | Same | 3 |
| High delivery count alert fires | `deliveryCount >= 3` alert Compose emits `HIGH_DELIVERY_COUNT` event | — |
| 4 | Same | 4 |
| 5 | Same | 5 = `maxDeliveryCount` |
| DLQ promotion | Service Bus moves message to `wms-inbound/$deadletterqueue` | N/A |
| dlq-monitor (next scheduled run) | Peeks DLQ; `dlqMessageCount = 1`; emits alert | — |

**Verify delivery count progression in Logic Apps run history:**
Each run of `wms-soap-dispatcher` shows `Init_DeliveryCount` output incrementing from 1 to 5.

**Verify DLQ entry:**
```bash
az servicebus queue show \
  --namespace-name <sb-namespace> \
  --name wms-inbound \
  --query "{active:properties.activeMessageCount, dlq:properties.deadLetterMessageCount}"
```

Expected output after all 5 deliveries: `{ "active": 0, "dlq": 1 }`

**Verify `dlq-monitor` alert:**
The `Check_Alert_Threshold` condition (`dlqMessageCount >= DlqAlertThreshold`, default 1) evaluates to true → `Placeholder_Send_Notification` fires.

**Recovery from this scenario:**
1. Fix the WMS mock (re-enable 200 responses)
2. Re-enqueue the DLQ message to `wms-inbound` with the original `orderId` as `messageId`
3. `wms-soap-dispatcher` picks it up (delivery count resets to 0 for a newly enqueued message — it's a new message for Service Bus purposes)
4. WMS responds successfully → order dispatched

**Pass criteria:**
- Zero data loss — the order is in `wms-inbound/$deadletterqueue` after 5 deliveries
- Each delivery is independently observable in Logic Apps run history
- `dlq-monitor` alert fires within the next 15-minute window
- Manual re-enqueue → successful dispatch after WMS recovery

---

## Appendix A — Queue property quick reference

| Property | `wms-inbound` | `wms-dead-letter-review` |
|---|---|---|
| `defaultMessageTimeToLive` | `PT4H` | `P7D` |
| `maxDeliveryCount` | `5` | `1` |
| `lockDuration` | `PT5M` | (not set — review only) |
| `deadLetteringOnMessageExpiration` | `true` | N/A |
| `requiresDuplicateDetection` | `true` |  |
| `duplicateDetectionHistoryTimeWindow` | `PT10M` | |
| `enablePartitioning` | `false` | `false` |
| SKU | Standard | Standard |

**Recommended upgrade path to Premium:**
- When payload > 256 KB (e.g. orders with 500 lines and large `notes` fields)
- When VNet injection is required (private endpoint for Service Bus)
- When geo-redundancy is required (Premium supports paired namespace failover)

---

## Appendix B — RBAC role assignments

| Principal | Role | Scope |
|---|---|---|
| Logic Apps Managed Identity | `Azure Service Bus Data Sender` | `wms-inbound` |
| Logic Apps Managed Identity | `Azure Service Bus Data Receiver` | `wms-inbound` + `wms-inbound/$deadletterqueue` |
| Ops team / Azure AD group | `Azure Service Bus Data Owner` | Namespace (for portal and CLI triage) |
| CI/CD service principal | `Azure Service Bus Data Owner` | Namespace (for test message injection) |

Set `disableLocalAuth: true` in the Bicep namespace properties to enforce Entra ID-only auth in production (removes SAS key access entirely).
