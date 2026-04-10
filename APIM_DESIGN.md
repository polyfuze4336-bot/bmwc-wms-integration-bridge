# BMWC → WMS Bridge — APIM Design

**Version**: 1.0  
**Date**: April 2026

---

## Table of Contents

1. [API Path Design](#1-api-path-design)
2. [Operation Names and Conventions](#2-operation-names-and-conventions)
3. [APIM Policy Reference](#3-apim-policy-reference)
4. [Error Response Handling](#4-error-response-handling)
5. [Product and Subscription Strategy](#5-product-and-subscription-strategy)
6. [OpenAPI Definition](#6-openapi-definition)
7. [Naming Recommendations](#7-naming-recommendations)
8. [Policy Scope Execution Order](#8-policy-scope-execution-order)
9. [Demo Quick-Start](#9-demo-quick-start)

---

## 1. API Path Design

### Base URL structure

```
https://{apim-name}.azure-api.net/bmwc
```

| Segment | Value | Rationale |
|---|---|---|
| Gateway prefix | `https://{apim-name}.azure-api.net` | APIM Consumption default — no VNet |
| API path prefix | `/bmwc` | Namespaces the API under the APIM instance; other APIs (`/health`, `/admin`) can coexist |
| Resource | `/orders` | Plural, lowercase noun — REST convention |
| Sub-resource | `/orders/{orderId}/status` | Nested status under the order resource |

### Operations

| Method | Path | Operation ID | Description |
|---|---|---|---|
| `POST` | `/bmwc/orders` | `submitOrder` | Submit a BMWC order — async fire-and-forget |
| `GET` | `/bmwc/orders/{orderId}/status` | `getOrderStatus` | Poll WMS dispatch status |

### Design decisions

**No `PUT` or `PATCH`**: Orders are immutable once submitted. Corrections require a new `orderId` (new order) — the WMS will have already started processing the original.

**No `DELETE`**: Cancellation is a WMS business process, not an API operation in this bridge. A separate `POST /orders/{orderId}/cancel` operation can be added when WMS WSDL exposes a `CancelOrder` operation.

**`/status` as sub-resource**: Keeps the order URI clean (`/orders/{id}`) for future expansion (e.g., `GET /orders/{id}/lines`, `GET /orders/{id}/shipments`).

**Versioning**: Not yet applied to the path (no `/v1/` prefix). Add `/v1/` when the API reaches its first breaking change. APIM supports version sets natively — update the `apiVersion` property in Bicep.

---

## 2. Operation Names and Conventions

### APIM resource names

| Resource | Bicep name | Display name |
|---|---|---|
| API | `bmwc-wms-api` | `BMWC → WMS Bridge` |
| POST operation | `post-order` | `Submit Order to WMS` |
| GET operation | `get-order-status` | `Get WMS Order Status` |
| Integration product | `bmwc-integration` | `BMWC Integration` |
| Demo product | `bmwc-demo` | `BMWC Demo` |
| Demo subscription | `bmwc-demo-subscription` | `BMWC Demo Subscription` |

### HTTP semantics

| Rule | Implementation |
|---|---|
| `POST /orders` returns `202` not `200` | Operation policy maps LA trigger 200 → 202 |
| `GET /orders/{id}/status` returns `200` | Standard synchronous read |
| Error responses use JSON body | All scopes (global → API → on-error) return structured JSON |
| `X-Correlation-ID` always present on response | Global policy `outbound` echoes it |
| `X-Workflow-Run-ID` on `POST /orders` 202 | Post-order operation policy promotes from LA header |

---

## 3. APIM Policy Reference

### Policy files

| File | Scope | Purpose |
|---|---|---|
| [apim-policies/global-policy.xml](apim-policies/global-policy.xml) | All APIs | CORS, correlation ID injection, subscription key strip, implementation header removal |
| [apim-policies/bmwc-api-policy.xml](apim-policies/bmwc-api-policy.xml) | `/bmwc` API | IP allowlist, rate-limit, quota, content-type check, 256 KB size guard, backend routing, async timeout |
| [apim-policies/post-order-operation-policy.xml](apim-policies/post-order-operation-policy.xml) | `POST /bmwc/orders` | Method guard, Content-Type enforce, 200→202 rewrite, cache headers |
| [apim-policies/get-status-operation-policy.xml](apim-policies/get-status-operation-policy.xml) | `GET /bmwc/orders/{id}/status` | orderId validation, demo mock response, cache comment |

---

### 3a. Subscription key check

Enforced at the **API level** in Bicep (`subscriptionRequired: true`), not in policy XML. APIM rejects requests without a valid `Ocp-Apim-Subscription-Key` header before any policy runs.

```bicep
// apim.bicep — API definition
subscriptionRequired: true
subscriptionKeyParameterNames: {
  header: 'Ocp-Apim-Subscription-Key'
  query: 'subscription-key'    // query param also accepted for Postman demos
}
```

The subscription key is stripped from the request before it reaches Logic Apps:

```xml
<!-- global-policy.xml inbound -->
<set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />
```

---

### 3b. IP Filtering / Allowlist

Located in `bmwc-api-policy.xml` `inbound` — commented out for demo, uncomment and populate CIDRs for production.

```xml
<!-- Production: replace CIDRs with BMWC source system egress IPs -->
<ip-filter action="allow">
    <address-range from="203.0.113.10" to="203.0.113.10" />
    <address-range from="198.51.100.0" to="198.51.100.255" />
</ip-filter>
```

**How it works**: APIM evaluates the client IP before any other inbound policy (it runs first in the chain regardless of XML position). Blocked IPs receive `403 Forbidden` without consuming rate-limit quota.

**Demo bypass**: The IP filter block is commented out. The `allow-all` sentinel is also commented out — simply omit the element to allow all IPs during the demo.

**For private networks**: If BMWC connects over ExpressRoute or VPN, use the private IP range of the BMWC on-premises NAT. For Azure-hosted callers, use the caller's VNet subnet or outbound NAT IP.

---

### 3c. Correlation ID Propagation

Three-layer propagation chain:

```
1. BMWC caller sends X-Correlation-ID: <guid>               (optional)
   ↓
2. APIM global-policy inbound:
     <set-header name="X-Correlation-ID" exists-action="skip">
       <value>@(context.RequestId.ToString())</value>        ← only if absent
     </set-header>
   ↓
3. APIM bmwc-api-policy inbound:
     <set-header name="X-Correlation-ID" exists-action="override">
       <value>@(context.Request.Headers.GetValueOrDefault("X-Correlation-ID",
                                                           context.RequestId.ToString()))</value>
     </set-header>                                           ← ensure it's set for backend
   ↓
4. Logic Apps bmwc-rest-ingress:
     Init_CorrelationId = coalesce(header X-Correlation-ID, guid())
     _meta.correlationId added to Service Bus message
   ↓
5. Service Bus message UserProperties.correlationId          ← queryable
   ↓
6. wms-soap-dispatcher reads _meta.correlationId
     Adds to SOAP header wms:CorrelationId
     Includes in all telemetry log entries
   ↓
7. APIM global-policy outbound echoes on response:
     X-Correlation-ID: <original guid>
```

Result: The same GUID appears in APIM access logs, Logic Apps run history, Service Bus message properties, WMS SOAP header, and Log Analytics — enabling a single-query full journey trace.

---

### 3d. Request Size Validation (256 KB)

```xml
<!-- bmwc-api-policy.xml — 262144 = 256 × 1024 bytes -->
<validate-content unspecified-content-type-action="prevent"
                  max-size="262144"
                  size-exceeded-action="prevent"
                  errors-variable-name="requestBodyErrors">
    <content type="application/json" validate-as="json" action="prevent" />
</validate-content>
```

**What APIM checks**:
- `Content-Length` header if present — fast path, no body read
- Actual body size if `Content-Length` absent (chunked transfer)

**On violation**: Returns `413 Content Too Large` before Logic Apps is invoked — no run created, no billing. The `on-error` handler wraps it in the standard JSON error envelope.

**Why 262144 not 256000**: 256 KB = 256 × 1024 = 262,144 bytes. The previous value of 102,400 was 100 KB — now corrected.

---

### 3e. Backend Timeout for Async Ingress

```xml
<!-- bmwc-api-policy.xml backend section -->
<forward-request timeout="30" fail-on-error-status-code="false" />
```

**Why 30 seconds**: The `bmwc-rest-ingress` workflow is async fire-and-forget — it validates the schema, initialises variables, composes the enriched message, and sends to Service Bus. Under normal conditions this completes in 1–3 seconds. 30 seconds accommodates cold start on Logic Apps Standard (first request after idle warm-up) and Service Bus transient retries.

**`fail-on-error-status-code="false"`**: Prevents APIM from short-circuiting on non-2xx responses from Logic Apps. The `on-error` handler at the API level provides consistent JSON formatting for all error status codes.

**If Logic Apps returns 504 gateway timeout**: APIM propagates it to the caller as a `504` with the structured JSON error body from `on-error`.

---

## 4. Error Response Handling

All errors — regardless of which policy scope produces them — return a consistent JSON envelope. Logic Apps raw errors, APIM XML fault documents, and backend error bodies are all suppressed.

### Standard error envelope

```json
{
  "status": "<ERROR_CATEGORY>",
  "code": "<MACHINE_READABLE_CODE>",
  "message": "<Human-readable explanation>",
  "correlationId": "<uuid>",
  "timestamp": "2026-04-09T02:00:05Z"
}
```

### Error code reference

| HTTP | `status` | `code` | Source |
|---|---|---|---|
| 400 | `VALIDATION_ERROR` | `SCHEMA_VALIDATION_FAILED` | Logic App `EnableSchemaValidation` |
| 400 | `VALIDATION_ERROR` | `TIMESTAMP_PARSE_FAILED` | Logic App runtime |
| 400 | `VALIDATION_ERROR` | `INVALID_ORDER_ID` | GET operation policy `orderId` regex |
| 401 | `UNAUTHORIZED` | `SUBSCRIPTION_KEY_INVALID` | APIM subscription check |
| 403 | `FORBIDDEN` | `IP_NOT_ALLOWED` | APIM `ip-filter` |
| 405 | `METHOD_NOT_ALLOWED` | `METHOD_NOT_ALLOWED` | POST operation policy |
| 413 | `PAYLOAD_TOO_LARGE` | `MAX_PAYLOAD_EXCEEDED` | APIM `validate-content` |
| 415 | `UNSUPPORTED_MEDIA_TYPE` | `CONTENT_TYPE_REQUIRED` | API policy `choose` block |
| 429 | `RATE_LIMITED` | `RATE_LIMIT_EXCEEDED` | APIM `rate-limit` |
| 429 | `RATE_LIMITED` | `QUOTA_EXCEEDED` | APIM `quota` |
| 500 | `ERROR` | `ENQUEUE_FAILED` | Logic App `Scope_EnqueueFailure` |
| 500 | `ERROR` | `GATEWAY_ERROR` | APIM `on-error` catch-all |
| 504 | `ERROR` | `GATEWAY_TIMEOUT` | APIM forward-request timeout |

### Headers on error responses

| Header | Value |
|---|---|
| `Content-Type` | `application/json` — always set on error |
| `X-Correlation-ID` | Always present (generated by global policy if not supplied by caller) |
| `Retry-After` | Present on 429 responses |
| `Allow` | Present on 405 responses |

---

## 5. Product and Subscription Strategy

### Products

| Product Bicep name | Display | Subscribers | Approval | Rate limit | Use |
|---|---|---|---|---|---|
| `bmwc-integration` | BMWC Integration | System accounts | Not required | API-level 100/min | Production system-to-system |
| `bmwc-demo` | BMWC Demo | Developers, demo audience | Not required | Same (API-level) | Live demos, Postman testing |

Both products surface the same API and policies — the product distinction is only for subscription key scoping. In production, add `approvalRequired: true` to `bmwc-integration` and issue keys manually.

### Subscriptions

| Subscription | Product | Purpose |
|---|---|---|
| `bmwc-demo-subscription` | `bmwc-demo` | Created automatically by azd — key available immediately post-provision |
| `bmwc-integration-{system}` | `bmwc-integration` | Created manually for each BMWC source system |

### Getting the demo key after deployment

```powershell
# Retrieve the primary key for the demo subscription
az apim subscription keys list \
  --resource-group <rg> \
  --service-name <apim-name> \
  --sid bmwc-demo-subscription \
  --query primaryKey -o tsv
```

---

## 6. OpenAPI Definition

The OpenAPI 3.0 skeleton is at [apim-policies/openapi-bmwc-wms-bridge.yaml](apim-policies/openapi-bmwc-wms-bridge.yaml).

Import into APIM:

```powershell
# Import OpenAPI definition into APIM (replaces existing API spec)
az apim api import \
  --resource-group <rg> \
  --service-name <apim-name> \
  --path bmwc \
  --specification-format OpenApiJson \
  --specification-url https://<storage-account>.blob.core.windows.net/specs/openapi-bmwc-wms-bridge.yaml \
  --api-id bmwc-wms-api
```

Or paste directly into Azure Portal → API Management → APIs → Import → OpenAPI.

The OpenAPI file can also be served from APIM itself:

```
GET https://{apim-name}.azure-api.net/bmwc?export=true&format=openapi
```

---

## 7. Naming Recommendations

### APIM service

```
apim-{project}-{env}
Examples:
  apim-bmwc-wms-dev
  apim-bmwc-wms-uat
  apim-bmwc-wms-prod
```

### APIs

```
{source-system}-{target-system}-api
Examples:
  bmwc-wms-api          ← current
  erp-wms-api           ← future ERP integration
  portal-wms-api        ← future self-service portal
```

### Operations

Format: `{http-verb}-{noun}-{qualifier?}`

| ✅ Good | ❌ Avoid |
|---|---|
| `post-order` | `create` (no noun) |
| `get-order-status` | `getOrderStatus` (camelCase) |
| `delete-order` | `DeleteOrder` (PascalCase) |

### Products

```
{source-system}-{tier}
Examples:
  bmwc-integration      ← system-to-system
  bmwc-demo             ← demo/test
  bmwc-premium          ← future: higher rate limits for critical flows
```

### Subscriptions

```
{source-system}-{consumer}-subscription
Examples:
  bmwc-demo-subscription          ← auto-created by azd
  bmwc-erp-subscription           ← ERP system
  bmwc-portal-subscription        ← self-service web portal
```

### Named Values

```
{backend-shortname}-{workflow}-{property}
Examples:
  la-bmwc-ingest-url       ← Logic App trigger URL for order ingress
  la-status-url            ← Logic App trigger URL for status query (future)
  wms-endpoint             ← WMS base URL (if needed at APIM level)
```

### APIM Policy files (in this repo)

```
apim-policies/
  global-policy.xml                    ← all-API scope
  bmwc-api-policy.xml                  ← /bmwc API scope
  post-order-operation-policy.xml      ← POST /orders operation scope
  get-status-operation-policy.xml      ← GET /orders/{id}/status operation scope
  openapi-bmwc-wms-bridge.yaml         ← API definition
```

---

## 8. Policy Scope Execution Order

APIM executes policies in **inbound → backend → outbound → on-error** order. Within a direction, scope runs from outer (global) to inner (operation) for inbound, and inner to outer for outbound.

```
INBOUND (outer → inner)
┌─ Global policy inbound
│    • CORS
│    • Inject X-Correlation-ID if absent
│    • Strip Ocp-Apim-Subscription-Key
└─── API policy inbound
│        • <base /> ← calls global
│        • IP filter (if enabled)
│        • rate-limit + quota
│        • Content-Type check
│        • validate-content (256 KB)
│        • Set X-Correlation-ID (override)
│        • set-backend-service
└─────── Operation policy inbound
             • <base /> ← calls API
             • Method guard
             • Set Content-Type for backend
             • Set X-Source-System
             • (Demo GET: return-response mock)

BACKEND
  forward-request (timeout 30s)

OUTBOUND (inner → outer)
┌─ Operation policy outbound
│    • <base /> ← calls API
│    • Map 200 → 202 (POST only)
│    • Strip Location header
│    • Set Cache-Control
└─── API policy outbound
│        • <base /> ← calls global
│        • Strip x-ms-workflow-run-id
│        • Promote X-Workflow-Run-ID
└─────── Global policy outbound
             • Set X-Correlation-ID (echo)
             • Set X-BMWC-Gateway
             • Delete Server, X-Powered-By

ON-ERROR
  API policy on-error (structured JSON)
  → falls through to global on-error
```

---

## 9. Demo Quick-Start

### Step 1 — Provision

```powershell
azd up
```

APIM Consumption tier provisions in ~2 minutes. The `post-provision.ps1` hook wires the Logic App trigger URL into the Named Value automatically.

### Step 2 — Get subscription key

```powershell
$key = az apim subscription keys list `
  --resource-group <rg> `
  --service-name <apim-name> `
  --sid bmwc-demo-subscription `
  --query primaryKey -o tsv
```

### Step 3 — Submit an order

```http
POST https://<apim-name>.azure-api.net/bmwc/orders
Content-Type: application/json
Ocp-Apim-Subscription-Key: <key>
X-Correlation-ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890

{
  "orderId": "ORD-2026-DEMO-001",
  "customerId": "CUST-BMWC-001",
  "warehouseCode": "WH-SIN",
  "orderDate": "2026-04-09T02:00:00Z",
  "lines": [
    { "lineNo": 1, "sku": "SKU-W-001", "quantity": 10 }
  ]
}
```

Expected: `202 Accepted` with JSON body containing `correlationId` and `workflowRunId`.

### Step 4 — Check status

```http
GET https://<apim-name>.azure-api.net/bmwc/orders/ORD-2026-DEMO-001/status
Ocp-Apim-Subscription-Key: <key>
```

Expected: `200 OK` with `status: "WMS_ACCEPTED"` (demo mock).

### Step 5 — View trace in Azure Portal

1. Open Logic Apps → `la-bmwc-wms-<token>` → Workflows → `bmwc-rest-ingress`
2. Navigate to Run History → find the run by `workflowRunId` from the 202 response
3. Click the run → see the full action execution trace with inputs/outputs
4. Filter Log Analytics with `correlationId` to see the end-to-end journey
