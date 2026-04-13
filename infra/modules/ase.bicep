// ─────────────────────────────────────────────────────────────────────────────
// App Service Environment v3 (External) — BMWC WMS Bridge
//
// ASEv3 External: Logic App trigger endpoint is served from a public IP on the ASE.
// This allows APIM (Consumption tier) to call the Logic App trigger without VNet peering.
//
// Key differences from Workflow Service Plan (WS1):
//   - Storage account can have allowSharedKeyAccess: false (Azure Policy compatible).
//     ASEv3 uses NFS mounts for home directory, NOT SMB/Azure Files shared key.
//   - Logic App is inside the VNet by design — no separate regional VNet integration needed.
//   - Plan SKU is I1v2 (IsolatedV2) rather than WS1 (WorkflowStandard).
//
// ⚠️  Provisioning time: ASEv3 takes 1–3 hours to create. Plan accordingly.
//
// Ref: https://learn.microsoft.com/en-us/azure/app-service/environment/overview-v3
// ─────────────────────────────────────────────────────────────────────────────

param name string
param location string
param tags object

@description('Resource ID of the /24 subnet dedicated to ASEv3 (snet-ase). Must be delegated to Microsoft.Web/hostingEnvironments.')
param aseSubnetId string

// ASEv3 External — internalLoadBalancingMode: 'None' → public IP on the ASE front-end.
// Change to 'Web, Publishing' for an Internal (ILB) ASE, which requires private DNS.
resource ase 'Microsoft.Web/hostingEnvironments@2022-03-01' = {
  name: name
  location: location
  tags: tags
  kind: 'ASEV3'
  properties: {
    internalLoadBalancingMode: 'None'   // External = public endpoint
    virtualNetwork: {
      id: aseSubnetId
    }
    zoneRedundant: false                // Set true in production for 99.99% SLA (requires 3 instances)
  }
}

output id   string = ase.id
output name string = ase.name
