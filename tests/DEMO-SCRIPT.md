# BMWC → WMS Bridge — Presenter Demo Script

**Event context:** Customer briefing / POC demonstration  
**Duration:** 45–60 minutes (adjust scenarios to time available)  
**Audience:** IT leadership, integration architects, operational stakeholders  
**Presenter pre-checks:** See §0 below — complete at least 30 minutes before the session.

---

## Narrative Arc

> *"Today I want to show you how BMWC's order management system can talk to your legacy WMS — without either side changing a line of code. The bridge sits in Azure Integration Services and handles the translation from modern REST JSON to the SOAP XML your WMS already understands. We'll cover the happy path, what happens when the WMS is temporarily unavailable, how failed orders are collected and surfaced to your operations team, and how the system rejects bad data before it consumes any resources."*

---

## §0 — Pre-Demo Setup Checklist

Complete 30 minutes before the session. Do not run this live.

| # | Action | Command / Portal step |
|---|---|---|
| 1 | Verify APIM is provisioned | Azure Portal → API Management → `apim-bmwc-{env}` → Status = Online |
| 2 | Verify Logic App is running | Azure Portal → Logic Apps → `la-bmwc-{env}` → Status = Running |
| 3 | Start WMS mock | `docker run --rm -p 8080:8080 --name wms-soap-mock wms-soap-mock` |
| 4 | Verify mock health | `curl http://localhost:8080/health` → `{"status":"healthy"}` |
| 5 | Export subscription key | APIM Portal → Subscriptions → `bmwc-demo-subscription` → Show keys → copy Primary |
| 6 | Set env vars | `export APIM_GATEWAY_URL=https://apim-bmwc-demo.azure-api.net` |
| 7 | | `export APIM_SUBSCRIPTION_KEY=<key from step 5>` |
| 8 | Open browser tabs pre-loaded | Tab 1: Service Bus → wms-inbound queue (Active Message Count visible) |
| 9 | | Tab 2: Logic App → Run History (auto-refresh enabled) |
| 10 | | Tab 3: Log Analytics workspace → Logs blade (query pre-typed, not yet run) |
| 11 | | Tab 4: Azure Monitor → Alerts (to show alert rules later) |
| 12 | Clear any old DLQ messages | Service Bus → wms-dead-letter-review → Delete all |
| 13 | Postman environment loaded | `BMWC Demo` environment selected; `apimGatewayUrl` and `subscriptionKey` set |

---

## §1 — Opening Context (5 minutes)

**Say:**

> *"The BMWC order management platform speaks REST. Your WMS service — which handles all dispatching and inventory movement — speaks SOAP over XML. Until now, these two systems couldn't talk directly.*
>
> *This bridge is the translator. BMWC submits a JSON order over HTTPS. The platform validates it, queues it durably in Azure Service Bus, dispatches it asynchronously to the WMS as SOAP, and gives you full observability at every layer. Let me show you each step.*
>
> *We're running against a live Azure environment — Singapore region — and a local WMS mock that simulates your actual WMS service contract."*

**Show on screen:** [ARCHITECTURE.md](../ARCHITECTURE.md) diagram (open in browser or VS Code Preview). Point to the four layers:

```
BMWC caller → APIM → Logic App bmwc-rest-ingress → Service Bus
                                                        ↓
                                          wms-soap-dispatcher → WMS
```

---

## §2 — Scenario 1: Success Path (10 minutes)

**Say:**

> *"Let's start with the most common case — a standard line-item order from the BMWC system to your Singapore warehouse. I'm going to send a single HTTP request and we'll trace it all the way through to the WMS."*

### Step 2.1 — Send the order

Open Postman. Select request **01 — Submit Standard Order**.

Point out the request body before sending:

- `"orderId": "ORD-2026-SGP-001"` — the idempotency key
- `"orderDate": "2026-04-10T02:00:00Z"` — UTC timestamp
- Three lines including a lot-tracked item on line 3 (`"lotNumber": "LOT-2026-003"`)
- `"shipTo"` block with full Malaysian address

Click **Send**.

