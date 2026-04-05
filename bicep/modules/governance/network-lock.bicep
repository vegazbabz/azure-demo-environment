// network-lock.bicep — CanNotDelete lock applied to the resource group this module is scoped to.
// Called by governance.bicep scoped to the networking resource group.
// Requires Microsoft.Authorization/locks write permission (Owner or User Access Administrator).

@description('Resource prefix for lock naming.')
param prefix string

resource lock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: '${prefix}-ade-lock'
  properties: {
    level: 'CanNotDelete'
    notes: 'ADE resource lock — managed by governance module. Prevents accidental deletion.'
  }
}
