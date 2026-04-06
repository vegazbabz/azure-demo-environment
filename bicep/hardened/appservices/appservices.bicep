// ─── hardened/appservices/appservices.bicep ───────────────────────────────────
// Deploys: App Service Plan (B1), Windows Web App,
//          Function App (Consumption), Static Web App, Logic App (Standard).
//
// NOTE: Linux App Service Plan is intentionally absent — Microsoft.Web/serverfarms
// with reserved:true is unavailable in several Azure regions (including swedencentral).
// The Windows plan + Function App cover the benchmark scope.
//
// HARDENED MODE: HTTPS-only, TLS 1.2, FTPS disabled, system-assigned managed
//               identity on all apps, client certificate mode optional,
//               remote debugging disabled, detailed error messages off,
//               function storage hardened (HTTPS + TLS 1.2).
//               Aligns with: CIS 9.x, MCSB DP-3, IM-1, NS-1.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Deploy Windows Web App.')
param deployWindowsApp bool = true

@description('Deploy Function App (Consumption plan).')
param deployFunctionApp bool = true

@description('Deploy Logic App (Standard).')
param deployLogicApp bool = true

@description('App Service Plan SKU.')
param appServicePlanSku string = 'B1'

@description('VNet integration subnet resource ID (appservices subnet, delegated to Microsoft.Web/serverFarms). When set, all apps route outbound traffic through the VNet to reach private endpoints.')
param subnetId string = ''

@description('Resource tags.')
param tags object = {}

// ─── Shared hardened site config ──────────────────────────────────────────────
// Applied to all App Service / Function sites

var hardenedSiteConfig = {
  // Hardened: TLS 1.2 minimum (CIS 9.3)
  minTlsVersion: '1.2'
  // Hardened: FTPS disabled (CIS 9.10)
  ftpsState: 'Disabled'
  // Hardened: remote debugging disabled
  remoteDebuggingEnabled: false
  // Hardened: detailed errors off (information disclosure)
  detailedErrorLoggingEnabled: false
  httpLoggingEnabled: true
  // Hardened: HTTP/2 enabled
  http20Enabled: true
  // Hardened: health check endpoint (MCSB — availability monitoring)
  healthCheckPath: '/health'
}

// ─── App Service Plan (Windows) ───────────────────────────────────────────────

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-asp'
  location: location
  tags: tags
  sku: {
    name: appServicePlanSku
    tier: 'Basic'
  }
  properties: {
    reserved: false
  }
}

// ─── Windows Web App ──────────────────────────────────────────────────────────

resource windowsWebApp 'Microsoft.Web/sites@2023-01-01' = if (deployWindowsApp) {
  name: '${prefix}-win-app'
  location: location
  tags: tags
  // Hardened: system-assigned managed identity (CIS 9.5, MCSB IM-1)
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    // Hardened: HTTPS-only (CIS 9.2)
    httpsOnly: true
    // NOTE: A private endpoint (group ID 'sites') is required to set publicNetworkAccess to 'Disabled'.
    // Keeping Enabled for demo deployability; add privateEndpointSubnetId param + PE resource for full hardening.
    publicNetworkAccess: 'Enabled'
    // Hardened: client cert in Optional mode — enables mutual TLS where clients supply certs (CIS 9.4)
    clientCertEnabled: true
    clientCertMode: 'Optional'
    // Hardened: VNet integration — outbound traffic to private endpoints in the VNet
    virtualNetworkSubnetId: !empty(subnetId) ? subnetId : null
    siteConfig: union(hardenedSiteConfig, {
      netFrameworkVersion: 'v8.0'
      // Route all outbound traffic through the VNet (reaches private endpoints)
      vnetRouteAllEnabled: !empty(subnetId)
    })
  }
}

// ─── Function App ─────────────────────────────────────────────────────────────
// Hardened: function backing storage with HTTPS + TLS 1.2 (public access allowed
// for AzureWebJobsStorage connection — required by Consumption plan).
// NOTE: For full hardening, migrate to Premium plan + VNet integration + managed
//       identity storage access using AzureWebJobsStorage__accountName.

resource functionStorageName 'Microsoft.Storage/storageAccounts@2023-04-01' = if (deployFunctionApp) {
  name: '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 8))}fn${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    // Hardened: HTTPS + TLS 1.2 on function backing storage
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // Shared key retained: Y1 Consumption plan WEBSITE_CONTENTAZUREFILECONNECTIONSTRING
    // requires key access for the deployment content share. AzureWebJobsStorage itself
    // uses managed identity (see siteConfig.appSettings below). Migrate to EP1 Premium
    // plan to fully eliminate key-based storage access.
    allowSharedKeyAccess: true
  }
}