**Expected response (show on screen):**
```json
HTTP/1.1 202 Accepted
X-Correlation-ID: demo-corr-1744250401000

{
  "accepted": true,
  "orderId": "ORD-2026-SGP-001",
  "correlationId": "demo-corr-1744250401000",
  "message": "Order accepted for processing"
}
```

**Say:**
> *"Notice it's 202 Accepted, not 200 OK. The system immediately acknowledges receipt but processes asynchronously — so your BMWC caller doesn't sit waiting for the WMS to respond. That's important for resilience."*

### Step 2.2 — Show the message in Service Bus

Switch to browser Tab 1 (Service Bus → wms-inbound).

> *"The message has landed in the queue. Watch the Active Message Count increase. The orderId is the messageId — that's what Service Bus uses for duplicate detection."*

Click **Messages → Peek** to show the message body. Point out:
- The canonical envelope with `_meta.correlationId`
- `_meta.enqueuedAtUtc` — the exact time it was queued
- `orderDate` is UTC `2026-04-10T02:00:00Z`

### Step 2.3 — Show Logic App execution

Switch to Tab 2 (Logic App → Run History).

> *"Two workflows ran. First `bmwc-rest-ingress` — it validated the schema, stamped the metadata, and wrote to Service Bus. Then `wms-soap-dispatcher` picked up the message, transformed the JSON into SOAP XML using a Liquid map, and called the WMS."*

Click into the `wms-soap-dispatcher` run. Expand the HTTP action to show the SOAP request body sent to the WMS.

### Step 2.4 — Show Log Analytics

Switch to Tab 3. Run this query:
```kusto
AppTraces
| where Properties.event in ("ENQUEUE_SUCCESS", "WMS_DISPATCH_SUCCESS")
| where Properties.orderId == "ORD-2026-SGP-001"
| project TimeGenerated, Properties.event, Properties.wmsOrderId, Properties.correlationId
| order by TimeGenerated asc
```

> *"Two events: ENQUEUE_SUCCESS when the message was written to Service Bus, and WMS_DISPATCH_SUCCESS when the WMS accepted the order. The wmsOrderId is the WMS-assigned internal reference. This is your full audit trail — one query gives you end-to-end visibility."*

**Leave time for questions.** Common question: *"Can we query by customer reference?"* — yes, `Properties.customerReference` is also stored.

---

## §3 — Scenario 2: Timezone Handling (5 minutes)

**Say:**

> *"BMWC's order management system is based in Malaysia — it stamps timestamps in GMT+8. Your WMS and all Azure services operate in UTC. Let me show you how the bridge handles that conversion automatically."*

### Step 3.1 — Send the order with +08:00 timestamp

Open Postman, select request **02 — Submit URGENT Order with GMT+8 Timestamp**.

Point out before sending:
- `"orderDate": "2026-04-10T10:00:00+08:00"` — 10 AM Malaysian time
- `"requestedDeliveryDate": "2026-04-10T18:00:00+08:00"` — 6 PM Malaysian time

Click **Send** → 202 Accepted.

### Step 3.2 — Peek the Service Bus message

Go to Service Bus → wms-inbound → Peek. Show the canonical envelope.

> *"Look at the orderDate in the queued message — it reads `2026-04-10T02:00:00Z`. The ingress workflow normalised the +08:00 offset to UTC before writing to Service Bus. The WMS and all downstream systems always receive UTC."*

### Step 3.3 — Reporting layer narrative

> *"Now, here's the design principle: UTC is the single source of truth across the entire platform — storage, messaging, SOAP calls, and Log Analytics. The +08:00 offset only appears in the reporting layer. If we were to connect Power BI or an Azure Monitor Workbook, it would render 2026-04-10T02:00:00Z as '10:00 AM MYT' for your operations team — but the underlying data never changes. This avoids the classic problem of daylight saving gaps or mismatched local times in operational databases."*

---

## §4 — Scenario 3: Transient Failure & Automatic Retry (10 minutes)

**Say:**

> *"Warehouse systems have maintenance windows. Network blips happen. Let me show you what this platform does when the WMS is temporarily unavailable — without losing a single order."*

