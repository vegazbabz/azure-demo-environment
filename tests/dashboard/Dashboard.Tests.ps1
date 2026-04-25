#Requires -Version 7.0
<#
.SYNOPSIS
    Unit tests for scripts/dashboard/Get-AdeCostDashboard.ps1

    Source analysis only — the script requires Azure CLI and live subscription context.
#>

BeforeAll {
    $script:repoRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:dashboardPs = Join-Path $script:repoRoot 'scripts\dashboard\Get-AdeCostDashboard.ps1'
}

Describe 'Get-AdeCostDashboard.ps1 – source analysis' -Tag 'unit' {

    It 'File exists' {
        Test-Path $script:dashboardPs | Should -BeTrue
    }

    It 'Requires PowerShell 7.0 or later' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match '#Requires -Version 7'
    }

    It 'Has a -Prefix parameter defaulting to "ade"' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match "Prefix\s*=\s*'ade'"
    }

    It 'Has a -Watch switch for periodic refresh' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match '\[switch\]\$Watch'
    }

    It 'Has a -StopAll switch' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match '\[switch\]\$StopAll'
    }

    It 'Has a -StartAll switch' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match '\[switch\]\$StartAll'
    }

    It 'Defines a Show-AdeDashboard function' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'function Show-AdeDashboard'
    }

    It 'Uses az group list to discover ADE resource groups' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'az group list'
    }

    It 'Queries VM power state via az vm get-instance-view or az vm list' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'az vm'
    }

    It 'Queries VM power state using Where-Object, not a JMESPath filter (Windows shell-quoting safe)' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Not -Match 'starts_with\(code' -Because 'JMESPath PowerState filter exits 255 on Windows due to shell quoting; use Where-Object instead'
        $source | Should -Match 'Where-Object.*PowerState|PowerState.*Where-Object' -Because 'PowerState must be filtered in PowerShell to avoid cross-platform shell quoting issues'
    }

    It 'Filters groups by managedBy=ade tag' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match "managedBy.*ade"
    }

    It 'Displays cost information (uses az consumption or cost management)' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'cost|consumption' -Because 'dashboard should show cost data'
    }

    It 'Uses REST API for cost query (not the unavailable az costmanagement query CLI)' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'Microsoft\.CostManagement/query' -Because 'az costmanagement query is not universally available; REST API must be used'
        $source | Should -Not -Match "az costmanagement query" -Because 'az costmanagement query is not a valid CLI command'
    }

    It 'Does not warn from a direct role-assignment preflight that misses inherited roles' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Not -Match 'may lack.*Cost Management Reader' -Because 'direct role preflight misses group and management-group inheritance'
        $source | Should -Not -Match 'role assignment list --assignee' -Because 'cost access should be inferred from the Cost Management query result'
    }

    It 'Fetches all RG costs in a single grouped REST call' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'grouping'
        $source | Should -Match 'properties\.rows'
    }

    It 'Fetches budgets via REST API (Microsoft.Consumption/budgets)' {
        $source = Get-Content $script:dashboardPs -Raw
        # Budget data must come from the REST endpoint, not the broken az consumption budget list
        $source | Should -Match 'Microsoft\.Consumption/budgets'
    }

    It 'Has no critical PowerShell syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:dashboardPs, [ref]$tokens, [ref]$errors)
        $critical = @($errors | Where-Object {
            $_.ErrorId -notin @('MissingArrayIndexExpression','MissingArgument')
        })
        $critical.Count | Should -Be 0
    }
}
