// ─── hardened/governance/governance.bicep ────────────────────────────────────
// Deploys: Automation Account (auto-stop/start runbooks + schedules),
//          Optional: Azure Policy initiative assignment (enforced), monthly budget,
//          Resource locks on networking RG.
//
// HARDENED MODE: Automation Account with local auth disabled + no public network
//               access. Policy assignments in 'Default' enforcement mode (active
//               deny). Resource locks ENABLED by default. Diagnostic settings on
//               Automation Account.
//               Aligns with: MCSB AM-4, GS-1, GS-2.
// ────────────────────────────────────────────────────────────────────────────

@description('Resource prefix.')
param prefix string

@description('Azure region.')
param location string = resourceGroup().location

@description('Log Analytics Workspace resource ID (for diagnostics).')
param logAnalyticsId string = ''

@description('Deploy Automation Account with auto-stop/start runbooks.')
param enableAutomation bool = true

@description('Assign Azure Policy initiatives in Default (enforced) mode.')
param enablePolicyAssignments bool = true     // Hardened: on by default

@description('Enable monthly budget with email alerts.')
param enableBudget bool = true

@description('Enable ReadOnly resource lock on the networking resource group.')
param enableResourceLocks bool = true    // Hardened: on by default

@description('Monthly budget amount in USD.')
param budgetAmount int = 300

@description('Budget alert email address.')
param budgetAlertEmail string = 'ops@example.com'

@description('Resource tags.')
param tags object = {}

@description('Deployment timestamp (auto-set). Used to compute schedule start dates.')
param deploymentTime string = utcNow()

@description('Daily auto-shutdown time in HHMM format (e.g. 1900 = 19:00 UTC).')
param autoShutdownTime string = '1900'

@description('Timezone for daily auto-shutdown/start schedules.')
param autoShutdownTimezone string = 'UTC'

@description('Enable daily auto-start at 08:00 UTC on weekdays.')
param autoStartEnabled bool = false

// ─── Automation Account ───────────────────────────────────────────────────────
// Hardened: local auth disabled, no public network access, system-assigned identity.

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = if (enableAutomation) {
  name: '${prefix}-automation'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    // Hardened: no public network access (MCSB NS-1)
    publicNetworkAccess: false
    // Hardened: disable local authentication (MCSB IM-3)
    disableLocalAuth: true
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

resource automationContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableAutomation) {
  name: guid(subscription().subscriptionId, automationAccount.id, 'contributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: automationAccount!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Hardened: diagnostic settings always enabled when Log Analytics provided
resource automationDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableAutomation && !empty(logAnalyticsId)) {
  name: '${prefix}-automation-diag'
  scope: automationAccount
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ─── Stop Runbook ─────────────────────────────────────────────────────────────

resource stopRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (enableAutomation) {
  parent: automationAccount
  name: 'Stop-AdeResources'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    description: 'Deallocates all ADE VMs, VMSS, and AKS clusters to minimize costs outside working hours.'
    logProgress: true
    logVerbose: false
  }
}

// ─── Start Runbook ────────────────────────────────────────────────────────────

resource startRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (enableAutomation) {
  parent: automationAccount
  name: 'Start-AdeResources'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    description: 'Starts all ADE VMs, VMSS, and AKS clusters at the start of the working day.'
    logProgress: true
    logVerbose: false
  }
}

// ─── Schedules ────────────────────────────────────────────────────────────────

var shutdownHour = int(substring(autoShutdownTime, 0, 2))
var shutdownMinute = int(substring(autoShutdownTime, 2, 2))
var scheduleDatePrefix = substring(dateTimeAdd(deploymentTime, 'P1D'), 0, 11)

resource stopSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (enableAutomation) {
  parent: automationAccount
  name: 'Daily-Stop-${autoShutdownTime}'
  properties: {
    description: 'Daily auto-stop for ADE resources at ${autoShutdownTime} UTC'
    startTime: '${scheduleDatePrefix}${padLeft(shutdownHour, 2, '0')}:${padLeft(shutdownMinute, 2, '0')}:00+00:00'
    expiryTime: '9999-12-31T23:59:00+00:00'
    frequency: 'Day'
    interval: 1
    timeZone: autoShutdownTimezone
    advancedSchedule: {
      weekDays: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
    }
  }
}

resource startSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (enableAutomation && autoStartEnabled) {
  parent: automationAccount
  name: 'Daily-Start-0800'
  properties: {
    description: 'Daily auto-start for ADE resources at 08:00 UTC weekdays'
    startTime: '${scheduleDatePrefix}08:00:00+00:00'
    expiryTime: '9999-12-31T23:59:00+00:00'
    frequency: 'Day'
    interval: 1
    timeZone: autoShutdownTimezone
    advancedSchedule: {
      weekDays: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
    }
  }
}

// Schedule links are created by deploy.ps1 after runbooks are published

// ─── ReadOnly Resource Lock — Networking RG ────────────────────────────────────
// Hardened: prevents accidental modification of networking resources.
// Lock targets the governance RG (networking RG is a separate resource group —
// locks must be applied from within that RG or via a cross-RG deployment).
// Here we lock the current (governance) RG as a reference implementation.

resource governanceLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableResourceLocks) {
  name: '${prefix}-governance-lock'
  properties: {
    level: 'ReadOnly'
    notes: 'ADE hardened mode: governance resource group locked read-only to prevent accidental changes.'
  }
}

// ─── Budget Alert ─────────────────────────────────────────────────────────────

module budgetModule '../../modules/governance/budget.bicep' = if (enableBudget) {
  name: 'ade-budget'
  scope: subscription()
  params: {
    prefix: prefix
    monthlyBudgetUsd: budgetAmount
    alertEmail: budgetAlertEmail
    thresholds: [50, 80, 100]
  }
}

// ─── CIS Policy Initiative Assignment ─────────────────────────────────────────
// Hardened: enforcement mode Default (deny effects applied)

module policyModule 'policy-assignments.bicep' = if (enablePolicyAssignments) {
  name: 'ade-policy-assignments'
  scope: subscription()
  params: {
    prefix: prefix
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output automationAccountId string = enableAutomation ? automationAccount.id : ''
output automationAccountName string = enableAutomation ? automationAccount.name : ''
