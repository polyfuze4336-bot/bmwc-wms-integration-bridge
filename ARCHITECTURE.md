# BMWC → WMS Bridge — Architecture Design

**Pattern**: REST-to-SOAP Fire-and-Forget Integration  
**Stack**: Azure Integration Services (APIM · Logic Apps Standard · Service Bus)  
**Region**: Southeast Asia — Singapore (`southeastasia`) · Malaysia South optional (`malaysiasouth`)  
**Date**: April 2026

---

## 1. Logical Architecture Diagram

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  BMWC Modern System (external)                                               ║
║  JSON payloads  ·  HTTPS only  ·  Source IP: known CIDR range               ║
╚════════════════════════════╤═════════════════════════════════════════════════╝
                             │  POST /bmwc/orders
                             │  Headers: Ocp-Apim-Subscription-Key
                             │           X-Correlation-ID (optional)
                             │  Body: application/json ≤ 256 KB
                             ▼
╔════════════════════════════════════════════════════════════════════════════╗
║  PERIMETER LAYER — Azure API Management (Consumption SKU)                  ║
║                                                                            ║
║  ┌─────────────────────────────────────────────────────────────────────┐  ║
║  │ Inbound policy chain (execution order)                              │  ║
║  │  1. ip-filter          — allowlist BMWC CIDR ranges                 │  ║
║  │  2. subscription-key   — validate Ocp-Apim-Subscription-Key         │  ║
║  │  3. rate-limit         — 100 calls/min per key                      │  ║
║  │  4. quota              — 10,000 calls/week per key                  │  ║
║  │  5. validate-content   — enforce JSON, max 256 KB                   │  ║
║  │  6. set-header         — inject X-Correlation-ID if absent          │  ║
║  │  7. set-backend-service — route to Logic App HTTP trigger           │  ║
║  └─────────────────────────────────────────────────────────────────────┘  ║
║                                                                            ║
║  Diagnostics: 100% sampled → Application Insights                         ║
╚════════════════════════════╤═════════════════════════════════════════════════╝
                             │  HTTPS  (Named Value: la-bmwc-ingest-url)
                             ▼
╔════════════════════════════════════════════════════════════════════════════╗
║  ORCHESTRATION LAYER — Logic Apps Standard  (WS1, VNet-integrated)         ║
║  Host: la-bmwc-wms-{token}.azurewebsites.net                               ║
║                                                                            ║
║  ┌─────────────────────────────────────────────────────────────────────┐  ║
║  │  WORKFLOW 1 — bmwc-rest-ingress  (Stateful)                         │  ║
║  │  Trigger: HTTP Request                                              │  ║
║  │                                                                     │  ║
║  │  ① Receive POST, read X-Correlation-ID from header                 │  ║
║  │  ② Initialize correlationId variable (header or new GUID)          │  ║
║  │  ③ Parse JSON body (schema validation)                              │  ║
║  │  ④ Compose enriched message (add _meta: source, UTC timestamp,     │  ║
║  │       schemaVersion, correlationId)                                 │  ║
║  │  ⑤ Send to Service Bus queue 'wms-inbound'  (built-in connector)   │  ║
║  │       messageId = orderId  (duplicate detection key)               │  ║
║  │  ⑥ Return 202 Accepted { orderId, correlationId, queuedAt }        │  ║
║  │  ⑦ On SB send failure → return 500 with correlationId              │  ║
║  └─────────────────────────────────────────────────────────────────────┘  ║
╚════════════════════════════╤═════════════════════════════════════════════════╝
                             │  amqp (Service Bus built-in connector)
                             │  messageId = orderId
                             │  userProperties: correlationId, warehouseCode, priority
                             ▼
