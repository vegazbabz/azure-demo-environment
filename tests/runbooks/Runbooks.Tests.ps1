#Requires -Version 7.0
<#
.SYNOPSIS
    Unit tests for scripts/runbooks/Start-AdeResources.ps1 and Stop-AdeResources.ps1

    These tests use AST/source analysis since the runbooks require the Az PowerShell
    module (installed only in Azure Automation environments).
#>

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:startPs  = Join-Path $script:repoRoot 'scripts\runbooks\Start-AdeResources.ps1'
    $script:stopPs   = Join-Path $script:repoRoot 'scripts\runbooks\Stop-AdeResources.ps1'
}

Describe 'Start-AdeResources.ps1 – source analysis' -Tag 'unit' {

    It 'File exists' {
        Test-Path $script:startPs | Should -BeTrue
    }

    It 'Requires PowerShell 7.0 or later' {
        $source = Get-Content $script:startPs -Raw
        $source | Should -Match '#Requires -Version 7'
    }

    It 'Has a -DryRun parameter' {
        $source = Get-Content $script:startPs -Raw
        $source | Should -Match '\$DryRun'
    }

    It 'Defaults ResourcePrefix to "ade"' {
        $source = Get-Content $script:startPs -Raw
        $source | Should -Match "ResourcePrefix\s*=\s*'ade'"
    }

    It 'Authenticates via managed identity' {
        $source = Get-Content $script:startPs -Raw
        $source | Should -Match 'Connect-AzAccount\s+-Identity'
    }

    It 'Starts VMs when DryRun is false' {
        $source = Get-Content $script:startPs -Raw
        $source | Should -Match 'Start-AzVM'
    }

    It 'Gates VM start behind -not \$DryRun check' {
        $source = Get-Content $script:startPs -Raw
        # DryRun guard must appear before the Start-AzVM call
        $dryRunIdx  = $source.IndexOf('-not $DryRun')
        $startVmIdx = $source.IndexOf('Start-AzVM')
        $dryRunIdx  | Should -BeLessThan $startVmIdx
    }

    It 'Starts VMSS when DryRun is false' {
        $source = Get-Content $script:startPs -Raw
        $source | Should -Match 'Start-AzVmss'
    }

    It 'Handles AKS clusters via Start-AzAksCluster (consistent Az module usage)' {
        $source = Get-Content $script:startPs -Raw
        $source | Should -Match 'Start-AzAksCluster'
        $source | Should -Not -Match 'az aks start' -Because 'runbooks should use Az module, not az CLI'
    }

    It 'Filters resources by managedBy=ade tag' {
        $source = Get-Content $script:startPs -Raw
        $source | Should -Match "managedBy.*ade"
    }

    It 'Has no critical syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:startPs, [ref]$tokens, [ref]$errors)
        $critical = $errors | Where-Object {
            $_.ErrorId -notin @('MissingArrayIndexExpression','MissingArgument')
        }
        $critical.Count | Should -Be 0
    }
}

Describe 'Stop-AdeResources.ps1 – source analysis' -Tag 'unit' {

    It 'File exists' {
        Test-Path $script:stopPs | Should -BeTrue
    }

    It 'Requires PowerShell 7.0 or later' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match '#Requires -Version 7'
    }

    It 'Has a -DryRun parameter' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match '\$DryRun'
    }

    It 'Defaults ResourcePrefix to "ade"' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match "ResourcePrefix\s*=\s*'ade'"
    }

    It 'Authenticates via managed identity' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match 'Connect-AzAccount\s+-Identity'
    }

    It 'Deallocates VMs with Stop-AzVM' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match 'Stop-AzVM'
    }

    It 'Uses -Force when stopping VMs' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match 'Stop-AzVM.*-Force'
    }

    It 'Gates VM stop behind -not \$DryRun check' {
        $source = Get-Content $script:stopPs -Raw
        $dryRunIdx = $source.IndexOf('-not $DryRun')
        $stopVmIdx = $source.IndexOf('Stop-AzVM')
        $dryRunIdx | Should -BeLessThan $stopVmIdx
    }

    It 'Stops VMSS when DryRun is false' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match 'Stop-AzVmss'
    }

    It 'Handles AKS clusters via Stop-AzAksCluster (consistent Az module usage)' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match 'Stop-AzAksCluster'
        $source | Should -Not -Match 'az aks stop' -Because 'runbooks should use Az module, not az CLI'
    }

    It 'Filters resources by managedBy=ade tag' {
        $source = Get-Content $script:stopPs -Raw
        $source | Should -Match "managedBy.*ade"
    }

    It 'Has no critical syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:stopPs, [ref]$tokens, [ref]$errors)
        $critical = $errors | Where-Object {
            $_.ErrorId -notin @('MissingArrayIndexExpression','MissingArgument')
        }
        $critical.Count | Should -Be 0
    }
}
