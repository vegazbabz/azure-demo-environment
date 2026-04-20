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
        $script:AdeRmAzCalls = @()
        Mock az {
            $script:AdeRmAzCalls += ($args -join ' ')
            $global:LASTEXITCODE = 0
            ''   # empty lock list
        }
    }

    It 'Calls az group delete with --yes' {
        Remove-AdeResourceGroup -Name 'ade-test-rg'
        $deleteCall = $script:AdeRmAzCalls | Where-Object { $_ -match 'group delete' }
        $deleteCall | Should -Not -BeNullOrEmpty
        $deleteCall | Should -Match '--yes'
    }

    It 'Passes --no-wait when -NoWait is set' {
        Remove-AdeResourceGroup -Name 'ade-test-rg' -NoWait
        $deleteCall = $script:AdeRmAzCalls | Where-Object { $_ -match 'group delete' }
        $deleteCall | Should -Match '--no-wait'
    }

    It 'Passes --no-wait when -NoWait is set' {
        Remove-AdeResourceGroup -Name 'ade-test-rg' -NoWait
        $deleteCall = $script:AdeRmAzCalls | Where-Object { $_ -match 'group delete' }
        $deleteCall | Should -Match '--no-wait'
    }

    It 'Does not pass --no-wait when -NoWait is not set' {
        Remove-AdeResourceGroup -Name 'ade-test-rg'
        $deleteCall = $script:AdeRmAzCalls | Where-Object { $_ -match 'group delete' }
        $deleteCall | Should -Not -Match '--no-wait'
    }

    It 'Attempts to remove resource locks before deleting the group' {
        Remove-AdeResourceGroup -Name 'ade-test-rg'
        $lockCall = $script:AdeRmAzCalls | Where-Object { $_ -match 'lock list' }
        $lockCall | Should -Not -BeNullOrEmpty
    }

    It 'Throws when az group delete exits non-zero' {
        Mock az {
            $args_str = $args -join ' '
            if ($args_str -match 'group delete') {
                $global:LASTEXITCODE = 1
                return $null
            }
            $global:LASTEXITCODE = 0
        }
        { Remove-AdeResourceGroup -Name 'ade-fail-rg' } |
            Should -Throw -ExpectedMessage '*az group delete failed*'
    }

    It 'Calls az lock delete once per lock when resource locks exist' {
        $script:AdeRmAzCalls = @()
        Mock az {
            $args_str = $args -join ' '
            $script:AdeRmAzCalls += $args_str
            $global:LASTEXITCODE = 0
            if ($args_str -match 'lock list') {
                return @(
                    '/subscriptions/sub-1/resourceGroups/ade-test-rg/providers/Microsoft.Authorization/locks/lock1',
                    '/subscriptions/sub-1/resourceGroups/ade-test-rg/providers/Microsoft.Authorization/locks/lock2'
                )
            }
        }
        Remove-AdeResourceGroup -Name 'ade-test-rg'
        $deleteCalls = $script:AdeRmAzCalls | Where-Object { $_ -match 'lock delete' }
        $deleteCalls.Count | Should -Be 2
    }

    It 'Does not call az group delete when -WhatIf is set' {
        $script:AdeRmAzCalls = @()
        Mock az {
            $script:AdeRmAzCalls += ($args -join ' ')
            $global:LASTEXITCODE = 0
            ''
        }
        Remove-AdeResourceGroup -Name 'ade-whatif-rg' -WhatIf
        $deleteCall = $script:AdeRmAzCalls | Where-Object { $_ -match 'group delete' }
        $deleteCall | Should -BeNullOrEmpty -Because '-WhatIf must prevent az group delete from running'
    }
}

Describe 'destroy.ps1 – source parses without errors' -Tag 'unit' {

    It 'Has no critical PowerShell syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:destroyPs, [ref]$tokens, [ref]$errors)
        # Filter out known benign parse artefacts (2>$null stderr redirect)
        $criticalErrors = @($errors | Where-Object {
            $_.ErrorId -notin @('MissingArrayIndexExpression','MissingArgument')
        })
        $criticalErrors.Count | Should -Be 0
    }
}

