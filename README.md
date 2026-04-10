# BMWC → WMS REST-to-SOAP Bridge

> **Enterprise integration platform** — BMWC's modern REST order API dispatches asynchronously to a legacy WMS SOAP service via Azure API Management, Logic Apps Standard, and Service Bus. Designed for production deployment in Singapore (`southeastasia`) with Malaysia South (`malaysiasouth`) as a secondary region.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        BMWC Modern System                                │
│                     (JSON / HTTPS REST clients)                          │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ POST /bmwc/orders
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│               Azure API Management (Consumption)                         │
│  • IP allowlist (BMWC CIDR)  • Subscription key auth                    │
│  • Rate-limit (100/min)      • X-Correlation-ID injection                │
│  • Quota (10k/week)          • App Insights 100% sampling                │
│  • Routes → Logic App HTTP trigger URL (Named Value)                     │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ HTTPS
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│       Logic Apps Standard — bmwc-rest-ingress (Stateful)                 │
│  • Schema validation (orderId, customerId, warehouseCode, lines)         │
│  • UTC timestamp normalisation                                            │
│  • Enriches with _meta (correlationId, enqueuedAtUtc, source)            │
│  • Enqueues to Service Bus (messageId = orderId for dedup)               │
│  • Returns 202 Accepted                                                   │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ wms-inbound queue
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│               Azure Service Bus (Standard) — wms-inbound                 │
│  • Duplicate detection (10 min)  • Lock duration: 10 min                 │
│  • Max delivery: 5               • TTL: 4 hours                          │
│  • Dead-letter → wms-dead-letter-review queue                            │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ peek-lock trigger
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│       Logic Apps Standard — wms-soap-dispatcher (Stateful)               │
│  • Liquid map: JSON → SOAP 1.1 envelope                                  │
│  • Calls WMS CreateOrder (exponential retry 3× — 5s, 30s, 120s)         │
│  • Handles SOAP Fault vs. server error                                   │
│  • Logs WMS_DISPATCH_SUCCESS / WMS_SOAP_FAULT to App Insights            │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ HTTPS/SOAP (VNet — private outbound)
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│               Legacy WMS SOAP Service (on-premises / private)            │
│               Operation: CreateOrder                                      │
│               (Demo: wms-soap-mock container on port 8080)               │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│       Logic Apps Standard — dlq-monitor (Stateful, scheduled)            │
│  • Runs every 15 minutes                                                  │
│  • Counts wms-dead-letter-review queue depth                             │
│  • Emits DLQ_ALERT_SUMMARY event to App Insights                        │
│  • Azure Monitor alert fires when count > 0                              │
└──────────────────────────────────────────────────────────────────────────┘

Observability — cross-cutting:
  Log Analytics workspace  ←  Logic Apps + APIM + Service Bus diagnostics
  Application Insights     ←  Distributed traces, structured events
  Azure Monitor            ←  6 alert rules (RunsFailed, DLQ, Latency, APIM 5xx, …)
```

### Component Diagram

```mermaid
graph TD
    BMWC["🏢 BMWC System\n(REST client)"]
    APIM["🔒 API Management\nConsumption SKU\n• IP allowlist\n• Subscription key\n• Rate limit 100/min\n• Quota 10k/week"]
    LA1["⚙️ Logic App\nbmwc-rest-ingress\nStateful workflow"]
    SB["📨 Service Bus\nStandard — wms-inbound\n• Dedup 10 min\n• Max delivery: 5\n• TTL: 4 hours"]
    LA2["⚙️ Logic App\nwms-soap-dispatcher\nStateful workflow"]
    WMS["🏭 Legacy WMS\nSOAP service\nCreateOrder"]
    LA3["⏰ Logic App\ndlq-monitor\nEvery 15 min"]
    DLQ["⚠️ Dead-letter Queue\nwms-dead-letter-review"]
    KV["🔑 Key Vault\nWMS credentials"]
    VNET["🌐 VNet snet-logicapp\n10.10.1.0/24"]
    OBS["📊 Observability\nLog Analytics + App Insights\nAzure Monitor Alerts"]

    BMWC -->|"POST /bmwc/orders\nHTTPS + subscription key"| APIM
    APIM -->|"HTTPS forward\nNamed Value: la-bmwc-ingest-url"| LA1
    LA1 -->|"Enqueue\nmessageId = orderId"| SB
    LA1 -->|"202 Accepted\n{orderId, correlationId}"| APIM
    SB -->|"Peek-lock trigger"| LA2
    LA2 -->|"Liquid transform\nJSON → SOAP"| VNET
    VNET -->|"HTTPS POST\nSOAP 1.1"| WMS
    SB -->|"After 5 failures\nauto dead-letter"| DLQ
    LA3 -->|"Count messages"| DLQ
    LA2 -.->|"KV secret references"| KV
    LA1 -.->|"KV secret references"| KV
    LA1 -.->|"Traces + events"| OBS
    LA2 -.->|"Traces + events"| OBS
    APIM -.->|"100% sampled"| OBS
    LA3 -.->|"DLQ_ALERT_SUMMARY"| OBS

    style BMWC fill:#0078D4,color:#fff
    style APIM fill:#E8A202,color:#fff
    style LA1 fill:#0054B1,color:#fff
    style LA2 fill:#0054B1,color:#fff
    style LA3 fill:#0054B1,color:#fff
    style SB fill:#0078D4,color:#fff
    style WMS fill:#666,color:#fff
    style DLQ fill:#D83B01,color:#fff
    style KV fill:#107C10,color:#fff
    style VNET fill:#773388,color:#fff
    style OBS fill:#555,color:#fff
