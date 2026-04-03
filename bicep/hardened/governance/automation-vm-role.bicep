// ─── automation-vm-role.bicep ─────────────────────────────────────────────────
// Assigns Virtual Machine Contributor to an Automation Account managed identity.
// Deployed as a separate module so it can be scoped to the compute resource group
// (cross-RG scope assignment is not allowed on inline resources in Bicep).
// ─────────────────────────────────────────────────────────────────────────────

@description('Principal ID of the Automation Account system-assigned managed identity.')
param automationPrincipalId string

@description('Resource ID of the Automation Account (used as GUID seed).')
param automationAccountId string

// Virtual Machine Contributor — allows start/deallocate but not subscription-level changes
resource vmContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccountId, 'vmcontributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c515-11e4-8731-1281d0574441')
    principalId: automationPrincipalId
    principalType: 'ServicePrincipal'
  }
}
