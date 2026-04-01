// ─── policy-assignments.bicep ─────────────────────────────────────────────────
// Assigns built-in CIS policy initiatives at subscription scope.
// CIS Azure Foundations Benchmark v2.0 + supplementary initiatives.
// ────────────────────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('Resource prefix for assignment naming.')
param prefix string

// ─── CIS Azure Foundations Benchmark v2.0 ────────────────────────────────────
// Built-in initiative ID (static across all tenants)
// /providers/Microsoft.Authorization/policySetDefinitions/<id>

var cisBenchmarkId = '/providers/Microsoft.Authorization/policySetDefinitions/612b5213-9160-4969-8578-1518bd2a000c'

resource cisAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${prefix}-cis-foundations'
  location: 'global'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    policyDefinitionId: cisBenchmarkId
    displayName: '[ADE] CIS Azure Foundations Benchmark v2.0'
    description: 'Assigned by Azure Demo Environment for CIS compliance testing.'
    enforcementMode: 'DoNotEnforce'                       // Audit only — no deny effects
    parameters: {}
    nonComplianceMessages: [
      {
        message: 'Resource is non-compliant with CIS Azure Foundations Benchmark v2.0. Review and remediate.'
      }
    ]
  }
}

// ─── Microsoft Cloud Security Benchmark ──────────────────────────────────────
// Successor to Azure Security Benchmark, also covers CIS controls

var mcssBenchmarkId = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'

resource mcssAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${prefix}-mcsb'
  location: 'global'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    policyDefinitionId: mcssBenchmarkId
    displayName: '[ADE] Microsoft Cloud Security Benchmark'
    description: 'Assigned by Azure Demo Environment for MCSB compliance coverage.'
    enforcementMode: 'DoNotEnforce'
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
    displayName: '[ADE] Auto-provision Defender agents'
    enforcementMode: 'DoNotEnforce'
    parameters: {}
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output cisAssignmentId string = cisAssignment.id
output mcssAssignmentId string = mcssAssignment.id
