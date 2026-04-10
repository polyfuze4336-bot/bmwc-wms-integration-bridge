# BMWC → WMS Transformation Layer Specification

**Version**: 1.0  
**Scope**: JSON-to-SOAP mapping for the `wms-soap-dispatcher` workflow  
**Date**: April 2026

---

## Table of Contents

1. [Canonical Input Payload (JSON)](#1-canonical-input-payload-json)
2. [Target WMS SOAP XML Structure](#2-target-wms-soap-xml-structure)
3. [Field Mapping Specification](#3-field-mapping-specification)
4. [Liquid Map Reference](#4-liquid-map-reference)
5. [Logic Apps Helper Compose Expressions](#5-logic-apps-helper-compose-expressions)
6. [Namespace Handling](#6-namespace-handling)
7. [Escaping Special Characters and Empty Fields](#7-escaping-special-characters-and-empty-fields)
8. [WMS SOAP Response Shapes](#8-wms-soap-response-shapes)
9. [SOAP Fault Handling](#9-soap-fault-handling)
10. [Updating for Real WSDL](#10-updating-for-real-wsdl)

---

## 1. Canonical Input Payload (JSON)

This is the internal canonical envelope written to Service Bus by `bmwc-rest-ingress` and consumed by `wms-soap-dispatcher`. It is the input to the Liquid map.

The `_auth` block is injected by the `Compose_SOAP_Input` workflow action — it is never stored in Service Bus or logged.

```json
{
  "orderId":               "ORD-2026-SGP-001",
  "customerId":            "CUST-BMWC-001",
  "warehouseCode":         "WH-SIN",
  "orderDate":             "2026-04-09T02:00:00Z",
  "priority":              "STANDARD",
  "requestedDeliveryDate": "2026-04-11T00:00:00Z",
  "customerReference":     "PO-BMWC-2026-045",
  "notes":                 "Handle with care \u2014 fragile components",

  "lines": [
    {
      "lineNo":      1,
      "sku":         "SKU-W-001",
      "description": "Wheel Assembly Type A",
      "quantity":    50,
      "uom":         "EA"
    },
    {
      "lineNo":      2,
      "sku":         "SKU-T-022",
      "description": "Tyre XR 235/55R18",
      "quantity":    200,
      "uom":         "EA"
    },
    {
      "lineNo":      3,
      "sku":         "SKU-E-055",
      "description": "Engine Gasket Set",
      "quantity":    10,
      "uom":         "SET",
      "lotNumber":   "LOT-2026-003"
    }
  ],

  "shipTo": {
    "name":         "BMWC Assembly Plant 1",
    "address1":     "Lot 5, Jalan Jubli Perak",
    "address2":     "Kawasan Perindustrian",
    "city":         "Shah Alam",
    "state":        "Selangor",
    "country":      "MY",
    "postcode":     "40150",
    "contactName":  "Ahmad Fauzi",
    "contactPhone": "+601112345678"
  },

  "_meta": {
    "correlationId":  "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "enqueuedAtUtc":  "2026-04-09T02:00:01Z",
    "source":         "BMWC",
    "schemaVersion":  "1.0",
    "workflowRunId":  "08585012345678901234567890ABCDEF"
  },

  "_auth": {
    "username": "bmwc_api",
    "password": "<resolved from Key Vault at runtime \u2014 never hardcoded>"
  }
}
```

### Timestamp rule

All timestamps in the canonical payload are **UTC ISO 8601 with `Z` suffix**. The `orderDate` field may have arrived from BMWC in `+08:00` offset — it is normalised to UTC by `bmwc-rest-ingress` before enqueue. The Liquid map passes timestamps through to SOAP as-is — **no timezone conversion happens in the transformation layer**.

---

## 2. Target WMS SOAP XML Structure

This is the target SOAP envelope sent to the WMS `CreateOrder` operation. This structure is based on a typical legacy WMS SOAP 1.1 service; actual element names and namespace must be verified against the real WSDL.

```xml
<?xml version="1.0" encoding="utf-8"?>
<soapenv:Envelope
    xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
    xmlns:wms="http://wms.legacy.corp/v1"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <soapenv:Header>
    <wms:RequestHeader>
      <wms:Username>bmwc_api</wms:Username>
      <wms:Password>••••••••</wms:Password>
      <wms:CorrelationId>a1b2c3d4-e5f6-7890-abcd-ef1234567890</wms:CorrelationId>
      <wms:RequestTimestamp>2026-04-09T02:00:01Z</wms:RequestTimestamp>
      <wms:SourceSystem>BMWC</wms:SourceSystem>
      <wms:SchemaVersion>1.0</wms:SchemaVersion>
    </wms:RequestHeader>
  </soapenv:Header>

  <soapenv:Body>
    <wms:CreateOrderRequest>

      <wms:OrderIdentification>
        <wms:ExternalOrderId>ORD-2026-SGP-001</wms:ExternalOrderId>
        <wms:CustomerId>CUST-BMWC-001</wms:CustomerId>
        <wms:CustomerReference>PO-BMWC-2026-045</wms:CustomerReference>
      </wms:OrderIdentification>

      <wms:WarehouseDetails>
        <wms:WarehouseCode>WH-SIN</wms:WarehouseCode>
        <wms:Priority>STANDARD</wms:Priority>
        <wms:OrderDate>2026-04-09T02:00:00Z</wms:OrderDate>
        <wms:RequestedDeliveryDate>2026-04-11T00:00:00Z</wms:RequestedDeliveryDate>
      </wms:WarehouseDetails>

      <wms:OrderLines totalLines="3">
        <wms:OrderLine sequence="1">
          <wms:LineNumber>1</wms:LineNumber>
          <wms:ItemCode>SKU-W-001</wms:ItemCode>
          <wms:ItemDescription>Wheel Assembly Type A</wms:ItemDescription>
          <wms:OrderedQuantity>50</wms:OrderedQuantity>
          <wms:UnitOfMeasure>EA</wms:UnitOfMeasure>
        </wms:OrderLine>
        <wms:OrderLine sequence="2">
          <wms:LineNumber>2</wms:LineNumber>
          <wms:ItemCode>SKU-T-022</wms:ItemCode>
          <wms:ItemDescription>Tyre XR 235/55R18</wms:ItemDescription>
          <wms:OrderedQuantity>200</wms:OrderedQuantity>
          <wms:UnitOfMeasure>EA</wms:UnitOfMeasure>
        </wms:OrderLine>
        <wms:OrderLine sequence="3">
          <wms:LineNumber>3</wms:LineNumber>
          <wms:ItemCode>SKU-E-055</wms:ItemCode>
          <wms:ItemDescription>Engine Gasket Set</wms:ItemDescription>
          <wms:OrderedQuantity>10</wms:OrderedQuantity>
          <wms:UnitOfMeasure>SET</wms:UnitOfMeasure>
          <wms:LotNumber>LOT-2026-003</wms:LotNumber>
        </wms:OrderLine>
      </wms:OrderLines>

      <wms:ShipToAddress>
        <wms:AddressName>BMWC Assembly Plant 1</wms:AddressName>
        <wms:AddressLine1>Lot 5, Jalan Jubli Perak</wms:AddressLine1>
        <wms:AddressLine2>Kawasan Perindustrian</wms:AddressLine2>
        <wms:City>Shah Alam</wms:City>
        <wms:State>Selangor</wms:State>
        <wms:Country>MY</wms:Country>
        <wms:PostalCode>40150</wms:PostalCode>
        <wms:ContactName>Ahmad Fauzi</wms:ContactName>
        <wms:ContactPhone>+601112345678</wms:ContactPhone>
      </wms:ShipToAddress>

      <wms:Notes>Handle with care &#x2014; fragile components</wms:Notes>

    </wms:CreateOrderRequest>
  </soapenv:Body>

</soapenv:Envelope>
```

### HTTP transport

| Property | Value |
|---|---|
| Method | `POST` |
| Content-Type | `text/xml; charset=utf-8` |
| SOAPAction header | `"http://wms.legacy.corp/v1/CreateOrder"` |
| X-Correlation-ID | propagated from canonical `_meta.correlationId` |
| X-Source-System | `BMWC-LA-Dispatcher` |

---

## 3. Field Mapping Specification

### Header Block

| JSON Path | SOAP Element | Type | Required | Notes |
|---|---|---|---|---|
| `_auth.username` | `wms:RequestHeader/wms:Username` | string | Yes | From Key Vault via `WmsUsername` parameter |
| `_auth.password` | `wms:RequestHeader/wms:Password` | string (secure) | Yes | From Key Vault via `WmsPassword` parameter |
| `_meta.correlationId` | `wms:RequestHeader/wms:CorrelationId` | string | Yes | End-to-end trace GUID |
| `_meta.enqueuedAtUtc` | `wms:RequestHeader/wms:RequestTimestamp` | UTC ISO 8601 | Yes | UTC — no conversion |
| `_meta.source` | `wms:RequestHeader/wms:SourceSystem` | string | Yes | Default: `BMWC` |
| `_meta.schemaVersion` | `wms:RequestHeader/wms:SchemaVersion` | string | Yes | Default: `1.0` |

### Order Identification Block

| JSON Path | SOAP Element | Type | Required | Notes |
|---|---|---|---|---|
| `orderId` | `wms:OrderIdentification/wms:ExternalOrderId` | string | Yes | xml_escape |
| `customerId` | `wms:OrderIdentification/wms:CustomerId` | string | Yes | xml_escape |
| `customerReference` | `wms:OrderIdentification/wms:CustomerReference` | string | No | Omit element if blank |

### Warehouse Details Block

| JSON Path | SOAP Element | Type | Required | Notes |
|---|---|---|---|---|
| `warehouseCode` | `wms:WarehouseDetails/wms:WarehouseCode` | string | Yes | xml_escape |
| `priority` | `wms:WarehouseDetails/wms:Priority` | string | Yes | Default: `STANDARD` |
| `orderDate` | `wms:WarehouseDetails/wms:OrderDate` | UTC ISO 8601 | Yes | Pass through — already UTC |
| `requestedDeliveryDate` | `wms:WarehouseDetails/wms:RequestedDeliveryDate` | UTC ISO 8601 | No | Omit element if blank |

### Order Lines Block

| JSON Path | SOAP Element / Attribute | Type | Required | Notes |
|---|---|---|---|---|
| `lines.size` | `wms:OrderLines/@totalLines` | integer | Yes | DotLiquid: `content.lines.size` |
| `lines[i].lineNo` | `wms:OrderLine/@sequence` | integer | Yes | Also repeated as child element |
| `lines[i].lineNo` | `wms:OrderLine/wms:LineNumber` | integer | Yes | |
| `lines[i].sku` | `wms:OrderLine/wms:ItemCode` | string | Yes | xml_escape |
| `lines[i].description` | `wms:OrderLine/wms:ItemDescription` | string | No | `xsi:nil="true"` if blank; xml_escape if present |
| `lines[i].quantity` | `wms:OrderLine/wms:OrderedQuantity` | number | Yes | No escaping needed |
| `lines[i].uom` | `wms:OrderLine/wms:UnitOfMeasure` | string | Yes | Default: `EA` |
| `lines[i].lotNumber` | `wms:OrderLine/wms:LotNumber` | string | No | Omit element if blank |
| `lines[i].serialNumber` | `wms:OrderLine/wms:SerialNumber` | string | No | Omit element if blank |

### Ship-To Address Block

| JSON Path | SOAP Element | Type | Required | Notes |
|---|---|---|---|---|
| `shipTo` (block) | `wms:ShipToAddress` | object | No | Entire block omitted if `shipTo` is null/absent |
| `shipTo.name` | `wms:ShipToAddress/wms:AddressName` | string | In block | xml_escape |
| `shipTo.address1` | `wms:ShipToAddress/wms:AddressLine1` | string | In block | xml_escape |
| `shipTo.address2` | `wms:ShipToAddress/wms:AddressLine2` | string | No | Omit if blank |
| `shipTo.city` | `wms:ShipToAddress/wms:City` | string | In block | xml_escape |
| `shipTo.state` | `wms:ShipToAddress/wms:State` | string | No | Omit if blank |
| `shipTo.country` | `wms:ShipToAddress/wms:Country` | string | In block | ISO 3166-1 alpha-2 — no escape needed |
| `shipTo.postcode` | `wms:ShipToAddress/wms:PostalCode` | string | No | Omit if blank |
| `shipTo.contactName` | `wms:ShipToAddress/wms:ContactName` | string | No | Omit if blank |
| `shipTo.contactPhone` | `wms:ShipToAddress/wms:ContactPhone` | string | No | Omit if blank |

### Root-level Optional Fields

| JSON Path | SOAP Element | Type | Required | Notes |
|---|---|---|---|---|
| `notes` | `wms:CreateOrderRequest/wms:Notes` | string | No | Omit entire element if blank; xml_escape if present |

### Fields NOT mapped to SOAP

These fields exist in the canonical payload but are **not** propagated to the WMS SOAP envelope. They are integration-layer metadata only.

| JSON Path | Reason not mapped |
|---|---|
| `_meta.workflowRunId` | Integration infrastructure — used for telemetry, not business data |
| `_meta.source` | Mapped to SOAP header SourceSystem — not a business field in the body |
| `_auth.*` | Credential fields — mapped once into SOAP header, never into body |

---

## 4. Liquid Map Reference

### Files

| Purpose | Source of Record | Deployable Path (Logic App Standard runtime) |
|---|---|---|
| JSON → SOAP request | [maps/bmwc-order-to-wms-soap.liquid](maps/bmwc-order-to-wms-soap.liquid) | [logic-app/lib/maps/bmwc-order-to-wms-soap.liquid](logic-app/lib/maps/bmwc-order-to-wms-soap.liquid) |
| SOAP response → JSON | [maps/wms-soap-response-to-json.liquid](maps/wms-soap-response-to-json.liquid) | [logic-app/lib/maps/wms-soap-response-to-json.liquid](logic-app/lib/maps/wms-soap-response-to-json.liquid) |

The `logic-app/lib/maps/` path is where Logic Apps Standard reads maps at runtime. `maps/` at root is the editable source — keep both in sync.

### Logic Apps Liquid action configuration

```json
{
  "type": "Liquid",
  "kind": "JsonToText",
  "inputs": {
    "body": "@outputs('Compose_SOAP_Input')",
    "map":  "bmwc-order-to-wms-soap"
  }
}
```

The `map` property is the filename **without extension**. Logic Apps Standard resolves the map from `lib/maps/<name>.liquid` within the deployed package.

### DotLiquid engine notes

Logic Apps Standard uses **DotLiquid** (a .NET port of Liquid). Key differences from standard Liquid:

| Feature | Standard Liquid | DotLiquid (Logic Apps) |
|---|---|---|
| Filter: `xml_escape` | Not built-in | Available — escapes `&`, `<`, `>`, `"`, `'` |
| Filter: `escape` | HTML-escapes | Same as xml_escape for ASCII XML |
| Nil check | `{% if var == nil %}` | Use `{% if var == blank %}` or `{% unless var == blank %}` |
| Empty string | `{% if var == '' %}` | Covered by `blank` (nil + empty string) |
| Array size | `{{ array.size }}` | `{{ content.lines.size }}` ✔ |
| Nested access | `{{ a.b.c }}` | Works for most JSON paths |
| Keys with `:` | N/A | Requires bracket notation: `content['ns:key']` |
| `| date:` filter | Supported | Limited format support — use `utcNow()` in Logic Apps instead |

---

## 5. Logic Apps Helper Compose Expressions

These are the Compose actions in `wms-soap-dispatcher` that support the transformation pipeline.

### Action 1: `Compose_SOAP_Input`

**Purpose**: Merge the canonical message body with WMS credentials into a single JSON object. This is the input to the Liquid action.

**Why needed**: The Liquid map must receive credentials as part of the `content` object. Parameters are injected here from Logic Apps workflow parameters (which resolve from Key Vault app settings at runtime).

```json
{
  "type": "Compose",
  "runAfter": { "Parse_Order_Message": ["Succeeded"] },
  "inputs": {
    "orderId":               "@{body('Parse_Order_Message')?['orderId']}",
    "customerId":            "@{body('Parse_Order_Message')?['customerId']}",
    "warehouseCode":         "@{body('Parse_Order_Message')?['warehouseCode']}",
    "orderDate":             "@{body('Parse_Order_Message')?['orderDate']}",
    "priority":              "@{coalesce(body('Parse_Order_Message')?['priority'], 'STANDARD')}",
    "requestedDeliveryDate": "@{body('Parse_Order_Message')?['requestedDeliveryDate']}",
    "customerReference":     "@{body('Parse_Order_Message')?['customerReference']}",
    "notes":                 "@{body('Parse_Order_Message')?['notes']}",
    "lines":                 "@{body('Parse_Order_Message')?['lines']}",
    "shipTo":                "@{body('Parse_Order_Message')?['shipTo']}",
    "_meta":                 "@{body('Parse_Order_Message')?['_meta']}",
    "_auth": {
      "username": "@{parameters('WmsUsername')}",
      "password": "@{parameters('WmsPassword')}"
    }
  }
}
```

> `WmsPassword` is `securestring` — Logic Apps **does not** log its value in run history. The `_auth.password` is transmitted only in the SOAP envelope to the WMS endpoint over TLS.

---

### Action 2: `Build_SOAP_Envelope` (Liquid)

**Purpose**: Apply the `bmwc-order-to-wms-soap` DotLiquid map to produce the SOAP XML string.

```json
{
  "type": "Liquid",
  "kind": "JsonToText",
  "runAfter": { "Compose_SOAP_Input": ["Succeeded"] },
  "inputs": {
    "body": "@outputs('Compose_SOAP_Input')",
    "map":  "bmwc-order-to-wms-soap"
  }
}
```

Output reference in `Call_WMS_SOAP_Endpoint`: `@{body('Build_SOAP_Envelope')}`

---

### Action 3: `Compose_Parse_WMS_Response`

**Purpose**: Convert the WMS SOAP XML response to a JSON object for fault detection and field extraction.

```json
{
  "type": "Compose",
  "runAfter": { "Call_WMS_SOAP_Endpoint": ["Succeeded"] },
  "inputs": "@xml(body('Call_WMS_SOAP_Endpoint'))"
}
```

The `xml()` function converts the XML document into a JSON representation where each element becomes a property named `<nsprefix>:<localname>`. Access paths:

```
Success: outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['wms:CreateOrderResponse']?['wms:WmsOrderId']
Fault:   outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['soapenv:Fault']?['faultstring']
```

---

### Alternative: `xpath()` for targeted field extraction

For individual fields, `xpath()` is more robust than property navigation — it handles namespace variations and avoids null-pointer faults:

```
-- Extract WMS order ID (namespace-agnostic):
@{xpath(xml(body('Call_WMS_SOAP_Endpoint')),
    'string(/*[local-name()="Envelope"]
              /*[local-name()="Body"]
              /*[local-name()="CreateOrderResponse"]
              /*[local-name()="WmsOrderId"])')}

-- Detect SOAP fault:
@{not(empty(xpath(xml(body('Call_WMS_SOAP_Endpoint')),
    '/*[local-name()="Envelope"]
       /*[local-name()="Body"]
       /*[local-name()="Fault"]')))}

-- Extract fault string:
@{xpath(xml(body('Call_WMS_SOAP_Endpoint')),
    'string(/*[local-name()="Envelope"]
              /*[local-name()="Body"]
              /*[local-name()="Fault"]
              /*[local-name()="faultstring"])')}
```

`local-name()` avoids binding to specific namespace prefixes — works regardless of which prefix the WMS server chooses to use.

---

### Transformation Pipeline Sequence

```
Parse_Order_Message
       │
       ▼
Compose_SOAP_Input          ← merges order body + _auth credentials
       │
       ▼
Build_SOAP_Envelope (Liquid)  ← DotLiquid map → SOAP XML string
       │
       ▼
Call_WMS_SOAP_Endpoint      ← HTTP POST text/xml to WMS
       │
       ▼
Compose_Parse_WMS_Response  ← xml() → JSON object
       │
       ▼
Check_WMS_HTTP_Status       ← condition: statusCode == 200
       │                                      │
       │ true                                 │ false
       ▼                                      ▼
Check_SOAP_Fault             Compose_WMS_Non200_Telemetry
       │                      → Terminate_Non200
  no fault  fault
       │       │
       ▼       ▼
Telemetry  Fault Telemetry
           → Terminate_SOAP_Fault
```

---

## 6. Namespace Handling

### Namespace declarations

Three XML namespaces are declared on the root `<soapenv:Envelope>` element:

| Prefix | URI | Purpose |
|---|---|---|
| `soapenv` | `http://schemas.xmlsoap.org/soap/envelope/` | SOAP 1.1 envelope structure |
| `wms` | `http://wms.legacy.corp/v1` | WMS business elements — **update to WSDL value** |
| `xsi` | `http://www.w3.org/2001/XMLSchema-instance` | `xsi:nil="true"` on empty required elements |

### Updating the WMS namespace

The WMS namespace `http://wms.legacy.corp/v1` is a placeholder. When the actual WSDL is available:

1. Open the WSDL and locate the `<wsdl:definitions targetNamespace="...">` attribute.
2. Replace `http://wms.legacy.corp/v1` in:
   - [maps/bmwc-order-to-wms-soap.liquid](maps/bmwc-order-to-wms-soap.liquid)
   - [logic-app/lib/maps/bmwc-order-to-wms-soap.liquid](logic-app/lib/maps/bmwc-order-to-wms-soap.liquid)
   - [maps/wms-soap-response-to-json.liquid](maps/wms-soap-response-to-json.liquid)
   - [logic-app/lib/maps/wms-soap-response-to-json.liquid](logic-app/lib/maps/wms-soap-response-to-json.liquid)
   - The `SOAPAction` header value in `wms-soap-dispatcher` `Call_WMS_SOAP_Endpoint`
3. Verify element names and the SOAP operation name match the WSDL `<wsdl:operation>` binding.

### Namespace in the response map

The response Liquid map (`wms-soap-response-to-json.liquid`) accesses parsed XML using bracket notation with namespace-prefixed keys. The keys depend on the prefix the **WMS server** uses in its response. If the WMS uses a different prefix for the envelope (e.g., `soap:Envelope` instead of `soapenv:Envelope`), update the map accordingly.

**Namespace-independent alternative using xpath():**

```
xpath() with local-name() predicate is immune to prefix choices.
Use it for production fault detection (see Compose_Parse_WMS_Response section).
```

### SOAP version

The bridge uses **SOAP 1.1**. If the WMS requires SOAP 1.2:
- Change envelope namespace to `http://www.w3.org/2003/05/soap-envelope`
- Change `Content-Type` header to `application/soap+xml; charset=utf-8; action="..."`
- Remove the `SOAPAction` HTTP header (SOAP 1.2 embeds action in Content-Type)
- Update fault element name from `soapenv:Fault` to the SOAP 1.2 structure

---

## 7. Escaping Special Characters and Empty Fields

### XML character escaping rules

| Character | XML escape | Applied to | DotLiquid filter |
|---|---|---|---|
| `&` | `&amp;` | All free-text strings | `\| xml_escape` |
| `<` | `&lt;` | All free-text strings | `\| xml_escape` |
| `>` | `&gt;` | All free-text strings | `\| xml_escape` |
| `"` | `&quot;` | Attribute values | `\| xml_escape` |
| `'` | `&#39;` | Attribute values | `\| xml_escape` |
| `—` (em dash) | `&#x2014;` | Free text (Unicode) | Auto by `xml_escape` if non-ASCII |
| `\n` `\r` | As-is | Preserved in text nodes | Not escaped |

### Fields that require `| xml_escape`

- All business string fields: `orderId`, `customerId`, `warehouseCode`, `customerReference`, `sku`, `description`, `uom`, `lotNumber`, `serialNumber`
- All address fields: `name`, `address1`, `address2`, `city`, `state`, `postcode`, `contactName`, `contactPhone`
- `notes` (free text — highest risk of special characters)
- Auth credentials: `username`, `password`

### Fields that do NOT need `| xml_escape`

- **Timestamps**: `orderDate`, `requestedDeliveryDate`, `enqueuedAtUtc` — contain only `[0-9T:Z\-]`
- **Country code**: two-letter ISO code — no special characters possible
- **Numeric quantities**: `quantity`, `lineNo` — numbers only
- **Priority enum**: `STANDARD`, `URGENT`, `EXPEDITE` — uppercase ASCII only

### Empty field strategy

Three strategies for optional fields — choose based on what the WMS WSDL requires:

#### Strategy A — Omit element entirely (preferred for truly optional fields)

```liquid
{%- unless content.customerReference == blank %}
<wms:CustomerReference>{{- content.customerReference | xml_escape -}}</wms:CustomerReference>
{%- endunless %}
```

Use when: The WSDL `<xs:element minOccurs="0">` and the WMS parser handles missing elements gracefully.

#### Strategy B — `xsi:nil="true"` self-closing element (for WSDL-required elements)

```liquid
{%- if line.description == blank %}
<wms:ItemDescription xsi:nil="true"/>
{%- else %}
<wms:ItemDescription>{{- line.description | xml_escape -}}</wms:ItemDescription>
{%- endif %}
```

Use when: The WSDL `<xs:element minOccurs="1" nillable="true">` — the element must appear but can carry `xsi:nil="true"` to signal an absent value. Requires `xmlns:xsi` in the envelope.

#### Strategy C — Self-closing empty element (last resort)

```liquid
<wms:CustomerReference/>
```

Use only when the WMS explicitly requires an empty element tag rather than omission or `xsi:nil`. **Do not use** as a general strategy — empty strings can confuse WMS validation.

### `blank` keyword in DotLiquid

In DotLiquid, `blank` evaluates to true for:
- `nil` / null JSON values
- Empty string `""`
- A string containing only whitespace

This makes `unless field == blank` the correct idiom for "render only if there is a non-empty value".

> Do NOT use `!= nil` — it passes for empty strings. Do NOT use `!= ''` — it fails to catch null JSON values.

### Whitespace in XML text nodes

Some legacy SOAP parsers are sensitive to whitespace before/after element content. To prevent Logic Apps from injecting extra whitespace from Liquid template indentation, use `{{- ... -}}` (trim whitespace on both sides) inside element content:

```liquid
<!-- Correct: no extra whitespace in text node -->
<wms:ItemCode>{{- line.sku | xml_escape -}}</wms:ItemCode>

<!-- Incorrect: may include a leading/trailing space -->
<wms:ItemCode>{{ line.sku | xml_escape }}</wms:ItemCode>
```

---

## 8. WMS SOAP Response Shapes

### Shape A — Successful dispatch (`ACCEPTED`)

```xml
<?xml version="1.0" encoding="utf-8"?>
<soapenv:Envelope
    xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
    xmlns:wms="http://wms.legacy.corp/v1">
  <soapenv:Body>
    <wms:CreateOrderResponse>
      <wms:Status>ACCEPTED</wms:Status>
      <wms:WmsOrderId>WMS-1744167600428-001</wms:WmsOrderId>
      <wms:Message>Order received and queued for warehouse processing</wms:Message>
      <wms:EstimatedReadyDate>2026-04-10T00:00:00Z</wms:EstimatedReadyDate>
      <wms:WarehouseRef>WH-SIN-ORD-2026-SGP-001</wms:WarehouseRef>
    </wms:CreateOrderResponse>
  </soapenv:Body>
</soapenv:Envelope>
```

### Shape B — WMS validation failure (SOAP Fault in HTTP 200)

```xml
<?xml version="1.0" encoding="utf-8"?>
<soapenv:Envelope
    xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
    xmlns:wms="http://wms.legacy.corp/v1">
  <soapenv:Body>
    <soapenv:Fault>
      <faultcode>wms:InvalidWarehouse</faultcode>
      <faultstring>Warehouse code WH-SIN not configured in WMS</faultstring>
      <detail>
        <wms:ErrorDetail>
          <wms:ErrorCode>WMS-4001</wms:ErrorCode>
          <wms:ErrorMessage>Warehouse code WH-SIN not found in master data</wms:ErrorMessage>
          <wms:CorrelationId>a1b2c3d4-e5f6-7890-abcd-ef1234567890</wms:CorrelationId>
        </wms:ErrorDetail>
      </detail>
    </soapenv:Fault>
  </soapenv:Body>
</soapenv:Envelope>
```

### Shape C — WMS item not found (SOAP Fault — line-level)

```xml
<soapenv:Fault>
  <faultcode>wms:InvalidItem</faultcode>
  <faultstring>Item SKU-W-001 not registered in warehouse WH-SIN</faultstring>
  <detail>
    <wms:ErrorDetail>
      <wms:ErrorCode>WMS-4011</wms:ErrorCode>
      <wms:ErrorMessage>SKU SKU-W-001 does not exist in item master for warehouse WH-SIN</wms:ErrorMessage>
      <wms:AffectedLineNo>1</wms:AffectedLineNo>
    </wms:ErrorDetail>
  </detail>
</soapenv:Fault>
```

### Response field extraction (extracted by `Compose_Parse_WMS_Response`)

```
wmsOrderId:         outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['wms:CreateOrderResponse']?['wms:WmsOrderId']
wmsStatus:          outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['wms:CreateOrderResponse']?['wms:Status']
estimatedReadyDate: outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['wms:CreateOrderResponse']?['wms:EstimatedReadyDate']
faultcode:          outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['soapenv:Fault']?['faultcode']
faultstring:        outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['soapenv:Fault']?['faultstring']
wmsErrorCode:       outputs('Compose_Parse_WMS_Response')?['soapenv:Envelope']?['soapenv:Body']?['soapenv:Fault']?['detail']?['wms:ErrorDetail']?['wms:ErrorCode']
```

---

## 9. SOAP Fault Handling

Legacy SOAP services have two patterns for signalling errors:

| Error pattern | HTTP status | Body | Handling in dispatcher |
|---|---|---|---|
| HTTP error | 4xx / 5xx | HTML or empty | `Check_WMS_HTTP_Status` false branch → `Terminate_Non200` |
| SOAP Fault in HTTP 200 | 200 | `<soapenv:Fault>` in body | `Check_SOAP_Fault` false branch → `Terminate_SOAP_Fault` |
| Network/DNS/timeout | N/A | N/A | `Scope_Catch_WMS_Call_Error` → `Terminate_WMS_Call_Error` |

### Retry strategy for different fault types

| WMS fault code pattern | Is retryable? | Recommended action |
|---|---|---|
| `wms:ServerError`, `wms:Unavailable` | Yes | Let Service Bus retry (terminate with Failed) |
| `wms:InvalidWarehouse`, `wms:InvalidItem` | No | Terminate and dead-letter immediately (avoid 5 retries) |
| `wms:DuplicateOrder` | No | Terminate with Cancelled (order already exists — success) |
| `wms:AuthenticationFailed` | No | Alert ops immediately — credential rotation needed |

> To implement permanent-error short-circuit: in `Terminate_SOAP_Fault`, check `wmsErrorCode` against a list of permanent codes and use `runStatus: "Cancelled"` instead of `"Failed"`. `Cancelled` does **not** increment the Service Bus delivery count.

---

## 10. Updating for Real WSDL

When the actual WMS WSDL becomes available, verify and update the following:

| Item | Current placeholder | Action required |
|---|---|---|
| SOAP target namespace | `http://wms.legacy.corp/v1` | Replace with WSDL `targetNamespace` |
| SOAP operation name | `CreateOrder` | Verify matches WSDL `<wsdl:operation name>` |
| SOAPAction header value | `"http://wms.legacy.corp/v1/CreateOrder"` | Verify from WSDL `<soap:operation soapAction>` |
| Root request element | `<wms:CreateOrderRequest>` | Verify from WSDL input message element |
| Root response element | `<wms:CreateOrderResponse>` | Verify from WSDL output message element |
| Fault detail namespace | `wms` prefix in `<detail>` | Verify fault schema from WSDL |
| `wms:RequestHeader` | Auth header structure | Verify WMS expects WS-Security UsernameToken or custom header |
| `xsi:nil` support | Used on `ItemDescription` | Verify WSDL allows `nillable="true"` |
| `@totalLines` attribute | On `wms:OrderLines` | Verify WMS expects this attribute (remove if not in schema) |
| `@sequence` attribute | On `wms:OrderLine` | Verify WMS expects this attribute |
