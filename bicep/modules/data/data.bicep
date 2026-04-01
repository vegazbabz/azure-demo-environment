// ─── data.bicep ───────────────────────────────────────────────────────────────
// Deploys: Azure Data Factory, Azure Synapse Analytics (optional),
//          Azure Databricks (optional), Microsoft Purview (optional).
//
// ALL RESOURCES OFF BY DEFAULT — complex setup and/or high cost.
// Data Factory is the exception — on by default as it is low cost.
//
// DEFAULT MODE: Public endpoints, default settings, no hardening.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Deploy Azure Data Factory.')
param deployDataFactory bool = true

@description('Deploy Azure Synapse Analytics. Off by default (costs vary).')
param deploySynapse bool = false

@description('Deploy Azure Databricks. Off by default (costs vary by cluster usage).')
param deployDatabricks bool = false

@description('Deploy Microsoft Purview. Off by default (~$50+/month).')
param deployPurview bool = false

@description('Resource tags.')
param tags object = {}

// ─── Azure Data Factory ───────────────────────────────────────────────────────

resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = if (deployDataFactory) {
  name: '${prefix}-adf'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

// Sample linked service — Azure Blob Storage (uses managed identity)
resource adfLinkedServiceBlob 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = if (deployDataFactory) {
  parent: dataFactory
  name: 'AzureBlobStorage_Demo'
  properties: {
    type: 'AzureBlobStorage'
    typeProperties: {
      #disable-next-line no-hardcoded-env-urls
      serviceEndpoint: 'https://demo.blob.core.windows.net'
      accountKind: 'StorageV2'
    }
    connectVia: {
      referenceName: 'AutoResolveIntegrationRuntime'
      type: 'IntegrationRuntimeReference'
    }
  }
}

// ─── Azure Synapse Analytics ──────────────────────────────────────────────────

resource synapseStorage 'Microsoft.Storage/storageAccounts@2023-04-01' = if (deploySynapse) {
  name: '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 8))}syn${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true
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
    }
    sqlAdministratorLogin: 'synapseadmin'
    sqlAdministratorLoginPassword: 'SynapseDemo123!'
    publicNetworkAccess: 'Enabled'
    managedVirtualNetwork: 'default'
  }
}

// ─── Azure Databricks ─────────────────────────────────────────────────────────

resource databricks 'Microsoft.Databricks/workspaces@2023-02-01' = if (deployDatabricks) {
  name: '${prefix}-databricks'
  location: location
  tags: tags
  sku: { name: 'standard' }
  properties: {
    managedResourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-databricks-managed-rg'
    publicNetworkAccess: 'Enabled'
    requiredNsgRules: 'AllRules'
  }
}

// ─── Microsoft Purview ────────────────────────────────────────────────────────

resource purviewAccount 'Microsoft.Purview/accounts@2021-12-01' = if (deployPurview) {
  name: '${prefix}-purview'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    publicNetworkAccess: 'Enabled'
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
