// ─── automation-role.bicep ────────────────────────────────────────────────────
// Grants the Automation Account Contributor role at subscription scope so that
// runbooks can start/stop VMs in any resource group.
// Must be a separate module because the parent governance.bicep is RG-scoped.
// ─────────────────────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('Principal ID of the Automation Account managed identity.')
param automationPrincipalId string

@description('Resource ID of the Automation Account (used as deduplication seed for the role assignment GUID).')
param automationAccountId string

resource automationContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().subscriptionId, automationAccountId, 'contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
    principalId: automationPrincipalId
    principalType: 'ServicePrincipal'
  }
}