```

### End-to-End Order Flow

```mermaid
sequenceDiagram
    participant B as BMWC System
    participant A as API Management
    participant L1 as bmwc-rest-ingress
    participant SB as Service Bus<br/>wms-inbound
    participant L2 as wms-soap-dispatcher
    participant W as WMS SOAP

    B->>A: POST /bmwc/orders<br/>Ocp-Apim-Subscription-Key
    A->>A: ① IP allowlist check<br/>② Subscription key validate<br/>③ Rate-limit / quota check<br/>④ Inject X-Correlation-ID
    A->>L1: HTTPS forward (Named Value URL)

    activate L1
    L1->>L1: Validate JSON schema<br/>Normalise orderDate → UTC<br/>Compose _meta envelope
    L1->>SB: Send message<br/>messageId = orderId (dedup key)
    L1-->>A: 202 Accepted {orderId, correlationId}
    deactivate L1

    A-->>B: 202 Accepted

    Note over SB,L2: Async dispatch (independent of BMWC call)

    SB->>L2: Peek-lock trigger<br/>(lock 10 min)
    activate L2
    L2->>L2: Parse order JSON<br/>Liquid map → SOAP envelope
    L2->>W: POST SOAP CreateOrder<br/>exponential retry 3×

    alt WMS success
        W-->>L2: 200 OK + wmsOrderId
        L2->>L2: Log WMS_DISPATCH_SUCCESS
        L2->>SB: Complete (delete) message
    else SOAP Fault
        W-->>L2: 200 OK + Fault element
        L2->>L2: Log WMS_SOAP_FAULT<br/>Terminate(Failed)
        L2->>SB: Abandon (delivery count++)
    else Network / timeout
        L2->>L2: Retry × 3 exhausted<br/>Terminate(Failed)
        L2->>SB: Abandon (delivery count++)
    end
    deactivate L2

    Note over SB: After 5 delivery attempts → auto dead-letter

    loop Every 15 minutes
        Note over L2: dlq-monitor polls<br/>wms-dead-letter-review<br/>Emits DLQ_ALERT_SUMMARY
    end