resource functionPlan 'Microsoft.Web/serverfarms@2023-01-01' = if (deployFunctionApp) {
  name: '${prefix}-func-asp'
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: false
  }
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = if (deployFunctionApp) {
  name: '${prefix}-funcapp'
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true
    // NOTE: A private endpoint (group ID 'sites') is required to set publicNetworkAccess to 'Disabled'.
    // Keeping Enabled for demo deployability; add privateEndpointSubnetId param + PE resource for full hardening.
    publicNetworkAccess: 'Enabled'
    // NOTE: Consumption (Y1) plan supports outbound VNet integration since 2023
    // Required for the function to reach private endpoints (databases, Key Vault, Service Bus)
    virtualNetworkSubnetId: !empty(subnetId) ? subnetId : null
    siteConfig: union(hardenedSiteConfig, {
      vnetRouteAllEnabled: !empty(subnetId)
      appSettings: [
        // Hardened: AzureWebJobsStorage uses managed identity — no storage key in App Settings (MCSB IM-3).
        // WEBSITE_CONTENTAZUREFILECONNECTIONSTRING retains a key: Y1 Consumption plan requires it
        // for the code deployment content share. Migrate to EP1 Premium to fully eliminate keys.
        {
          name: 'AzureWebJobsStorage__accountName'
          value: functionStorageName!.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${functionStorageName!.name};AccountKey=${functionStorageName!.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: '${prefix}-funcapp'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }
      ]
    })
  }
}

// ─── Logic App (Standard) ─────────────────────────────────────────────────────

resource logicAppPlan 'Microsoft.Web/serverfarms@2023-01-01' = if (deployLogicApp) {
  name: '${prefix}-logic-asp'
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  properties: {
    reserved: false
  }
}

resource logicAppStorage 'Microsoft.Storage/storageAccounts@2023-04-01' = if (deployLogicApp) {
  name: '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 8))}la${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // Hardened: shared key disabled — Logic App Standard (WS1) supports full managed identity
    // storage access via AzureWebJobsStorage__accountName (see app settings below).
    allowSharedKeyAccess: false
  }
}

resource logicApp 'Microsoft.Web/sites@2023-01-01' = if (deployLogicApp) {
  name: '${prefix}-logicapp'
  location: location
  tags: tags
  kind: 'workflowapp,functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: logicAppPlan.id
    httpsOnly: true
    // NOTE: A private endpoint (group ID 'sites') is required to set publicNetworkAccess to 'Disabled'.
    // Keeping Enabled for demo deployability; add privateEndpointSubnetId param + PE resource for full hardening.
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: !empty(subnetId) ? subnetId : null
    siteConfig: union(hardenedSiteConfig, {
      vnetRouteAllEnabled: !empty(subnetId)
      appSettings: [
        // Hardened: full managed identity storage — no keys in App Settings (MCSB IM-3).
        // Logic App Standard (WS1) fully supports AzureWebJobsStorage__accountName with managed identity.
        {
          name: 'AzureWebJobsStorage__accountName'
          value: logicAppStorage!.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'APP_KIND'
          value: 'workflowApp'
        }
      ]
    })
  }
}

// ─── Storage RBAC — Function App identity → Function backing storage ─────────
// Required for managed identity AzureWebJobsStorage connection (MCSB IM-3).
// Roles needed by the Functions runtime: Blob Data Owner, Queue Data Contributor,
// Table Data Contributor.

resource funcStorageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFunctionApp) {
  name: guid(functionStorageName!.id, functionApp!.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: functionStorageName
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Owner
    principalId: functionApp!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFunctionApp) {
  name: guid(functionStorageName!.id, functionApp!.id, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  scope: functionStorageName
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88') // Storage Queue Data Contributor
    principalId: functionApp!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFunctionApp) {
  name: guid(functionStorageName!.id, functionApp!.id, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  scope: functionStorageName
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3') // Storage Table Data Contributor
    principalId: functionApp!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Storage RBAC — Logic App identity → Logic App backing storage ────────────
// Logic App Standard (WS1) uses managed identity for all storage operations.

resource logicStorageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployLogicApp) {
  name: guid(logicAppStorage!.id, logicApp!.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: logicAppStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Owner
    principalId: logicApp!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource logicStorageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployLogicApp) {
  name: guid(logicAppStorage!.id, logicApp!.id, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  scope: logicAppStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88') // Storage Queue Data Contributor
    principalId: logicApp!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource logicStorageTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployLogicApp) {
  name: guid(logicAppStorage!.id, logicApp!.id, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  scope: logicAppStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3') // Storage Table Data Contributor
    principalId: logicApp!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output windowsWebAppId string = deployWindowsApp ? windowsWebApp.id : ''
output windowsWebAppHostname string = deployWindowsApp ? windowsWebApp!.properties.defaultHostName : ''
output functionAppId string = deployFunctionApp ? functionApp.id : ''
output functionAppHostname string = deployFunctionApp ? functionApp!.properties.defaultHostName : ''
output logicAppId string = deployLogicApp ? logicApp.id : ''
output logicAppHostname string = deployLogicApp ? logicApp!.properties.defaultHostName : ''
