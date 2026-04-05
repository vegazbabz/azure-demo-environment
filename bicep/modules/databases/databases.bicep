// ─── databases.bicep ─────────────────────────────────────────────────────────
// Deploys: Azure SQL (PaaS) by default.
//          Optional: SQL Server on VM (IaaS), Cosmos DB, PostgreSQL, MySQL, Redis.
//
// DEFAULT MODE: SQL PaaS only. All other engines are opt-in via feature flags.
//               Public network access enabled, no forced TLS minimum.
//               SQL uses AdventureWorksLT sample for dummy data.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('SQL Server administrator login.')
param sqlAdminLogin string = 'sqladmin'

@description('SQL Server administrator password.')
@secure()
param sqlAdminPassword string

@description('PostgreSQL administrator login.')
param pgAdminLogin string = 'pgadmin'

@description('PostgreSQL administrator password.')
@secure()
param pgAdminPassword string

@description('Deploy Azure SQL Database.')
param deploySql bool = true

@description('Deploy SQL Server on a Windows VM (IaaS). Requires sqlVmSubnetId or subnetId.')
param deploySqlVm bool = false

@description('Subnet resource ID for the SQL Server VM. Required when deploySqlVm = true. Must NOT be the PG-delegated databases subnet.')
param sqlVmSubnetId string = ''

@description('Deploy Cosmos DB (serverless). Off by default — opt-in only.')
param deployCosmos bool = false

@description('Deploy PostgreSQL Flexible Server. Off by default — opt-in only.')
param deployPostgresql bool = false

@description('Deploy MySQL Flexible Server.')
param deployMysql bool = false

@description('Deploy Redis Cache.')
param deployRedis bool = false

@description('Database subnet resource ID (used for PostgreSQL VNet injection — requires Microsoft.DBforPostgreSQL/flexibleServers delegation).')
param subnetId string = ''

@description('MySQL subnet resource ID for VNet injection (requires Microsoft.DBforMySQL/flexibleServers delegation).')
param mysqlSubnetId string = ''

@description('Private DNS zone resource ID for PostgreSQL VNet injection (privatelink.postgres.database.azure.com). When empty, falls back to public access with AllowAzureServices rule.')
param postgresDnsZoneId string = ''

@description('Private DNS zone resource ID for MySQL VNet injection (privatelink.mysql.database.azure.com). When empty, falls back to public access with AllowAzureServices rule.')
param mysqlDnsZoneId string = ''

@description('Private endpoint subnet resource ID for private endpoint connectivity.')
#disable-next-line no-unused-params
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource ID for SQL Server (privatelink.database.windows.net).')
#disable-next-line no-unused-params
param sqlDnsZoneId string = ''

@description('Private DNS zone resource ID for Cosmos DB (privatelink.documents.azure.com).')
#disable-next-line no-unused-params
param cosmosDnsZoneId string = ''

@description('Private DNS zone resource ID for Redis Cache (privatelink.redis.cache.windows.net).')
#disable-next-line no-unused-params
param redisDnsZoneId string = ''

@description('Resource tags.')
param tags object = {}

// ─── Azure SQL Server ─────────────────────────────────────────────────────────

resource sqlServer 'Microsoft.Sql/servers@2023-02-01-preview' = if (deploySql) {
  name: '${prefix}-sqlserver'
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    // Public network access enabled (default — no hardening)
    publicNetworkAccess: 'Enabled'
    minimalTlsVersion: '1.2'
  }
}

// Allow Azure services to access SQL (default portal behaviour)
resource sqlFirewallAzureServices 'Microsoft.Sql/servers/firewallRules@2023-02-01-preview' = if (deploySql) {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Open firewall for demo access
resource sqlFirewallAll 'Microsoft.Sql/servers/firewallRules@2023-02-01-preview' = if (deploySql) {
  parent: sqlServer
  name: 'AllowAll'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-02-01-preview' = if (deploySql) {
  parent: sqlServer
  name: '${prefix}-sqldb'
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    // AdventureWorksLT sample database for dummy data
    sampleName: 'AdventureWorksLT'
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: 'Local'
  }
}