```

---

## Azure Services

| Service | SKU | Purpose |
|---|---|---|
| API Management | Consumption | Secure REST ingress, IP allowlist, rate limiting, correlation |
| Logic Apps Standard | WS1 | Orchestration, JSON→SOAP transform, retry, DLQ monitoring |
| Service Bus | Standard | Async buffer, duplicate detection, dead-letter queue |
| VNet | — | Private outbound from Logic Apps to WMS (10.10.0.0/16) |
| Key Vault | Standard | WMS endpoint URL and credentials as KV secret references |
| Log Analytics | PerGB2018 | Centralised log store, 30d demo / 90d production |
| Application Insights | — | Distributed traces, structured event telemetry |
| Storage Account | LRS | Logic Apps Standard runtime state |

**Primary region**: Southeast Asia (Singapore) `southeastasia`  
**Secondary region**: Malaysia South `malaysiasouth` — independent deployment via `main.parameters.prod-my.json`

---

## Repo Structure

```
AppLogic/
├── infra/
│   ├── main.bicep                        # Subscription-scoped Bicep orchestrator
│   ├── main.parameters.json              # azd env-var bindings (all environments)
│   ├── main.parameters.demo.json         # Demo defaults — permissive, Singapore
│   ├── main.parameters.prod-sg.json      # Production — hardened, Singapore
│   ├── main.parameters.prod-my.json      # Production — hardened, Malaysia South
│   └── modules/
│       ├── apim.bicep                    # APIM + BMWC API definition + IP-filter policy
│       ├── alerts.bicep                  # 6 Azure Monitor alert rules
│       ├── keyvault.bicep                # Key Vault + WMS credential secrets
│       ├── loganalytics.bicep            # Log Analytics + Application Insights
│       ├── logicapp.bicep                # Logic Apps Standard WS1 + App Service Plan
│       ├── servicebus.bicep              # Service Bus namespace + queues
│       └── vnet.bicep                    # VNet + subnets + NSGs
├── logic-app/
│   ├── host.json                         # Logic Apps runtime config (extensionBundle)
│   ├── connections.json                  # Service Bus built-in connector declaration
│   ├── parameters.json                   # Workflow parameter → app setting bindings
│   ├── lib/
│   │   └── maps/                         # Liquid maps consumed by Logic Apps runtime
│   │       ├── bmwc-order-to-wms-soap.liquid
│   │       └── wms-soap-response-to-json.liquid
│   └── workflows/
│       ├── bmwc-rest-ingress/            # HTTP trigger → validate → enqueue → 202
│       │   └── workflow.json
│       ├── wms-soap-dispatcher/          # SB trigger → Liquid transform → WMS SOAP call
│       │   └── workflow.json
│       └── dlq-monitor/                  # Recurrence → count DLQ → log alert summary
│           └── workflow.json
├── maps/                                 # Canonical Liquid map source (mirrors lib/maps/)
│   ├── bmwc-order-to-wms-soap.liquid
│   └── wms-soap-response-to-json.liquid
├── apim-policies/
│   ├── global-policy.xml                 # Correlation ID injection (all APIs)
│   ├── bmwc-api-policy.xml               # Rate-limit, IP-filter, backend routing
│   ├── post-order-operation-policy.xml   # POST /bmwc/orders operation policy
│   ├── get-status-operation-policy.xml   # GET /bmwc/orders/{id}/status policy
│   └── openapi-bmwc-wms-bridge.yaml      # OpenAPI 3.0 definition for BMWC API
├── mocks/
│   └── wms-soap-mock/
│       ├── server.js                     # Express SOAP mock — CreateOrder endpoint
│       ├── package.json
│       └── Dockerfile
├── tests/
│   ├── bmwc-order.http                   # VS Code REST Client integration tests
│   ├── BMWC-WMS-Bridge.postman_collection.json  # Postman collection (7 scenarios)
│   ├── curl-demo.sh                      # End-to-end bash demo script
│   ├── DEMO-SCRIPT.md                    # Presenter script with narration + Q&A
│   ├── EXPECTED-OUTPUTS.md               # Per-layer expected values for each scenario
│   ├── log-analytics-queries.kql         # 12 KQL queries (import as Saved Queries)
│   ├── payloads/                         # Sample BMWC request payloads
│   │   ├── 01-success-standard.json
│   │   ├── 02-success-urgent-timezone.json
│   │   ├── 03-transient-failure.json
│   │   ├── 04-dlq-trigger.json
│   │   ├── 05-invalid-missing-required.json
│   │   ├── 06-invalid-orderid-pattern.json
│   │   └── 07-idempotency-duplicate.json
│   └── wms-responses/                    # WMS SOAP mock response examples
│       ├── wms-response-success.xml
│       ├── wms-response-soap-fault.xml
│       └── wms-response-server-fault.xml
├── scripts/
│   └── post-provision.ps1                # azd postprovision hook: wire APIM → LA trigger URL
├── azure.yaml                            # azd project definition
├── .env.example                          # Full environment variable reference
├── .gitignore
│
│   Design docs
├── ARCHITECTURE.md                       # Logical architecture + decision log
├── API_CONTRACT.md                       # Canonical JSON schema + field reference
├── TRANSFORMATION_SPEC.md                # JSON→SOAP field mapping + Liquid map reference
├── APIM_DESIGN.md                        # APIM policy chain + OpenAPI design
├── SERVICE_BUS_DESIGN.md                 # Queue configuration + dead-letter design
├── NETWORK_DESIGN.md                     # VNet topology + NSG rules
└── OBSERVABILITY_DESIGN.md              # Log Analytics queries + alert rule spec
```

---

## Workflows

### `bmwc-rest-ingress` — HTTP trigger → Service Bus

Triggered by APIM forwarding a `POST /bmwc/orders` call. Acts as the firewall and intake valve for all orders.

| Step | Action |
|---|---|
| 1 | Receive `POST` — read or generate `X-Correlation-ID` |
| 2 | Validate JSON schema (`orderId`, `customerId`, `warehouseCode`, `lines[]` required) |
| 3 | Normalise `orderDate` to UTC (strip `+08:00` or any offset) |
| 4 | Compose `_meta` envelope (`correlationId`, `enqueuedAtUtc`, `source`, `schemaVersion`) |
| 5 | Send enriched message to `wms-inbound` queue — `messageId = orderId` (dedup key) |
| 6 | Return `202 Accepted` `{ orderId, correlationId, message }` |
| 7 | On Service Bus failure → return `500` with `correlationId` |

### `wms-soap-dispatcher` — Service Bus trigger → WMS SOAP

Dequeues from `wms-inbound` in peek-lock mode and dispatches to the WMS. The lock and retry budget are the durability guarantee.

| Step | Action |
|---|---|
| 1 | Dequeue message (peek-lock, 10-min lock) |
| 2 | Recover `correlationId` from message `userProperties` |
| 3 | Parse canonical order JSON from message body |
| 4 | Transform JSON → SOAP 1.1 envelope via Liquid map |
| 5 | `POST` to WMS endpoint — exponential retry 3× (5s → 30s → 120s) |
| 6 | `200 OK` with `<wms:Status>SUCCESS</wms:Status>` → log `WMS_DISPATCH_SUCCESS`, complete message |
| 7 | SOAP Fault → log `WMS_SOAP_FAULT`, terminate run; Service Bus increments delivery count |
| 8 | After 5 delivery attempts → Service Bus dead-letters automatically |

### `dlq-monitor` — Recurrence → DLQ check

Runs on a 15-minute schedule. Provides ops visibility without requiring queue polling by humans.

| Step | Action |
|---|---|
| 1 | Trigger every 15 minutes |
| 2 | Get `wms-dead-letter-review` queue message count |
| 3 | If count > 0 → emit `DLQ_ALERT_SUMMARY` to App Insights |
| 4 | Azure Monitor alert rule `alert-dlq-present-{env}` fires when count > 0 |

---

## Naming Conventions

| Resource | Pattern | Example |
|---|---|---|
| Resource Group | `rg-bmwc-wms-{env}` | `rg-bmwc-wms-prod-sg` |
| Logic App | `la-bmwc-wms-{token}` | `la-bmwc-wms-abc123` |
| App Service Plan | `asp-bmwc-wms-{token}` | `asp-bmwc-wms-abc123` |
| Service Bus | `sb-bmwc-wms-{token}` | `sb-bmwc-wms-abc123` |
| SB queue — inbound | `wms-inbound` | — |
| SB queue — dead-letter review | `wms-dead-letter-review` | — |
| Key Vault | `kv-bmwc-{token}` | `kv-bmwc-abc123` |
| APIM | `apim-bmwc-{env}` | `apim-bmwc-prod-sg` |
| VNet | `vnet-bmwc-wms-{token}` | — |
| Log Analytics | `log-bmwc-wms-{token}` | — |
| App Insights | `appi-bmwc-wms-{token}` | — |
| Workflow names | `{source}-{verb}-{noun}` | `bmwc-rest-ingress`, `wms-soap-dispatcher`, `dlq-monitor` |
| APIM API base path | `bmwc` | `/bmwc/orders` |
| KV secrets | `wms-soap-{attribute}` | `wms-soap-endpoint`, `wms-soap-password` |

---

## Quick Start

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.57
- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) ≥ 1.7
- PowerShell 7+
- Node.js 18+ (for WMS mock)
- Docker (optional — for containerised mock)

### 1. Clone and configure

```bash
git clone <this-repo>
cd AppLogic
cp .env.example .env
# Edit .env: set AZURE_SUBSCRIPTION_ID, APIM_PUBLISHER_EMAIL
```

### 2. Start the local WMS mock

```bash
cd mocks/wms-soap-mock
npm install
npm start
# Mock runs on http://localhost:8080
# WSDL:   http://localhost:8080/WMSService.svc?wsdl
# Health: http://localhost:8080/health
```

### 3. Provision infrastructure

Choose one of the three parameter files, then run:

```bash
azd auth login
azd env new demo                                          # or prod-sg / prod-my
azd env set AZURE_LOCATION southeastasia                  # or malaysiasouth
azd env set WMS_USERNAME bmwc_api
azd env set WMS_PASSWORD <wms-password>
azd env set APIM_PUBLISHER_EMAIL ops@bmwc.example.com

