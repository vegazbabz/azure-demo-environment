// ─── defender-plans.bicep ─────────────────────────────────────────────────────
// Subscription-scoped deployment for Microsoft Defender for Cloud P2 plans.
// Referenced by security.bicep as a nested module.
// CIS 2.1–2.10 — Enable Defender P2 for all supported resource types.
// ────────────────────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('List of Defender for Cloud pricing tier names to enable at P2 (Standard).')
param plans array

resource pricingTiers 'Microsoft.Security/pricings@2023-01-01' = [
  for plan in plans: {
    name: plan
    properties: {
      pricingTier: 'Standard'    // P2
    }
  }
]

// CIS 2.13 — Set Security Contact email
// Note: patch this via az security contact after deployment if needed

// CIS 2.14 — Ensure auto-provisioning of monitoring agent is On
resource autoProvisioning 'Microsoft.Security/autoProvisioningSettings@2017-08-01-preview' = {
  name: 'mma'
  properties: {
    autoProvision: 'On'
  }
}
