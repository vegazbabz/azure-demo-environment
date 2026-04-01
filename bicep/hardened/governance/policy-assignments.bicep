// ─── hardened/governance/policy-assignments.bicep ────────────────────────────
// Assigns built-in CIS and MCSB policy initiatives at subscription scope.
//
// HARDENED MODE: Enforcement mode 'Default' — policies are actively enforced
//               (deny effects applied). This will BLOCK non-compliant resource
//               creation. Use with caution — review initiative exclusions before
//               enabling in shared subscriptions.
//               Aligns with: MCSB GS-1, GS-2.
// ────────────────────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('Resource prefix for assignment naming.')
param prefix string

// ─── CIS Azure Foundations Benchmark v2.0 ────────────────────────────────────

var cisBenchmarkId = '/providers/Microsoft.Authorization/policySetDefinitions/612b5213-9160-4969-8578-1518bd2a000c'

resource cisAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${prefix}-cis-foundations'
  location: 'global'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    policyDefinitionId: cisBenchmarkId
    displayName: '[ADE Hardened] CIS Azure Foundations Benchmark v2.0'
    description: 'Assigned by Azure Demo Environment (hardened mode) — actively enforced.'
    // Hardened: Default enforcement — deny effects are applied (CIS actively enforced)
    enforcementMode: 'Default'
    parameters: {}
    nonComplianceMessages: [
      {
        message: 'Resource blocked: non-compliant with CIS Azure Foundations Benchmark v2.0 (ADE hardened mode).'
      }
    ]
  }
}

// ─── Microsoft Cloud Security Benchmark ──────────────────────────────────────

var mcssBenchmarkId = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'

resource mcssAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${prefix}-mcsb'
  location: 'global'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    policyDefinitionId: mcssBenchmarkId
    displayName: '[ADE Hardened] Microsoft Cloud Security Benchmark'
    description: 'Assigned by Azure Demo Environment (hardened mode) — actively enforced.'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// ─── Defender for Cloud auto-provisioning policy ──────────────────────────────

var defenderProvisioning = '/providers/Microsoft.Authorization/policyDefinitions/d367bd60-64ca-4364-98ea-276775bddd37'

resource defenderProvisioningAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${prefix}-defender-provisioning'
  location: 'global'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    policyDefinitionId: defenderProvisioning
    displayName: '[ADE Hardened] Auto-provision Defender agents'
    // Hardened: actively enforce Defender agent provisioning
    enforcementMode: 'Default'
    parameters: {}
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output cisAssignmentId string = cisAssignment.id
output mcssAssignmentId string = mcssAssignment.id
