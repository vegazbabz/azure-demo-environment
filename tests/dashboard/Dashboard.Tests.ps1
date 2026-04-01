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

    It 'Filters groups by managedBy=ade tag' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match "managedBy.*ade"
    }

    It 'Displays cost information (uses az consumption or cost management)' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'cost|consumption' -Because 'dashboard should show cost data'
    }

    It 'Uses az costmanagement query (not the deprecated az consumption usage list)' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'costmanagement query'
        $source | Should -Not -Match 'consumption usage list' -Because 'az consumption usage list was deprecated in CLI 2.61'
    }

    It 'Extracts cost from costmanagement query response (properties.rows[0][0])' {
        $source = Get-Content $script:dashboardPs -Raw
        $source | Should -Match 'properties\.rows'
    }

    It 'az consumption budget list includes --scope parameter' {
        $source = Get-Content $script:dashboardPs -Raw
        # Budget list must be scoped to the subscription, not called globally
        $source | Should -Match 'budget list.*--scope|budget list[\s\S]{1,200}--scope'
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