// ─── Cosmos DB ────────────────────────────────────────────────────────────────

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = if (deployCosmos) {
  name: '${prefix}-cosmos'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    // Serverless — no provisioned throughput cost
    capabilities: [
      { name: 'EnableServerless' }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    // Public network access enabled (default)
    publicNetworkAccess: 'Enabled'
    enableFreeTier: false
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-11-15' = if (deployCosmos) {
  parent: cosmosAccount
  name: '${prefix}-db'
  properties: {
    resource: { id: '${prefix}-db' }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = if (deployCosmos) {
  parent: cosmosDatabase
  name: 'items'
  properties: {
    resource: {
      id: 'items'
      partitionKey: {
        paths: ['/id']
        kind: 'Hash'
      }
    }
  }
}

// ─── PostgreSQL Flexible Server ───────────────────────────────────────────────
// Private mode: VNet injection using the PG-delegated databases subnet + private DNS zone.
// Public mode (fallback): AllowAzureServices firewall rule.

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = if (deployPostgresql) {
  name: '${prefix}-postgres'
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: pgAdminLogin
    administratorLoginPassword: pgAdminPassword
    version: '16'
    storage: { storageSizeGB: 32 }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: empty(postgresDnsZoneId) ? {
      publicNetworkAccess: 'Enabled'
    } : {
      publicNetworkAccess: 'Disabled'
      delegatedSubnetResourceId: subnetId
      privateDnsZoneArmResourceId: postgresDnsZoneId
    }
    highAvailability: { mode: 'Disabled' }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
  }
}

// AllowAzureServices firewall rule — only applied in public mode
resource postgresFirewallAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = if (deployPostgresql && empty(postgresDnsZoneId)) {
  parent: postgresServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = if (deployPostgresql) {
  parent: postgresServer
  name: '${prefix}db'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// ─── MySQL Flexible Server ────────────────────────────────────────────────────
// Private mode: VNet injection using the MySQL-delegated subnet + private DNS zone.
// Public mode (fallback): AllowAzureServices firewall rule.

resource mysqlServer 'Microsoft.DBforMySQL/flexibleServers@2023-06-30' = if (deployMysql) {
  name: '${prefix}-mysql'
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: pgAdminLogin
    administratorLoginPassword: pgAdminPassword
    version: '8.0.21'
    storage: { storageSizeGB: 20, autoGrow: 'Enabled' }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: empty(mysqlDnsZoneId) ? {} : {
      delegatedSubnetResourceId: mysqlSubnetId
      privateDnsZoneResourceId: mysqlDnsZoneId
    }
    highAvailability: { mode: 'Disabled' }
  }
}

// AllowAzureServices firewall rule — only applied in public mode
resource mysqlFirewallAzureServices 'Microsoft.DBforMySQL/flexibleServers/firewallRules@2023-06-30' = if (deployMysql && empty(mysqlDnsZoneId)) {
  parent: mysqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource mysqlDatabase 'Microsoft.DBforMySQL/flexibleServers/databases@2023-06-30' = if (deployMysql) {
  parent: mysqlServer
  name: '${prefix}db'
  properties: {
    charset: 'utf8'
    collation: 'utf8_general_ci'
  }
}

// ─── Redis Cache ──────────────────────────────────────────────────────────────

resource redisCache 'Microsoft.Cache/redis@2023-08-01' = if (deployRedis) {
  name: '${prefix}-redis'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 0
    }
    enableNonSslPort: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

// ─── SQL Server on VM (IaaS) ──────────────────────────────────────────────────

// SQL VM NIC uses sqlVmSubnetId directly. Leaving it empty when deploySqlVm = true
// causes an ARM validation failure — intentional to prevent silent misconfiguration.
var sqlVmEffectiveSubnetId = sqlVmSubnetId

resource sqlVmPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (deploySqlVm) {
  name: '${prefix}-sqlvm-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource sqlVmNic 'Microsoft.Network/networkInterfaces@2023-09-01' = if (deploySqlVm) {
  name: '${prefix}-sqlvm-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: sqlVmEffectiveSubnetId }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: sqlVmPublicIp.id }
        }
      }
    ]
  }
}


resource sqlVm 'Microsoft.Compute/virtualMachines@2023-09-01' = if (deploySqlVm) {
  name: '${prefix}-sqlvm'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2s_v3' }
    osProfile: {
      computerName: '${prefix}sqlvm'
      adminUsername: sqlAdminLogin
      adminPassword: sqlAdminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: 'sql2022-ws2022'
        sku: 'standard-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: sqlVmNic.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

// SQL IaaS Agent — enables SQL Server management in the Azure portal
resource sqlVmIaasExtension 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2022-07-01-preview' = if (deploySqlVm) {
  name: '${prefix}-sqlvm'
  location: location
  tags: tags
  properties: {
    virtualMachineResourceId: sqlVm.id
    sqlServerLicenseType: 'PAYG'
    sqlManagement: 'Full'
    sqlImageSku: 'Standard'
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output sqlServerId string = deploySql ? sqlServer.id : ''
output sqlServerFqdn string = deploySql ? sqlServer!.properties.fullyQualifiedDomainName : ''
output sqlDatabaseId string = deploySql ? sqlDatabase.id : ''
output sqlDatabaseName string = deploySql ? sqlDatabase.name : ''
output sqlVmId string = deploySqlVm ? sqlVm.id : ''
output sqlVmName string = deploySqlVm ? sqlVm.name : ''
output cosmosAccountId string = deployCosmos ? cosmosAccount.id : ''
output cosmosAccountEndpoint string = deployCosmos ? cosmosAccount!.properties.documentEndpoint : ''
output postgresServerId string = deployPostgresql ? postgresServer.id : ''
output postgresServerFqdn string = deployPostgresql ? postgresServer!.properties.fullyQualifiedDomainName : ''
output mysqlServerId string = deployMysql ? mysqlServer.id : ''
output redisCacheId string = deployRedis ? redisCache.id : ''
output redisCacheHostName string = deployRedis ? redisCache!.properties.hostName : ''