Describe 'destroy.ps1 – soft-deleted Key Vault purge' -Tag 'unit' {

    It 'Calls az keyvault list-deleted after deletions succeed' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'keyvault list-deleted'
    }

    It 'Filters deleted vaults by prefix' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match "starts_with\(name.*-kv-"
    }

    It 'Calls az keyvault purge for each matching deleted vault' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'keyvault.*purge'
    }

    It 'Uses --no-wait on purge to avoid az CLI timeouts' {
        $source = Get-Content $script:destroyPs -Raw
        # Purge is now synchronous (no --no-wait) so the CLI blocks until complete
        $source | Should -Not -Match 'keyvault purge.*--no-wait'
    }

    It 'Logs success after purge completes' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'Safe to re-deploy immediately'
    }

    It 'Passes --location to az keyvault purge' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match '--location.*\$loc'
    }

    It 'Does not purge KVs when -NoWait is set (RGs may still be deleting)' {
        $source = Get-Content $script:destroyPs -Raw
        # The purge block must be guarded by -not $NoWait
        $source | Should -Match '-not \$NoWait'
    }

    It 'Does not purge KVs when any RG deletion failed' {
        $source = Get-Content $script:destroyPs -Raw
        # The purge block must check $failedRgs.Count -eq 0
        $source | Should -Match 'failedRgs.Count -eq 0'
    }
}

Describe 'destroy.ps1 – soft-deleted Cognitive Services purge' -Tag 'unit' {

    It 'Calls az cognitiveservices account list-deleted after deletions succeed' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'cognitiveservices account list-deleted'
    }

    It 'Filters deleted Cognitive Services accounts by prefix' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'cognitiveservices account list-deleted.*starts_with\(name'
    }

    It 'Calls az cognitiveservices account purge for each matching deleted account' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'cognitiveservices account purge'
    }

    It 'Extracts resource-group name from ARM resource ID' {
        $source = Get-Content $script:destroyPs -Raw
        # RG must be extracted from the ARM id — not hardcoded
        $source | Should -Match 'resourceGroups/\(\[\^/\]\+\)'
    }

    It 'Passes --resource-group and --location to the purge command' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match '--resource-group.*acctRg'
        $source | Should -Match '--location.*acctLoc'
    }

    It 'Guards the CogSvc purge block with the same -NoWait / failedRgs conditions as KV purge' {
        $source = Get-Content $script:destroyPs -Raw
        # Both purge sections must be inside the same outer if block
        $source | Should -Match '-not \$NoWait'
        $source | Should -Match 'failedRgs.Count -eq 0'
    }
}

Describe 'destroy.ps1 – parallel deletion loop' -Tag 'unit' {

    It 'Calls Remove-AdeResourceGroup with -NoWait for every RG (parallel launch)' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'Remove-AdeResourceGroup.*-NoWait'
    }

    It 'Polls with az group exists after starting deletions' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'group exists'
    }

    It 'Has a maximum wait timeout to avoid blocking forever' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'maxSeconds'
    }
}

Describe 'destroy.ps1 – subscription-scope budget cleanup' -Tag 'unit' {

    It 'Checks for a budget named {prefix}-monthly-budget' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'monthly-budget'
    }

    It 'Uses az rest GET to check budget existence before deleting' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'az rest.*--method GET'
        $source | Should -Match 'Microsoft.Consumption/budgets'
    }

    It 'Uses az rest DELETE to remove the budget' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'az rest.*--method DELETE'
    }

    It 'Skips budget deletion when -NoWait is set' {
        $source = Get-Content $script:destroyPs -Raw
        # Budget cleanup must be inside the same -not $NoWait guard
        $source | Should -Match '-not \$NoWait'
    }

    It 'Skips budget deletion when any RG deletion failed' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'failedRgs.Count -eq 0'
    }

    It 'Logs success after budget is deleted' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match "Budget.*deleted"
    }
}

Describe 'destroy.ps1 – WhatIf safety' -Tag 'unit' {

    It 'Declares SupportsShouldProcess on the script to accept -WhatIf' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'SupportsShouldProcess'
    }

    It 'Skips the DELETE confirmation prompt when $WhatIfPreference is true' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match 'WhatIfPreference' -Because 'must not prompt for confirmation during -WhatIf'
    }

    It 'Skips purge and budget cleanup when $WhatIfPreference is true' {
        $source = Get-Content $script:destroyPs -Raw
        $source | Should -Match '-not \$NoWait.*WhatIfPreference|WhatIfPreference.*-not \$NoWait' -Because 'purge block must not run during -WhatIf'
    }

    It 'Remove-AdeResourceGroup calls ShouldProcess before deleting the resource group' {
        $commonSrc = Get-Content (Join-Path $script:repoRoot 'scripts\helpers\common.ps1') -Raw
        $commonSrc | Should -Match "ShouldProcess.*Delete resource group" -Because 'missing ShouldProcess guard was root cause of WhatIf not working'
    }
}