# Demo deployment (permissive defaults — Singapore)
azd provision --parameters infra/main.parameters.demo.json

# Production Singapore
azd provision --parameters infra/main.parameters.prod-sg.json
```

`azd provision` will:
1. Deploy all 7 Bicep modules in dependency order
2. Run `scripts/post-provision.ps1` — wires the APIM Named Value `la-bmwc-ingest-url` to the Logic App trigger callback URL

### 4. Deploy Logic App workflows

```bash
# VS Code — recommended for iterative development
# Open logic-app/ in VS Code with Azure Logic Apps (Standard) extension → Deploy to Logic App

# CLI zip-deploy — recommended for CI/CD
cd logic-app
zip -r ../logicapp-deploy.zip .
az logicapp deployment source config-zip \
  --name $LOGIC_APP_NAME \
  --resource-group $RESOURCE_GROUP_NAME \
  --src ../logicapp-deploy.zip
```

### 5. Run the demo

```bash
export APIM_GATEWAY_URL="https://apim-bmwc-demo.azure-api.net"
export APIM_SUBSCRIPTION_KEY="<from APIM portal → Subscriptions>"

# End-to-end bash demo (all 6 scenarios)
bash tests/curl-demo.sh

# Or open tests/BMWC-WMS-Bridge.postman_collection.json in Postman
```

See [tests/DEMO-SCRIPT.md](tests/DEMO-SCRIPT.md) for the full presenter walkthrough.

### 6. Rotate WMS credentials (production)

```bash
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name wms-soap-password \
  --value "<real-password>"
