// ─── hardened/storage/storage.bicep ──────────────────────────────────────────
// Deploys: General-purpose v2 Storage Account (Blob, Queue, Table, Files),
//          Data Lake Storage Gen2 (separate account, HNS enabled),
//          Azure File Share.
//
// HARDENED MODE: HTTPS-only, TLS 1.2 minimum, no public blob access,
//               shared key access disabled (RBAC-based access only),
//               blob soft delete (30 days), versioning enabled,
//               no publicly accessible containers.
//               Aligns with: CIS 3.x, MCSB DP-3, DP-4, NS-1.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Enable blob soft delete and versioning. Hardened: always on.')
#disable-next-line no-unused-params
param enableSoftDelete bool = true    // Hardened: on

@description('Enable Data Lake Gen2 storage account.')
param enableDataLake bool = true

@description('Log Analytics workspace resource ID for diagnostic settings.')
param logAnalyticsId string = ''

@description('Private endpoint subnet resource ID. When set, private endpoints for blob and Data Lake blob are deployed.')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource ID for blob storage (privatelink.blob.core.windows.net).')
param blobDnsZoneId string = ''

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
    // Hardened: HTTPS-only (CIS 3.1)
    supportsHttpsTrafficOnly: true
    // Hardened: TLS 1.2 minimum (CIS 3.2)
    minimumTlsVersion: 'TLS1_2'
    // Hardened: no anonymous public blob access (CIS 3.5)
    allowBlobPublicAccess: false
    // Hardened: disable shared key — use RBAC (Entra ID) only (MCSB IM-3)
    // NOTE: If any workloads use connection strings, grant Storage Blob/Queue Data roles instead.
    allowSharedKeyAccess: false
    // Hardened: disable public network access entirely (CIS 3.7, MCSB NS-1)
    publicNetworkAccess: 'Disabled'
    // Hardened: network ACLs — deny all by default; accept only from VNet/private endpoints
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    // Hardened: 30-day soft delete (CIS 3.8)
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    // Hardened: versioning enabled (CIS 3.9)
    isVersioningEnabled: true
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
  properties: {
    // Hardened: enable soft delete on file shares
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
  }
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
// Hardened: no public-access containers

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

// Hardened: 'public' container removed — no public blob access in hardened mode

// ─── Storage Account Diagnostic Settings ──────────────────────────────────────

resource storageDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsId)) {
  name: '${prefix}-storage-diag'
  scope: storageAccount
  properties: {
    workspaceId: logAnalyticsId
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
      {
        category: 'Capacity'
        enabled: true
      }
    ]
  }
}

resource blobDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsId)) {
  name: '${prefix}-blob-diag'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

// ─── Data Lake Gen2 Storage Account ───────────────────────────────────────────
// Hardened: same security properties as general storage

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
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    // Hardened: disable public network access entirely
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource dataLakeBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-04-01' = if (enableDataLake) {
  parent: dataLakeAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    isVersioningEnabled: true
  }
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
output dataLakeId string = enableDataLake ? dataLakeAccount.id : ''
output dataLakeName string = enableDataLake ? dataLakeAccount.name : ''

// ─── Private Endpoints ────────────────────────────────────────────────────────
// Required: storage has publicNetworkAccess: 'Disabled' and allowSharedKeyAccess: false
// Callers inside the VNet reach storage only via these private endpoints + DNS zones.

resource storageBlobPe 'Microsoft.Network/privateEndpoints@2023-09-01' = if (!empty(privateEndpointSubnetId)) {
  name: '${prefix}-storage-blob-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-storage-blob-plsc'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource storageBlobPeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (!empty(privateEndpointSubnetId) && !empty(blobDnsZoneId)) {
  parent: storageBlobPe
  name: 'blob-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: { privateDnsZoneId: blobDnsZoneId }
      }
    ]
  }
}

resource dataLakeBlobPe 'Microsoft.Network/privateEndpoints@2023-09-01' = if (enableDataLake && !empty(privateEndpointSubnetId)) {
  name: '${prefix}-datalake-blob-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-datalake-blob-plsc'
        properties: {
          privateLinkServiceId: dataLakeAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource dataLakeBlobPeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (enableDataLake && !empty(privateEndpointSubnetId) && !empty(blobDnsZoneId)) {
  parent: dataLakeBlobPe
  name: 'datalake-blob-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: { privateDnsZoneId: blobDnsZoneId }
      }
    ]
  }
}