╔════════════════════════════════════════════════════════════════════════════╗
║  BUFFER LAYER — Azure Service Bus (Standard SKU)                           ║
║  Namespace: sb-bmwc-wms-{token}.servicebus.windows.net                     ║
║                                                                            ║
║  ┌───────────────────────────────┐   ┌──────────────────────────────────┐ ║
║  │  Queue: wms-inbound           │   │  Queue: wms-dead-letter-review   │ ║
║  │  TTL:          4 hours        │   │  (ops review + reprocess)        │ ║
║  │  Lock duration: 5 min         │   │  TTL: 7 days                     │ ║
║  │  Max delivery:  5 attempts    │──▶│  Alert: count > 10               │ ║
║  │  Duplicate detect: 10 min     │   │  Alert: growing in 15-min window │ ║
║  │  Partitioned:   false         │   └──────────────────────────────────┘ ║
║  │  Max size:      256 KB        │                                         ║
║  └───────────────────────────────┘                                         ║
╚════════════════════════════╤═════════════════════════════════════════════════╝
                             │  trigger: receiveQueueMessages (peek-lock)
                             ▼
╔════════════════════════════════════════════════════════════════════════════╗
║  TRANSFORM & DISPATCH LAYER — Logic Apps Standard  (same Logic App host)   ║
║                                                                            ║
║  ┌─────────────────────────────────────────────────────────────────────┐  ║
║  │  WORKFLOW 2 — wms-soap-dispatcher  (Stateful)                       │  ║
║  │  Trigger: Service Bus — receiveQueueMessages (peek-lock)            │  ║
║  │                                                                     │  ║
║  │  ① Decode base64 content body                                      │  ║
║  │  ② Parse enriched JSON order message                               │  ║
║  │  ③ Transform: JSON → SOAP XML envelope                             │  ║
║  │       Option A: Compose action (inline string interpolation)       │  ║
║  │       Option B: Liquid map (bmwc-order-to-wms-soap.liquid)         │  ║
║  │  ④ HTTP POST to WMS SOAP endpoint  (private path — VNet)           │  ║
║  │       Header: SOAPAction, Content-Type: text/xml                   │  ║
║  │       Retry: exponential, 3×, 15s → 1h                             │  ║
║  │  ⑤ Check HTTP status code                                          │  ║
║  │       200 → log success, message auto-completed by connector        │  ║
║  │       non-200 → Terminate(Failed) → SB delivery count increments   │  ║
║  │  ⑥ HTTP call fails entirely → Terminate(Failed) → SB retries      │  ║
║  │  ⑦ After 5 delivery attempts → SB dead-letters the message        │  ║
║  └─────────────────────────────────────────────────────────────────────┘  ║
╚════════════════════════════╤═════════════════════════════════════════════════╝
                             │  HTTPS POST, text/xml
                             │  SOAPAction: http://wms.legacy.corp/v1/CreateOrder
                             │  (routed privately through VNet integration)
                             ▼
╔════════════════════════════════════════════════════════════════════════════╗
║  LEGACY WMS — SOAP Service                                                 ║
║  http://wms.internal/WMSService.svc                                        ║
║  (on-premises or private endpoint — not internet-reachable)                ║
║  Dev substitute: wms-soap-mock container on port 8080                      ║
╚════════════════════════════════════════════════════════════════════════════╝

