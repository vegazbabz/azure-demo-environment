// ─── automation-role.bicep ────────────────────────────────────────────────────
// Grants the Automation Account Virtual Machine Contributor role at subscription
// scope so that runbooks can start/stop VMs and VMSS in any resource group.
// Subscription scope is required because demo VMs/VMSS span multiple RGs.
// Must be a separate module because the parent governance.bicep is RG-scoped.
// ─────────────────────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('Principal ID of the Automation Account managed identity.')
param automationPrincipalId string

resource automationVmContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Seed on principalId (not accountId) so a new system-assigned MI after
  // resource recreation produces a new GUID instead of colliding with the
  // orphaned assignment from the previous MI.
  name: guid(subscription().subscriptionId, automationPrincipalId, '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c') // Virtual Machine Contributor
    principalId: automationPrincipalId
    principalType: 'ServicePrincipal'
  }
}
