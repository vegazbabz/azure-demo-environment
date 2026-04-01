// ─── monitoring.bicep ────────────────────────────────────────────────────────
// Deploys: Log Analytics Workspace, Application Insights, Action Group.
//          Optional: Alert rules.
//
// DEFAULT MODE: Minimal configuration. No diagnostic settings pushed to other
//               resources. No forced data collection rules. Log Analytics is
//               available for opt-in use by other modules.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Email address to receive alert notifications.')
param alertEmailAddress string = 'admin@example.com'

@description('Log Analytics Workspace retention in days.')
param retentionDays int = 30

@description('Deploy alert rules.')
param deployAlertRules bool = false

@description('Resource tags.')
param tags object = {}

// ─── Log Analytics Workspace ──────────────────────────────────────────────────

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
    // No daily cap — default behaviour
    workspaceCapping: { dailyQuotaGb: -1 }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ─── Application Insights ─────────────────────────────────────────────────────

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ─── Action Group ─────────────────────────────────────────────────────────────

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${prefix}-ag'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'ade-alerts'
    enabled: true
    emailReceivers: [
      {
        name: 'admin-email'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

// ─── Alert Rules (optional) ───────────────────────────────────────────────────
// Basic resource health alerts. Off by default.

resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (deployAlertRules) {
  name: '${prefix}-service-health-alert'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    scopes: [subscription().id]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: actionGroup.id }
      ]
    }
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output logAnalyticsId string = logAnalyticsWorkspace.id
output logAnalyticsName string = logAnalyticsWorkspace.name
output appInsightsId string = appInsights.id
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output actionGroupId string = actionGroup.id

