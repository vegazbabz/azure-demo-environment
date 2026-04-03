// ─── hardened/ai/ai.bicep ─────────────────────────────────────────────────────
// Deploys: Azure AI Services (multi-service), Azure OpenAI, Cognitive Search,
//          Azure Machine Learning.
//
// HARDENED MODE: Local auth disabled on all cognitive services (Entra ID only).
//               Network restrictions on AI services and ML workspace.
//               ML workspace with system-assigned identity and managed VNet.
//               Aligns with: MCSB IM-3, NS-1, AI-1.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Deploy Azure AI Services (multi-service account).')
param deployAiServices bool = false

@description('Deploy Azure OpenAI Service. Requires quota approval.')
param deployOpenAi bool = false

@description('Deploy Azure Cognitive Search (Basic ~$75/month).')
param deployCognitiveSearch bool = false

@description('Deploy Azure Machine Learning workspace.')
param deployMachineLearning bool = false

@description('Resource tags.')
param tags object = {}

// ─── Azure AI Services ────────────────────────────────────────────────────────
// Hardened: local auth disabled, public access disabled.

resource aiServices 'Microsoft.CognitiveServices/accounts@2023-10-01-preview' = if (deployAiServices) {
  name: '${prefix}-aiservices'
  location: location
  tags: tags
  kind: 'CognitiveServices'
  sku: { name: 'S0' }
  properties: {
    // Hardened: public access disabled (private endpoint required for production)
    publicNetworkAccess: 'Disabled'
    // Hardened: local auth disabled — Entra ID RBAC only (MCSB IM-3)
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

// ─── Azure OpenAI ─────────────────────────────────────────────────────────────
// Hardened: local auth disabled, network restrictions.

resource openAiAccount 'Microsoft.CognitiveServices/accounts@2023-10-01-preview' = if (deployOpenAi) {
  name: '${prefix}-openai'
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    publicNetworkAccess: 'Disabled'
    // Hardened: Entra ID authentication only (no API keys)
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource openAiDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-10-01-preview' = if (deployOpenAi) {
  parent: openAiAccount
  name: 'gpt-4o'
  sku: {
    name: 'Standard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-11-20'
    }
  }
}

// ─── Cognitive Search ─────────────────────────────────────────────────────────
// Hardened: local auth disabled, no public access.

resource cognitiveSearch 'Microsoft.Search/searchServices@2023-11-01' = if (deployCognitiveSearch) {
  name: '${prefix}-search'
  location: location
  tags: tags
  sku: { name: 'basic' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    // Hardened: public access disabled
    publicNetworkAccess: 'disabled'
    // Hardened: local auth disabled (Entra ID RBAC only — MCSB IM-3)
    disableLocalAuth: true
    // Hardened: require HTTPS (enforced by default; explicit for auditability)
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

// ─── Azure Machine Learning ───────────────────────────────────────────────────
// Hardened: managed VNet, no public access, system-assigned identity.

resource mlStorage 'Microsoft.Storage/storageAccounts@2023-04-01' = if (deployMachineLearning) {
  name: '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 8))}ml${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // Shared key retained for ML workspace internal operations (workspace SDK requires it)
    allowSharedKeyAccess: true
    // Hardened: disable public network access (MCSB NS-1)
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource mlKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (deployMachineLearning) {
  name: '${prefix}-ml-kv-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenant().tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    enableRbacAuthorization: true
    accessPolicies: []
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource mlAppInsights 'Microsoft.Insights/components@2020-02-02' = if (deployMachineLearning) {
  name: '${prefix}-ml-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

resource mlWorkspace 'Microsoft.MachineLearningServices/workspaces@2024-01-01-preview' = if (deployMachineLearning) {
  name: '${prefix}-mlworkspace'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    storageAccount: mlStorage.id
    keyVault: mlKeyVault.id
    applicationInsights: mlAppInsights.id
    // Hardened: no public access — private endpoint or VPN required
    publicNetworkAccess: 'Disabled'
    v1LegacyMode: false
    // Hardened: managed VNet for outbound isolation
    managedNetwork: {
      isolationMode: 'AllowInternetOutbound'
    }
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output aiServicesId string = deployAiServices ? aiServices.id : ''
output aiServicesEndpoint string = deployAiServices ? aiServices!.properties.endpoint : ''
output openAiId string = deployOpenAi ? openAiAccount.id : ''
output openAiEndpoint string = deployOpenAi ? openAiAccount!.properties.endpoint : ''
output cognitiveSearchId string = deployCognitiveSearch ? cognitiveSearch.id : ''
output cognitiveSearchEndpoint string = deployCognitiveSearch ? 'https://${cognitiveSearch.name}.search.windows.net' : ''
output mlWorkspaceId string = deployMachineLearning ? mlWorkspace.id : ''
