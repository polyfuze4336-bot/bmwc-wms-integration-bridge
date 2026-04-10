# BMWC → WMS Bridge — API Contract & Message Design

**Version**: 1.0  
**Status**: Draft for prototype  
**Owner**: Integration Platform Team  
**Date**: April 2026

---

## Table of Contents

1. [API Surface Overview](#1-api-surface-overview)
2. [Canonical BMWC Payload Schema](#2-canonical-bmwc-payload-schema)
3. [Field Reference — Required vs Optional](#3-field-reference--required-vs-optional)
4. [Field Naming Conventions](#4-field-naming-conventions)
5. [Correlation and Traceability Fields](#5-correlation-and-traceability-fields)
6. [UTC Timestamp Standards](#6-utc-timestamp-standards)
7. [Validation Rules](#7-validation-rules)
8. [Example Payloads](#8-example-payloads)
9. [OpenAPI Request / Response Specification](#9-openapi-request--response-specification)
10. [Idempotency Guidance](#10-idempotency-guidance)
11. [Canonical Envelope (Internal — BMWC → Service Bus)](#11-canonical-envelope-internal--bmwc--service-bus)

---

## 1. API Surface Overview

```
POST   {apim-gateway}/bmwc/orders           Submit a BMWC order for WMS dispatch
GET    {apim-gateway}/bmwc/orders/{id}/status  Query dispatch status by orderId
```

### Transport contract

| Property | Value |
|---|---|
| Protocol | HTTPS only (TLS 1.2 minimum) |
| Content-Type | `application/json; charset=utf-8` |
| Max payload size | 256 KB (enforced at APIM before it reaches Logic Apps) |
| Auth | `Ocp-Apim-Subscription-Key` header |
| Source restriction | IP allowlist enforced in APIM `ip-filter` policy |
| Rate limit | 100 calls/min per subscription key |
| Weekly quota | 10,000 calls/week per subscription key |
| Idempotency key | `orderId` — identical `orderId` within 10 min is a duplicate |
| Correlation ID | `X-Correlation-ID` header (GUID) — injected by APIM if caller omits it |

---

## 2. Canonical BMWC Payload Schema

This is the **authoritative schema** for the BMWC → WMS bridge inbound API. It is registered in the Logic App trigger (`EnableSchemaValidation`) and should be the source of truth for APIM OpenAPI definition, client SDKs, and test fixtures.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://bmwc.integration/schemas/order/v1.0",
  "title": "BMWC Order",
  "description": "Canonical BMWC order payload for WMS dispatch via Azure Integration Services",
  "type": "object",
  "required": ["orderId", "customerId", "warehouseCode", "orderDate", "lines"],
  "additionalProperties": true,

  "properties": {

    "orderId": {
      "type": "string",
      "minLength": 1,
      "maxLength": 50,
      "pattern": "^[A-Z0-9\\-]+$",
      "description": "BMWC order reference — uppercase alphanumeric with hyphens. Used as Service Bus messageId for duplicate detection.",
      "example": "ORD-2026-SGP-001"
    },

    "customerId": {
      "type": "string",
      "minLength": 1,
      "maxLength": 50,
      "description": "BMWC customer identifier.",
      "example": "CUST-BMWC-001"
    },

    "warehouseCode": {
      "type": "string",
      "minLength": 1,
      "maxLength": 20,
      "description": "Target WMS warehouse. Must match a valid warehouse code configured in the WMS.",
      "example": "WH-SIN"
    },

    "orderDate": {
      "type": "string",
      "description": "Order creation timestamp. Accepted as any valid ISO 8601 date-time string — the Logic App normalises it to UTC before storage. Callers should send UTC where possible.",
      "example": "2026-04-09T02:00:00Z"
    },

    "priority": {
      "type": "string",
      "enum": ["STANDARD", "URGENT", "EXPEDITE"],
      "default": "STANDARD",
      "description": "Dispatch priority. Defaults to STANDARD if omitted."
    },

    "requestedDeliveryDate": {
      "type": "string",
      "description": "Caller-supplied delivery deadline. ISO 8601 date or date-time. Optional — passed through to WMS as-is after UTC normalisation.",
      "example": "2026-04-11T00:00:00Z"
    },

    "notes": {
      "type": "string",
      "maxLength": 500,
      "description": "Free-text instructions for the warehouse. Optional."
    },

    "lines": {
      "type": "array",
      "minItems": 1,
      "maxItems": 500,
      "description": "Order line items. At least one line is required.",
      "items": {
        "type": "object",
        "required": ["lineNo", "sku", "quantity"],
        "additionalProperties": false,

        "properties": {
          "lineNo": {
            "type": "integer",
            "minimum": 1,
            "description": "Sequential line number — must be unique within the order.",
            "example": 1
          },
          "sku": {
            "type": "string",
            "minLength": 1,
            "maxLength": 50,
            "description": "BMWC stock-keeping unit. Must be registered in the WMS item master.",
            "example": "SKU-W-001"
          },
          "description": {
            "type": "string",
            "maxLength": 255,
            "description": "Human-readable item description. Optional — informational only."
          },
          "quantity": {
            "type": "number",
            "exclusiveMinimum": 0,
            "description": "Requested dispatch quantity. Must be greater than zero.",
            "example": 50
          },
          "uom": {
            "type": "string",
            "maxLength": 10,
            "default": "EA",
            "description": "Unit of measure. Defaults to EA (each) if omitted.",
            "example": "EA"
          },
          "lotNumber": {
            "type": "string",
            "maxLength": 50,
            "description": "Batch/lot number for lot-tracked items. Optional."
          },
          "serialNumber": {
            "type": "string",
            "maxLength": 100,
            "description": "Serial number for serialised items. Optional."
          }
        }
      }
    },

    "shipTo": {
      "type": "object",
      "required": ["name", "address1", "city", "country"],
      "description": "Shipping destination. Required for outbound dispatch orders.",
      "properties": {
        "name": {
          "type": "string",
          "maxLength": 100,
          "example": "BMWC Assembly Plant 1"
        },
        "address1": {
          "type": "string",
          "maxLength": 150,
          "example": "Lot 5, Jalan Jubli Perak"
        },
        "address2": {
          "type": "string",
          "maxLength": 150
        },
        "city": {
          "type": "string",
          "maxLength": 100,
          "example": "Shah Alam"
        },
        "state": {
          "type": "string",
          "maxLength": 100
        },
        "country": {
          "type": "string",
          "minLength": 2,
          "maxLength": 2,
          "description": "ISO 3166-1 alpha-2 country code.",
          "example": "MY"
        },
        "postcode": {
          "type": "string",
          "maxLength": 20,
          "example": "40150"
        },
        "contactName": {
          "type": "string",
          "maxLength": 100
        },
        "contactPhone": {
          "type": "string",
          "maxLength": 30
        }
      }
    },

    "customerReference": {
      "type": "string",
      "maxLength": 100,
      "description": "BMWC customer's own reference number (purchase order or work order). Passed through to WMS for buyer reference matching.",
      "example": "PO-BMWC-2026-045"
    }

  }
}
```

---

## 3. Field Reference — Required vs Optional

### Root-level Fields

| Field | Type | Required | Max Length | Default | Notes |
|---|---|---|---|---|---|
| `orderId` | string | **Yes** | 50 | — | Pattern: `^[A-Z0-9\-]+$`. Idempotency key. |
| `customerId` | string | **Yes** | 50 | — | |
| `warehouseCode` | string | **Yes** | 20 | — | Must match WMS warehouse master |
| `orderDate` | string | **Yes** | — | — | ISO 8601, normalised to UTC by Logic App |
| `lines` | array | **Yes** | 500 items | — | Minimum 1 item |
| `shipTo` | object | Conditionally required | — | — | Required for outbound orders |
| `priority` | string enum | No | — | `STANDARD` | `STANDARD` \| `URGENT` \| `EXPEDITE` |
| `requestedDeliveryDate` | string | No | — | — | ISO 8601 |
| `notes` | string | No | 500 | — | Free text for warehouse |
| `customerReference` | string | No | 100 | — | BMWC PO/WO reference |

### `lines[]` Item Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `lineNo` | integer | **Yes** | ≥ 1, unique within order |
| `sku` | string | **Yes** | Must exist in WMS item master |
| `quantity` | number | **Yes** | > 0 |
| `description` | string | No | Informational |
| `uom` | string | No | Default: `EA` |
| `lotNumber` | string | No | Lot-tracked items |
| `serialNumber` | string | No | Serialised items |

### `shipTo` Fields

| Field | Type | Required within `shipTo` | Notes |
|---|---|---|---|
| `name` | string | **Yes** | |
| `address1` | string | **Yes** | |
| `city` | string | **Yes** | |
| `country` | string | **Yes** | ISO 3166-1 alpha-2 |
| `address2` | string | No | |
| `state` | string | No | |
| `postcode` | string | No | |
| `contactName` | string | No | |
| `contactPhone` | string | No | |

---

## 4. Field Naming Conventions

All field names follow **lowerCamelCase** without underscores or hyphens.

| Rule | Example |
|---|---|
| Compound nouns: lowerCamelCase | `warehouseCode`, `orderDate`, `lineNo` |
| ID fields: suffix `Id` | `orderId`, `customerId` |
| Code fields: suffix `Code` | `warehouseCode` |
| Date fields: suffix `Date` | `orderDate`, `requestedDeliveryDate` |
| Number fields: suffix `No` | `lineNo` |
| Count fields: suffix `Count` | (reserved for responses) |
| Arrays: plural noun | `lines` |
| Boolean flags: `is` prefix | `isPartialShipmentAllowed` (if added) |
| Internal `_meta` properties: prefixed with `_` | `_meta.correlationId` |

### Rationale for `_` prefix on `_meta`

The `_meta` object is added by the integration layer — it is not part of the BMWC business payload. The underscore prefix signals to downstream systems (WMS mapping, logging) that this is infrastructure metadata, not business data, and should not be mapped into SOAP business elements.

---

## 5. Correlation and Traceability Fields

### HTTP Headers (caller-to-APIM)

| Header | Direction | Required | Description |
|---|---|---|---|
| `Ocp-Apim-Subscription-Key` | Request | **Yes** | APIM subscription key — authentication |
| `X-Correlation-ID` | Request | No | GUID from BMWC caller. APIM injects a new GUID if absent. Propagated through all layers. |
| `X-Correlation-ID` | Response | Always | Echo of the resolved correlation ID |
| `X-Workflow-Run-ID` | Response | Always | Logic Apps run GUID — use for run history lookup in Azure portal |

### Canonical Payload Tracing (`_meta` block)

Added by `bmwc-rest-ingress` before enqueuing to Service Bus. All downstream workflows read these fields — never regenerate them.

| Field | Type | Source | Description |
|---|---|---|---|
| `_meta.correlationId` | string | Resolved from `X-Correlation-ID` header | End-to-end trace key |
| `_meta.enqueuedAtUtc` | string | `utcNow()` at enqueue time | UTC ISO 8601 — when the message entered Service Bus |
| `_meta.source` | string | Hard-coded `"BMWC"` | Source system identifier |
| `_meta.schemaVersion` | string | Hard-coded `"1.0"` | Canonical schema version |
| `_meta.workflowRunId` | string | `workflow()['run']['name']` | Logic Apps run ID for the ingest workflow |

### Service Bus Message Properties

| Property | Value | Purpose |
|---|---|---|
| `messageId` | `orderId` | Service Bus duplicate detection key |
| `label` | `BMWC.Order.v1` | Message classification for routing/filtering |
| `userProperties.correlationId` | from `_meta` | Queryable without deserialising body |
| `userProperties.orderId` | `orderId` | Queryable without deserialising body |
| `userProperties.warehouseCode` | `warehouseCode` | Future routing/subscription filter |
| `userProperties.priority` | `priority` | Future priority-based routing |
| `userProperties.schemaVersion` | `1.0` | Version-based message routing |

---

## 6. UTC Timestamp Standards

### Rule: All timestamps at the system layer are UTC. GMT+8 is only used in reporting.

| Context | Format | Example |
|---|---|---|
| API request `orderDate` | ISO 8601, any offset accepted | `2026-04-09T10:00:00+08:00` |
| API response timestamps | UTC ISO 8601 with `Z` suffix | `2026-04-09T02:00:00Z` |
| `_meta.enqueuedAtUtc` | UTC ISO 8601 with `Z` suffix | `2026-04-09T02:00:01Z` |
| Service Bus `enqueuedTimeUtc` | UTC (platform property) | automatic |
| Logic App `utcNow()` | UTC ISO 8601 | `2026-04-09T02:00:01.000Z` |
| Log Analytics `TimeGenerated` | UTC (platform) | automatic |
| WMS SOAP `<wms:OrderDate>` | UTC ISO 8601 | `2026-04-09T02:00:00Z` |
| Reports / dashboards | GMT+8 via KQL `datetime_utc_to_local()` | `2026-04-09T10:00:00+08:00` |

### Normalisation in Logic Apps (`bmwc-rest-ingress`)

```
Input:  "2026-04-09T10:00:00+08:00"   (from BMWC in SGT/MYT)
Step:   convertTimeZone(orderDate, 'UTC', 'UTC')
        formatDateTime(..., 'yyyy-MM-ddTHH:mm:ssZ')
Output: "2026-04-09T02:00:00Z"        (stored in canonical message)
```

If the caller sends a date-only string (`"2026-04-09"`), the Logic App coerces it to `"2026-04-09T00:00:00Z"`.

---

## 7. Validation Rules

Validation is enforced at two layers — APIM (transport) and Logic App trigger (schema). This defence-in-depth means the Logic App never processes a structurally invalid payload.

### Layer 1 — APIM Policy (`bmwc-api-policy.xml`)

| Rule | Enforcement | Behaviour on failure |
|---|---|---|
| IP allowlist | `ip-filter` | `403 Forbidden` before any processing |
| Subscription key | `subscription-key` | `401 Unauthorized` |
| Rate limit | `rate-limit` | `429 Too Many Requests` |
| Weekly quota | `quota` | `429 Too Many Requests` |
| Content-Type must be `application/json` | `validate-content` | `415 Unsupported Media Type` |
| Payload size ≤ 256 KB | `validate-content` | `413 Content Too Large` |

### Layer 2 — Logic App Trigger Schema Validation (`EnableSchemaValidation`)

| Rule | Field | HTTP response on failure |
|---|---|---|
| `orderId` present | required | `400 Bad Request` by Logic App runtime |
| `customerId` present | required | `400` |
| `warehouseCode` present | required | `400` |
| `orderDate` present | required | `400` |
| `lines` present and ≥ 1 item | required, minItems | `400` |
| Each line has `lineNo`, `sku`, `quantity` | required | `400` |
| `priority` one of enum values | enum | `400` |
| `country` is 2 characters | minLength/maxLength | `400` |
| `quantity > 0` | exclusiveMinimum | `400` |
| `lineNo ≥ 1` | minimum | `400` |

> When `EnableSchemaValidation` rejects a payload, the Logic App returns a `400` directly — no workflow run is created, no Service Bus message is sent, and no billing occurs.

### Layer 3 — Business Rules (future: implement in Logic App action or Azure Function)

These rules are **not** JSON-schema enforceable and should be implemented as explicit condition checks in the workflow:

| Rule | How to enforce |
|---|---|
| `lineNo` values are unique within `lines[]` | Condition + expression after parse |
| `warehouseCode` is in allowed set | Parameter lookup or HTTP call to a config API |
| `requestedDeliveryDate` is not in the past | `greater(variables('normalisedDeliveryDate'), utcNow())` |
| Total `quantity` across all lines ≤ system limit | `sum()` expression check |

---

## 8. Example Payloads

### 8a. Valid Request — Standard Order

```json
POST /bmwc/orders HTTP/1.1
Host: apim-bmwc-wms-abc.azure-api.net
Content-Type: application/json
Ocp-Apim-Subscription-Key: <subscription-key>
X-Correlation-ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890

{
  "orderId": "ORD-2026-SGP-001",
  "customerId": "CUST-BMWC-001",
  "warehouseCode": "WH-SIN",
  "orderDate": "2026-04-09T10:00:00+08:00",
  "priority": "STANDARD",
  "customerReference": "PO-BMWC-2026-045",
  "notes": "Handle with care — fragile components",
  "lines": [
    {
      "lineNo": 1,
      "sku": "SKU-W-001",
      "description": "Wheel Assembly Type A",
      "quantity": 50,
      "uom": "EA"
    },
    {
      "lineNo": 2,
      "sku": "SKU-T-022",
      "description": "Tyre XR 235/55R18",
      "quantity": 200,
      "uom": "EA"
    },
    {
      "lineNo": 3,
      "sku": "SKU-E-055",
      "description": "Engine Gasket Set",
      "quantity": 10,
      "uom": "SET"
    }
  ],
  "shipTo": {
    "name": "BMWC Assembly Plant 1",
    "address1": "Lot 5, Jalan Jubli Perak",
    "city": "Shah Alam",
    "state": "Selangor",
    "country": "MY",
    "postcode": "40150",
    "contactName": "Ahmad Fauzi",
    "contactPhone": "+601112345678"
  }
}
```

---

### 8b. Valid Request — Minimal (only required fields)

```json
POST /bmwc/orders HTTP/1.1
Content-Type: application/json
Ocp-Apim-Subscription-Key: <subscription-key>

{
  "orderId": "ORD-2026-MIN-001",
  "customerId": "CUST-BMWC-002",
  "warehouseCode": "WH-KUL",
  "orderDate": "2026-04-09T02:00:00Z",
  "lines": [
    {
      "lineNo": 1,
      "sku": "SKU-X-099",
      "quantity": 5
    }
  ]
}
```

> `priority` defaults to `STANDARD`. `uom` defaults to `EA`. `shipTo` is omitted (valid for transfer orders without a delivery address).

---

### 8c. Missing Required Field — `orderId` absent

```json
POST /bmwc/orders HTTP/1.1
Content-Type: application/json
Ocp-Apim-Subscription-Key: <subscription-key>

{
  "customerId": "CUST-BMWC-001",
  "warehouseCode": "WH-SIN",
  "orderDate": "2026-04-09T02:00:00Z",
  "lines": [
    { "lineNo": 1, "sku": "SKU-W-001", "quantity": 10 }
  ]
}
```

**Expected response**: `400 Bad Request`

```json
HTTP/1.1 400 Bad Request
Content-Type: application/json
X-Correlation-ID: d9e8f7a6-b5c4-3210-fedc-ba9876543210

{
  "status": "VALIDATION_ERROR",
  "code": "SCHEMA_VALIDATION_FAILED",
  "message": "Request body does not conform to the required schema. Missing required property: 'orderId'.",
  "correlationId": "d9e8f7a6-b5c4-3210-fedc-ba9876543210",
  "timestamp": "2026-04-09T02:00:05Z"
}
```

---

### 8d. Large Payload Near Limit (~250 KB, 480 lines)

```json
POST /bmwc/orders HTTP/1.1
Content-Type: application/json
Ocp-Apim-Subscription-Key: <subscription-key>
X-Correlation-ID: f1a2b3c4-d5e6-7890-1234-abcdef567890

{
  "orderId": "ORD-2026-LARGE-001",
  "customerId": "CUST-BMWC-FLEET",
  "warehouseCode": "WH-SIN",
  "orderDate": "2026-04-09T02:00:00Z",
  "priority": "STANDARD",
  "notes": "Fleet replenishment — bulk order",
  "lines": [
    { "lineNo": 1,   "sku": "SKU-PART-0001", "description": "Component Assembly Type 1",  "quantity": 100, "uom": "EA" },
    { "lineNo": 2,   "sku": "SKU-PART-0002", "description": "Component Assembly Type 2",  "quantity": 200, "uom": "EA" },
    { "lineNo": 3,   "sku": "SKU-PART-0003", "description": "Component Assembly Type 3",  "quantity": 150, "uom": "EA" },
    "... (up to 480 lines — 500 max) ..."
  ],
  "shipTo": {
    "name": "BMWC Central Warehouse",
    "address1": "Jalan Bukit Kemuning",
    "city": "Shah Alam",
    "country": "MY",
    "postcode": "40460"
  }
}
```

> **Note**: Each line object is approximately 100–200 bytes. 500 lines × 200 bytes = ~100 KB for lines alone. With base object and `shipTo`, total payload stays well within the 256 KB limit. The `maxItems: 500` schema rule provides the hard ceiling.

---

### 8e. Invalid Timestamp Format

```json
POST /bmwc/orders HTTP/1.1
Content-Type: application/json
Ocp-Apim-Subscription-Key: <subscription-key>

{
  "orderId": "ORD-2026-TS-001",
  "customerId": "CUST-001",
  "warehouseCode": "WH-SIN",
  "orderDate": "09/04/2026 10:00 AM",
  "lines": [
    { "lineNo": 1, "sku": "SKU-001", "quantity": 1 }
  ]
}
```

> `orderDate` passes schema validation (typed as `string`, format not strictly enforced at JSON Schema layer). However, the Logic App `Init_NormalisedOrderDate` step will produce a **runtime fault** when `convertTimeZone` cannot parse the value.

**Handling**: The Logic App trigger returns `400` and the run is marked `Failed`. The `Scope_EnqueueFailure` block is not invoked (parse happens before enqueue).

**Recommendation**: Add a `format: "date-time"` JSON Schema annotation (informational) and include a Logic App action that explicitly validates the timestamp format before normalisation:

```
@equals(
  isMatch(triggerBody()?['orderDate'], '\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}'),
  true
)
```

**Expected response**: `400 Bad Request`

```json
{
  "status": "VALIDATION_ERROR",
  "code": "TIMESTAMP_PARSE_FAILED",
  "message": "Field 'orderDate' could not be parsed as an ISO 8601 date-time string. Value received: '09/04/2026 10:00 AM'. Expected format: yyyy-MM-ddTHH:mm:ssZ",
  "correlationId": "b9c8d7e6-f5a4-3210-9876-fedcba123456",
  "timestamp": "2026-04-09T02:00:08Z"
}
```

---

## 9. OpenAPI Request / Response Specification

### POST `/bmwc/orders` — Submit Order

#### Request

```yaml
POST /bmwc/orders
Headers:
  Content-Type:               application/json
  Ocp-Apim-Subscription-Key:  string (required)
  X-Correlation-ID:           string (UUID, optional — generated by APIM if absent)
Body: BmwcOrder (see schema above)
```

#### Response — `202 Accepted` (success)

Returned when the order payload is valid and has been successfully written to Service Bus. **WMS dispatch has not happened yet** — this is confirmation of queuing only.

```json
HTTP/1.1 202 Accepted
Content-Type: application/json
X-Correlation-ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
X-Workflow-Run-ID: 08585012345678901234567890ABCDEF

{
  "status": "QUEUED",
  "message": "Order accepted for asynchronous WMS dispatch",
  "orderId": "ORD-2026-SGP-001",
  "correlationId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "workflowRunId": "08585012345678901234567890ABCDEF",
  "enqueuedAtUtc": "2026-04-09T02:00:01Z"
}
```

| Field | Description |
|---|---|
| `status` | Always `"QUEUED"` on success |
| `message` | Human-readable confirmation |
| `orderId` | Echo of the submitted `orderId` |
| `correlationId` | Use this for all subsequent traceability queries |
| `workflowRunId` | Use in Azure Portal → Logic Apps → Run History for detailed trace |
| `enqueuedAtUtc` | UTC timestamp when the message entered Service Bus |

---

#### Response — `400 Bad Request` (validation failure)

```json
HTTP/1.1 400 Bad Request
Content-Type: application/json
X-Correlation-ID: d9e8f7a6-b5c4-3210-fedc-ba9876543210

{
  "status": "VALIDATION_ERROR",
  "code": "SCHEMA_VALIDATION_FAILED",
  "message": "Request body does not conform to the required schema.",
  "detail": "Missing required property: 'orderId'.",
  "correlationId": "d9e8f7a6-b5c4-3210-fedc-ba9876543210",
  "timestamp": "2026-04-09T02:00:05Z"
}
```

---

#### Response — `401 Unauthorized` (missing/invalid subscription key)

```json
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{
  "status": "UNAUTHORIZED",
  "code": "SUBSCRIPTION_KEY_INVALID",
  "message": "Access denied due to missing or invalid subscription key. Include a valid Ocp-Apim-Subscription-Key header.",
  "timestamp": "2026-04-09T02:00:03Z"
}
```

---

#### Response — `403 Forbidden` (IP not allowlisted)

```json
HTTP/1.1 403 Forbidden
Content-Type: application/json

{
  "status": "FORBIDDEN",
  "code": "IP_NOT_ALLOWED",
  "message": "The request origin IP address is not permitted to call this API.",
  "timestamp": "2026-04-09T02:00:03Z"
}
```

---

#### Response — `413 Content Too Large` (payload exceeds 256 KB)

```json
HTTP/1.1 413 Content Too Large
Content-Type: application/json
X-Correlation-ID: e2f3a4b5-c6d7-8901-2345-fedcba678901

{
  "status": "PAYLOAD_TOO_LARGE",
  "code": "MAX_PAYLOAD_EXCEEDED",
  "message": "Request body exceeds the maximum allowed size of 256 KB.",
  "correlationId": "e2f3a4b5-c6d7-8901-2345-fedcba678901",
  "timestamp": "2026-04-09T02:00:06Z"
}
```

---

#### Response — `429 Too Many Requests` (rate limit or quota exceeded)

```json
HTTP/1.1 429 Too Many Requests
Content-Type: application/json
Retry-After: 60

{
  "status": "RATE_LIMITED",
  "code": "RATE_LIMIT_EXCEEDED",
  "message": "Too many requests. You have exceeded the rate limit of 100 calls per minute.",
  "correlationId": "f0a1b2c3-d4e5-6789-abcd-0123456789ef",
  "retryAfterSeconds": 60,
  "timestamp": "2026-04-09T02:00:07Z"
}
```

---

#### Response — `500 Internal Server Error` (enqueue failure)

Returned when the Logic App could not write to Service Bus after all retries. The order has **not** been queued — the caller must retry.

```json
HTTP/1.1 500 Internal Server Error
Content-Type: application/json
X-Correlation-ID: c3d4e5f6-a7b8-9012-cdef-123456789012

{
  "status": "ERROR",
  "code": "ENQUEUE_FAILED",
  "message": "Order could not be queued for WMS dispatch — please retry with the same orderId.",
  "orderId": "ORD-2026-SGP-001",
  "correlationId": "c3d4e5f6-a7b8-9012-cdef-123456789012",
  "failedAtUtc": "2026-04-09T02:00:09Z"
}
```

---

### GET `/bmwc/orders/{orderId}/status` — Query Dispatch Status

```
GET /bmwc/orders/ORD-2026-SGP-001/status
Ocp-Apim-Subscription-Key: <subscription-key>
X-Correlation-ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

#### Response — `200 OK` (WMS accepted)

```json
HTTP/1.1 200 OK
Content-Type: application/json

{
  "orderId": "ORD-2026-SGP-001",
  "status": "WMS_ACCEPTED",
  "wmsOrderId": "WMS-1744167600001-428",
  "warehouseRef": "WH-SIN-ORD-2026-SGP-001",
  "estimatedReadyDate": "2026-04-10",
  "correlationId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "enqueuedAtUtc": "2026-04-09T02:00:01Z",
  "dispatchedAtUtc": "2026-04-09T02:00:45Z"
}
```

#### Response — `200 OK` (still pending)

```json
{
  "orderId": "ORD-2026-SGP-001",
  "status": "QUEUED",
  "message": "Order is pending WMS dispatch",
  "correlationId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "enqueuedAtUtc": "2026-04-09T02:00:01Z"
}
```

#### Status Lifecycle

```
QUEUED → WMS_DISPATCHING → WMS_ACCEPTED
                         → WMS_REJECTED  (WMS returned a SOAP Fault)
                         → DISPATCH_FAILED → [DLQ after 5 retries]
```

---

## 10. Idempotency Guidance

### How idempotency is enforced

| Layer | Mechanism | Window |
|---|---|---|
| Service Bus | `requiresDuplicateDetection: true` on `wms-inbound` queue | 10 minutes |
| Service Bus `messageId` | Set to `orderId` by `bmwc-rest-ingress` | Per queue retention period |
| APIM | No built-in idempotency — duplicate detection is handled by SB | — |

### Behaviour on duplicate submission

If BMWC submits an order with the same `orderId` within the 10-minute duplicate detection window:

1. APIM forwards the request normally to Logic Apps.
2. Logic App processes it and calls `Send_To_Service_Bus`.
3. Service Bus detects `messageId = orderId` already in the duplicate detection history.
4. Service Bus **silently discards** the second message — it does not raise an error.
5. Logic App receives a success response from Service Bus and returns `202 Accepted` to BMWC.

> The second 202 is indistinguishable from the first — this is correct idempotent behaviour. The WMS will only receive one dispatch request.

### Guidance for BMWC callers

| Scenario | Action |
|---|---|
| Network timeout on `POST /orders` — unsure if received | **Retry with same `orderId`** — safe within 10 minutes |
| 500 received — enqueue failed | **Retry with same `orderId`** — safe (SB dedup protects against re-queueing if first attempt partially succeeded) |
| Business re-submission of same order (e.g., corrected quantity) | **Use a new `orderId`** — the original order may already be at the WMS |
| 429 received | Wait `Retry-After` seconds, then retry with same `orderId` and same payload |

### Idempotency key must be deterministic

BMWC must generate `orderId` before calling the API — never use a server-generated ID as the idempotency key (because the server may never have received the first request).

**Recommended pattern**:
```
orderId = {system-prefix}-{YYYYMM}-{internal-order-number}
Example: ORD-202604-0001234
```

---

## 11. Canonical Envelope (Internal — BMWC → Service Bus)

This is the **internal message format** written to the `wms-inbound` queue by `bmwc-rest-ingress`. It is consumed by `wms-soap-dispatcher`. BMWC callers never see this format.

```json
{
  "orderId": "ORD-2026-SGP-001",
  "customerId": "CUST-BMWC-001",
  "warehouseCode": "WH-SIN",
  "orderDate": "2026-04-09T02:00:00Z",
  "priority": "STANDARD",
  "customerReference": "PO-BMWC-2026-045",
  "notes": "Handle with care — fragile components",
  "lines": [
    {
      "lineNo": 1,
      "sku": "SKU-W-001",
      "description": "Wheel Assembly Type A",
      "quantity": 50,
      "uom": "EA"
    },
    {
      "lineNo": 2,
      "sku": "SKU-T-022",
      "description": "Tyre XR 235/55R18",
      "quantity": 200,
      "uom": "EA"
    }
  ],
  "shipTo": {
    "name": "BMWC Assembly Plant 1",
    "address1": "Lot 5, Jalan Jubli Perak",
    "city": "Shah Alam",
    "state": "Selangor",
    "country": "MY",
    "postcode": "40150"
  },
  "_meta": {
    "correlationId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "enqueuedAtUtc": "2026-04-09T02:00:01Z",
    "source": "BMWC",
    "schemaVersion": "1.0",
    "workflowRunId": "08585012345678901234567890ABCDEF"
  }
}
```

### Decoupling from SOAP structure

The canonical envelope is deliberately **independent** of the WMS SOAP contract. The `wms-soap-dispatcher` maps _from_ this envelope _to_ SOAP using the Liquid template (`maps/bmwc-order-to-wms-soap.liquid`). This means:

- If the WMS SOAP schema changes, only the Liquid map changes — not the API contract.
- If BMWC adds new fields, they flow through automatically (`additionalProperties: true` on the schema) without breaking the SOAP mapping.
- The `_meta` block is never mapped into SOAP business elements — it is only used for telemetry and logging.