═══════════════════════════════ CROSS-CUTTING ════════════════════════════════

  Observability Plane
  ┌────────────────────────────────────────────────────────────────────────┐
  │  Log Analytics Workspace (log-bmwc-wms-{token})                        │
  │    ← Logic App run history, trigger history, action telemetry          │
  │    ← Service Bus metrics (ActiveMessages, DeadLettered, IncomingMsgs)  │
  │    ← APIM requests, latency, errors                                    │
  │                                                                         │
  │  Application Insights (appi-bmwc-wms-{token})                          │
  │    ← Distributed traces across APIM + Logic Apps                       │
  │    ← Custom properties: correlationId, orderId, warehouseCode           │
  │                                                                         │
  │  Azure Monitor Alerts                                                   │
  │    ▸ Logic App RunsFailed > 5 in 5 min  → Severity 2                   │
  │    ▸ SB dead-letter count > 10           → Severity 2                   │
  └────────────────────────────────────────────────────────────────────────┘

  Networking Plane
  ┌────────────────────────────────────────────────────────────────────────┐
  │  VNet: vnet-bmwc-wms-{token}  (10.10.0.0/16)                          │
  │                                                                         │
  │  snet-logicapp  (10.10.1.0/24)                                         │
  │    Delegated: Microsoft.Web/serverFarms                                 │
  │    Service endpoints: Microsoft.ServiceBus, Microsoft.KeyVault          │
  │    Logic App outbound traffic routed here (vnetRouteAllEnabled=true)   │
  │    → all calls to WMS SOAP go through this subnet                      │
  │                                                                         │
  │  snet-private-endpoints  (10.10.2.0/24)                                │
  │    Reserved for Service Bus / Key Vault private endpoints (future)     │
  └────────────────────────────────────────────────────────────────────────┘

  Security Plane
  ┌────────────────────────────────────────────────────────────────────────┐
  │  Key Vault (kv-bmwc-{token})                                           │
  │    ▸ wms-soap-endpoint  (KV reference in Logic App app settings)       │
  │    ▸ wms-soap-username                                                  │
  │    ▸ wms-soap-password                                                  │
  │                                                                         │
  │  Managed Identity (System-Assigned on Logic App)                       │
  │    ▸ Key Vault Secrets User  → read KV references at runtime           │
  │    ▸ Service Bus Data Owner  → send + receive (future: replace SAS)    │
  └────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Workflow-by-Workflow Breakdown

### Workflow 1 — `bmwc-rest-ingress`

**Trigger**: HTTP Request (POST)  
**Kind**: Stateful  
**Called by**: APIM (via Named Value `la-bmwc-ingest-url`)  
**SLA target**: < 2 seconds end-to-end (ingest only; WMS dispatch is async)

| Step | Action Type | Key Configuration |
|---|---|---|
| 1 | `InitializeVariable` | `correlationId` ← `X-Correlation-ID` header or new GUID |
| 2 | `ParseJson` | Schema enforces `orderId`, `customerId`, `warehouseCode`, `lines[]` required |
| 3 | `Compose` | Enriched message: original payload + `_meta` object |
| 4 | `ServiceProvider` — Send message | Queue: `wms-inbound`; `messageId` = `orderId` (idempotency) |
| 5 | `Response` (success path) | `202 Accepted` — `{ status, orderId, correlationId, queuedAt }` |
| 6 | `Response` (failure path) | `500` — `{ status: ERROR, message, correlationId }` |

**`_meta` envelope added at step 3:**
```json
{
  "_meta": {
    "correlationId": "<uuid>",
    "receivedAt": "2026-04-09T02:00:00Z",   ← UTC always
    "source": "BMWC",
    "schemaVersion": "1.0"
  }
}
```

**Concurrency note**: HTTP-triggered stateful workflows on WS1 default to unbounded concurrency. With 3 elastic workers (`maximumElasticWorkerCount: 3`), the plan handles ~100 parallel executions. Set `operationOptions: "DisableAsyncPattern"` if strict 202 semantics are needed.

---

### Workflow 2 — `wms-soap-dispatcher`

**Trigger**: Service Bus — `receiveQueueMessages` on `wms-inbound` (peek-lock mode)  
**Kind**: Stateful  
**Called by**: Service Bus trigger (event-driven, not polled)  
**SLA target**: best-effort; WMS is legacy — 30-second timeout per attempt

| Step | Action Type | Key Configuration |
|---|---|---|
| 1 | Trigger | Peek-lock, `isSessionsEnabled: false`, `lockDuration: PT5M` |
| 2 | `Compose` | `base64ToString(triggerBody()['contentData'])` |
| 3 | `ParseJson` | Parse enriched order JSON from decoded body |
| 4 | `Compose` | Build SOAP `CreateOrder` envelope (inline or Liquid map) |
| 5 | `Http` | `POST` to `@parameters('WmsSoapEndpoint')` — content-type `text/xml` |
| 6 | `Condition` | Branch on `statusCode == 200` |
| 7a | `Compose` (success) | Log success event with `wmsOrderId`, `correlationId`, `completedAt` |
| 7b | `Terminate` (failure) | `runStatus: Failed` → SB increments delivery count |
| 8 | `Terminate` (HTTP error) | Catches `Failed`/`TimedOut` from step 5 |