### Step 4.1 — Stop the WMS mock

```bash
docker stop wms-soap-mock
```

> *"The WMS is now offline."*

### Step 4.2 — Send the order

Open Postman, select request **04 — Transient Failure Demo**. Click **Send** → 202 Accepted.

> *"APIM still returns 202 immediately. BMWC doesn't know the WMS is down — and it shouldn't need to. The message is safely in Service Bus."*

### Step 4.3 — Show retry in Logic App

Navigate to Logic App → `wms-soap-dispatcher` → Run History. Click the failing run.

> *"You can see the WMS HTTP call is being retried with exponential back-off. After 3 attempts within this run, it will complete with a failure. Service Bus tracks the delivery count — after 5 total delivery attempts across all retry cycles, the message is moved to the dead-letter queue."*

### Step 4.4 — Restore the WMS mock

```bash
docker start wms-soap-mock
```

> *"WMS is back. In a real scenario, the lock on the Service Bus message would expire, the message would become available again, and `wms-soap-dispatcher` would process it automatically on the next pickup — no human intervention needed for transient faults."*

### Step 4.5 — Key message

> *"The durable queue is what makes this resilient. If we had called the WMS synchronously — REST to SOAP, direct HTTP — a 10-minute WMS outage would mean 10 minutes of failed BMWC orders and unhappy callers. With the queue, it means 10 minutes of processing delay. The orders don't disappear."*

---

## §5 — Scenario 4: DLQ & Operations Visibility (10 minutes)

**Say:**

> *"Some failures are permanent — a bad SKU, a deactivated warehouse code. Those messages can't be retried their way to success. The platform detects this and consolidates them for your operations team."*

### Step 5.1 — Send 3 messages with bad SKU

Open Postman, select request **05 — DLQ Demo**. Send it 3 times, changing `orderId` to `ORD-2026-DLQ-001`, `DLQ-002`, `DLQ-003` between sends.

> *"The WMS mock is configured to return a SOAP Fault for SKU `SKU-X-999` or warehouse code `WH-DLQ`. These orders will never succeed as submitted."*

### Step 5.2 — Show the DLQ

Navigate to Service Bus → `wms-dead-letter-review` queue.

> *"Three messages. Operations can peek these, read the full original payload and the fault reason, correct the SKU in the WMS item master, and resubmit. Nothing is lost — the message is preserved exactly as it arrived."*

### Step 5.3 — Show Log Analytics

Run this query:
```kusto
AppTraces
| where Properties.event == "WMS_SOAP_FAULT"
| project TimeGenerated, Properties.orderId, Properties.faultcode, Properties.faultstring
| order by TimeGenerated desc
```

> *"Every fault is logged with full detail — the orderId, the SOAP faultcode, and the faultstring from the WMS. Your integration team can diagnose root cause without touching the production system."*

### Step 5.4 — DLQ summary alert

> *"The `dlq-monitor` workflow runs on a 15-minute schedule. It counts the dead-letter queue depth and emits a `DLQ_ALERT_SUMMARY` event. An Azure Monitor alert rule fires when that count is above zero — your operations team gets an email or Teams notification without manual queue polling."*

Show the Azure Monitor alert rule in the Portal (Tab 4).

---

## §6 — Scenario 5: Schema Validation Gate (5 minutes)

**Say:**

> *"The system protects itself — and the WMS — from badly formed data. Let me show you the validation gate."*

### Step 6.1 — Send invalid payload

Open Postman, select request **06 — Invalid Request: Missing required fields**. Click **Send**.

> *"This payload is missing `orderId` and `lines` — both required fields. The Logic App trigger has schema validation enabled."*

**Expected response:**
```
HTTP 400 Bad Request
```

> *"The system returns 400 immediately. Look at the Service Bus queue — the message count did NOT go up. That message never touched Service Bus, never triggered the dispatcher, and the WMS was never called. Garbage data is stopped at the gate, not deep in the pipeline where it's expensive to diagnose."*

---

## §7 — Scenario 6: Idempotency (3 minutes)

**Say:**

> *"BMWC's order system has a retry on timeout. What happens if a 202 response gets lost in the network and BMWC resends the same order?"*

