// ─── security.bicep ──────────────────────────────────────────────────────────
// Deploys: Key Vault (Standard), User-Assigned Managed Identity.
//          Optional: Defender for Cloud (P2), Microsoft Sentinel.
//
// DEFAULT MODE: Key Vault with RBAC authorization — access is controlled via
//               Azure role assignments (Key Vault Administrator, Secrets User,
//               etc.) rather than vault-level access policies.
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

@description('Object ID of the deployer principal (SP or user). When provided, grants Key Vault Secrets Officer so seed-data.ps1 can write secrets post-deploy.')
param deployerPrincipalId string = ''

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
    // RBAC authorization — access policies are ignored when this is true.
    // Assign roles (Key Vault Administrator, Key Vault Secrets User, etc.)
    // via Azure RBAC instead of vault-level access policies.
    enableRbacAuthorization: true
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

// ─── User-Assigned Managed Identity ───────────────────────────────────────────

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployManagedIdentity) {
  name: '${prefix}-identity'
  location: location
  tags: tags
}

// ─── Key Vault Secrets Officer for deployer ──────────────────────────────────
// Grants seed-data.ps1 permission to write secrets after Bicep deployment.
// Only created when deployerPrincipalId is explicitly passed.

resource kvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployKeyVault && !empty(deployerPrincipalId)) {
  name: guid(keyVault.id, deployerPrincipalId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: keyVault
  properties: {
    // Key Vault Secrets Officer
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
  }
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

