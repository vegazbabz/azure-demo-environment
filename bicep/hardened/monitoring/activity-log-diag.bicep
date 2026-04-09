// ─── hardened/monitoring/activity-log-diag.bicep ────────────────────────────
// Subscription-scoped Activity Log diagnostic settings.
// Streams all Activity Log categories to the shared Log Analytics workspace.
//
// HARDENED MODE: Satisfies CIS v5.0.0 controls 5.1.x (ensure diagnostic settings
//               capture Administrative, Security, Alert, Policy, and more).
//               Called as a subscription-scoped module from monitoring.bicep.
// ─────────────────────────────────────────────────────────────────────────────
targetScope = 'subscription'

@description('Resource ID of the Log Analytics workspace to send Activity Logs to.')
param logAnalyticsId string

// ─── Subscription-level Activity Log diagnostic settings ──────────────────────
// Writes all Activity Log categories to Log Analytics. Retention managed by the
// workspace retention policy; the retentionPolicy block is deprecated for
// workspace destinations but included for ARM schema compliance.

resource activityLogDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'ade-activitylog-diag'
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      { category: 'Administrative', enabled: true }
      { category: 'Security',       enabled: true }
      { category: 'ServiceHealth',  enabled: true }
      { category: 'Alert',          enabled: true }
      { category: 'Recommendation', enabled: true }
      { category: 'Policy',         enabled: true }
      { category: 'Autoscale',      enabled: true }
      { category: 'ResourceHealth', enabled: true }
    ]
  }
}