### Step 7.1 — Resend original order

Open Postman, select request **07 — Idempotency: Duplicate orderId**. Same `orderId: ORD-2026-SGP-001` as scenario 1. Click **Send**.

**Expected response:** 202 Accepted.

> *"202 again — but watch the Service Bus queue. The message count did NOT go up. Service Bus duplicate detection is keyed on the messageId, which we set to the orderId. Within the 10-minute duplicate detection window, Service Bus silently drops the second copy. The WMS is called exactly once per order, no matter how many times BMWC retries the submission."*

---

## §8 — Observability Recap (3 minutes)

**Say:**

> *"Let me close by showing you the full observability picture in one query."*

Run this in Log Analytics:
```kusto
AppTraces
| where TimeGenerated > ago(1h)
| extend event = tostring(Properties.event)
| summarize Count = count() by event
| order by Count desc
```

> *"In the last hour we can see every event type across every workflow run — ingest, dispatch, faults, DLQ summaries. This is all structured telemetry from Application Insights, routed to Log Analytics, available for dashboards, alert rules, and export to any SIEM or reporting tool."*

Show the 6 alert rules in Azure Monitor:

> *"Six alert rules are pre-configured and deployed as code alongside the infrastructure. Logic App failures, WMS fault spikes, DLQ messages, end-to-end latency p95, enqueue failures, and APIM error rate. All wired to your action group for email, SMS, or Teams notifications."*

---

## §9 — Q&A Prompts

Anticipated questions and suggested responses:

| Question | Suggested answer |
|---|---|
| *"What happens if Azure Service Bus goes down?"* | Service Bus is a fully managed, geo-redundant Azure service with 99.9% SLA. The ingress Logic App would return 503 to BMWC, which would retry according to its own retry policy. No data loss once the message is accepted. |
| *"Can we add more queues for different WMS operations?"* | Yes. The queue name is parameterised. A second queue and a second dispatcher workflow can be added without changing the infrastructure model. |
| *"Is the subscription key the only security layer at APIM?"* | No. Three layers: TLS mutual auth is optional; IP allowlist (`ip-filter` policy) restricts source; subscription key validates the caller. Internally, Logic App to Service Bus uses Managed Identity — no connection strings in code. |
| *"How do we promote from demo to production?"* | `azd env new prod-sg`, supply the production parameter file (`infra/main.parameters.prod-sg.json`), run `azd provision`. The production file has hardened settings: 90-day log retention, purge protection on Key Vault, APIM sampling at 10%, rate limit at 500 calls/min. |
| *"Can the platform handle Malaysia South (DR)?"* | Yes. An identical deployment is defined in `infra/main.parameters.prod-my.json` targeting `malaysiasouth`. Azure Front Door or Traffic Manager can be placed in front of both APIM gateway URLs for active-active or failover routing. |
| *"What does an operations team do with DLQ messages?"* | Check the DLQ alert → identify the faultstring → fix root cause (e.g. register SKU in WMS item master) → use Service Bus Explorer (Portal or CLI) to resubmit the message. Alternatively, the team can call the APIM endpoint again with a corrected payload and a new orderId. |
| *"How long are messages retained if the WMS is down for hours?"* | Service Bus message TTL is parameterised. Default is 4 hours (`PT4H`). It can be extended up to 14 days in the parameter file. After TTL expiry, expired messages move to the DLQ automatically. |

---

## §10 — Closing Statement

> *"What you've seen today is a production-ready integration backbone built entirely on Azure PaaS services — no VMs, no middleware servers to patch. Infrastructure is versioned as code in Bicep and deployed via Azure Developer CLI in minutes. The platform handles durability, retry, dead-lettering, timezone normalisation, validation, observability, and alerting — so your BMWC and WMS teams can focus on business logic rather than plumbing.*
>
> *The next step is to point the dispatcher at your real WMS endpoint, validate the SOAP structure against your actual WSDL, and run a hardened deployment to the production Singapore environment."*

---

*Presenter notes generated for BMWC → WMS Bridge POC — April 2026.*
