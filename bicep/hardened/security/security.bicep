// ─── hardened/security/security.bicep ────────────────────────────────────────
// Deploys: Key Vault (Standard, RBAC-based), User-Assigned Managed Identity.
//          Optional: Defender for Cloud (P2), Microsoft Sentinel.
//
// HARDENED MODE: Key Vault with RBAC authorization (no access policies),
//               purge protection enabled, 90-day soft delete, public network
//               access disabled (private endpoints only). Defender and Sentinel
//               ENABLED by default. No plaintext secrets for demo credentials.
//               Aligns with: CIS 8.x, MCSB IM-1, IM-3, LT-1, PV-1.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Deploy Key Vault.')
param deployKeyVault bool = true

@description('Deploy User-Assigned Managed Identity.')
param deployManagedIdentity bool = true

@description('Enable Defender for Cloud P2 plans. Hardened: ON by default.')
param enableDefender bool = true     // Hardened: on

@description('Enable Microsoft Sentinel on Log Analytics. Hardened: ON by default.')
param enableSentinel bool = true     // Hardened: on

@description('Log Analytics Workspace resource ID (required for Sentinel).')
param logAnalyticsId string = ''

@description('Private endpoint subnet resource ID. When set, a private endpoint for Key Vault is deployed.')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource ID for Key Vault (privatelink.vaultcore.azure.net).')
param keyVaultDnsZoneId string = ''

@description('Object ID of the deployer (user or service principal). When set, grants Key Vault Secrets Officer role so seed-data.ps1 can write secrets post-deployment.')
param deployerPrincipalId string = ''

@description('Public IP address ranges (CIDR notation) to allow through Key Vault network ACLs. Use this to permit deployer workstation or CI runner IPs. RFC1918 private ranges are not supported here — VNet access uses private endpoints. Example: ["203.0.113.0/24"]')
param allowedCidrRanges array = []

@description('Resource tags.')
param tags object = {}

// ─── Key Vault ────────────────────────────────────────────────────────────────
// Hardened: RBAC authorization (CIS 8.5), purge protection, 90-day soft delete,
//           public network access disabled, network ACLs deny by default.

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (deployKeyVault) {
  name: '${prefix}-kv-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    // Hardened: RBAC-based authorization — no access policies (CIS 8.5, MCSB IM-3)
    enableRbacAuthorization: true
    accessPolicies: []
    // Hardened: soft delete + purge protection (CIS 8.4, prevents accidental/malicious deletion)
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    enabledForDeployment: false             // Hardened: off — RBAC + private endpoint is the only access path (CIS 8.1)
    enabledForTemplateDeployment: false     // Hardened: off — secrets must not be pulled inline by ARM (CIS 8.1)
    enabledForDiskEncryption: true
    // Hardened: no public network access — private endpoints only (MCSB NS-2)
    // Exception: allowedCidrRanges can be set to permit deployer/CI runner public IPs.
    publicNetworkAccess: empty(allowedCidrRanges) ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      // Inject deployer/CI public IPs so they can reach KV without VPN.
      // RFC1918 private ranges are NOT supported in ipRules; use private endpoints for VNet access.
      ipRules: [for cidr in allowedCidrRanges: { value: cidr }]
      virtualNetworkRules: []
    }
  }
}

// Key Vault diagnostic settings — sends all audit events to Log Analytics
resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployKeyVault && !empty(logAnalyticsId)) {
  name: '${prefix}-kv-diag'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ─── Hardened demo secrets ────────────────────────────────────────────────────
// NOTE: In hardened mode, no real credentials are stored in KV at deploy time.
//       Reference secrets (placeholder values only) are loaded for structure.
//       Real credentials should be injected post-deployment via CI/CD pipeline
//       with appropriate RBAC (Key Vault Secrets Officer role).
//
// Public network access is disabled, so KV secrets require private endpoint or
// deploy via az CLI from within the VNet / trusted service bypass.

// ─── User-Assigned Managed Identity ───────────────────────────────────────────

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployManagedIdentity) {
  name: '${prefix}-identity'
  location: location
  tags: tags
}

// ─── Defender for Cloud ───────────────────────────────────────────────────────
// Hardened: all major resource types enabled by default.

var defenderPlans = [
  'VirtualMachines'
  'SqlServers'
  'SqlServerVirtualMachines'    // Hardened: SQL on VMs coverage (CIS 2.x)
  'AppServices'
  'StorageAccounts'
  'Containers'
  'KeyVaults'
  'Arm'
  'Apis'                        // Hardened: Defender for APIs coverage (MCSB NS-1)
  'OpenSourceRelationalDatabases'
  'CosmosDbs'
  'Dns'
]

// Defender plans require subscription scope — deployed as a nested module.
// Includes auto-provisioning settings (CIS 2.14).
module defenderModule '../../modules/security/defender-plans.bicep' = if (enableDefender) {
  name: 'defenderPlans'
  scope: subscription()
  params: {
    plans: defenderPlans
    logAnalyticsId: logAnalyticsId
  }
}

// ─── Microsoft Sentinel ───────────────────────────────────────────────────────

resource sentinel 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = if (enableSentinel && !empty(logAnalyticsId)) {
  name: 'SecurityInsights(${last(split(logAnalyticsId, '/'))})'
  location: location
  tags: tags
  plan: {
    name: 'SecurityInsights(${last(split(logAnalyticsId, '/'))})'
    publisher: 'Microsoft'
    product: 'OMSGallery/SecurityInsights'
    promotionCode: ''
  }
  properties: {
    workspaceResourceId: logAnalyticsId
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output keyVaultId string = deployKeyVault ? keyVault.id : ''
output keyVaultName string = deployKeyVault ? keyVault.name : ''
output keyVaultUri string = deployKeyVault ? keyVault!.properties.vaultUri : ''
output managedIdentityId string = deployManagedIdentity ? managedIdentity.id : ''
output managedIdentityClientId string = deployManagedIdentity ? managedIdentity!.properties.clientId : ''
output managedIdentityPrincipalId string = deployManagedIdentity ? managedIdentity!.properties.principalId : ''

// ─── Key Vault Private Endpoint ───────────────────────────────────────────────
// Required: KV has publicNetworkAccess: 'Disabled' and networkAcls defaultAction: 'Deny'
// Without a private endpoint callers inside the VNet cannot reach Key Vault at all.

resource kvPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (deployKeyVault && !empty(privateEndpointSubnetId)) {
  name: '${prefix}-kv-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-kv-plsc'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource kvPeDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (deployKeyVault && !empty(privateEndpointSubnetId) && !empty(keyVaultDnsZoneId)) {
  parent: kvPrivateEndpoint
  name: 'kv-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: { privateDnsZoneId: keyVaultDnsZoneId }
      }
    ]
  }
}

// ─── Deployer RBAC ────────────────────────────────────────────────────────────
// Grant the deployer Key Vault Secrets Officer so seed-data.ps1 can write secrets
// from inside the VNet or via the Azure CLI with trusted-service bypass.

resource kvSecretsOfficerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployKeyVault && !empty(deployerPrincipalId)) {
  name: guid(keyVault.id, deployerPrincipalId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')  // Key Vault Secrets Officer
    principalId: deployerPrincipalId
    principalType: 'User'
  }
}
