// ─── secrets.bicep ────────────────────────────────────────────────────────────
// Writes per-service admin-password secrets into the environment Key Vault.
//
// Deployed by deploy.ps1 (Resolve-AdeServicePasswords) into <prefix>-security-rg
// for BOTH default and hardened modes — the write goes through the ARM control
// plane, so it succeeds even when the hardened vault firewall blocks the
// deployer's data-plane access (publicNetworkAccess: 'Disabled').
//
// NOTE: five discrete @secure() params instead of one object — Bicep does not
// allow loops over @secure() values, and discrete params are auto-routed
// through the temp JSON parameter file by Invoke-AdeBicepDeployment (any param
// name matching *password* is never passed inline on the command line).
// Each secret is only created/updated when its param is non-empty.
// ─────────────────────────────────────────────────────────────────────────────

@description('Name of the existing Key Vault in this resource group.')
param keyVaultName string

@description('VM / VMSS / Domain Controller local admin password. Empty = do not write.')
@secure()
param vmAdminPassword string = ''

@description('Azure SQL administrator password. Empty = do not write.')
@secure()
param sqlAdminPassword string = ''

@description('PostgreSQL Flexible Server administrator password. Empty = do not write.')
@secure()
param postgresAdminPassword string = ''

@description('MySQL Flexible Server administrator password. Empty = do not write.')
@secure()
param mysqlAdminPassword string = ''

@description('Synapse workspace SQL administrator password. Empty = do not write.')
@secure()
param synapseAdminPassword string = ''

@description('Resource tags.')
param tags object = {}

var contentType = 'ADE per-service admin password'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource vmSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(vmAdminPassword)) {
  parent: vault
  name: 'vm-admin-password'
  tags: tags
  properties: {
    value: vmAdminPassword
    contentType: contentType
  }
}

resource sqlSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(sqlAdminPassword)) {
  parent: vault
  name: 'sql-admin-password'
  tags: tags
  properties: {
    value: sqlAdminPassword
    contentType: contentType
  }
}

resource postgresSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(postgresAdminPassword)) {
  parent: vault
  name: 'postgres-admin-password'
  tags: tags
  properties: {
    value: postgresAdminPassword
    contentType: contentType
  }
}

resource mysqlSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(mysqlAdminPassword)) {
  parent: vault
  name: 'mysql-admin-password'
  tags: tags
  properties: {
    value: mysqlAdminPassword
    contentType: contentType
  }
}

resource synapseSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(synapseAdminPassword)) {
  parent: vault
  name: 'synapse-admin-password'
  tags: tags
  properties: {
    value: synapseAdminPassword
    contentType: contentType
  }
}

output keyVaultName string = keyVaultName
