// ─── ai.bicep ─────────────────────────────────────────────────────────────────
// Deploys: Azure AI Services (multi-service), Azure OpenAI, Cognitive Search,
//          Azure Machine Learning.
//
// ALL RESOURCES OFF BY DEFAULT — require quota approval and have unpredictable costs.
// Enable individually via flags.
//
// DEFAULT MODE: Public endpoints, default settings, no hardening.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Deploy Azure AI Services (multi-service account).')
param deployAiServices bool = false

@description('Deploy Azure OpenAI Service. Requires quota approval in your subscription.')
param deployOpenAi bool = false

@description('Deploy Azure Cognitive Search (Basic ~$75/month).')
param deployCognitiveSearch bool = false

@description('Deploy Azure Machine Learning workspace.')
param deployMachineLearning bool = false

@description('AI subnet resource ID for future VNet-integration of AI/ML services.')
#disable-next-line no-unused-params
param subnetId string = ''

@description('Resource tags.')
param tags object = {}

// ─── Azure AI Services ────────────────────────────────────────────────────────

resource aiServices 'Microsoft.CognitiveServices/accounts@2023-10-01-preview' = if (deployAiServices) {
  name: '${prefix}-aiservices'
  location: location
  tags: tags
  kind: 'CognitiveServices'
  sku: { name: 'S0' }
  properties: {
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
    // No customer-managed keys — default
  }
}

// ─── Azure OpenAI ─────────────────────────────────────────────────────────────

resource openAiAccount 'Microsoft.CognitiveServices/accounts@2023-10-01-preview' = if (deployOpenAi) {
  name: '${prefix}-openai'
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

// Deploy GPT-4o as default model (most commonly used for demos)
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

resource cognitiveSearch 'Microsoft.Search/searchServices@2023-11-01' = if (deployCognitiveSearch) {
  name: '${prefix}-search'
  location: location
  tags: tags
  sku: { name: 'basic' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    publicNetworkAccess: 'enabled'
    disableLocalAuth: false
  }
}

// ─── Azure Machine Learning ───────────────────────────────────────────────────

// ML workspace requires Key Vault, Storage, App Insights as dependencies
resource mlStorage 'Microsoft.Storage/storageAccounts@2023-04-01' = if (deployMachineLearning) {
  name: '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 8))}ml${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {}
}

resource mlKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (deployMachineLearning) {
  name: '${prefix}-ml-kv-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenant().tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    accessPolicies: []
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
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
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
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
    publicNetworkAccess: 'Enabled'
    v1LegacyMode: false
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
