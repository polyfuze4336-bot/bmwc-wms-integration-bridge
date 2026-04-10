#!/usr/bin/env bash
# =============================================================================
# BMWC → WMS Bridge — curl Demo Scripts
#
# Prerequisites:
#   export APIM_GATEWAY_URL="https://apim-bmwc-demo.azure-api.net"
#   export APIM_SUBSCRIPTION_KEY="<your subscription key>"
#   export MOCK_WMS_URL="http://localhost:8080"    # or container host
#
# Start the WMS mock first:
#   cd mocks/wms-soap-mock && docker run -p 8080:8080 wms-soap-mock
#
# Run all scenarios in order:
#   bash tests/curl-demo.sh
# =============================================================================

set -euo pipefail

APIM="${APIM_GATEWAY_URL:-https://apim-bmwc-demo.azure-api.net}"
KEY="${APIM_SUBSCRIPTION_KEY:-REPLACE_WITH_SUBSCRIPTION_KEY}"
WMS="${MOCK_WMS_URL:-http://localhost:8080}"

sep() { echo; echo "────────────────────────────────────────────────────────────"; echo "$1"; echo "────────────────────────────────────────────────────────────"; }
ok()  { echo "  ✓  $1"; }
note(){ echo "  ↳  $1"; }


# ── STEP 0 — Health check: WMS mock WSDL ──────────────────────────────────────
sep "0 — Health Check: WMS Mock WSDL"
note "Verifies the WMS mock is running and serves its WSDL"

curl -s -o /dev/null -w "HTTP %{http_code}" "$WMS/WMSService.svc?wsdl" | grep -q "HTTP 200" \
  && ok "WMS mock is healthy (HTTP 200)" \
  || { echo "  ✗  WMS mock not reachable — start it first: docker run -p 8080:8080 wms-soap-mock"; exit 1; }


# ── STEP 1 — Success: Standard 3-line order ───────────────────────────────────
sep "1 — SUCCESS PATH: Standard 3-line order"
note "orderId: ORD-2026-SGP-001 | Priority: STANDARD | Timestamp: UTC"
note "Expected: 202 Accepted"

CORR_ID="demo-corr-$(date +%s)"

curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "$APIM/bmwc/orders" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: $KEY" \
  -H "X-Correlation-ID: $CORR_ID" \
  -d '{
    "orderId":               "ORD-2026-SGP-001",
    "customerId":            "CUST-BMWC-001",
    "warehouseCode":         "WH-SIN",
    "orderDate":             "2026-04-10T02:00:00Z",
    "priority":              "STANDARD",
    "requestedDeliveryDate": "2026-04-11T00:00:00Z",
    "customerReference":     "PO-BMWC-2026-045",
    "notes":                 "Handle with care — fragile components",
    "lines": [
      { "lineNo": 1, "sku": "SKU-W-001", "description": "Wheel Assembly Type A",  "quantity": 50,  "uom": "EA" },
      { "lineNo": 2, "sku": "SKU-T-022", "description": "Tyre XR 235/55R18",      "quantity": 200, "uom": "EA" },
      { "lineNo": 3, "sku": "SKU-E-055", "description": "Engine Gasket Set",       "quantity": 10,  "uom": "SET", "lotNumber": "LOT-2026-003" }
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
    }
  }'

echo
note "Next: Azure Portal → Service Bus → wms-inbound → Messages → peek"
note "      Azure Portal → Logic App → bmwc-rest-ingress → Run History"
note "      Log Analytics: AppTraces | where Properties.event == 'WMS_DISPATCH_SUCCESS'"


# ── STEP 2 — Timezone normalisation: URGENT order with +08:00 timestamp ───────
sep "2 — TIMEZONE DEMO: URGENT order sent with GMT+8 timestamp"
note "orderDate: 2026-04-10T10:00:00+08:00  →  stored as UTC: 2026-04-10T02:00:00Z"
note "Expected: 202 Accepted; Service Bus message body shows UTC"

CORR_ID="demo-tz-$(date +%s)"

curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "$APIM/bmwc/orders" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: $KEY" \
  -H "X-Correlation-ID: $CORR_ID" \
  -d '{
    "orderId":               "ORD-2026-KLU-007",
    "customerId":            "CUST-BMWC-001",
    "warehouseCode":         "WH-KUL",
    "orderDate":             "2026-04-10T10:00:00+08:00",
    "priority":              "URGENT",
    "requestedDeliveryDate": "2026-04-10T18:00:00+08:00",
    "customerReference":     "WO-2026-URGENT-007",
    "notes":                 "URGENT — production line stoppage. Same-day dispatch required.",
    "lines": [
      { "lineNo": 1, "sku": "SKU-B-009", "description": "Brake Caliper Assembly — Front Left", "quantity": 4, "uom": "EA" }
    ],
    "shipTo": {
      "name":         "BMWC Assembly Plant 2 — Kuala Lumpur",
      "address1":     "Jalan Cheras KM12",
      "city":         "Kuala Lumpur",
      "state":        "Wilayah Persekutuan",
      "country":      "MY",
      "postcode":     "56000",
      "contactName":  "Lee Wei Ming",
      "contactPhone": "+60312345678"
    }
  }'

echo
note "The ingress workflow normalises +08:00 → UTC before writing to Service Bus."
note "Peek the Service Bus message: orderDate should show 2026-04-10T02:00:00Z"
note "Reporting layer (Power BI / Workbook) renders this as 10:00 AM MYT for human readers."


# ── STEP 3 — DLQ demo: 3 identical orders with bad SKU ────────────────────────
sep "3 — DLQ DEMO: 3 orders with unknown SKU (WH-DLQ)"
note "Submit 3 messages. WMS mock returns SOAP Fault for WH-DLQ. All 3 move to DLQ."
note "Expected: 202 × 3 at APIM; 3 entries on wms-dead-letter-review queue"

for i in 1 2 3; do
  CORR_ID="demo-dlq-${i}-$(date +%s)"
  echo "  → Submitting ORD-2026-DLQ-00${i}..."
  curl -s -w "  HTTP %{http_code}\n" \
    -X POST "$APIM/bmwc/orders" \
    -H "Content-Type: application/json" \
    -H "Ocp-Apim-Subscription-Key: $KEY" \
    -H "X-Correlation-ID: $CORR_ID" \
    -d "{
      \"orderId\":       \"ORD-2026-DLQ-00${i}\",
      \"customerId\":    \"CUST-BMWC-DLQ\",
      \"warehouseCode\": \"WH-DLQ\",
      \"orderDate\":     \"2026-04-10T04:0${i}:00Z\",
      \"priority\":      \"STANDARD\",
      \"lines\": [{ \"lineNo\": 1, \"sku\": \"SKU-X-999\", \"description\": \"Unknown SKU\", \"quantity\": 1, \"uom\": \"EA\" }],
      \"shipTo\": { \"name\": \"DLQ Test\", \"address1\": \"1 Integration Drive\", \"city\": \"Singapore\", \"country\": \"SG\" }
    }"
  sleep 1
done

echo
note "Now observe:"
note "  1. Service Bus → wms-dead-letter-review queue → 3 messages"
note "  2. Log Analytics → AppTraces | where Properties.event == 'WMS_SOAP_FAULT'"
note "  3. Log Analytics → AppTraces | where Properties.event == 'DLQ_ALERT_SUMMARY'  (wait ≤15 min)"
note "  4. Azure Monitor → Alerts → check if alert fired"


# ── STEP 4 — Invalid request: missing orderId + lines ─────────────────────────
sep "4 — INVALID REQUEST: Missing orderId and lines"
note "Schema validation fires in Logic App trigger — never reaches Service Bus"
note "Expected: 400 Bad Request"

curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "$APIM/bmwc/orders" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: $KEY" \
  -d '{
    "customerId":    "CUST-BMWC-001",
    "warehouseCode": "WH-SIN",
    "orderDate":     "2026-04-10T02:00:00Z",
    "shipTo": {
      "name":     "BMWC Assembly Plant 1",
      "address1": "Lot 5, Jalan Jubli Perak",
      "city":     "Shah Alam",
      "country":  "MY"
    }
  }'

echo
note "Service Bus queue message count should NOT have incremented."


# ── STEP 5 — Idempotency: re-submit ORD-2026-SGP-001 ─────────────────────────
sep "5 — IDEMPOTENCY DEMO: Duplicate submission of ORD-2026-SGP-001"
note "Run this within 10 minutes of Step 1. orderId = ORD-2026-SGP-001"
note "Expected: 202 at APIM; Service Bus silently deduplicates; WMS NOT called again"

CORR_ID="demo-idem-$(date +%s)"

curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "$APIM/bmwc/orders" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: $KEY" \
  -H "X-Correlation-ID: $CORR_ID" \
  -d '{
    "orderId":       "ORD-2026-SGP-001",
    "customerId":    "CUST-BMWC-001",
    "warehouseCode": "WH-SIN",
    "orderDate":     "2026-04-10T02:00:00Z",
    "priority":      "STANDARD",
    "lines": [
      { "lineNo": 1, "sku": "SKU-W-001", "description": "Wheel Assembly Type A", "quantity": 50, "uom": "EA" }
    ],
    "shipTo": {
      "name":     "BMWC Assembly Plant 1",
      "address1": "Lot 5, Jalan Jubli Perak",
      "city":     "Shah Alam",
      "country":  "MY"
    }
  }'

echo
note "Service Bus → wms-inbound → Active Message Count should not have changed."
note "wms-soap-dispatcher run history should show NO new run after this submission."


# ── STEP 6 — Direct SOAP call to WMS mock (bypass platform) ───────────────────
sep "6 — DIRECT SOAP CALL to WMS Mock (diagnostic only)"
note "Sends a raw SOAP 1.1 CreateOrder request directly to the mock"
note "Use this to verify the mock is behaving correctly, independent of the Azure platform"

curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "$WMS/WMSService.svc" \
  -H "Content-Type: text/xml; charset=utf-8" \
  -H "SOAPAction: \"http://wms.legacy.corp/v1/CreateOrder\"" \
  -d '<?xml version="1.0" encoding="utf-8"?>
<soapenv:Envelope
    xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
    xmlns:wms="http://wms.legacy.corp/v1">
  <soapenv:Header>
    <wms:RequestHeader>
      <wms:Username>bmwc_api</wms:Username>
      <wms:Password>demo-password</wms:Password>
      <wms:CorrelationId>direct-soap-test-001</wms:CorrelationId>
      <wms:RequestTimestamp>2026-04-10T02:00:00Z</wms:RequestTimestamp>
      <wms:SourceSystem>BMWC</wms:SourceSystem>
      <wms:SchemaVersion>1.0</wms:SchemaVersion>
    </wms:RequestHeader>
  </soapenv:Header>
  <soapenv:Body>
    <wms:CreateOrderRequest>
      <wms:OrderIdentification>
        <wms:ExternalOrderId>DIRECT-SOAP-001</wms:ExternalOrderId>
        <wms:CustomerId>CUST-BMWC-001</wms:CustomerId>
        <wms:CustomerReference>PO-DIRECT-001</wms:CustomerReference>
      </wms:OrderIdentification>
      <wms:WarehouseDetails>
        <wms:WarehouseCode>WH-SIN</wms:WarehouseCode>
        <wms:Priority>STANDARD</wms:Priority>
        <wms:OrderDate>2026-04-10T02:00:00Z</wms:OrderDate>
      </wms:WarehouseDetails>
      <wms:OrderLines totalLines="1">
        <wms:OrderLine sequence="1">
          <wms:LineNumber>1</wms:LineNumber>
          <wms:ItemCode>SKU-W-001</wms:ItemCode>
          <wms:ItemDescription>Wheel Assembly Type A</wms:ItemDescription>
          <wms:OrderedQuantity>10</wms:OrderedQuantity>
          <wms:UnitOfMeasure>EA</wms:UnitOfMeasure>
        </wms:OrderLine>
      </wms:OrderLines>
      <wms:ShipToAddress>
        <wms:AddressName>BMWC Assembly Plant 1</wms:AddressName>
        <wms:AddressLine1>Lot 5, Jalan Jubli Perak</wms:AddressLine1>
        <wms:City>Shah Alam</wms:City>
        <wms:Country>MY</wms:Country>
      </wms:ShipToAddress>
    </wms:CreateOrderRequest>
  </soapenv:Body>
</soapenv:Envelope>'

echo
note "Expected: HTTP 200 with a SUCCESS CreateOrderResponse SOAP body"
note "The WmsOrderId in the response is what gets logged to Log Analytics as wmsOrderId"


# ── Done ──────────────────────────────────────────────────────────────────────
sep "Demo Complete"
echo "All 6 scenarios executed. Review outputs at:"
echo ""
echo "  Azure Portal — Service Bus namespace → queues:"
echo "    wms-inbound             — active messages"
echo "    wms-dead-letter-review  — DLQ messages (scenario 3)"
echo ""
echo "  Azure Portal — Logic App Standard:"
echo "    bmwc-rest-ingress       — Run History (all requests)"
echo "    wms-soap-dispatcher     — Run History (scenarios 1–3)"
echo "    dlq-monitor             — Run History (next 15-min trigger)"
echo ""
echo "  Log Analytics — AppTraces queries (see tests/log-analytics-queries.kql)"
echo ""
