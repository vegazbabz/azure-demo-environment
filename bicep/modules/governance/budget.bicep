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

@description('Budget start date in YYYY-MM-01 format. Defaults to the first day of the current month.')
param budgetStartDate string = '${substring(utcNow('o'), 0, 7)}-01'

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: '${prefix}-monthly-budget'
  properties: {
    category: 'Cost'
    amount: monthlyBudgetUsd
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
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
