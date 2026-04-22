// ─── defender-plans.bicep ─────────────────────────────────────────────────────
// Subscription-scoped deployment for Microsoft Defender for Cloud P2 plans.
// Referenced by security.bicep as a nested module.
// CIS 2.1–2.10 — Enable Defender P2 for all supported resource types.
// ────────────────────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('List of Defender for Cloud pricing tier names to enable at P2 (Standard).')
param plans array

@description('Log Analytics Workspace resource ID. When provided, Defender for Cloud is configured to send data to this workspace instead of auto-creating DefaultResourceGroup-{REGION} with an unmanaged default workspace.')
param logAnalyticsId string = ''

resource pricingTiers 'Microsoft.Security/pricings@2023-01-01' = [
  for plan in plans: {
    name: plan
    properties: {
      pricingTier: 'Standard'    // P2
    }
  }
]

// ─── Defender workspace setting ───────────────────────────────────────────────
// Controls which Log Analytics workspace Defender uses for data collection.
// Without this, enabling Defender for Servers P2 (or any plan that needs a LAW)
// causes Azure to auto-create DefaultResourceGroup-{REGION} with a default workspace
// outside ADE's control and not cleaned up by destroy.ps1.
// CIS 2.14 — Use a designated Log Analytics workspace for Defender.
resource workspaceSetting 'Microsoft.Security/workspaceSettings@2017-08-01-preview' = if (!empty(logAnalyticsId)) {
  name: 'default'
  properties: {
    workspaceId: logAnalyticsId
    // Apply to the entire subscription scope
    scope: subscription().id
  }
}

// CIS 2.13 — Set Security Contact email
// Note: patch this via az security contact after deployment if needed

// NOTE: MMA (Microsoft Monitoring Agent) auto-provisioning is intentionally
// NOT set here.  The MMA agent was retired by Microsoft in August 2024.
// Enabling autoProvisioningSettings 'mma' = 'On' causes Azure Defender for
// Cloud to silently create an unmanaged DefaultResourceGroup-{REGION} resource
// group and a default Log Analytics workspace outside ADE's control.
// For CIS 2.14 compliance use the Azure Monitor Agent (AMA) instead.