**HTTP retry policy (step 5):**
```json
{
  "type": "exponential",
  "count": 3,
  "interval": "PT15S",
  "maximumInterval": "PT1H",
  "minimumInterval": "PT5S"
}
```

**Dead-letter flow:**
When `wms-soap-dispatcher` terminates with `Failed`, Service Bus releases the message lock. On the 5th delivery attempt, Service Bus moves the message to `wms-dead-letter-review` queue automatically. Alert fires when dead-letter count > 10.

**Timezone handling:**
- All `utcNow()` expressions throughout workflows → always UTC
- `_meta.receivedAt`, `completedAt`, `failedAt` all UTC ISO 8601
- GMT+8 conversion applied only in reporting queries (Log Analytics KQL: `datetime_utc_to_local(TimeGenerated, 'Asia/Kuala_Lumpur')`)

---

## 3. Deployment Dependency Order

Dependencies must be provisioned strictly in this order. Each group can be deployed in parallel within the group.

```
Layer 0 — Foundation (no dependencies)
  └── Resource Group  (rg-bmwc-wms-{env})

Layer 1 — Shared Platform Services (depend only on RG)
  ├── VNet + Subnets        (vnet.bicep)
  └── Log Analytics         (loganalytics.bicep)
      └── Application Insights  [child — provisioned inside loganalytics.bicep]

Layer 2 — Data & Secret Plane (depend on Layer 1)
  ├── Key Vault             (keyvault.bicep)  ← depends on: RG
  └── Service Bus           (servicebus.bicep) ← depends on: RG

Layer 3 — Compute (depends on Layer 1 + 2)
  └── Logic Apps Standard   (logicapp.bicep)
      ├── Storage Account   [child — inside logicapp.bicep]
      ├── App Service Plan  [child]
      ├── Logic App Site    [child — depends on: VNet subnet, App Insights, SB conn str, KV name]
      └── Role Assignment   [child — KV Secrets User on Logic App MI]

Layer 4 — API Gateway (depends on Layer 3)
  └── API Management        (apim.bicep)
      ├── Logger            [child — depends on: App Insights instrumentation key]
      ├── Diagnostics       [child]
      ├── Named Value       [child — la-bmwc-ingest-url (placeholder until post-provision hook)]
      ├── BMWC API          [child]
      └── Rate-limit policy [child]

Layer 5 — Alerting (depends on Layers 1 + 3)
  └── Azure Monitor Alerts  (alerts.bicep)
      ├── Metric Alert      — depends on: Logic App resource ID
      └── Query Alert       — depends on: Log Analytics workspace ID

Layer 6 — Post-Provision Hook (depends on all layers)
  └── scripts/post-provision.ps1
      ← Reads Logic App trigger callback URL (SAS-signed)
      → Patches APIM Named Value 'la-bmwc-ingest-url'
      ← This step cannot be done in Bicep (SAS URL generated at runtime)
```

**azd provision execution sequence:**
```
azd provision
  bicep deploy main.bicep (subscription scope)
    → rg
    → vnet  |  loganalytics         [parallel]
    → keyvault  |  servicebus       [parallel]
    → logicapp                      [sequential: needs vnet, loganalytics, servicebus, keyvault]
    → apim                          [sequential: needs logicapp, loganalytics]
    → alerts                        [sequential: needs logicapp, loganalytics]
  hook: postprovision
    → post-provision.ps1
```

**Logic App workflow deployment** (separate from infrastructure):
- Workflows are deployed via VS Code Azure Logic Apps extension or zip deploy
- Must happen **after** Layer 3 — the Logic App host must exist
- `connections.json` and `parameters.json` are consumed at first workflow run

---

## 4. Configuration Boundaries

### APIM Owns

