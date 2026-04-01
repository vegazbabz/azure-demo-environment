// ─── databases.bicep ─────────────────────────────────────────────────────────
// Deploys: Azure SQL Server + Serverless DB, Cosmos DB (serverless),
//          PostgreSQL Flexible Server, MySQL Flexible Server (optional),
//          Redis Cache (optional).
//
// DEFAULT MODE: Public network access enabled, no forced TLS minimum,
//               no auditing, no threat detection, no CMK. Out-of-the-box settings.
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

@description('Deploy Cosmos DB (serverless).')
param deployCosmos bool = true

@description('Deploy PostgreSQL Flexible Server.')
param deployPostgresql bool = true

@description('Deploy MySQL Flexible Server.')
param deployMysql bool = false

@description('Deploy Redis Cache.')
param deployRedis bool = false

@description('Database subnet resource ID (used for PostgreSQL/MySQL delegation).')
#disable-next-line no-unused-params
param subnetId string = ''

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
    minimalTlsVersion: '1.0'
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
    // Public access — default mode (VNet integration requires private DNS zone)
    network: {
      publicNetworkAccess: 'Enabled'
    }
    highAvailability: { mode: 'Disabled' }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
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
    network: {
      publicNetworkAccess: 'Enabled'
    }
    highAvailability: { mode: 'Disabled' }
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
    minimumTlsVersion: '1.0'
    publicNetworkAccess: 'Enabled'
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output sqlServerId string = deploySql ? sqlServer.id : ''
output sqlServerFqdn string = deploySql ? sqlServer!.properties.fullyQualifiedDomainName : ''
output sqlDatabaseId string = deploySql ? sqlDatabase.id : ''
output sqlDatabaseName string = deploySql ? sqlDatabase.name : ''
output cosmosAccountId string = deployCosmos ? cosmosAccount.id : ''
output cosmosAccountEndpoint string = deployCosmos ? cosmosAccount!.properties.documentEndpoint : ''
output postgresServerId string = deployPostgresql ? postgresServer.id : ''
output postgresServerFqdn string = deployPostgresql ? postgresServer!.properties.fullyQualifiedDomainName : ''
output mysqlServerId string = deployMysql ? mysqlServer.id : ''
output redisCacheId string = deployRedis ? redisCache.id : ''
output redisCacheHostName string = deployRedis ? redisCache!.properties.hostName : ''

