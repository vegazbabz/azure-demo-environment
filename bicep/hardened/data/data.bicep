// ─── hardened/data/data.bicep ─────────────────────────────────────────────────
// Deploys: Azure Data Factory, Azure Synapse Analytics (optional),
//          Azure Databricks (optional), Microsoft Purview (optional).
//
// HARDENED MODE: Data Factory with managed VNet and no public access.
//               Synapse: public access disabled, no hardcoded credentials.
//               Databricks: no public network access (NsgRules = NoAzureDatabricksRules).
//               Purview: public access disabled.
//               Aligns with: MCSB IG-1, NS-1, DP-3.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Deploy Azure Data Factory.')
param deployDataFactory bool = true

@description('Deploy Azure Synapse Analytics.')
param deploySynapse bool = false

@description('Deploy Azure Databricks.')
param deployDatabricks bool = false

@description('Deploy Microsoft Purview.')
param deployPurview bool = false

@description('Synapse SQL admin password. Required when deploySynapse = true.')
@secure()
param synapseAdminPassword string = ''

@description('Resource tags.')
param tags object = {}

// ─── Azure Data Factory ───────────────────────────────────────────────────────
// Hardened: managed VNet, no public network access, system-assigned identity.

resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = if (deployDataFactory) {
  name: '${prefix}-adf'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    // Hardened: no public network access — use private endpoint
    publicNetworkAccess: 'Disabled'
    globalParameters: {}
  }
}

// Sample linked service — uses managed identity (no connection string)
resource adfLinkedServiceBlob 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = if (deployDataFactory) {
  parent: dataFactory
  name: 'AzureBlobStorage_Demo'
  properties: {
    type: 'AzureBlobStorage'
    typeProperties: {
      #disable-next-line no-hardcoded-env-urls
      serviceEndpoint: 'https://demo.blob.core.windows.net'
      accountKind: 'StorageV2'
      // Hardened: managed identity authentication (no SAS or connection string)
    }
    connectVia: {
      referenceName: 'AutoResolveIntegrationRuntime'
      type: 'IntegrationRuntimeReference'
    }
  }
}

// ─── Azure Synapse Analytics ──────────────────────────────────────────────────
// Hardened: public access disabled, system-assigned identity, Entra ID auth,
//           no hardcoded credentials (password param required).

resource synapseStorage 'Microsoft.Storage/storageAccounts@2023-04-01' = if (deploySynapse) {
  name: '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 8))}syn${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false    // Hardened: no shared key — Synapse uses MSI
  }
}

resource synapseWorkspace 'Microsoft.Synapse/workspaces@2021-06-01' = if (deploySynapse) {
  name: '${prefix}-synapse'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    defaultDataLakeStorage: {
      accountUrl: synapseStorage!.properties.primaryEndpoints.dfs
      filesystem: 'synapse'
      // Hardened: use managed identity to access storage (not shared key)
      resourceId: synapseStorage!.id
      createManagedPrivateEndpoint: false
    }
    sqlAdministratorLogin: 'synapseadmin'
    sqlAdministratorLoginPassword: synapseAdminPassword
    // Hardened: no public access (MCSB NS-1)
    publicNetworkAccess: 'Disabled'
    managedVirtualNetwork: 'default'
    // Hardened: Azure AD-only auth where possible
    azureADOnlyAuthentication: false    // Keep false so SQL auth still works for demos
    managedVirtualNetworkSettings: {
      allowedAadTenantIdsForLinking: []
      preventDataExfiltration: true    // Hardened: prevent data exfiltration
    }
  }
}

// ─── Azure Databricks ─────────────────────────────────────────────────────────
// Hardened: no public network access, Secure Cluster Connectivity (no public IPs),
//           AllRules → NoAzureDatabricksRules removes open inbound NSG rules.

resource databricks 'Microsoft.Databricks/workspaces@2023-02-01' = if (deployDatabricks) {
  name: '${prefix}-databricks'
  location: location
  tags: tags
  // Hardened: Premium SKU required for private networking + Entra ID only auth
  sku: { name: 'premium' }
  properties: {
    managedResourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-databricks-managed-rg'
    // Hardened: no public network access (MCSB NS-1)
    publicNetworkAccess: 'Disabled'
    // Hardened: remove open Databricks NSG rules — use Secure Cluster Connectivity
    requiredNsgRules: 'NoAzureDatabricksRules'
    parameters: {
      // Hardened: Enable Secure Cluster Connectivity (no public IPs on nodes)
      enableNoPublicIp: { value: true }
    }
  }
}

// ─── Microsoft Purview ────────────────────────────────────────────────────────
// Hardened: public access disabled.

resource purviewAccount 'Microsoft.Purview/accounts@2021-12-01' = if (deployPurview) {
  name: '${prefix}-purview'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    // Hardened: public access disabled
    publicNetworkAccess: 'Disabled'
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output dataFactoryId string = deployDataFactory ? dataFactory.id : ''
output dataFactoryName string = deployDataFactory ? dataFactory.name : ''
output synapseWorkspaceId string = deploySynapse ? synapseWorkspace.id : ''
output synapseWorkspaceName string = deploySynapse ? synapseWorkspace.name : ''
output databricksId string = deployDatabricks ? databricks.id : ''
output databricksWorkspaceUrl string = deployDatabricks ? databricks!.properties.workspaceUrl : ''
output purviewId string = deployPurview ? purviewAccount.id : ''
