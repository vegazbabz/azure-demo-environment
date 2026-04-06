// ─── storage.bicep ───────────────────────────────────────────────────────────
// Deploys: General-purpose v2 Storage Account (Blob, Queue, Table, Files),
//          Data Lake Storage Gen2 (separate account, HNS enabled),
//          Azure File Share.
//
// DEFAULT MODE: No HTTPS-only enforcement, no TLS minimum version, public blob
//               access as Azure defaults, shared key access enabled,
//               no soft delete, no versioning. Out-of-the-box settings.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Enable blob soft delete and versioning.')
param enableSoftDelete bool = false

@description('Enable Data Lake Gen2 storage account.')
param enableDataLake bool = true

@description('Private endpoint subnet resource ID for private endpoint connectivity.')
#disable-next-line no-unused-params
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource ID for blob storage (privatelink.blob.core.windows.net).')
#disable-next-line no-unused-params
param blobDnsZoneId string = ''

@description('Private DNS zone resource ID for file storage (privatelink.file.core.windows.net).')
#disable-next-line no-unused-params
param fileDnsZoneId string = ''

@description('Resource tags.')
param tags object = {}

// ─── General-purpose v2 Storage Account ──────────────────────────────────────

var storageAccountName = '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 12))}${uniqueString(resourceGroup().id)}'
var storageNameTrimmed = substring(storageAccountName, 0, min(length(storageAccountName), 24))

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  name: storageNameTrimmed
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    // Benchmark baseline: HTTPS-only intentionally disabled to expose the
    // Azure-default setting for security comparison testing.
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: false
    allowBlobPublicAccess: true
    allowSharedKeyAccess: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: enableSoftDelete
      days: enableSoftDelete ? 7 : null
    }
    isVersioningEnabled: enableSoftDelete
  }
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {}
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {}
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {}
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-04-01' = {
  parent: fileService
  name: '${prefix}-fileshare'
  properties: {
    shareQuota: 5
    accessTier: 'TransactionOptimized'
  }
}

// ─── Blob Containers ──────────────────────────────────────────────────────────
// Sample containers for dummy data seeding

resource containerData 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-04-01' = {
  parent: blobService
  name: 'data'
  properties: {
    publicAccess: 'None'
  }
}

resource containerLogs 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-04-01' = {
  parent: blobService
  name: 'logs'
  properties: {
    publicAccess: 'None'
  }
}

resource containerPublic 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-04-01' = {
  parent: blobService
  name: 'public'
  properties: {
    publicAccess: 'Blob'
  }
}

// ─── Data Lake Gen2 Storage Account ───────────────────────────────────────────

var dataLakeName = '${substring(replace(toLower(prefix), '-', ''), 0, min(length(replace(toLower(prefix), '-', '')), 10))}dl${uniqueString(resourceGroup().id)}'
var dataLakeNameTrimmed = substring(dataLakeName, 0, min(length(dataLakeName), 24))

resource dataLakeAccount 'Microsoft.Storage/storageAccounts@2023-04-01' = if (enableDataLake) {
  name: dataLakeNameTrimmed
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: false
    allowBlobPublicAccess: true
    allowSharedKeyAccess: true
  }
}

resource dataLakeBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-04-01' = if (enableDataLake) {
  parent: dataLakeAccount
  name: 'default'
  properties: {}
}

resource dataLakeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-04-01' = if (enableDataLake) {
  parent: dataLakeBlobService
  name: 'raw'
  properties: {
    publicAccess: 'None'
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output storageAccountPrimaryEndpoint string = storageAccount.properties.primaryEndpoints.blob
output dataLakeAccountId string = enableDataLake ? dataLakeAccount.id : ''
output dataLakeAccountName string = enableDataLake ? dataLakeAccount.name : ''

