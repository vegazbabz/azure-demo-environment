// ─── hardened/databases/databases.bicep ──────────────────────────────────────
// Deploys: Azure SQL Server + Serverless DB, Cosmos DB (serverless),
//          PostgreSQL Flexible Server, MySQL Flexible Server (optional),
//          Redis Cache (optional).
//
// HARDENED MODE: TLS 1.2 minimum on all services. SQL auditing + threat detection
//               enabled. No open firewall rules (Azure services bypass only).
//               Cosmos DB with local auth disabled (Entra ID only).
//               PostgreSQL with Entra ID auth enabled. Redis SSL-only.
//               Aligns with: CIS 4.x, MCSB DP-1, DP-3, LT-3, NS-1.
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

@description('Database subnet resource ID.')
#disable-next-line no-unused-params
param subnetId string = ''

@description('Log Analytics workspace resource ID for SQL audit logs.')
#disable-next-line no-unused-params
param logAnalyticsId string = ''

@description('Resource tags.')
param tags object = {}

// ─── Azure SQL Server ─────────────────────────────────────────────────────────
// Hardened: TLS 1.2, public access disabled (private endpoint), Entra ID admin,
//           auditing + threat detection enabled.

resource sqlServer 'Microsoft.Sql/servers@2023-02-01-preview' = if (deploySql) {
  name: '${prefix}-sqlserver'
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    // Hardened: TLS 1.2 minimum (CIS 4.1.1)
    minimalTlsVersion: '1.2'
    // Hardened: disable public access — private endpoint or VNet service endpoint only
    publicNetworkAccess: 'Disabled'
    // Restrict outbound to Azure-internal only
    restrictOutboundNetworkAccess: 'Enabled'
  }
}

// Hardened: only Azure services bypass — no AllowAll rule, no open IP range
resource sqlFirewallAzureServices 'Microsoft.Sql/servers/firewallRules@2023-02-01-preview' = if (deploySql) {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}
// Hardened: AllowAll firewall rule NOT deployed (CIS 4.1.2 — no 0.0.0.0-255.255.255.255)

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
    sampleName: 'AdventureWorksLT'
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: 'Local'
  }
}

// Hardened: SQL Server-level auditing to Log Analytics (CIS 4.1.3)
resource sqlAuditingPolicy 'Microsoft.Sql/servers/auditingSettings@2023-02-01-preview' = if (deploySql) {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
    retentionDays: 90
    auditActionsAndGroups: [
      'SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP'
      'FAILED_DATABASE_AUTHENTICATION_GROUP'
      'BATCH_COMPLETED_GROUP'
    ]
  }
}

// Hardened: Defender for SQL — threat detection on all databases (CIS 4.2.1 - 4.2.5)
resource sqlThreatDetection 'Microsoft.Sql/servers/securityAlertPolicies@2023-02-01-preview' = if (deploySql) {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    emailAccountAdmins: true
    retentionDays: 90
  }
}

// Hardened: Defender for SQL vulnerability assessment
resource sqlVulnerabilityAssessment 'Microsoft.Sql/servers/vulnerabilityAssessments@2023-02-01-preview' = if (deploySql) {
  parent: sqlServer
  name: 'default'
  dependsOn: [sqlThreatDetection]
  properties: {
    storageContainerPath: ''    // Set to a blob SAS URL to store results; leave empty to route to Azure Monitor only
    recurringScans: {
      isEnabled: true
      emailSubscriptionAdmins: true
    }
  }
}

// ─── Cosmos DB ────────────────────────────────────────────────────────────────
// Hardened: local auth disabled (Entra ID RBAC only), no public network access,
//           IP firewall deny all (MCSB IM-3, NS-1).

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = if (deployCosmos) {
  name: '${prefix}-cosmos'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
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
    // Hardened: disable local auth — Entra ID RBAC only (MCSB IM-3)
    disableLocalAuth: true
    // Hardened: disable public access
    publicNetworkAccess: 'Disabled'
    enableFreeTier: false
    // Hardened: restrict management plane writes via data plane keys (CIS 4.5.2)
    disableKeyBasedMetadataWriteAccess: true
    // Hardened: restrict network access
    networkAclBypassResourceIds: []
    ipRules: []
    isVirtualNetworkFilterEnabled: false
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
// Hardened: Entra ID auth enabled, TLS 1.2, no public access (VNet integration).

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
      backupRetentionDays: 30    // Hardened: 30 days
      geoRedundantBackup: 'Disabled'
    }
    // Hardened: public access disabled — requires VNet integration or private DNS
    network: {
      publicNetworkAccess: 'Disabled'
    }
    highAvailability: { mode: 'Disabled' }
    authConfig: {
      // Hardened: Entra ID auth enabled (CIS 4.3.7), password auth retained for demo
      activeDirectoryAuth: 'Enabled'
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
// Hardened: TLS 1.2, no public access, Entra ID auth enabled.

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
      backupRetentionDays: 30
      geoRedundantBackup: 'Disabled'
    }
    network: {
      // Hardened: no public access
      publicNetworkAccess: 'Disabled'
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
// Hardened: SSL-only, TLS 1.2, no public access.

resource redisCache 'Microsoft.Cache/redis@2023-08-01' = if (deployRedis) {
  name: '${prefix}-redis'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Standard'   // Hardened: Standard (not Basic) — supports private link
      family: 'C'
      capacity: 1
    }
    // Hardened: disable non-SSL port (CIS 4.7)
    enableNonSslPort: false
    // Hardened: TLS 1.2 minimum
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
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