| Concern | Mechanism | Value |
|---|---|---|
| IP allowlist | `ip-filter` policy | BMWC source CIDR ranges |
| Auth | `subscription-key` check | `Ocp-Apim-Subscription-Key` header |
| Rate limiting | `rate-limit` | 100 calls/min per key |
| Weekly quota | `quota` | 10,000 calls/week per key |
| Payload size | `validate-content` | max 256 KB, `application/json` enforced |
| Correlation ID | `set-header` | inject if absent |
| Backend routing | `set-backend-service` | Named Value → Logic App trigger URL |
| Observability | `diagnostics` logger | 100% sampling → App Insights |
| Error responses | `on-error` policy | Structured JSON, includes correlationId |
| CORS | `cors` policy | Global policy; restrict to BMWC origin in production |

APIM does **not** own: payload transformation, business logic, retry, or WMS connectivity.

---

### Logic App Standard Owns

| Concern | Mechanism |
|---|---|
| JSON schema validation | `ParseJson` action with schema definition |
| Payload enrichment | `Compose` — adds `_meta` envelope |
| Correlation ID propagation | variable passed through all actions |
| Service Bus enqueue | Built-in Service Bus connector (`ServiceProvider`) |
| Message ID (idempotency) | `messageId = orderId` on send |
| JSON→SOAP transformation | `Compose` (inline) or `Liquid` map action |
| WMS SOAP call | `Http` action with exponential retry |
| Error classification | `Condition` (HTTP status) + `Terminate` |
| WMS credential handling | App settings referencing Key Vault secrets |
| VNet-routed outbound | `vnetRouteAllEnabled: true` on site config |
| Timezone at system layer | `utcNow()` everywhere — no local time in workflows |

Logic Apps does **not** own: auth/authz, rate limiting, IP filtering, routing decisions.

---

### Service Bus Owns

| Concern | Configuration |
|---|---|
| Async decoupling | Queue `wms-inbound` (fire-and-forget from BMWC perspective) |
| Message ordering | FIFO per queue (no sessions = best-effort ordering) |
| Duplicate suppression | `requiresDuplicateDetection: true`, 10-minute window |
| At-least-once delivery | Peek-lock (`lockDuration: PT5M`) — consumer completes or abandons |
| Retry budget | `maxDeliveryCount: 5` — 5 delivery attempts before DLQ |
| Poison message isolation | System auto-dead-letter after max delivery count |
| Message TTL | `defaultMessageTimeToLive: PT4H` — expired = auto-DLQ |
| Ops review queue | `wms-dead-letter-review` with 7-day retention |

Service Bus does **not** own: message content transformation, WMS connectivity, alerting thresholds.

---

### Networking Owns

| Concern | Configuration |
|---|---|
| Logic App outbound isolation | `snet-logicapp` (10.10.1.0/24), delegated to `Microsoft.Web/serverFarms` |
| VNet routing | `vnetRouteAllEnabled: true` — all outbound (including WMS) through VNet |
| Service Bus access from VNet | Service endpoint `Microsoft.ServiceBus` on `snet-logicapp` |
| Key Vault access from VNet | Service endpoint `Microsoft.KeyVault` on `snet-logicapp` |
| APIM inbound | Public (Consumption SKU); upgrade to Premium for VNet injection |
| WMS reachability | Private IP within VNet, or VNet peering, or ExpressRoute (site-specific) |
| Future private endpoints | `snet-private-endpoints` (10.10.2.0/24) reserved |

---

### Monitoring Owns

| Concern | Resource | Configuration |
|---|---|---|
| Log ingestion cap | Log Analytics | `dailyQuotaGb: 1` GB (demo guard) |
| Trace retention | Log Analytics | 30 days (extend to 90+ in production) |
| Distributed traces | Application Insights | LinkedWorkspace mode, `WorkspaceResourceId` set |
| Run failure alert | Metric Alert | `RunsFailed > 5` in 5-min window, Severity 2 |
| DLQ growth alert | Scheduled Query Rule | KQL on `AzureMetrics`, `DeadLetteredMessages > 10` |
| APIM sampling rate | APIM Diagnostics | 100% dev; reduce to 10% production |

---

## 5. Design Decisions and Tradeoffs

