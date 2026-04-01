// ─── budget.bicep ─────────────────────────────────────────────────────────────
// Subscription-scoped budget with email alerts at 50%, 80%, and 100% thresholds.
// Referenced by governance.bicep.
// ────────────────────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('Resource prefix for budget naming.')
param prefix string

@description('Monthly budget amount in USD.')
param monthlyBudgetUsd int = 300

@description('Email for budget alert notifications.')
param alertEmail string = 'ops@example.com'

@description('Budget alert threshold percentages.')
param thresholds array = [50, 80, 100]

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: '${prefix}-monthly-budget'
  properties: {
    category: 'Cost'
    amount: monthlyBudgetUsd
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: '2026-04-01'
      endDate: '2030-12-31'
    }
    filter: {
      tags: {
        name: 'managedBy'
        operator: 'In'
        values: ['ade']
      }
    }
    notifications: toObject(
      map(thresholds, threshold => {
        key: 'Alert${threshold}'
        value: {
          enabled: true
          operator: 'GreaterThanOrEqualTo'
          threshold: threshold
          contactEmails: [alertEmail]
          thresholdType: 'Actual'
        }
      }),
      item => item.key,
      item => item.value
    )
  }
}
