// ─── security.bicep ──────────────────────────────────────────────────────────
// Deploys: Key Vault (Standard), User-Assigned Managed Identity.
//          Optional: Defender for Cloud (P2), Microsoft Sentinel.
//
// DEFAULT MODE: Key Vault with default settings — soft delete enabled (Azure
//               enforces this), but no RBAC forced, access policies allowed,
//               no diagnostic settings. No Defender, no Sentinel by default.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Deploy Key Vault.')
param deployKeyVault bool = true

@description('Deploy User-Assigned Managed Identity.')
param deployManagedIdentity bool = true

@description('Enable Defender for Cloud P2 plans. Off by default.')
param enableDefender bool = false

@description('Enable Microsoft Sentinel on Log Analytics. Off by default.')
param enableSentinel bool = false

@description('Log Analytics Workspace resource ID (required for Sentinel).')
param logAnalyticsId string = ''

@description('Resource tags.')
param tags object = {}

// ─── Key Vault ────────────────────────────────────────────────────────────────

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
    // Default: access policy model (not RBAC-based) — default Azure portal behaviour
    enableRbacAuthorization: false
    accessPolicies: []
    // Soft delete is now enforced by Azure (cannot be disabled)
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: true
    // Public network access enabled — default
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Pre-seed dummy secrets for demo use
resource secretDbConnectionString 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (deployKeyVault) {
  parent: keyVault
  name: 'db-connection-string'
  properties: {
    #disable-next-line no-hardcoded-env-urls
    value: 'Server=demo.database.windows.net;Database=demodb;User Id=sqladmin;Password=DemoPassword123!'
  }
}

resource secretApiKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (deployKeyVault) {
  parent: keyVault
  name: 'api-key'
  properties: {
    value: 'demo-api-key-12345-placeholder'
  }
}

resource secretStorageKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (deployKeyVault) {
  parent: keyVault
  name: 'storage-account-key'
  properties: {
    value: 'demo-storage-key-placeholder'
  }
}

// ─── User-Assigned Managed Identity ───────────────────────────────────────────

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployManagedIdentity) {
  name: '${prefix}-identity'
  location: location
  tags: tags
}

// ─── Defender for Cloud ───────────────────────────────────────────────────────
// All major resource types. Subscription-scoped. Off by default.

var defenderPlans = [
  'VirtualMachines'
  'SqlServers'
  'AppServices'
  'StorageAccounts'
  'Containers'
  'KeyVaults'
  'Arm'
  'OpenSourceRelationalDatabases'
  'CosmosDbs'
]

// Defender plans require subscription scope — deployed as a nested module
module defenderModule './defender-plans.bicep' = if (enableDefender) {
  name: 'defenderPlans'
  scope: subscription()
  params: {
    plans: defenderPlans
  }
}

// ─── Microsoft Sentinel ───────────────────────────────────────────────────────
// Deployed on top of Log Analytics. Off by default (pay-per-GB cost).

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

