// ─── governance.bicep ────────────────────────────────────────────────────────
// Deploys: Automation Account (auto-stop/start runbooks + schedules),
//          Optional: Azure Policy initiative assignment, Monthly budget alerts,
//          Resource locks on networking RG
// Default settings — no hardening, no forced diagnostics.
// ────────────────────────────────────────────────────────────────────────────

@description('Resource prefix.')
param prefix string

@description('Azure region.')
param location string = resourceGroup().location

@description('Log Analytics Workspace resource ID (for optional diagnostics).')
param logAnalyticsId string = ''

@description('Deploy Automation Account with auto-stop/start runbooks.')
param enableAutomation bool = true

@description('Assign Azure Policy initiatives (e.g. CIS Benchmark).')
param enablePolicyAssignments bool = false

@description('Enable monthly budget with email alerts.')
param enableBudget bool = true

@description('Enable ReadOnly resource lock on the networking resource group.')
#disable-next-line no-unused-params
param enableResourceLocks bool = false

@description('Monthly budget amount in USD.')
param budgetAmount int = 300

@description('Budget alert email address.')
param budgetAlertEmail string = ''

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

@description('Compute resource group name (hardened mode — used for VM Contributor role scope).')
#disable-next-line no-unused-params
param computeResourceGroupName string = '${prefix}-compute-rg'

@description('Base URL for runbook script content (hardened mode).')
#disable-next-line no-unused-params
param runbooksBaseUrl string = ''

@description('Allow the role assignment for the Automation Account managed identity. Requires Owner or User Access Administrator on the subscription. Set to false when deploying with Contributor-only credentials.')
param enableAutomationRoleAssignment bool = false

// ─── Automation Account ───────────────────────────────────────────────────────

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
    publicNetworkAccess: true
    disableLocalAuth: false
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

// Grant Automation Account Contributor role at subscription scope so runbooks can
// manage VMs in any resource group. Deployed via a sub-module because this file
// is resource-group scoped and subscription-scoped resources require a separate module.
// Guarded by enableAutomationRoleAssignment — requires Owner or User Access Administrator.
module automationContributorRole 'automation-role.bicep' = if (enableAutomation && enableAutomationRoleAssignment) {
  name: '${prefix}-automation-role'
  scope: subscription()
  params: {
    automationPrincipalId: automationAccount!.identity.principalId
    automationAccountId: automationAccount!.id
  }
}

// Automation Account diagnostic settings — only if Log Analytics is provided
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
// Content uploaded post-deployment via deploy.ps1 from scripts/runbooks/Stop-AdeResources.ps1

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

// Parse shutdown time HHMM -> HH:MM
var shutdownHour = int(substring(autoShutdownTime, 0, 2))
var shutdownMinute = int(substring(autoShutdownTime, 2, 2))
var scheduleDatePrefix = substring(dateTimeAdd(deploymentTime, 'P1D'), 0, 11) // tomorrow's date + 'T'

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
// (Azure Automation does not allow linking schedules to draft/unpublished runbooks)

// ─── Budget Alert ─────────────────────────────────────────────────────────────
// Deployed at subscription scope via nested module

module budgetModule 'budget.bicep' = if (enableBudget) {
  name: 'ade-budget'
  scope: subscription()
  params: {
    prefix: prefix
    monthlyBudgetUsd: budgetAmount
    alertEmail: budgetAlertEmail
    thresholds: [50, 80, 100]
  }
}

// ─── CIS Policy Initiative Assignment ────────────────────────────────────────
// Assigns the built-in CIS Microsoft Azure Foundations Benchmark initiative

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
