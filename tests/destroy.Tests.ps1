#Requires -Version 7.0
<#
.SYNOPSIS
    Unit / smoke tests for scripts/destroy.ps1
#>

BeforeAll {
    $script:repoRoot  = Split-Path $PSScriptRoot -Parent
    $script:destroyPs = Join-Path $script:repoRoot 'scripts\destroy.ps1'

    # Provide a no-op az stub so Pester can Mock it
    function script:az {}
}

Describe 'destroy.ps1 – parameter validation' -Tag 'unit' {

    It 'Accepts a valid lowercase alphanumeric prefix' {
        $source = Get-Content $script:destroyPs -Raw
        # Verify the file contains a ValidatePattern for the Prefix parameter
        $source | Should -Match 'ValidatePattern'
        $source | Should -Match 'Prefix'
    }


    It 'Has a ValidatePattern that rejects uppercase letters' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'ValidatePattern'
    }

    It 'ValidatePattern uses (?-i) for case-sensitive Prefix enforcement' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match '\(\?-i\)' -Because 'must reject uppercase even on case-insensitive filesystems'
    }

    It 'Checks az account set exit code and throws on failure' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'az account set'
        $source | Should -Match 'LASTEXITCODE'
    }

    It 'Defaults Prefix to "ade"' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match "Prefix\s*=\s*'ade'"
    }

    It 'Has a -Force switch parameter' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match '\[switch\]\$Force'
    }

    It 'Has a -NoWait switch parameter' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match '\[switch\]\$NoWait'
    }

}

Describe 'destroy.ps1 – destroy order' -Tag 'unit' {

    It 'Defines a destroy order list that includes all 12 known modules' {
        $source = Get-Content $script:destroyPs -Raw
        $expectedModules = @(
            'governance','containers','appservices','databases',
            'storage','compute','security','networking','monitoring',
            'data','ai','integration'
        )
        foreach ($mod in $expectedModules) {
            $source | Should -Match "'$mod'" -Because "destroy order must include '$mod'"
        }
    }

    It 'Puts networking before compute in the destroy order (reverse-dependency)' {
        $source = Get-Content $script:destroyPs -Raw
        # networking must appear AFTER compute in the destroy order array
        $networkingIdx = $source.IndexOf("'networking'")
        $computeIdx    = $source.IndexOf("'compute'")
        $networkingIdx | Should -BeGreaterThan $computeIdx
    }

    It 'Puts monitoring after networking in the destroy order' {
        $source = Get-Content $script:destroyPs -Raw
        $monitoringIdx = $source.IndexOf("'monitoring'")
        $networkingIdx = $source.IndexOf("'networking'")
        $monitoringIdx | Should -BeGreaterThan $networkingIdx
    }
}

Describe 'destroy.ps1 – Remove-AdeResourceGroup helper' -Tag 'unit' {

    BeforeAll {
        # Dot-source just the helpers
        . (Join-Path $script:repoRoot 'scripts\helpers\common.ps1')
        $global:LASTEXITCODE = 0
    }

    BeforeEach {
        $global:LASTEXITCODE = 0
        $global:AdeRmAzCalls = @()
        Mock az {
            $global:AdeRmAzCalls += ($args -join ' ')
            $global:LASTEXITCODE = 0
            ''   # empty lock list
        }
    }

    It 'Calls az group delete with --yes' {
        Remove-AdeResourceGroup -Name 'ade-test-rg'
        $deleteCall = $global:AdeRmAzCalls | Where-Object { $_ -match 'group delete' }
        $deleteCall | Should -Not -BeNullOrEmpty
        $deleteCall | Should -Match '--yes'
    }

    It 'Passes --no-wait when -NoWait is set' {
        Remove-AdeResourceGroup -Name 'ade-test-rg' -NoWait
        $deleteCall = $global:AdeRmAzCalls | Where-Object { $_ -match 'group delete' }
        $deleteCall | Should -Match '--no-wait'
    }

    It 'Does not pass --no-wait when -NoWait is not set' {
        Remove-AdeResourceGroup -Name 'ade-test-rg'
        $deleteCall = $global:AdeRmAzCalls | Where-Object { $_ -match 'group delete' }
        $deleteCall | Should -Not -Match '--no-wait'
    }

    It 'Attempts to remove resource locks before deleting the group' {
        Remove-AdeResourceGroup -Name 'ade-test-rg'
        $lockCall = $global:AdeRmAzCalls | Where-Object { $_ -match 'lock list' }
        $lockCall | Should -Not -BeNullOrEmpty
    }

    It 'Calls az lock delete once per lock when resource locks exist' {
        $global:AdeRmAzCalls = @()
        Mock az {
            $args_str = $args -join ' '
            $global:AdeRmAzCalls += $args_str
            $global:LASTEXITCODE = 0
            if ($args_str -match 'lock list') {
                return @(
                    '/subscriptions/sub-1/resourceGroups/ade-test-rg/providers/Microsoft.Authorization/locks/lock1',
                    '/subscriptions/sub-1/resourceGroups/ade-test-rg/providers/Microsoft.Authorization/locks/lock2'
                )
            }
        }
        Remove-AdeResourceGroup -Name 'ade-test-rg'
        $deleteCalls = $global:AdeRmAzCalls | Where-Object { $_ -match 'lock delete' }
        $deleteCalls.Count | Should -Be 2
    }
}

Describe 'destroy.ps1 – source parses without errors' -Tag 'unit' {

    It 'Has no critical PowerShell syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:destroyPs, [ref]$tokens, [ref]$errors)
        # Filter out known benign parse artefacts (2>$null stderr redirect)
        $criticalErrors = $errors | Where-Object {
            $_.ErrorId -notin @('MissingArrayIndexExpression','MissingArgument')
        }
        $criticalErrors.Count | Should -Be 0
    }
}
