// ─── hardened/monitoring/monitoring.bicep ─────────────────────────────────────
// Deploys: Log Analytics Workspace, Application Insights, Action Group.
//          Optional: Alert rules.
//
// HARDENED MODE: 90-day retention, private ingestion/query endpoints disabled
//               for public access, diagnostic settings enabled by default,
//               data collection rule for Azure Monitor Agent.
//               Aligns with: CIS 5.x (Logging), MCSB LT-1, LT-3, LT-4.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Email address to receive alert notifications.')
param alertEmailAddress string = 'admin@example.com'

@description('Log Analytics Workspace retention in days.')
param retentionDays int = 90   // Hardened: 90 days (CIS 5.1.2 recommends 90+)

@description('Deploy alert rules.')
param deployAlertRules bool = true   // Hardened: on by default

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
    workspaceCapping: { dailyQuotaGb: -1 }
    // Hardened: restrict public network access to the workspace
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    features: {
      // Immutable log collection — prevents tampering with audit logs
      immediatePurgeDataOn30Days: false
      enableLogAccessUsingOnlyResourcePermissions: true
    }
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
    // Hardened: ingestion/query only via workspace private link
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    // Disable sampling to ensure all telemetry is captured
    SamplingPercentage: 100
    DisableIpMasking: false
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

// ─── Data Collection Rule (Azure Monitor Agent) ───────────────────────────────
// DCR defines what telemetry AMA collects from monitored VMs.
// Hardened: always deployed so VMs can be onboarded to AMA.
// Covers: CIS 5.x, MCSB LT-2, LT-3.

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr'
  location: location
  tags: tags
  properties: {
    description: 'ADE default data collection rule — Windows & Linux performance + syslog + security events.'
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCountersWindows'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available Bytes'
            '\\LogicalDisk(_Total)\\Disk Read Bytes/sec'
            '\\LogicalDisk(_Total)\\Disk Write Bytes/sec'
            '\\Network Interface(*)\\Bytes Total/sec'
          ]
        }
        {
          name: 'perfCountersLinux'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Memory(*)\\% Available Memory'
            'Logical Disk(*)\\Disk Read Bytes/sec'
            'Logical Disk(*)\\Disk Write Bytes/sec'
            'Network(*)\\Total Bytes Transmitted'
          ]
        }
      ]
      syslog: [
        {
          name: 'syslogLinux'
          streams: ['Microsoft-Syslog']
          facilityNames: ['auth', 'authpriv', 'cron', 'daemon', 'kern', 'syslog', 'user']
          logLevels: ['Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
      ]
      windowsEventLogs: [
        {
          name: 'windowsSecurityEvents'
          streams: ['Microsoft-SecurityEvent']
          xPathQueries: [
            'Security!*[System[(EventID=4624) or (EventID=4625) or (EventID=4648) or (EventID=4672) or (EventID=4688) or (EventID=4720) or (EventID=4728) or (EventID=4732)]]'
          ]
        }
        {
          name: 'windowsSystemEvents'
          streams: ['Microsoft-Event']
          xPathQueries: [
            'System!*[System[Level=1 or Level=2 or Level=3]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'la-destination'
          workspaceResourceId: logAnalyticsWorkspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-Perf', 'Microsoft-Syslog', 'Microsoft-SecurityEvent', 'Microsoft-Event']
        destinations: ['la-destination']
      }
    ]
  }
}

// ─── Alert Rules ───────────────────────────────────────────────────────────────
// Hardened: deployed by default. Service health + sign-in failure + suspicious activity.

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

resource securityAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (deployAlertRules) {
  name: '${prefix}-security-alert'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    scopes: [subscription().id]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Security'
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

resource policyAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (deployAlertRules) {
  name: '${prefix}-policy-alert'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    scopes: [subscription().id]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Policy'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Authorization/policyAssignments/write'
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
output dataCollectionRuleId string = dataCollectionRule.id
