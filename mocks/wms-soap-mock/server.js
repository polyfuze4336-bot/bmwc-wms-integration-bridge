/**
 * mocks/wms-soap-mock/server.js
 *
 * Lightweight WMS SOAP mock for local and demo environments.
 * Simulates the legacy WMS CreateOrder SOAP operation without a real WMS instance.
 *
 * Endpoints:
 *   GET  /WMSService.svc?wsdl   — returns the service WSDL
 *   POST /WMSService.svc        — handles SOAP CreateOrder requests
 *   GET  /health                 — liveness check for container orchestrators
 *
 * Run: node server.js      (PORT env var, default 8080)
 */

'use strict';

const express = require('express');
const app = express();

// Parse text/xml and application/xml SOAP bodies as raw text
app.use(express.text({ type: ['text/xml', 'application/xml', 'application/soap+xml'] }));
app.use(express.json());

// ── Helper: extract element value from raw XML string ───────────────────────
function extractElement(xml, tagName) {
  const ns = ['wms', 'ns0', 'ns1', ''];
  for (const prefix of ns) {
    const open = prefix ? `<${prefix}:${tagName}>` : `<${tagName}>`;
    const close = prefix ? `</${prefix}:${tagName}>` : `</${tagName}>`;
    const start = xml.indexOf(open);
    if (start !== -1) {
      const end = xml.indexOf(close, start);
      return xml.substring(start + open.length, end).trim();
    }
  }
  return null;
}

// ── Minimal WSDL ─────────────────────────────────────────────────────────────
const wsdl = `<?xml version="1.0" encoding="utf-8"?>
<definitions xmlns="http://schemas.xmlsoap.org/wsdl/"
             xmlns:soap="http://schemas.xmlsoap.org/wsdl/soap/"
             xmlns:wms="http://wms.legacy.corp/v1"
             targetNamespace="http://wms.legacy.corp/v1"
             name="WMSService">
  <types>
    <schema xmlns="http://www.w3.org/2001/XMLSchema" targetNamespace="http://wms.legacy.corp/v1">
      <element name="CreateOrder">
        <complexType><sequence>
          <element name="OrderRequest" type="wms:OrderRequestType"/>
        </sequence></complexType>
      </element>
      <complexType name="OrderRequestType">
        <sequence>
          <element name="OrderId" type="string"/>
          <element name="CustomerId" type="string"/>
          <element name="WarehouseCode" type="string"/>
          <element name="Priority" type="string" minOccurs="0"/>
        </sequence>
      </complexType>
      <element name="CreateOrderResponse">
        <complexType><sequence>
          <element name="Status" type="string"/>
          <element name="WmsOrderId" type="string"/>
          <element name="Message" type="string"/>
        </sequence></complexType>
      </element>
    </schema>
  </types>
  <message name="CreateOrderRequest"><part name="parameters" element="wms:CreateOrder"/></message>
  <message name="CreateOrderResponse"><part name="parameters" element="wms:CreateOrderResponse"/></message>
  <portType name="WMSPortType">
    <operation name="CreateOrder">
      <input message="wms:CreateOrderRequest"/>
      <output message="wms:CreateOrderResponse"/>
    </operation>
  </portType>
  <binding name="WMSBinding" type="wms:WMSPortType">
    <soap:binding style="document" transport="http://schemas.xmlsoap.org/soap/http"/>
    <operation name="CreateOrder">
      <soap:operation soapAction="http://wms.legacy.corp/v1/CreateOrder"/>
      <input><soap:body use="literal"/></input>
      <output><soap:body use="literal"/></output>
    </operation>
  </binding>
  <service name="WMSService">
    <port name="WMSPort" binding="wms:WMSBinding">
      <soap:address location="http://localhost:${process.env.PORT || 8080}/WMSService.svc"/>
    </port>
  </service>
</definitions>`;

// ── WSDL endpoint ─────────────────────────────────────────────────────────────
app.get('/WMSService.svc', (req, res) => {
  if ('wsdl' in req.query || req.query.WSDL !== undefined) {
    res.set('Content-Type', 'text/xml; charset=utf-8');
    return res.send(wsdl);
  }
  res.status(400).json({ error: 'Use POST for SOAP calls or add ?wsdl for WSDL' });
});

// ── SOAP endpoint ─────────────────────────────────────────────────────────────
app.post('/WMSService.svc', (req, res) => {
  const body = req.body || '';

  // Validate it looks like a SOAP envelope
  if (!body.includes('Envelope')) {
    return res.status(400).send('<error>Not a SOAP envelope</error>');
  }

  const orderId = extractElement(body, 'OrderId') || 'UNKNOWN';
  const customerId = extractElement(body, 'CustomerId') || '';
  const warehouseCode = extractElement(body, 'WarehouseCode') || '';
  const priority = extractElement(body, 'Priority') || 'STANDARD';
  const correlationId = extractElement(body, 'CorrelationId') || '';

  const wmsOrderId = `WMS-${Date.now()}-${Math.floor(Math.random() * 1000)}`;

  console.log(JSON.stringify({
    event: 'WMS_MOCK_RECEIVED',
    orderId,
    customerId,
    warehouseCode,
    priority,
    correlationId,
    wmsOrderId,
    timestamp: new Date().toISOString()
  }));

  // Simulate a ~50ms processing delay (remove in unit tests)
  setTimeout(() => {
    res.set('Content-Type', 'text/xml; charset=utf-8');
    res.status(200).send(`<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:wms="http://wms.legacy.corp/v1">
  <soap:Header>
    <wms:ResponseHeader>
      <wms:CorrelationId>${correlationId}</wms:CorrelationId>
    </wms:ResponseHeader>
  </soap:Header>
  <soap:Body>
    <wms:CreateOrderResponse>
      <wms:Status>SUCCESS</wms:Status>
      <wms:WmsOrderId>${wmsOrderId}</wms:WmsOrderId>
      <wms:Message>Order ${orderId} accepted by WMS warehouse ${warehouseCode}</wms:Message>
      <wms:EstimatedReadyDate>${new Date(Date.now() + 86400000).toISOString().split('T')[0]}</wms:EstimatedReadyDate>
      <wms:WarehouseRef>${warehouseCode}-${orderId}</wms:WarehouseRef>
    </wms:CreateOrderResponse>
  </soap:Body>
</soap:Envelope>`);
  }, 50);
});

// ── Health check ──────────────────────────────────────────────────────────────
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', service: 'wms-soap-mock', timestamp: new Date().toISOString() });
});

// ── Start ─────────────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 8080;
app.listen(PORT, () => {
  console.log(JSON.stringify({
    event: 'WMS_MOCK_STARTED',
    port: PORT,
    endpoints: {
      wsdl: `http://localhost:${PORT}/WMSService.svc?wsdl`,
      soap: `http://localhost:${PORT}/WMSService.svc`,
      health: `http://localhost:${PORT}/health`
    }
  }));
});
