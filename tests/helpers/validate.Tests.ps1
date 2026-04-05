#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
<#
.SYNOPSIS
    Pester tests for scripts/helpers/validate.ps1

    These are pure-logic unit tests. All az CLI, file system, and console calls are mocked
    so the suite runs without an Azure subscription or any installed tooling.
#>

BeforeAll {
    # ── Load common.ps1 first (validate.ps1 calls Write-AdeLog / Write-AdeSection) ──
    $commonPath   = Join-Path $PSScriptRoot '..\..\scripts\helpers\common.ps1'
    $validatePath = Join-Path $PSScriptRoot '..\..\scripts\helpers\validate.ps1'

    # Stub Write-AdeLog and Write-AdeSection so tests don't produce noise
    function Write-AdeLog   { param([string]$Message, $Level, [switch]$NoNewline) }
    function Write-AdeSection { param([string]$Title) }

    # Stub Get-FeatureFlag (defined in common.ps1, used by Confirm-AdeDeployment in validate.ps1)
    function Get-FeatureFlag {
        param([object]$Features, [string]$Name, $Default = $false)
        if ($null -eq $Features) { return $Default }
        $prop = $Features.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $Default }
        return $prop.Value
    }

    # Stub az as a PS function so Pester can mock it even when Azure CLI is not installed
    if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
        function script:az {}
    }

    . $validatePath
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-AdeProfile
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Test-AdeProfile' {

    Context 'Valid profiles' {

        It 'Accepts a monitoring-only profile' {
            $profile = [pscustomobject]@{
                profileName = 'monitoring-only'
                modules     = [pscustomobject]@{
                    monitoring = [pscustomobject]@{ enabled = $true }
                    networking = [pscustomobject]@{ enabled = $false }
                }
            }
            { Test-AdeProfile -Profile $profile } | Should -Not -Throw
        }

        It 'Accepts monitoring + networking with no dependants' {
            $profile = [pscustomobject]@{
                profileName = 'net-only'
                modules     = [pscustomobject]@{
                    monitoring = [pscustomobject]@{ enabled = $true }
                    networking = [pscustomobject]@{ enabled = $true }
                    compute    = [pscustomobject]@{ enabled = $false }
                    databases  = [pscustomobject]@{ enabled = $false }
                    containers = [pscustomobject]@{ enabled = $false }
                    appservices= [pscustomobject]@{ enabled = $false }
                    integration= [pscustomobject]@{ enabled = $false }
                    ai         = [pscustomobject]@{ enabled = $false }
                    data       = [pscustomobject]@{ enabled = $false }
                }
            }
            { Test-AdeProfile -Profile $profile } | Should -Not -Throw
        }

        It 'Accepts a full profile with all modules enabled' {
            $modules = @(
                'monitoring','networking','security','compute','storage',
                'databases','appservices','containers','integration','ai','data','governance'
            )
            $modulesObj = [pscustomobject]@{}
            foreach ($m in $modules) {
                $modulesObj | Add-Member -NotePropertyName $m -NotePropertyValue ([pscustomobject]@{ enabled = $true })
            }
            $profile = [pscustomobject]@{ profileName = 'full'; modules = $modulesObj }
            { Test-AdeProfile -Profile $profile } | Should -Not -Throw
        }
    }

    Context 'Dependency violations — monitoring' {

        It 'Throws when networking is enabled but monitoring is not' {
            $profile = [pscustomobject]@{
                profileName = 'bad'
                modules     = [pscustomobject]@{
                    monitoring = [pscustomobject]@{ enabled = $false }
                    networking = [pscustomobject]@{ enabled = $true }
                }
            }
            { Test-AdeProfile -Profile $profile } | Should -Throw -ExpectedMessage "*monitoring*must be enabled*"
        }

        It 'Throws when compute is enabled but monitoring is not' {
            $profile = [pscustomobject]@{
                profileName = 'bad'
                modules     = [pscustomobject]@{
                    monitoring = [pscustomobject]@{ enabled = $false }
                    networking = [pscustomobject]@{ enabled = $true }
                    compute    = [pscustomobject]@{ enabled = $true }
                }
            }
            { Test-AdeProfile -Profile $profile } | Should -Throw -ExpectedMessage "*monitoring*must be enabled*"
        }
    }

    Context 'Dependency violations — networking' {

        It "Throws when '<mod>' is enabled but networking is not" -TestCases @(
            @{ mod = 'compute'     }
            @{ mod = 'databases'   }
            @{ mod = 'containers'  }
            @{ mod = 'appservices' }
            @{ mod = 'integration' }
            @{ mod = 'ai'          }
            @{ mod = 'data'        }
        ) {
            param ($mod)
            $modulesObj = [pscustomobject]@{
                monitoring = [pscustomobject]@{ enabled = $true }
                networking = [pscustomobject]@{ enabled = $false }
            }
            $modulesObj | Add-Member -NotePropertyName $mod -NotePropertyValue ([pscustomobject]@{ enabled = $true })
            $profile = [pscustomobject]@{ profileName = 'bad'; modules = $modulesObj }
            { Test-AdeProfile -Profile $profile } | Should -Throw -ExpectedMessage "*$mod*requires*networking*"
        }
    }

    Context 'Warnings for missing security module' {

        It 'Does not throw when compute is enabled without security (emits warning)' {
            $profile = [pscustomobject]@{
                profileName = 'no-security'
                modules     = [pscustomobject]@{
                    monitoring = [pscustomobject]@{ enabled = $true }
                    networking = [pscustomobject]@{ enabled = $true }
                    compute    = [pscustomobject]@{ enabled = $true }
                    security   = [pscustomobject]@{ enabled = $false }
                }
            }
            { Test-AdeProfile -Profile $profile } | Should -Not -Throw
        }

        It 'Does not throw when containers is enabled without security (emits warning)' {
            $profile = [pscustomobject]@{
                profileName = 'no-security'
                modules     = [pscustomobject]@{
                    monitoring = [pscustomobject]@{ enabled = $true }
                    networking = [pscustomobject]@{ enabled = $true }
                    containers = [pscustomobject]@{ enabled = $true }
                    security   = [pscustomobject]@{ enabled = $false }
                }
            }
            { Test-AdeProfile -Profile $profile } | Should -Not -Throw
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-AdePrerequisites
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Test-AdePrerequisites' {

    BeforeEach {
        # Ensure $LASTEXITCODE is always initialized before each test
        $global:LASTEXITCODE = 0
        $script:AzCallCount  = 0
    }

    Context 'All tools present and logged in' {

        It 'Returns $true when all checks pass' {
            Mock az {
                # version --output json (single call after Fix R — no separate tsv probe)
                if ($args -contains '--output' -and $args -contains 'json' -and $args[0] -eq 'version') {
                    $global:LASTEXITCODE = 0
                    return '{"azure-cli":"2.57.0"}'
                }
                # bicep version
                if ($args -contains 'bicep' -and $args -contains 'version') {
                    $global:LASTEXITCODE = 0; return 'Bicep CLI version 0.28.1'
                }
                # account show
                if ($args -contains 'account' -and $args -contains 'show') {
                    $global:LASTEXITCODE = 0; return '{"user":{"name":"user@test.com"},"name":"MySub","id":"sub-123"}'
                }
                $global:LASTEXITCODE = 0
            }

            $result = Test-AdePrerequisites
            $result | Should -Be $true
        }

        It 'Calls az version exactly once (single JSON call, no redundant tsv probe)' {
            $script:versionCallCount = 0
            Mock az {
                if ($args[0] -eq 'version') {
                    $script:versionCallCount++
                    $global:LASTEXITCODE = 0
                    return '{"azure-cli":"2.57.0"}'
                }
                if ($args -contains 'bicep') { $global:LASTEXITCODE = 0; return 'Bicep CLI version 0.28.1' }
                if ($args -contains 'account') { $global:LASTEXITCODE = 0; return '{"user":{"name":"u@t.com"},"name":"S","id":"s"}' }
                $global:LASTEXITCODE = 0
            }
            $null = Test-AdePrerequisites
            $script:versionCallCount | Should -Be 1
        }
    }

    Context 'Azure CLI missing' {

        It 'Returns $false (does not throw) when az is not found' {
            Mock az { $global:LASTEXITCODE = 1; return $null }

            $result = Test-AdePrerequisites
            $result | Should -Be $false
        }

        It 'Throws when -StopOnError is specified and az is missing' {
            Mock az { $global:LASTEXITCODE = 1; return $null }

            { Test-AdePrerequisites -StopOnError } | Should -Throw
        }
    }

    Context 'Not logged in to Azure CLI' {

        It 'Returns $false when account show fails' {
            Mock az {
                if ($args -contains 'version') { $global:LASTEXITCODE = 0; return '{"azure-cli":"2.57.0"}' }
                if ($args -contains 'bicep')   { $global:LASTEXITCODE = 0; return 'Bicep CLI version 0.28.1' }
                # account show fails
                $global:LASTEXITCODE = 1
                return $null
            }
            $result = Test-AdePrerequisites
            $result | Should -Be $false
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Confirm-AdeDeployment
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Confirm-AdeDeployment' {

    BeforeAll {
        # Minimal profile helper
        function Get-MinimalProfile ([string]$Name = 'test') {
            [pscustomobject]@{
                profileName = $Name
                description = 'Test profile'
                modules     = [pscustomobject]@{
                    monitoring  = [pscustomobject]@{ enabled = $true; features = $null }
                    networking  = [pscustomobject]@{ enabled = $true; features = [pscustomobject]@{
                        enableFirewall = 'None'; enableAppGateway = $false; enableVpnGateway = $false; enableDdos = $false
                    }}
                    security    = [pscustomobject]@{ enabled = $false; features = $null }
                    governance  = [pscustomobject]@{ enabled = $false; features = [pscustomobject]@{
                        budgetAmount = 200; automationAccount = $false
                    }}
                    integration = [pscustomobject]@{ enabled = $false; features = $null }
                }
                tags = $null
            }
        }
    }

    It 'Does not throw with -Force (skips prompt)' {
        $p = Get-MinimalProfile
        {
            Confirm-AdeDeployment `
                -Profile        $p `
                -Location       'westeurope' `
                -Prefix         'ade' `
                -SubscriptionId 'sub-123' `
                -Force
        } | Should -Not -Throw
    }

    It 'Throws "cancelled by user" when prompt returns N' {
        $p = Get-MinimalProfile
        Mock Read-Host { return 'N' }
        {
            Confirm-AdeDeployment `
                -Profile        $p `
                -Location       'westeurope' `
                -Prefix         'ade' `
                -SubscriptionId 'sub-123'
        } | Should -Throw -ExpectedMessage "*cancelled*"
    }

    It 'Does not throw when prompt returns y' {
        $p = Get-MinimalProfile
        Mock Read-Host { return 'y' }
        {
            Confirm-AdeDeployment `
                -Profile        $p `
                -Location       'westeurope' `
                -Prefix         'ade' `
                -SubscriptionId 'sub-123'
        } | Should -Not -Throw
    }

    It 'Accepts hardened mode without throwing' {
        $p = Get-MinimalProfile
        {
            Confirm-AdeDeployment `
                -Profile        $p `
                -Location       'westeurope' `
                -Prefix         'ade' `
                -SubscriptionId 'sub-123' `
                -Mode           'hardened' `
                -Force
        } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-AdeSubscription
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Test-AdeSubscription' -Tag 'unit' {

    BeforeAll {
        $global:LASTEXITCODE = 0
    }

    BeforeEach {
        $global:LASTEXITCODE = 0
        $script:AzSubCalls = @()
        Mock az {
            $script:AzSubCalls += ($args -join ' ')
            $global:LASTEXITCODE = 0
            # Return different JSON depending on the subcommand called
            if ($args -contains 'show') {
                return '{"id":"sub-abc","name":"ADE Demo","tenantId":"tenant-x"}'
            }
            if ($args -contains 'signed-in-user') {
                return 'user-object-id-123'
            }
            if ($args -contains 'list') {
                return "Contributor`n"
            }
            return ''
        }
    }

    It 'Returns the subscription object on success' {
        $result = Test-AdeSubscription -SubscriptionId 'sub-abc'
        $result.id   | Should -Be 'sub-abc'
        $result.name | Should -Be 'ADE Demo'
    }

    It 'Calls az account show with the given subscription ID' {
        Test-AdeSubscription -SubscriptionId 'sub-abc'
        $showCall = $script:AzSubCalls | Where-Object { $_ -match 'account show' }
        $showCall | Should -Not -BeNullOrEmpty
        $showCall | Should -Match 'sub-abc'
    }

    It 'Throws when az account show exits non-zero' {
        Mock az {
            $global:LASTEXITCODE = 1
            return ''
        }
        { Test-AdeSubscription -SubscriptionId 'bad-sub' } |
            Should -Throw -ExpectedMessage "*not found*"
    }

    It 'Throws when az account show returns null output' {
        Mock az {
            $global:LASTEXITCODE = 0
            return $null
        }
        { Test-AdeSubscription -SubscriptionId 'null-sub' } |
            Should -Throw -ExpectedMessage "*not found*"
    }

    It 'Does not throw when role assignment check returns no assignments (warning only)' {
        Mock az {
            $global:LASTEXITCODE = 0
            if ($args -contains 'show') {
                return '{"id":"sub-abc","name":"ADE Demo","tenantId":"t"}'
            }
            return ''   # empty for signed-in-user and role list
        }
        { Test-AdeSubscription -SubscriptionId 'sub-abc' } | Should -Not -Throw
    }

    It 'Queries role assignments at the subscription scope' {
        Test-AdeSubscription -SubscriptionId 'sub-abc'
        $roleCall = $script:AzSubCalls | Where-Object { $_ -match 'role assignment list' }
        $roleCall | Should -Not -BeNullOrEmpty
        $roleCall | Should -Match 'sub-abc'
    }

    It 'Uses full-field JMESPath syntax for Owner and Contributor check' {
        $validatePs = Join-Path $PSScriptRoot '..\..\scripts\helpers\validate.ps1'
        $source = Get-Content $validatePs -Raw
        # Bug: prior version used invalid JMESPath like "== 'Owner' || == 'Contributor'"
        # (missing field repetition). Correct form repeats the field name on each side of ||.
        $source | Should -Match "roleDefinitionName == 'Owner'.*\|\|.*roleDefinitionName == 'Contributor'" `
            -Because 'JMESPath requires the field name on BOTH sides of ||'
    }
}