```

---

## Demo Scenarios

| # | Scenario | File | What it demonstrates |
|---|---|---|---|
| 1 | Success — standard order | `payloads/01-success-standard.json` | Full happy path, lot-tracked item |
| 2 | Success — URGENT + GMT+8 | `payloads/02-success-urgent-timezone.json` | UTC normalisation from +08:00 |
| 3 | Transient WMS failure | `payloads/03-transient-failure.json` | Retry + lock behaviour |
| 4 | DLQ consolidation | `payloads/04-dlq-trigger.json` | Bad SKU → DLQ alert |
| 5 | Invalid request | `payloads/05-invalid-missing-required.json` | Schema gate — never reaches SB |
| 6 | orderId pattern violation | `payloads/06-invalid-orderid-pattern.json` | Pattern `^[A-Z0-9\-]+$` enforced |
| 7 | Idempotency | `payloads/07-idempotency-duplicate.json` | Service Bus dedup in 10-min window |

Expected outputs for every scenario at every layer: [tests/EXPECTED-OUTPUTS.md](tests/EXPECTED-OUTPUTS.md)  
12 KQL queries ready to import: [tests/log-analytics-queries.kql](tests/log-analytics-queries.kql)

---

## Parameter Files

| File | Target | Region | Key settings |
|---|---|---|---|
| `main.parameters.demo.json` | Demo / POC | `southeastasia` | 30d log retention, 1GB quota cap, 3 workers, purge protection off |
| `main.parameters.prod-sg.json` | Production | `southeastasia` | 90d retention, unlimited quota, 10 workers, purge protection on, sampling 10% |
| `main.parameters.prod-my.json` | Production (DR) | `malaysiasouth` | Same as prod-sg, separate WMS endpoint |

All sensitive parameters (`wmsUsername`, `wmsPassword`) must be supplied at deploy time via `azd env set` — they are never stored in parameter files.

---

## Production Hardening Checklist

- [ ] Upgrade APIM to **Developer** or **Premium** SKU for VNet injection
- [ ] Add `<validate-jwt>` APIM policy for Entra ID token enforcement
- [ ] Switch Service Bus to **Premium** SKU for private endpoints
- [ ] Add Key Vault private endpoint (subnet `snet-private-endpoints`)
- [ ] Replace Service Bus connection string with Managed Identity RBAC (`Service Bus Data Sender/Receiver`)
- [ ] Wire Alert Action Group: APIM → Monitor → Action Groups → set `actionGroupId` parameter
- [ ] Enable Logic App IP restriction (allow only APIM outbound IPs)
- [ ] Add Azure Front Door or Traffic Manager across `prod-sg` and `prod-my` APIM gateway URLs for DR failover
- [ ] Set `disableLocalAuth: true` on Service Bus after Managed Identity migration