### Decision 1 — Logic Apps Standard (WS1) over Consumption

| | Standard WS1 | Consumption |
|---|---|---|
| VNet integration | ✅ Regional outbound | ❌ Not supported |
| Stateful workflows | ✅ Durable run history | ✅ |
| Built-in SB connector | ✅ (no ManagedAPI cost) | ✅ |
| Concurrent executions | ~100 across 3 workers | ~1,000 (serverless) |
| Cold start | None (always warm) | Rarely (warm) |
| Cost model | Fixed monthly (WS1 ~$0.18/hr) | Per-execution |
| Liquid transform support | ✅ | ✅ |

**Decision**: WS1 is mandatory to satisfy VNet integration. The fixed cost is acceptable for a demo and predictable in production at ~100 concurrent executions.

---

### Decision 2 — Async (Service Bus) over Synchronous Pass-through

| | Async (current) | Sync pass-through |
|---|---|---|
| BMWC wait time | < 2s (queue send) | WMS latency (unpredictable, legacy) |
| WMS downtime impact | BMWC unaffected — messages queue up | BMWC receives 500/timeout immediately |
| Retry ownership | Service Bus manages | BMWC caller must retry |
| Throughput ceiling | Service Bus Standard: 1,000 msgs/sec | WMS throughput |
| Order status | Eventual (callback or polling needed) | Immediate (synchronous) |
| Complexity | Two workflows + queue | One workflow |

**Decision**: Async is correct for a legacy WMS that may be slow, unavailable, or geographically separate. BMWC clients poll `GET /bmwc/orders/{id}/status` for feedback. Tradeoff: eventual consistency — BMWC cannot confirm WMS success in the same HTTP response.

---

### Decision 3 — Inline SOAP Build vs Liquid Map

| | Inline Compose (current) | Liquid Map |
|---|---|---|
| Tooling required | None | Liquid template file in `maps/` |
| Iteration arrays | Requires `join()` workaround | Native `for` loop |
| Maintainability | Harder to edit XML in JSON string | Clean, readable template |
| Conditional elements | Possible but verbose | Clean `{% if %}` syntax |
| Runtime dependency | None | Map file must be in Logic App content share |
| Best for | Simple, fixed structures | Complex, iterated XML (multi-line items) |

**Decision**: Use Liquid map (`maps/bmwc-order-to-wms-soap.liquid`) for the production path — order lines array requires iteration. Keep inline Compose as a fallback for debugging or simple payloads. Both are included; the workflow references the Liquid action.

---

### Decision 4 — Service Bus Standard vs Premium SKU

| | Standard | Premium |
|---|---|---|
| Max message size | 256 KB | 100 MB |
| Private endpoints | ❌ | ✅ |
| VNet injection (namespace) | ❌ | ✅ |
| Geo-redundancy | ❌ | ✅ |
| Message sessions (FIFO) | ✅ | ✅ |
| Cost | ~$10/month base | ~$670/month base |

**Decision**: Standard meets the 256 KB payload requirement and is sufficient for demo and initial production. Service Bus in Standard SKU is not in the VNet — connectivity from Logic Apps uses the service endpoint on `snet-logicapp`, which restricts access to that subnet without exposing a private endpoint. **Upgrade path**: move to Premium when private endpoint isolation or geo-recovery is required.

---

### Decision 5 — APIM Consumption vs Developer/Premium for VNet

| | Consumption | Developer | Premium |
|---|---|---|---|
| VNet injection (inbound) | ❌ | ✅ (non-prod only) | ✅ |
| VNet injection (outbound) | ❌ | ✅ | ✅ |
| SLA | 99.9% | None | 99.99% |
| Scale units | Auto | 1 | Multi-region |
| Cost | Per-call | ~$50/month | ~$570/month |

**Decision**: Consumption for demo — fast to deploy, zero idle cost. APIM handles inbound from public internet (BMWC is an external modern system). The VNet-sensitive path is the **outbound** call to WMS, which belongs to Logic Apps — not APIM. **Upgrade path**: Developer or Premium when APIM must also route via private VNet (e.g., if Logic App itself is on Internal VNet mode).

