#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
<#
.SYNOPSIS
    Pester tests for policies/Deploy-AdePolicies.ps1 and policy definition JSON files.

    Two test groups:
      1. Policy JSON schema validation — each definition and the initiative are valid before
         any az CLI call is made.
      2. Deploy-AdePolicies.ps1 behaviour — all az CLI calls are mocked; tests verify the
         script invokes the right commands and exits correctly.
#>

BeforeAll {
    $script:repoRoot       = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:definitionsDir = Join-Path $script:repoRoot 'policies\definitions'
    $script:initiativePath = Join-Path $script:repoRoot 'policies\initiatives\ade-governance-initiative.json'
    $script:scriptPath     = Join-Path $script:repoRoot 'policies\Deploy-AdePolicies.ps1'

    # Stub az so Pester can mock it even when Azure CLI is not installed
    if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
        function script:az {}
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Policy definition JSON schema
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Policy definition JSON files' {

    BeforeDiscovery {
        $definitionCases = Get-ChildItem (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'policies\definitions') -Filter '*.json' |
            ForEach-Object { @{ File = $_ } }
    }

    It 'Parses as valid JSON — <File.Name>' -TestCases $definitionCases {
        param ($File)
        $def = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $def | Should -Not -BeNullOrEmpty
    }

    It 'Has a non-empty name field — <File.Name>' -TestCases $definitionCases {
        param ($File)
        $def = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $def.name | Should -Not -BeNullOrEmpty
    }

    It 'Has a displayName in properties — <File.Name>' -TestCases $definitionCases {
        param ($File)
        $def = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $def.properties.displayName | Should -Not -BeNullOrEmpty
    }

    It 'Has a policyRule with if/then structure — <File.Name>' -TestCases $definitionCases {
        param ($File)
        $def = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $def.properties.policyRule.if   | Should -Not -BeNullOrEmpty
        $def.properties.policyRule.then | Should -Not -BeNullOrEmpty
    }

    It 'then.effect is a parameter reference — <File.Name>' -TestCases $definitionCases {
        param ($File)
        $def = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $def.properties.policyRule.then.effect | Should -Match '^\[parameters\('
    }

    It 'effect parameter defines allowedValues — <File.Name>' -TestCases $definitionCases {
        param ($File)
        $def = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $allowed = $def.properties.parameters.effect.allowedValues
        $allowed | Should -Not -BeNullOrEmpty
        $allowed.Count | Should -BeGreaterThan 1
    }

    It 'effect parameter has a defaultValue — <File.Name>' -TestCases $definitionCases {
        param ($File)
        $def = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $def.properties.parameters.effect.defaultValue | Should -Not -BeNullOrEmpty
    }

    It 'defaultValue is one of the allowedValues — <File.Name>' -TestCases $definitionCases {
        param ($File)
        $def    = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $default = $def.properties.parameters.effect.defaultValue
        $allowed = $def.properties.parameters.effect.allowedValues
        $allowed | Should -Contain $default
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Initiative JSON schema
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Governance initiative JSON' {

    BeforeAll {
        $path = Join-Path $script:repoRoot 'policies\initiatives\ade-governance-initiative.json'
        $script:initiative = Get-Content $path -Raw | ConvertFrom-Json
    }

    It 'Parses as valid JSON' {
        $script:initiative | Should -Not -BeNullOrEmpty
    }

    It 'Has a non-empty name field' {
        $script:initiative.name | Should -Not -BeNullOrEmpty
    }

    It 'Has at least one policyDefinitions entry' {
        $script:initiative.properties.policyDefinitions.Count | Should -BeGreaterThan 0
    }

    It 'Every policyDefinitions entry has a policyDefinitionId' {
        foreach ($entry in $script:initiative.properties.policyDefinitions) {
            $entry.policyDefinitionId | Should -Not -BeNullOrEmpty
        }
    }

    It 'Every policyDefinitions entry has a unique policyDefinitionReferenceId' {
        $refs = $script:initiative.properties.policyDefinitions | ForEach-Object { $_.policyDefinitionReferenceId }
        ($refs | Select-Object -Unique).Count | Should -Be $refs.Count
    }

    It 'Has a matching parameter in the initiative for each policyDefinitions parameter reference' {
        foreach ($entry in $script:initiative.properties.policyDefinitions) {
            foreach ($param in $entry.parameters.PSObject.Properties) {
                $valueExpr = $param.Value.value
                if ($valueExpr -match "^\[parameters\('(.+)'\)\]$") {
                    $paramName = $Matches[1]
                    $script:initiative.properties.parameters.$paramName |
                        Should -Not -BeNullOrEmpty -Because "initiative parameter '$paramName' referenced in entry '$($entry.policyDefinitionReferenceId)' must be declared"
                }
            }
        }
    }

    It 'Contains all four expected ADE policy references' {
        $refs = $script:initiative.properties.policyDefinitions.policyDefinitionReferenceId
        $refs | Should -Contain 'adeRequireResourceTags'
        $refs | Should -Contain 'adeDenyPublicIpOnNic'
        $refs | Should -Contain 'adeRestrictVmSkus'
        $refs | Should -Contain 'adeAuditStoragePublicAccess'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Deploy-AdePolicies.ps1 — behaviour tests (all az calls mocked)
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Deploy-AdePolicies.ps1' {

    BeforeAll {
        $script:scriptPath = Join-Path $script:repoRoot 'policies\Deploy-AdePolicies.ps1'
        $global:LASTEXITCODE = 0
    }

    BeforeEach {
        $global:LASTEXITCODE = 0
    }

    Context 'Prefix parameter validation' {

        It 'Rejects a prefix shorter than 2 characters' {
            { & $script:scriptPath -SubscriptionId 'sub-1' -Prefix 'x' } |
                Should -Throw
        }

        It 'Rejects a prefix longer than 8 characters' {
            { & $script:scriptPath -SubscriptionId 'sub-1' -Prefix 'toolongprefix' } |
                Should -Throw
        }

        It 'Rejects a prefix with uppercase letters' {
            { & $script:scriptPath -SubscriptionId 'sub-1' -Prefix 'ADE' } |
                Should -Throw
        }

        It 'Rejects a prefix with special characters' {
            { & $script:scriptPath -SubscriptionId 'sub-1' -Prefix 'my-env' } |
                Should -Throw
        }
    }

    Context 'Successful run without assignment' {

        BeforeAll {
            $script:AzCalls = [System.Collections.Generic.List[string]]::new()
            $capturedCalls  = $script:AzCalls   # reference captured by the closure below

            Mock az ({
                $capturedCalls.Add($args -join ' ')
                $global:LASTEXITCODE = 0
                return $null
            }.GetNewClosure())

            & $script:scriptPath `
                -SubscriptionId 'xxxxxxxx-0000-0000-0000-xxxxxxxxxxxx' `
                -Prefix         'ade'
        }

        It 'Calls az account set' {
            (@($script:AzCalls | Where-Object { $_ -match 'account set' })).Count | Should -BeGreaterThan 0
        }

        It 'Calls az policy definition create for each definition file' {
            $definitionCount = (Get-ChildItem (Join-Path $script:repoRoot 'policies\definitions') -Filter '*.json').Count
            $definitionCalls = $script:AzCalls | Where-Object { $_ -match 'policy definition create' }
            $definitionCalls.Count | Should -Be $definitionCount
        }

        It 'Calls az policy set-definition create for the initiative' {
            $setCalls = @($script:AzCalls | Where-Object { $_ -match 'policy set-definition create' })
            $setCalls.Count | Should -Be 1
        }

        It 'Does NOT call az policy assignment create when -Assign is not passed' {
            $assignCalls = @($script:AzCalls | Where-Object { $_ -match 'policy assignment create' })
            $assignCalls.Count | Should -Be 0
        }
    }

    Context 'Successful run with -Assign' {

        BeforeAll {
            $script:AzCalls = [System.Collections.Generic.List[string]]::new()
            $capturedCalls  = $script:AzCalls   # reference captured by the closure below

            Mock az ({
                $capturedCalls.Add($args -join ' ')
                $global:LASTEXITCODE = 0
                return $null
            }.GetNewClosure())

            & $script:scriptPath `
                -SubscriptionId 'xxxxxxxx-0000-0000-0000-xxxxxxxxxxxx' `
                -Prefix         'ade' `
                -Assign
        }

        It 'Calls az policy assignment create exactly once' {
            $assignCalls = @($script:AzCalls | Where-Object { $_ -match 'policy assignment create' })
            $assignCalls.Count | Should -Be 1
        }
    }

    Context 'az account set fails' {

        It 'Writes failure message and exits non-zero when az account set returns exit 1' {
            Mock az {
                if ($args -contains 'account' -and $args -contains 'set') {
                    $global:LASTEXITCODE = 1
                    return $null
                }
                $global:LASTEXITCODE = 0
                return $null
            }

            & $script:scriptPath -SubscriptionId 'bad-sub' -Prefix 'ade'
            $LASTEXITCODE | Should -Be 1
        }
    }
}
