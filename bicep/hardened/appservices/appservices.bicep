// ─── hardened/appservices/appservices.bicep ───────────────────────────────────
// Deploys: App Service Plan (B1), Windows Web App, Linux Web App,
//          Function App (Consumption), Static Web App, Logic App (Standard).
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

@description('Deploy Linux Web App.')
param deployLinuxApp bool = true

@description('Deploy Function App (Consumption plan).')
param deployFunctionApp bool = true

@description('Deploy Static Web App.')
param deployStaticWebApp bool = true

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
    // Hardened: disable public network access (MCSB NS-1)
    publicNetworkAccess: 'Disabled'
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

// ─── Linux App Service Plan ───────────────────────────────────────────────────

resource linuxAppServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = if (deployLinuxApp) {
  name: '${prefix}-linux-asp'
  location: location
  tags: tags
  sku: {
    name: appServicePlanSku
    tier: 'Basic'
  }
  properties: {
    reserved: true
  }
}

// ─── Linux Web App ────────────────────────────────────────────────────────────

resource linuxWebApp 'Microsoft.Web/sites@2023-01-01' = if (deployLinuxApp) {
  name: '${prefix}-linux-app'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: linuxAppServicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    clientCertEnabled: true
    clientCertMode: 'Optional'
    virtualNetworkSubnetId: !empty(subnetId) ? subnetId : null
    siteConfig: union(hardenedSiteConfig, {
      linuxFxVersion: 'NODE|20-lts'
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
    // Shared key retained for Consumption plan AzureWebJobsStorage connection string
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
    publicNetworkAccess: 'Disabled'
    // NOTE: Consumption (Y1) plan supports outbound VNet integration since 2023
    // Required for the function to reach private endpoints (databases, Key Vault, Service Bus)
    virtualNetworkSubnetId: !empty(subnetId) ? subnetId : null
    siteConfig: union(hardenedSiteConfig, {
      vnetRouteAllEnabled: !empty(subnetId)
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${functionStorageName!.name};AccountKey=${functionStorageName!.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
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

// ─── Static Web App ───────────────────────────────────────────────────────────
// Static Web Apps enforce HTTPS by default — no additional config needed.

resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = if (deployStaticWebApp) {
  name: '${prefix}-static-app'
  location: location
  tags: tags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {}
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
    allowSharedKeyAccess: true    // Required for Logic App Standard backing storage
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
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: !empty(subnetId) ? subnetId : null
    siteConfig: union(hardenedSiteConfig, {
      vnetRouteAllEnabled: !empty(subnetId)
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${logicAppStorage!.name};AccountKey=${logicAppStorage!.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
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

// ─── Outputs ──────────────────────────────────────────────────────────────────

output windowsWebAppId string = deployWindowsApp ? windowsWebApp.id : ''
output windowsWebAppHostname string = deployWindowsApp ? windowsWebApp!.properties.defaultHostName : ''
output linuxWebAppId string = deployLinuxApp ? linuxWebApp.id : ''
output linuxWebAppHostname string = deployLinuxApp ? linuxWebApp!.properties.defaultHostName : ''
output functionAppId string = deployFunctionApp ? functionApp.id : ''
output functionAppHostname string = deployFunctionApp ? functionApp!.properties.defaultHostName : ''
output staticWebAppId string = deployStaticWebApp ? staticWebApp.id : ''
output staticWebAppHostname string = deployStaticWebApp ? staticWebApp!.properties.defaultHostname : ''
output logicAppId string = deployLogicApp ? logicApp.id : ''
output logicAppHostname string = deployLogicApp ? logicApp!.properties.defaultHostName : ''
