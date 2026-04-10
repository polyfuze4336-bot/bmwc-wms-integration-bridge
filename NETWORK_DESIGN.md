# BMWC → WMS Bridge — Network Architecture Design

**Version**: 1.0  
**Date**: April 2026

---

## Table of Contents

1. [Network Architecture — Plain English](#1-network-architecture--plain-english)
2. [Subnets and Their Purpose](#2-subnets-and-their-purpose)
3. [VNet Integration and Private Endpoints](#3-vnet-integration-and-private-endpoints)
4. [NSG Considerations](#4-nsg-considerations)
5. [DNS Considerations](#5-dns-considerations)
6. [Demo vs Production Security Assumptions](#6-demo-vs-production-security-assumptions)
7. [WMS Private Endpoint and SOAP URL in Config](#7-wms-private-endpoint-and-soap-url-in-config)
8. [Security Narrative for Customer Demo](#8-security-narrative-for-customer-demo)

---

## 1. Network Architecture — Plain English

The integration bridge sits entirely within Azure. Traffic flows in one direction through a layered security perimeter — it never travels directly between BMWC and the WMS.

### How a message travels

```
BMWC System (internet)
    │
    │  HTTPS  Ocp-Apim-Subscription-Key
    ▼
Azure API Management (Consumption)
    │  Public endpoint — secured by subscription key + IP allowlist
    │  Strips internal headers before forwarding
    │
    │  HTTPS  to Logic Apps trigger URL
    ▼
Logic Apps Standard — bmwc-rest-ingress workflow
    │  Runs inside App Service Plan
    │  Validates schema, enriches message, sends to queue
    │
    │  HTTPS  via VNet service endpoint (snet-logicapp → Microsoft.ServiceBus)
    ▼
Azure Service Bus — wms-inbound queue
    │  Async buffer — decouples ingress from WMS processing
    │  Messages survive WMS outages (4-hour TTL)
    │
    │  Peek-lock  via VNet service endpoint
    ▼
Logic Apps Standard — wms-soap-dispatcher workflow
    │  Runs inside same App Service Plan (VNet-integrated)
    │  Reads WMS credentials from Key Vault at runtime
    │  Transforms JSON → SOAP using Liquid map
    │
    │  HTTP/SOAP  via VNet, private routing, port 8080
    ▼
WMS SOAP Service  [demo: container in snet-wms-mock]
                  [prod:  on-premises via VPN/ExpressRoute]
```

### Key security properties

- **No direct BMWC-to-WMS path exists.** The WMS is isolated inside the VNet (or on-premises network). BMWC cannot reach it.
- **No WMS credentials traverse the internet.** Credentials are stored in Key Vault, injected into the Logic App at runtime inside the VNet, and sent to WMS only over the private path.
- **APIM never touches the WMS.** APIM routes to Logic Apps (public trigger URL) then returns. All WMS interaction happens asynchronously behind the queue.
- **Logic Apps outbound traffic has no direct internet path.** The NSG on `snet-logicapp` explicitly denies `Internet` as an outbound destination; only named Azure service tags and the WMS CIDR are permitted.

---

## 2. Subnets and Their Purpose

All subnets live inside VNet `vnet-bmwc-wms-{token}` with address space `10.10.0.0/16`.

### `snet-logicapp` — 10.10.1.0/24

**Purpose**: Logic Apps Standard outbound VNet integration.

When Logic Apps Standard is configured with regional VNet integration, the platform delegates this subnet to `Microsoft.Web/serverFarms`. Outbound traffic from the Logic App — calls to the WMS, calls to Service Bus, calls to Key Vault — routes through this subnet into the VNet.

**Inbound to this subnet**: Not applicable. The Logic Apps HTTP trigger is served from the App Service public endpoint (`la-xxx.azurewebsites.net`), which is not in this subnet. APIM reaches the trigger over HTTPS on the public endpoint; the traffic does not enter this subnet.

**Key settings**:
- Delegation: `Microsoft.Web/serverFarms`
- Service endpoints: `Microsoft.ServiceBus`, `Microsoft.KeyVault`, `Microsoft.Storage`
- NSG: `nsg-snet-logicapp`

### `snet-private-endpoints` — 10.10.2.0/24

**Purpose**: Hosts Azure Private Endpoints for PaaS services.

A private endpoint places a private IP address from this subnet into the VNet, allowing the Logic App to reach that Azure service over the VNet backbone rather than over the public internet. Private endpoint traffic is controlled at the NIC level — the PE itself only responds to traffic it is configured for.

**Currently deployed**: Key Vault private endpoint (PE for `kv-bmwc-{token}`).

**Planned for production**: Service Bus private endpoint (requires Premium SKU upgrade).

**Key settings**:
- `privateEndpointNetworkPolicies: Disabled` — required by Azure for PE deployment
- NSG: `nsg-snet-private-endpoints`

### `snet-wms-mock` — 10.10.3.0/24 (demo only)

**Purpose**: Houses the WMS SOAP mock service inside the VNet.

The mock is a Node.js container (from `mocks/wms-soap-mock/`) deployed as an Azure Container Instance or Container App into this subnet. It listens on port 8080 and simulates WMS SOAP responses. This is the only component visible from `snet-logicapp` on port 8080.

**Why this subnet is demo-only**: In production, the WMS lives on-premises. This subnet is removed; the `WmsSoapEndpoint` Key Vault secret points to an IP reachable via VPN gateway or ExpressRoute. No subnet change is needed on the Azure side — only the endpoint URL changes.

**Key settings**:
- NSG: `nsg-snet-wms-mock`
- No delegation, no service endpoints

### Address allocation summary

| Subnet | CIDR | Used by | Environment |
|---|---|---|---|
| `snet-logicapp` | 10.10.1.0/24 | Logic Apps Standard (delegated) | All |
| `snet-private-endpoints` | 10.10.2.0/24 | Key Vault PE, future SB PE | All |
| `snet-wms-mock` | 10.10.3.0/24 | WMS mock container | Demo only |
| Reserved | 10.10.4.0/24 – 10.10.255.0/24 | VPN gateway, peering, expansion | Future |

---

## 3. VNet Integration and Private Endpoints

### Logic Apps Standard — VNet integration (outbound)

Logic Apps Standard uses **regional VNet integration**. This is an outbound-only mechanism: it routes traffic that the Logic App initiates out through `snet-logicapp` into the VNet.

```
Logic App initiates outbound call
    → routing table on snet-logicapp
    → next hop: VNet
    → destination: 10.10.3.x (WMS) or service endpoint (SB/KV) or PE (10.10.2.x)
```

This is configured in `logicapp.bicep` via `virtualNetworkSubnetId` on the App Service site resource.

**What VNet integration does NOT do**:
- Does not create a private inbound endpoint for the Logic App trigger URL
- Does not prevent APIM from calling the trigger over the public internet
- Does not apply to storage account access unless storage also has service endpoints

### Key Vault — two layers

| Layer | Mechanism | Status |
|---|---|---|
| Service endpoint | `Microsoft.KeyVault` endpoint on `snet-logicapp` | ✅ Active (demo + prod) |
| Private endpoint | PE in `snet-private-endpoints` | ⬜ Add for production |
| KV network ACL | `defaultAction: Deny` + VNet rule for `snet-logicapp` | ✅ Active |

For the demo, service endpoint protection is sufficient. Key Vault denies all traffic except from `snet-logicapp` (and `bypass: AzureServices` which covers Key Vault Reference resolution from the Logic Apps runtime).

In production, add a Key Vault private endpoint into `snet-private-endpoints` and add a private DNS zone record for `kv-bmwc-{token}.privatelink.vaultcore.azure.net`. This removes the service endpoint dependency and makes KV completely unreachable from the public internet.

### Service Bus — service endpoint (Standard SKU)

Service Bus Standard does not support private endpoints. Traffic from `snet-logicapp` uses the `Microsoft.ServiceBus` service endpoint — it routes over the Microsoft backbone without traversing the public internet, but the Service Bus namespace still has a public DNS name and technically a public IP.

For production in a regulated environment, upgrade to Service Bus **Premium SKU** and add a private endpoint into `snet-private-endpoints`. The upgrade also enables:
- VNet injection (namespace network filtering)
- Message size > 256 KB
- Geo-redundancy / paired namespace

### APIM — current limitation

APIM **Consumption SKU** does not support VNet injection.

This means APIM sits on the public internet and calls the Logic Apps trigger URL over HTTPS. APIM is secured by:
- Subscription key
- IP allowlist (commented in `bmwc-api-policy.xml`, enable for production)
- TLS 1.2 minimum
- Header stripping (strips `Ocp-Apim-Subscription-Key` before forwarding)

For production in a regulated environment, upgrade APIM to **Developer or Premium SKU** and inject APIM into a fourth subnet (`snet-apim`, e.g. `10.10.4.0/24`). This moves the entire flow inside the VNet:

```
BMWC → APIM (VNet-injected) → Logic Apps (private endpoint inbound) → SB → LA → WMS
```

This full path is out of scope for the demo but is the correct production target architecture.

---

## 4. NSG Considerations

Three NSGs are deployed — one per subnet. Rules enforce least-privilege egress for the Logic Apps subnet and strict isolation for the WMS mock.

### `nsg-snet-logicapp`

| Direction | Rule name | Port | Destination | Priority | Rationale |
|---|---|---|---|---|---|
| Inbound | Allow-AzureLoadBalancer | `*` | `*` | 100 | ASP health probes |
| Inbound | Allow-VNet-Return | `*` | `*` | 110 | Return packets from VNet |
| Inbound | Deny-All | `*` | `*` | 4096 | No unsolicited inbound |
| Outbound | Allow-WMS-Mock-SOAP | 8080 | 10.10.3.0/24 | 100 | SOAP call to mock WMS |
| Outbound | Allow-PrivateEndpoints | 443 | 10.10.2.0/24 | 110 | Key Vault PE (present) + SB PE (future) |
| Outbound | Allow-ServiceBus | 443 | `ServiceBus` | 120 | Service Bus service endpoint |
| Outbound | Allow-KeyVault | 443 | `AzureKeyVault` | 130 | Key Vault service endpoint |
| Outbound | Allow-Storage | 443 | `Storage` | 140 | Logic Apps runtime storage |
| Outbound | Allow-AzureMonitor | 443 | `AzureMonitor` | 150 | App Insights + Log Analytics |
| Outbound | Deny-Internet | `*` | `Internet` | 4096 | No direct internet egress |

**Note on DNS**: Azure DNS (168.63.129.16) is classified as `VirtualNetwork` traffic, not `Internet`. It is not blocked by the `Deny-Internet-Outbound` rule. Logic Apps can resolve `privatelink.vaultcore.azure.net` names through Azure DNS without any additional NSG rule.

**Note on the delegated subnet**: Azure applies the NSG to traffic that passes through the subnet's routing table. For inbound traffic to the Logic App itself (APIM calling the trigger URL), traffic arrives at the App Service front-end, not through `snet-logicapp`. The inbound rules on this NSG do not affect trigger reachability.

### `nsg-snet-private-endpoints`

| Direction | Rule name | Port | Source / Destination | Priority |
|---|---|---|---|---|
| Inbound | Allow-LogicApp-HTTPS | 443 | 10.10.1.0/24 | 100 |
| Inbound | Deny-All | `*` | `*` | 4096 |
| Outbound | Deny-Internet | `*` | `Internet` | 4096 |

**`privateEndpointNetworkPolicies: Disabled`** is required on this subnet. When disabled, standard NSG rules apply to PE-targeted traffic but route table UDRs do not affect PE traffic. This is an Azure platform requirement, not a security weakening.

### `nsg-snet-wms-mock`

| Direction | Rule name | Port | Source / Destination | Priority |
|---|---|---|---|---|
| Inbound | Allow-LogicApp-SOAP | 8080 | 10.10.1.0/24 | 100 |
| Inbound | Deny-Internet | `*` | `Internet` | 200 |
| Outbound | Deny-Internet | `*` | `Internet` | 4096 |

The mock only needs to receive SOAP requests on port 8080. It does not need internet access.

### Flow verification

After deployment, confirm NSG flow logs or run:
```bash
# Verify effective outbound rules on Logic Apps subnet
az network nic show-effective-nsg \
  --resource-group <rg> \
  --name <nic-of-logic-app-plan>

# Test connectivity from Logic Apps to WMS mock (use Kudu console or a probe workflow)
# curl http://10.10.3.4:8080/WMSService.svc
```

---

## 5. DNS Considerations

### Current demo (service endpoints only)

No custom DNS is needed. Service endpoints use public DNS names (e.g. `sb-bmwc-wms-xxx.servicebus.windows.net`) but route over the Microsoft backbone. Azure DNS resolves these names to public IPs, and the service endpoint redirects traffic to the internal path transparently.

### When adding private endpoints (production)

Each private endpoint requires a **Private DNS Zone** linked to the VNet. Without this, the service name resolves to its public IP, and traffic bypasses the private endpoint.

| Service | DNS zone | Record |
|---|---|---|
| Key Vault PE | `privatelink.vaultcore.azure.net` | A record: `kv-bmwc-{token}` → `10.10.2.x` |
| Service Bus PE (Premium) | `privatelink.servicebus.windows.net` | A record: `sb-bmwc-wms-{token}` → `10.10.2.y` |
| Storage (optional) | `privatelink.blob.core.windows.net` | A record → `10.10.2.z` |

**To deploy a Key Vault private DNS zone in Bicep** (add to `vnet.bicep` or a new `dns.bicep` module):

```bicep
resource kvPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource kvDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: kvPrivateDnsZone
  name: 'link-to-${vnet.name}'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false   // Only resolve — do not auto-register resources
  }
}
```

The A record is created automatically when the private endpoint is deployed with `privateDnsZoneGroup` set.

### WMS mock DNS (demo)

The WMS mock container in `snet-wms-mock` is accessed by private IP (`10.10.3.x`). The `wms-soap-endpoint` Key Vault secret stores this IP directly:

```
http://10.10.3.4:8080/WMSService.svc
```

No DNS zone is needed for the mock. If a hostname is preferred (e.g. `wms-mock.internal`), create a private DNS zone `internal` and add an A record manually.

### Hybrid DNS for production

When the WMS lives on-premises, the on-premises DNS server must be authoritative for the WMS hostname. Configure Azure DNS forwarding:
1. Deploy an Azure DNS Private Resolver in a dedicated subnet
2. Add a forwarding ruleset: `wms.corp` → on-premises DNS server IP
3. Logic App resolves `wms.internal.corp` → DNS Resolver → on-premises DNS → private IP

This is optional for the demo but required in production if the WMS is addressed by hostname rather than IP.

---

## 6. Demo vs Production Security Assumptions

### Side-by-side comparison

| Control | Demo (this prototype) | Production (regulated) |
|---|---|---|
| **APIM ingress** | Consumption SKU, public internet, subscription key | Developer/Premium SKU, VNet-injected, subscription key + IP allowlist + mutual TLS |
| **Logic App trigger** | Public azurewebsites.net endpoint | Private endpoint inbound (blocks public access entirely) |
| **Logic App outbound** | VNet integration via snet-logicapp | Same — already correct |
| **Service Bus** | Standard SKU, service endpoint | Premium SKU, private endpoint, `disableLocalAuth: true` |
| **Key Vault** | Standard SKU, service endpoint + ACL deny | Standard SKU, private endpoint, `enablePurgeProtection: true`, 90-day retention |
| **WMS path** | Container in snet-wms-mock (private IP) | On-premises via VPN/ExpressRoute — same VNet integration, different endpoint |
| **Storage Account** | Public with TLS 1.2 | Private endpoint or service endpoint, Shared Key disabled (`allowSharedKeyAccess: false`), UAMI for Logic Apps |
| **Managed Identity** | System-assigned on Logic App | System-assigned + optionally User-assigned for explicit control |
| **Local auth** | Enabled (SB connection string) | Disabled (`disableLocalAuth: true` on SB and LA) — Managed Identity only |
| **IP allowlist** | Commented out in APIM policy | Populated with BMWC egress IPs |
| **Soft delete** | 7-day KV retention | 90-day KV retention, purge protection enabled |
| **NSGs** | Deployed with flow log disabled | Deploy with NSG flow logs → Log Analytics, enable Traffic Analytics |

### What the demo already gets right

These controls are **production-grade today** — no changes needed:
- TLS 1.2 enforced on all services
- Managed Identity (no credential in code paths)
- Key Vault References for WMS credentials (never in app settings in plaintext)
- `disableLocalAuth: false` is flagged in Bicep comments for production tightening
- NSG on Logic Apps subnet blocks all internet egress
- Key Vault `defaultAction: Deny` — locked to VNet only
- No subscription key forwarded to Logic Apps (stripped in APIM global policy)
- Correlation ID and run ID propagation for forensic traceability

### What to change before production

```
1. Upgrade APIM SKU → Developer or Premium, add VNet injection
2. Add Logic Apps inbound private endpoint (disables public trigger URL)
3. Upgrade Service Bus → Premium, add private endpoint
4. Add Key Vault private endpoint, enable purge protection
5. Set disableLocalAuth: true on Service Bus namespace
6. Set allowSharedKeyAccess: false on Storage Account
7. Populate APIM IP allowlist with production BMWC source CIDRs
8. Enable NSG flow logs on all three NSGs
9. Replace snet-wms-mock with VPN/ExpressRoute path to on-premises WMS
10. Set softDeleteRetentionInDays: 90 on Key Vault
```

---

## 7. WMS Private Endpoint and SOAP URL in Config

The WMS SOAP URL travels through the following config chain — changing it for production requires touching only one record:

### Config chain

```
main.parameters.json  (azd deploy parameter)
    wmsSoapEndpoint = "http://10.10.3.4:8080/WMSService.svc"   ← demo
                    = "https://wms.internal.corp:8443/WMS.svc"  ← production
        │
        ▼
infra/modules/keyvault.bicep  (Key Vault secret)
    secret name: wms-soap-endpoint
    value: wmsSoapEndpoint param
        │
        ▼
infra/modules/logicapp.bicep  (App Setting — Key Vault Reference)
    WMS__SoapEndpoint = @Microsoft.KeyVault(VaultName=...; SecretName=wms-soap-endpoint)
        │
        ▼
logic-app/parameters.json  (workflow parameter binding)
    WmsSoapEndpoint → ${WMS__SoapEndpoint}
        │
        ▼
wms-soap-dispatcher/workflow.json  (Call_WMS_SOAP_Endpoint action)
    uri: @parameters('WmsSoapEndpoint')
```

### Demo endpoint (container in snet-wms-mock)

The WMS mock container receives a private IP from `snet-wms-mock` (10.10.3.0/24) when deployed as an Azure Container Instance. The private IP is not predictable at Bicep deployment time.

**Post-deploy step** (add to `post-provision.ps1`):

```powershell
# Get the private IP assigned to the WMS mock container
$wmsMockIp = az container show `
  --resource-group $Env:AZURE_RESOURCE_GROUP `
  --name aci-wms-mock `
  --query ipAddress.ip -o tsv

# Update the Key Vault secret with the actual container IP
az keyvault secret set `
  --vault-name $Env:AZURE_KEY_VAULT_NAME `
  --name wms-soap-endpoint `
  --value "http://${wmsMockIp}:8080/WMSService.svc"
```

Alternatively, assign a static IP to the container by specifying it at `az container create` time and setting the same IP in `main.parameters.json`.

### Production endpoint (on-premises WMS via VPN/ExpressRoute)

For production, replace the Key Vault secret value with the WMS private IP or hostname reachable over the VPN/ExpressRoute-connected network:

```bash
# Update Key Vault secret post-VPN-provisioning (no Bicep re-deploy needed)
az keyvault secret set \
  --vault-name kv-bmwc-<token> \
  --name wms-soap-endpoint \
  --value "https://wms.internal.corp:8443/WMSService.svc"
```

The Logic App picks up the new secret value on next run (Key Vault References are resolved at workflow execution time, not at deploy time).

### If the WMS URL is sensitive

If the WMS hostname/IP is classified (e.g. reveals internal network topology), do not pass it as a plain `main.parameters.json` value. Instead:

```powershell
# Set the secret directly, never in a parameters file
az keyvault secret set `
  --vault-name $Env:AZURE_KEY_VAULT_NAME `
  --name wms-soap-endpoint `
  --value $SecureWmsUrl   # injected from CI/CD secrets vault
```

Remove `wmsSoapEndpoint` from `main.parameters.json` and set `keyvault.bicep` to only create the secret structure (empty value) — then post-provision populates the real value.

---

## 8. Security Narrative for Customer Demo

> Use this narrative when presenting the solution to a customer in a regulated industry (financial services, manufacturing, healthcare). Adapt the specific numbers and names to match the customer's environment.

---

### "How does my data stay secure?"

Every message submitted by your system travels through a layered security perimeter before reaching the WMS.

**Layer 1 — API Gateway perimeter (Azure API Management)**

Your call arrives at an Azure API Management gateway. APIM immediately validates your subscription key and, in production, confirms your source IP is on our allowlist. If either check fails, the call is rejected before any Integration logic runs. APIM strips all internal headers — your subscription key is never forwarded to the Logic App or logged.

**Layer 2 — Logic App validation and enrichment**

The Logic App validates the message schema, normalises timestamps, and assigns a correlation ID that will trace this exact message end-to-end through every system — from your original call to the WMS SOAP response — in a single Log Analytics query.

**Layer 3 — Service Bus buffer (async decoupling)**

Rather than calling the WMS directly, the Logic App places your message into an Azure Service Bus queue. This means:  
- Your system gets an immediate `202 Accepted` response — no waiting for the WMS  
- If the WMS is momentarily unavailable, your data is safe in the queue for up to 4 hours and will be delivered automatically when the WMS recovers  
- The same `orderId` submitted twice within 10 minutes is silently deduplicated — no double-orders

**Layer 4 — Private network path to the WMS**

The second Logic App workflow — the dispatcher — picks up messages from Service Bus and calls the WMS. This outbound call travels through a **private Virtual Network**. There is no path from the public internet to the WMS. The Logic App's outbound networking rules explicitly deny all internet egress; the only allowed outbound destination is the WMS subnet (or, in production, your on-premises network via VPN or ExpressRoute).

**Layer 5 — Credentials never in code**

WMS username and password are stored in Azure Key Vault, which is locked to the private VNet — it cannot be reached from the internet. The Logic App retrieves credentials at runtime using its Managed Identity. No credential ever appears in source code, configuration files, or log entries.

**What the customer sees:**
- A single REST endpoint with a subscription key
- A `202 Accepted` response confirming the order was received
- A `correlationId` to trace the message through the system

**What the customer never sees:**
- The WMS SOAP endpoint address
- The WMS credentials
- Internal Azure workflow run IDs or queue depths (all stripped at APIM egress)
- Any indication that a legacy SOAP service is involved

---

### "What happens if the WMS goes down?"

Your orders are not lost. They wait in the Service Bus queue for up to 4 hours. When the WMS recovers, the dispatcher automatically picks up where it left off — oldest messages first. No operator intervention is required for outages shorter than 4 hours.

For longer outages, operations can extend the queue retention with a single CLI command and begin recovery immediately when the WMS is available again.

### "How do we know an order was processed?"

Every action in the chain produces a structured telemetry event logged to Azure Log Analytics with the same `correlationId` that was returned in your `202 Accepted` response. Operations can query the complete journey of any order in a single search — from the moment APIM received it to the moment the WMS returned its acknowledgement.

The `GET /orders/{orderId}/status` endpoint returns the current WMS dispatch status. Any message that the WMS permanently rejects is moved to a dead-letter queue and triggers an operations alert within 15 minutes.