---

### Decision 6 — Stateful vs Stateless Workflows

| | Stateful | Stateless |
|---|---|---|
| Run history kept | ✅ 30 days | ❌ (in-memory only) |
| Debuggability | ✅ Full action input/output visible | ❌ |
| Performance | Slightly higher latency (storage I/O) | Faster, lower cost |
| Retry support | ✅ | ✅ |
| Long-running | ✅ | ❌ (limited) |

**Decision**: Both workflows are **Stateful** — the run history is essential for troubleshooting SOAP failures and auditing BMWC orders. Storage overhead is negligible on WS1 with a single LRS storage account.

---

### Decision 7 — Payload Timezone Convention

**Rule**: UTC everywhere at the system layer. GMT+8 is a presentation concern only.

| Layer | Timezone | Mechanism |
|---|---|---|
| Logic App `utcNow()` | UTC | Built-in — no configuration |
| Service Bus `EnqueuedTimeUtc` | UTC | Platform property |
| Log Analytics `TimeGenerated` | UTC | Platform standard |
| App Insights traces | UTC | Platform standard |
| BMWC API responses | UTC | `queuedAt`, `completedAt` fields |
| KQL reporting queries | GMT+8 | `datetime_utc_to_local(TimeGenerated, 'Asia/Kuala_Lumpur')` |
| Application dashboards | GMT+8 | Workbook time offset parameter |

---

### Decision 8 — Capacity: ~100 Concurrent Executions on WS1

Logic Apps Standard on WS1 uses elastic scale. Each WS1 worker:
- 1 vCPU, 3.5 GB RAM
- Handles 30–50 stateful workflow executions concurrently (I/O bound)

To reach 100 concurrent:
- `maximumElasticWorkerCount: 3` in App Service Plan (3 workers × ~35 = ~105)
- Workers scale out in ~1 minute — spiky traffic may briefly queue at Service Bus
- Service Bus acts as the natural load buffer — workflows process at their own pace

If sustained > 100 concurrent is required:
- Scale to WS2 (2 vCPU) or WS3 (4 vCPU) per worker
- Increase `maximumElasticWorkerCount` accordingly
- Consider splitting ingest and dispatch onto separate Logic App instances

---

## Appendix A — KQL Queries for Observability

```kql
-- Failed Logic App runs in last 24h (GMT+8 display)
AzureDiagnostics
| where ResourceType == "SITES" and Category == "WorkflowRuntime"
| where OperationName == "Microsoft.Logic/workflows/workflowRunCompleted"
| where status_s == "Failed"
| project
    OrderTime = datetime_utc_to_local(TimeGenerated, 'Asia/Kuala_Lumpur'),
    WorkflowName = resource_workflowName_s,
    CorrelationId = correlation_clientTrackingId_s,
    ErrorCode = error_code_s,
    ErrorMessage = error_message_s
| order by OrderTime desc

-- Service Bus dead-letter queue depth (last hour)
AzureMetrics
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| where MetricName == "DeadletteredMessages"
| summarize MaxDLQ = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc

-- End-to-end order flow: APIM → Logic App → Service Bus
requests
| where cloud_RoleName startswith "apim" or cloud_RoleName startswith "la-bmwc"
| extend CorrelationId = tostring(customDimensions["X-Correlation-ID"])
| where isnotempty(CorrelationId)
| project timestamp, cloud_RoleName, name, duration, success, CorrelationId
| order by timestamp desc
```

---

## Appendix B — Scaling Reference

| Metric | WS1 × 1 worker | WS1 × 3 workers | WS2 × 3 workers |
|---|---|---|---|
| Approx concurrent executions | ~35 | ~100 | ~200 |
| Max message throughput (SB) | ~200 msg/min | ~600 msg/min | ~1,200 msg/min |
| VNet integration | ✅ | ✅ | ✅ |
| Monthly compute cost (SGD approx) | ~$35 | ~$105 | ~$210 |

> Costs are estimates for Southeast Asia region. Verify with the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/).
