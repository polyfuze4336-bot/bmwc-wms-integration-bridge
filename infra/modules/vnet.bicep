// ─────────────────────────────────────────────────────────────────────────────
// VNet module  — BMWC WMS Bridge
// Creates a VNet with two subnets:
//   snet-logicapp          : delegated to Microsoft.Web/serverFarms (Logic Apps outbound)
//   snet-private-endpoints : for future Service Bus / Key Vault private endpoints
// ─────────────────────────────────────────────────────────────────────────────

param name string
param location string
param tags object

// ─── NSG: snet-logicapp ───────────────────────────────────────────────────────
// Logic Apps Standard VNet integration is OUTBOUND ONLY.
// The Logic App HTTP trigger is served from the public azurewebsites.net endpoint
// and is not subject to this NSG.  This NSG controls what the Logic App can
// reach through the VNet (WMS, private endpoints, Azure PaaS services).
resource nsgLogicApp 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'nsg-snet-logicapp'
  location: location
  tags: tags
  properties: {
    securityRules: [

      // ── Inbound ───────────────────────────────────────────────────────────
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Required for App Service plan health probes'
        }
      }
      {
        name: 'Allow-VNet-Return-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Return traffic from private endpoints and other VNet resources'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Belt-and-suspenders: block unsolicited inbound to delegated subnet'
        }
      }

      // ── Outbound ──────────────────────────────────────────────────────────
      {
        name: 'Allow-WMS-Mock-SOAP-Outbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '10.10.3.0/24'
          destinationPortRange: '8080'
          description: 'Logic App → WMS mock SOAP on port 8080 (demo). In production replace with WMS on-premises CIDR reachable via VPN/ExpressRoute.'
        }
      }
      {
        name: 'Allow-PrivateEndpoints-Outbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '10.10.2.0/24'
          destinationPortRange: '443'
          description: 'Logic App → Key Vault private endpoint. Expand for Service Bus Premium PE in production.'
        }
      }
      {
        name: 'Allow-ServiceBus-ServiceEndpoint-Outbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'ServiceBus'
          destinationPortRange: '443'
          description: 'Service Bus (Standard SKU, service endpoint). Traffic stays on Microsoft backbone.'
        }
      }
      {
        name: 'Allow-KeyVault-ServiceEndpoint-Outbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
          description: 'Key Vault service endpoint. Also covers Key Vault Reference resolution by Logic Apps runtime.'
        }
      }
      {
        name: 'Allow-Storage-Outbound'
        properties: {
          priority: 140
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '443'
          description: 'Logic Apps runtime: Azure Storage for workflow state, run history, and content share'
        }
      }
      {
        name: 'Allow-AzureMonitor-Outbound'
        properties: {
          priority: 150
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureMonitor'
          destinationPortRange: '443'
          description: 'Application Insights telemetry and Log Analytics ingestion'
        }
      }
      {
        name: 'Deny-Internet-Outbound'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
          description: 'No direct internet egress. All Logic App outbound must target named Azure services or VNet resources.'
        }
      }
    ]
  }
}

// ─── NSG: snet-private-endpoints ─────────────────────────────────────────────
// Private endpoints are passive: they receive traffic from Logic Apps, they do
// not initiate outbound connections.
resource nsgPrivateEndpoints 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'nsg-snet-private-endpoints'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-LogicApp-HTTPS-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.10.1.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          description: 'Logic App subnet → Key Vault private endpoint'
        }
      }
      {
        name: 'Deny-All-Other-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Internet-Outbound'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
          description: 'Private endpoints do not egress to internet'
        }
      }
    ]
  }
}

// ─── NSG: snet-wms-mock (demo only) ──────────────────────────────────────────
// Houses the WMS mock SOAP service (Node.js container, port 8080).
// Production equivalent: this subnet is removed; the WMS SOAP URL resolves to
// an on-premises IP reachable via VPN gateway or ExpressRoute circuit.
resource nsgWmsMock 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'nsg-snet-wms-mock'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-LogicApp-SOAP-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.10.1.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8080'
          description: 'Logic App → WMS mock SOAP listener on port 8080'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'WMS mock must not be publicly reachable — demo isolation'
        }
      }
      {
        name: 'Deny-Internet-Outbound'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
          description: 'Mock WMS is isolated from the internet'
        }
      }
    ]
  }
}

// ─── Virtual Network ──────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.10.0.0/16']
    }
    subnets: [
      // Subnet 0 — Logic Apps Standard outbound VNet integration
      // Delegation gives Logic Apps exclusive use of this subnet for egress routing.
      {
        name: 'snet-logicapp'
        properties: {
          addressPrefix: '10.10.1.0/24'
          delegations: [
            {
              name: 'delegation-logicapp'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
          serviceEndpoints: [
            { service: 'Microsoft.ServiceBus'  }
            { service: 'Microsoft.KeyVault'    }
            { service: 'Microsoft.Storage'     }
          ]
          networkSecurityGroup: { id: nsgLogicApp.id }
        }
      }
      // Subnet 1 — Private endpoints
      // Key Vault PE (deployed now). Service Bus PE when SKU is upgraded to Premium.
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.10.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: { id: nsgPrivateEndpoints.id }
        }
      }
      // Subnet 2 — WMS mock container (demo only)
      // Remove in production; replace WmsSoapEndpoint with the on-premises WMS URL
      // reachable over VPN gateway or ExpressRoute.
      {
        name: 'snet-wms-mock'
        properties: {
          addressPrefix: '10.10.3.0/24'
          networkSecurityGroup: { id: nsgWmsMock.id }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output logicAppSubnetId string = vnet.properties.subnets[0].id
output privateEndpointSubnetId string = vnet.properties.subnets[1].id
output wmsMockSubnetId string = vnet.properties.subnets[2].id
