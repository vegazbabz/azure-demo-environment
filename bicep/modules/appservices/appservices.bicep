// ─── appservices.bicep ───────────────────────────────────────────────────────
// Deploys: App Service Plan (B1), Windows Web App,
//          Function App (Consumption), Logic App (Standard).
//
// NOTE: Linux App Service Plan is intentionally absent — Microsoft.Web/serverfarms
// with reserved:true is unavailable in several Azure regions (including swedencentral).
// The Windows plan + Function App cover the benchmark scope.
//
// DEFAULT MODE: No forced HTTPS, no TLS minimum, no managed identity,
//               no diagnostic settings. Out-of-the-box Azure defaults.
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

@description('App Service Plan SKU. Automatically upgraded to S1 (Standard) when appServiceSubnetId is provided, since Basic tier does not support VNet integration.')
param appServicePlanSku string = 'B1'

@description('App Services subnet resource ID for outbound VNet integration. When set, plans upgrade to Standard (S1) and all web apps route traffic through the VNet.')
param appServiceSubnetId string = ''

@description('Resource tags.')
param tags object = {}

// Upgrade to Standard when VNet integration is requested — Basic does not support it
var effectiveSku  = empty(appServiceSubnetId) ? appServicePlanSku : 'S1'
var effectiveTier = empty(appServiceSubnetId) ? 'Basic' : 'Standard'
var vnetEnabled   = !empty(appServiceSubnetId)

// ─── App Service Plan (Windows) ───────────────────────────────────────────────

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-asp'
  location: location
  tags: tags
  sku: {
    name: effectiveSku
    tier: effectiveTier
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
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: false
    virtualNetworkSubnetId: vnetEnabled ? appServiceSubnetId : null
    siteConfig: {
      minTlsVersion: '1.0'
      ftpsState: 'AllAllowed'
      netFrameworkVersion: 'v8.0'
      vnetRouteAllEnabled: vnetEnabled
    }
  }
}

// ─── Function App ─────────────────────────────────────────────────────────────

resource functionStorageName 'Microsoft.Storage/storageAccounts@2023-04-01' = if (deployFunctionApp) {
  name: '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 8))}fn${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {}
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
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: false
    siteConfig: {
      minTlsVersion: '1.0'
      ftpsState: 'AllAllowed'
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
    }
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
  properties: {}
}

resource logicApp 'Microsoft.Web/sites@2023-01-01' = if (deployLogicApp) {
  name: '${prefix}-logicapp'
  location: location
  tags: tags
  kind: 'workflowapp,functionapp'
  properties: {
    serverFarmId: logicAppPlan.id
    httpsOnly: false
    virtualNetworkSubnetId: vnetEnabled ? appServiceSubnetId : null
    siteConfig: {
      minTlsVersion: '1.0'
      ftpsState: 'AllAllowed'
      vnetRouteAllEnabled: vnetEnabled
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
    }
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output windowsWebAppId string = deployWindowsApp ? windowsWebApp.id : ''
output windowsWebAppHostname string = deployWindowsApp ? windowsWebApp!.properties.defaultHostName : ''
output functionAppId string = deployFunctionApp ? functionApp.id : ''
output functionAppHostname string = deployFunctionApp ? functionApp!.properties.defaultHostName : ''
output logicAppId string = deployLogicApp ? logicApp.id : ''
output logicAppHostname string = deployLogicApp ? logicApp!.properties.defaultHostName : ''

