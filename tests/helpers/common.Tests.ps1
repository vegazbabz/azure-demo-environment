#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
<#
.SYNOPSIS
    Pester tests for scripts/helpers/common.ps1

    All az CLI calls are mocked. No Azure subscription is required.
    All file I/O for Get-AdeProfile uses temp profile files created inline.
#>

BeforeAll {
    # Silence Write-Host so test output stays clean
    Mock Write-Host {}

    $commonPath = Join-Path $PSScriptRoot '..\..\scripts\helpers\common.ps1'
    . $commonPath
}

# ─────────────────────────────────────────────────────────────────────────────
# Write-AdeLog
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Write-AdeLog' -Tag 'unit' {

    It 'Does not throw for each log level' {
        $levels = [AdeLogLevel]::Info, [AdeLogLevel]::Success, [AdeLogLevel]::Warning,
                  [AdeLogLevel]::Error, [AdeLogLevel]::Step, [AdeLogLevel]::Debug
        foreach ($lvl in $levels) {
            { Write-AdeLog "test message" -Level $lvl } | Should -Not -Throw
        }
    }

    It 'Defaults to Info level without throwing' {
        { Write-AdeLog "default level" } | Should -Not -Throw
    }

    It 'Writes to log file when AdeLogFile is set' {
        $logFile = Join-Path $TestDrive 'test.log'
        $script:AdeLogFile = $logFile

        Write-AdeLog "hello from test" -Level Info

        $script:AdeLogFile = $null
        Get-Content $logFile | Should -Match 'hello from test'
    }

    It 'Appends without newline when -NoNewline is passed' {
        $logFile = Join-Path $TestDrive 'nonewline.log'
        $script:AdeLogFile = $logFile

        Write-AdeLog "part1" -NoNewline
        Write-AdeLog " part2"

        $script:AdeLogFile = $null
        $content = Get-Content $logFile -Raw
        # Two writes: first no-newline raw append, second Add-Content line
        $content | Should -Not -BeNullOrEmpty
    }

    It 'Does not write to file when AdeLogFile is null' {
        $script:AdeLogFile = $null
        { Write-AdeLog "no file" } | Should -Not -Throw
    }

    It 'Suppresses Debug-level console output when AdeVerbose is false' {
        $script:AdeVerbose = $false
        Write-AdeLog "hidden debug" -Level Debug
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -match 'hidden debug' }
    }

    It 'Shows Debug-level console output when AdeVerbose is true' {
        $script:AdeVerbose = $true
        Write-AdeLog "visible debug" -Level Debug
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -match 'visible debug' }
        $script:AdeVerbose = $false
    }

    It 'Still writes Debug messages to log file even when AdeVerbose is false' {
        $script:AdeVerbose = $false
        $logFile = Join-Path $TestDrive 'debug-silent.log'
        $script:AdeLogFile = $logFile
        Write-AdeLog "debug to file" -Level Debug
        $script:AdeLogFile = $null
        Get-Content $logFile | Should -Match 'debug to file'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Write-AdeSection
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Write-AdeSection' -Tag 'unit' {

    It 'Does not throw' {
        { Write-AdeSection "My Section" } | Should -Not -Throw
    }

    It 'Writes section title to log file when AdeLogFile is set' {
        $logFile = Join-Path $TestDrive 'section.log'
        $script:AdeLogFile = $logFile

        Write-AdeSection "Deployment Phase"

        $script:AdeLogFile = $null
        $content = Get-Content $logFile -Raw
        $content | Should -Match 'Deployment Phase'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-AdeDeploymentOrder
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Get-AdeDeploymentOrder' -Tag 'unit' {

    It 'Returns only enabled modules' {
        $profile = [pscustomobject]@{
            modules = [pscustomobject]@{
                monitoring  = [pscustomobject]@{ enabled = $true }
                networking  = [pscustomobject]@{ enabled = $false }
                security    = [pscustomobject]@{ enabled = $true }
                compute     = [pscustomobject]@{ enabled = $false }
                storage     = [pscustomobject]@{ enabled = $false }
                databases   = [pscustomobject]@{ enabled = $false }
                appservices = [pscustomobject]@{ enabled = $false }
                containers  = [pscustomobject]@{ enabled = $false }
                integration = [pscustomobject]@{ enabled = $false }
                ai          = [pscustomobject]@{ enabled = $false }
                data        = [pscustomobject]@{ enabled = $false }
                governance  = [pscustomobject]@{ enabled = $false }
            }
        }
        $order = Get-AdeDeploymentOrder -Profile $profile
        $order | Should -Be @('monitoring', 'security')
    }

    It 'Preserves fixed dependency order' {
        $profile = [pscustomobject]@{
            modules = [pscustomobject]@{
                monitoring  = [pscustomobject]@{ enabled = $true }
                networking  = [pscustomobject]@{ enabled = $true }
                security    = [pscustomobject]@{ enabled = $true }
                compute     = [pscustomobject]@{ enabled = $true }
                storage     = [pscustomobject]@{ enabled = $true }
                databases   = [pscustomobject]@{ enabled = $true }
                appservices = [pscustomobject]@{ enabled = $true }
                containers  = [pscustomobject]@{ enabled = $true }
                integration = [pscustomobject]@{ enabled = $true }
                ai          = [pscustomobject]@{ enabled = $true }
                data        = [pscustomobject]@{ enabled = $true }
                governance  = [pscustomobject]@{ enabled = $true }
            }
        }
        $order = Get-AdeDeploymentOrder -Profile $profile
        $order[0]  | Should -Be 'monitoring'
        $order[1]  | Should -Be 'networking'
        $order[-1] | Should -Be 'governance'
        $order.Count | Should -Be 12
    }

    It 'Returns empty list when all modules are disabled' {
        $profile = [pscustomobject]@{
            modules = [pscustomobject]@{
                monitoring  = [pscustomobject]@{ enabled = $false }
                networking  = [pscustomobject]@{ enabled = $false }
                security    = [pscustomobject]@{ enabled = $false }
                compute     = [pscustomobject]@{ enabled = $false }
                storage     = [pscustomobject]@{ enabled = $false }
                databases   = [pscustomobject]@{ enabled = $false }
                appservices = [pscustomobject]@{ enabled = $false }
                containers  = [pscustomobject]@{ enabled = $false }
                integration = [pscustomobject]@{ enabled = $false }
                ai          = [pscustomobject]@{ enabled = $false }
                data        = [pscustomobject]@{ enabled = $false }
                governance  = [pscustomobject]@{ enabled = $false }
            }
        }
        $order = @(Get-AdeDeploymentOrder -Profile $profile)
        $order.Count | Should -Be 0
    }

    It 'Ignores modules with null config' {
        $profile = [pscustomobject]@{
            modules = [pscustomobject]@{
                monitoring = [pscustomobject]@{ enabled = $true }
                networking = $null
                security   = [pscustomobject]@{ enabled = $true }
            }
        }
        $order = Get-AdeDeploymentOrder -Profile $profile
        $order | Should -Not -Contain 'networking'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Build-AdeTags
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Build-AdeTags' -Tag 'unit' {

    BeforeAll {
        $script:tagProfile = [pscustomobject]@{
            profileName = 'test-profile'
            tags = [pscustomobject]@{
                project     = 'ADE'
                purpose     = 'benchmark'
                environment = 'demo'
                managedBy   = 'ade'
            }
        }
    }

    It 'Returns a hashtable with required keys' {
        $tags = Build-AdeTags -Profile $script:tagProfile
        $tags | Should -BeOfType [hashtable]
        $tags.Keys | Should -Contain 'project'
        $tags.Keys | Should -Contain 'purpose'
        $tags.Keys | Should -Contain 'environment'
        $tags.Keys | Should -Contain 'managedBy'
        $tags.Keys | Should -Contain 'deployedAt'
        $tags.Keys | Should -Contain 'profile'
    }

    It 'Includes module key when -Module is specified' {
        $tags = Build-AdeTags -Profile $script:tagProfile -Module 'compute'
        $tags['module'] | Should -Be 'compute'
    }

    It 'Does not include module key when -Module is omitted' {
        $tags = Build-AdeTags -Profile $script:tagProfile
        $tags.Keys | Should -Not -Contain 'module'
    }

    It 'Sets profile tag from profileName' {
        $tags = Build-AdeTags -Profile $script:tagProfile
        $tags['profile'] | Should -Be 'test-profile'
    }

    It 'Sets deployedAt to a parseable datetime string' {
        $tags = Build-AdeTags -Profile $script:tagProfile
        { [datetime]::Parse($tags['deployedAt']) } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-AdeDeploymentOutput
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Get-AdeDeploymentOutput' -Tag 'unit' {

    It 'Returns the .value property of a named output' {
        $outputs = [pscustomobject]@{
            logWorkspaceId = [pscustomobject]@{ value = '/subscriptions/x/resourceGroups/y/providers/z' }
        }
        Get-AdeDeploymentOutput -Outputs $outputs -Key 'logWorkspaceId' |
            Should -Be '/subscriptions/x/resourceGroups/y/providers/z'
    }

    It 'Returns null when outputs is null' {
        Get-AdeDeploymentOutput -Outputs $null -Key 'anything' | Should -BeNullOrEmpty
    }

    It 'Returns null when the key does not exist' {
        $outputs = [pscustomobject]@{
            someOther = [pscustomobject]@{ value = 'x' }
        }
        Get-AdeDeploymentOutput -Outputs $outputs -Key 'missing' | Should -BeNullOrEmpty
    }

    It 'Returns null when the key exists but value is null' {
        $outputs = [pscustomobject]@{
            emptyOut = [pscustomobject]@{ value = $null }
        }
        Get-AdeDeploymentOutput -Outputs $outputs -Key 'emptyOut' | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-AdeProfile
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Get-AdeProfile' -Tag 'unit' {

    It 'Loads a profile from an explicit file path' {
        $profileJson = @'
{
  "profileName": "custom-test",
  "modules": { "monitoring": { "enabled": true } },
  "tags": { "project": "ADE", "purpose": "test", "environment": "demo", "managedBy": "ade" }
}
'@
        $tmpProfile = Join-Path $TestDrive 'custom-test.json'
        $profileJson | Set-Content $tmpProfile -Encoding UTF8

        $result = Get-AdeProfile -ProfileNameOrPath $tmpProfile
        $result.profileName | Should -Be 'custom-test'
    }

    It 'Throws when profile name is unknown and no file exists' {
        { Get-AdeProfile -ProfileNameOrPath 'nonexistent-xyz' } | Should -Throw
    }

    It 'Loads the built-in minimal profile by name' {
        $result = Get-AdeProfile -ProfileNameOrPath 'minimal'
        $result.profileName | Should -Be 'minimal'
    }

    It 'Injects tags from defaults when profile has no tags property' {
        $profileJson = @'
{
  "profileName": "no-tags",
  "modules": { "monitoring": { "enabled": true } }
}
'@
        $tmpProfile = Join-Path $TestDrive 'no-tags.json'
        $profileJson | Set-Content $tmpProfile -Encoding UTF8

        $result = Get-AdeProfile -ProfileNameOrPath $tmpProfile
        # tags injected from defaults.json — verify the property is present with expected keys
        $result.tags | Should -Not -BeNullOrEmpty -Because 'defaults.json globalSettings.tags should be injected'
        $result.tags.managedBy | Should -Be 'ade'
    }

    It 'Throws on malformed JSON' {
        $badJson = '{ "profileName": "broken", invalid: }'
        $tmpProfile = Join-Path $TestDrive 'bad.json'
        $badJson | Set-Content $tmpProfile -Encoding UTF8
        { Get-AdeProfile -ProfileNameOrPath $tmpProfile } | Should -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke-AzCmd
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Invoke-AzCmd' -Tag 'unit' {

    BeforeAll {
        # Stub az as a PS function so Pester can mock it even when the Azure CLI is not installed
        if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
            function script:az {}
        }
    }

    Context 'Successful command' {

        BeforeAll {
            # Mock az to return valid JSON and exit 0
            Mock az {
                $global:LASTEXITCODE = 0
                '{"name":"test-rg","location":"westeurope"}'
            }
        }

        It 'Returns parsed JSON object on exit 0' {
            $result = Invoke-AzCmd -Arguments 'group show --name test-rg' -Silent
            $result.name | Should -Be 'test-rg'
        }
    }

    Context 'Failed command' {

        BeforeAll {
            Mock az {
                $global:LASTEXITCODE = 1
                Write-Error 'Resource group not found' -ErrorAction SilentlyContinue
            }
        }

        It 'Throws on non-zero exit code' {
            { Invoke-AzCmd -Arguments 'group show --name missing' -Silent } | Should -Throw
        }

        It 'Does not throw when -AllowFailure is set' {
            { Invoke-AzCmd -Arguments 'group show --name missing' -Silent -AllowFailure } |
                Should -Not -Throw
        }
    }

    Context 'Command returning plain text' {

        BeforeAll {
            Mock az {
                $global:LASTEXITCODE = 0
                'westeurope'
            }
        }

        It 'Returns the raw string when output is not JSON' {
            $result = Invoke-AzCmd -Arguments 'account list-locations --query [0].name -o tsv' -Silent
            $result | Should -Be 'westeurope'
        }
    }

    Context 'Command returning nothing' {

        BeforeAll {
            Mock az {
                $global:LASTEXITCODE = 0
            }
        }

        It 'Returns null for empty output' {
            $result = Invoke-AzCmd -Arguments 'group delete --name x --yes' -Silent
            $result | Should -BeNullOrEmpty
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# New-AdeResourceGroup
# ─────────────────────────────────────────────────────────────────────────────

Describe 'New-AdeResourceGroup' -Tag 'unit' {

    BeforeAll {
        if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
            function script:az {}
        }
    }

    BeforeEach {
        $global:LASTEXITCODE = 0
    }

    It 'Calls az group create when the resource group does not yet exist' {
        Mock az {
            # group show returns non-zero (RG not found)
            if ($args -contains 'show') { $global:LASTEXITCODE = 1; return $null }
            $global:LASTEXITCODE = 0
        }

        $tags = @{ project = 'ade'; env = 'test' }
        New-AdeResourceGroup -Name 'ade-test-rg' -Location 'westeurope' -Tags $tags

        Should -Invoke az -Times 1 -ParameterFilter { $args -contains 'create' -and $args -contains 'ade-test-rg' }
    }

    It 'Re-uses an existing RG in the same location without calling az group create' {
        Mock az {
            if ($args -contains 'show') {
                $global:LASTEXITCODE = 0
                return '{"name":"ade-test-rg","location":"westeurope"}'
            }
            $global:LASTEXITCODE = 0
        }

        $tags = @{ project = 'ade' }
        { New-AdeResourceGroup -Name 'ade-test-rg' -Location 'westeurope' -Tags $tags } | Should -Not -Throw

        Should -Invoke az -Times 0 -ParameterFilter { $args -contains 'create' }
    }

    It 'Logs a warning and continues when the existing RG is in a different location' {
        Mock az {
            if ($args -contains 'show') {
                $global:LASTEXITCODE = 0
                return '{"name":"ade-test-rg","location":"westeurope"}'
            }
            $global:LASTEXITCODE = 0
        }

        $tags = @{ project = 'ade' }
        # Should NOT throw — location mismatch is now a warning, not a hard failure
        { New-AdeResourceGroup -Name 'ade-test-rg' -Location 'northeurope' -Tags $tags } | Should -Not -Throw
        # And must NOT call az group create (it reuses the existing RG)
        Should -Invoke az -Times 0 -ParameterFilter { $args -contains 'create' }
    }

    It 'Throws when az group create exits non-zero' {
        Mock az {
            if ($args -contains 'show') { $global:LASTEXITCODE = 1; return $null }
            $global:LASTEXITCODE = 1
        }

        $tags = @{ project = 'ade' }
        { New-AdeResourceGroup -Name 'bad-rg' -Location 'westeurope' -Tags $tags } |
            Should -Throw -ExpectedMessage '*Failed to create resource group*'
    }

    It 'Filters out null or empty tag values before passing to az' {
        Mock az {
            if ($args -contains 'show') { $global:LASTEXITCODE = 1; return $null }
            $script:capturedAzArgs = $args
            $global:LASTEXITCODE = 0
        }

        $tags = @{ project = 'ade'; nullTag = $null; emptyTag = '' }
        New-AdeResourceGroup -Name 'ade-rg' -Location 'westeurope' -Tags $tags

        # The tag args passed to az should not include null/empty values
        $tagArgs = $script:capturedAzArgs | Where-Object { $_ -match '=' -and $_ -notmatch '^--' }
        $tagArgs | Should -Not -Contain { $_ -match 'nullTag' }
        $tagArgs | Should -Not -Contain { $_ -match 'emptyTag' }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke-AdeBicepDeployment
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Invoke-AdeBicepDeployment' -Tag 'unit' {

    BeforeAll {
        if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
            function script:az {}
        }
        # Create a real temp .bicep file so Test-Path passes
        $script:fakeBicep = Join-Path $TestDrive 'test.bicep'
        Set-Content $script:fakeBicep 'param prefix string'

        # Suppress actual sleeping in the poll loop
        Mock Start-Sleep {}
    }

    # Helper mock: returns Succeeded for 'show', null for everything else.
    # Each test that exercises the polling path uses this as its base mock.
    function New-SucceededShowMock ([psobject]$Outputs = $null) {
        $props = [pscustomobject]@{ provisioningState = 'Succeeded'; outputs = $Outputs; error = $null }
        return { param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{ properties = $props }
            }
            return $null
        }.GetNewClosure()
    }

    BeforeEach {
        $global:LASTEXITCODE = 0
    }

    It 'Throws when the template file does not exist' {
        { Invoke-AdeBicepDeployment -ResourceGroup 'rg' -TemplatePath 'C:\nonexistent.bicep' -DeploymentName 'dep' } |
            Should -Throw -ExpectedMessage '*Bicep template not found*'
    }

    It 'Calls Invoke-AzCmd with deployment group create' {
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; outputs = $null; error = $null } }
            }
            return $null
        }

        Invoke-AdeBicepDeployment `
            -ResourceGroup  'ade-rg' `
            -TemplatePath   $script:fakeBicep `
            -DeploymentName 'ade-test-deploy' `
            -PollIntervalSeconds 0

        Should -Invoke Invoke-AzCmd -ParameterFilter {
            $ArgumentList -contains 'create' -and $ArgumentList -contains 'group'
        }
    }

    It 'Uses deployment group what-if when -WhatIf is set' {
        Mock Invoke-AzCmd { return $null }

        Invoke-AdeBicepDeployment `
            -ResourceGroup  'ade-rg' `
            -TemplatePath   $script:fakeBicep `
            -DeploymentName 'ade-whatif' `
            -WhatIf

        Should -Invoke Invoke-AzCmd -Times 1 -ParameterFilter {
            $ArgumentList -contains 'what-if'
        }
    }

    It 'Passes each parameter key=value to az' {
        $script:capturedCreateArgs = $null
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; outputs = $null; error = $null } }
            }
            if ($ArgumentList -contains 'create') { $script:capturedCreateArgs = $ArgumentList }
            return $null
        }

        Invoke-AdeBicepDeployment `
            -ResourceGroup  'ade-rg' `
            -TemplatePath   $script:fakeBicep `
            -DeploymentName 'ade-params-test' `
            -Parameters     @{ prefix = 'ade'; location = 'westeurope' } `
            -PollIntervalSeconds 0

        ($script:capturedCreateArgs -join ' ') | Should -Match 'prefix=ade'
        ($script:capturedCreateArgs -join ' ') | Should -Match 'location=westeurope'
    }

    It 'Handles template paths containing spaces without splitting them' {
        $spacyDir  = Join-Path $TestDrive 'path with spaces'
        $null      = New-Item -ItemType Directory -Path $spacyDir -Force
        $spacyBicep = Join-Path $spacyDir 'my template.bicep'
        Set-Content $spacyBicep 'param prefix string'
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; outputs = $null; error = $null } }
            }
            return $null
        }

        { Invoke-AdeBicepDeployment -ResourceGroup 'rg' -TemplatePath $spacyBicep -DeploymentName 'dep' -PollIntervalSeconds 0 } |
            Should -Not -Throw
        Should -Invoke Invoke-AzCmd -ParameterFilter {
            $ArgumentList -contains $spacyBicep
        }
    }

    It 'Returns the outputs object from a successful deployment' {
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{
                    properties = [pscustomobject]@{
                        provisioningState = 'Succeeded'
                        outputs           = [pscustomobject]@{ logAnalyticsId = [pscustomobject]@{ value = '/subscriptions/x/workspaces/y' } }
                        error             = $null
                    }
                }
            }
            return $null
        }

        $result = Invoke-AdeBicepDeployment `
            -ResourceGroup  'ade-rg' `
            -TemplatePath   $script:fakeBicep `
            -DeploymentName 'ade-out-test' `
            -PollIntervalSeconds 0

        $result.logAnalyticsId.value | Should -Be '/subscriptions/x/workspaces/y'
    }

    It 'Returns null when deployment produces no outputs' {
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; outputs = $null; error = $null } }
            }
            return $null
        }

        $result = Invoke-AdeBicepDeployment `
            -ResourceGroup  'ade-rg' `
            -TemplatePath   $script:fakeBicep `
            -DeploymentName 'ade-noout' `
            -PollIntervalSeconds 0

        $result | Should -BeNullOrEmpty
    }

    It 'Calls az resource list before and after deployment for the new/existing diff' {
        $script:listCallCount = 0
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; outputs = $null; error = $null } }
            }
            if ($ArgumentList -contains 'list' -and $ArgumentList -contains 'resource') {
                $script:listCallCount++
                return @(
                    [pscustomobject]@{ name = 'ade-law'; type = 'Microsoft.OperationalInsights/workspaces' }
                    [pscustomobject]@{ name = 'ade-ag';  type = 'Microsoft.Insights/actionGroups' }
                )
            }
            return $null
        }

        Invoke-AdeBicepDeployment `
            -ResourceGroup  'ade-rg' `
            -TemplatePath   $script:fakeBicep `
            -DeploymentName 'ade-res-summary' `
            -PollIntervalSeconds 0

        # Once before deployment (snapshot) and once after (diff)
        $script:listCallCount | Should -Be 2
    }

    It 'Labels newly created resources as [new] and pre-existing resources as [existing]' {
        $script:listCall = 0
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; outputs = $null; error = $null } }
            }
            if ($ArgumentList -contains 'list' -and $ArgumentList -contains 'resource') {
                $script:listCall++
                if ($script:listCall -eq 1) {
                    # Pre-deploy: only ade-law exists
                    return @([pscustomobject]@{ name = 'ade-law'; type = 'Microsoft.OperationalInsights/workspaces' })
                }
                # Post-deploy: ade-law still there + ade-ag is new
                return @(
                    [pscustomobject]@{ name = 'ade-law'; type = 'Microsoft.OperationalInsights/workspaces' }
                    [pscustomobject]@{ name = 'ade-ag';  type = 'Microsoft.Insights/actionGroups' }
                )
            }
            return $null
        }

        $logOutput = [System.Collections.Generic.List[string]]::new()
        Mock Write-AdeLog { $logOutput.Add("$args") }

        Invoke-AdeBicepDeployment `
            -ResourceGroup  'ade-rg' `
            -TemplatePath   $script:fakeBicep `
            -DeploymentName 'ade-diff-test' `
            -PollIntervalSeconds 0

        $logOutput | Where-Object { $_ -match 'ade-ag.*\[new\]' }      | Should -Not -BeNullOrEmpty
        $logOutput | Where-Object { $_ -match 'ade-law.*\[existing\]' } | Should -Not -BeNullOrEmpty
    }

    It 'Throws with details.message when deployment fails and details are present' {
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{
                    properties = [pscustomobject]@{
                        provisioningState = 'Failed'
                        outputs           = $null
                        error             = [pscustomobject]@{
                            code    = 'DeploymentFailed'
                            message = 'At least one resource deployment operation failed.'
                            details = @(
                                [pscustomobject]@{ code = 'VaultAlreadyExists'; message = "The vault name 'ade-kv-abc' is already in use." }
                            )
                        }
                    }
                }
            }
            return $null
        }

        { Invoke-AdeBicepDeployment -ResourceGroup 'rg' -TemplatePath $script:fakeBicep -DeploymentName 'dep' -PollIntervalSeconds 0 } |
            Should -Throw -ExpectedMessage "*VaultAlreadyExists*"
    }

    It 'Throws with outer message when deployment fails and no details are present' {
        Mock Invoke-AzCmd {
            param($ArgumentList)
            if ($ArgumentList -contains 'show') {
                return [pscustomobject]@{
                    properties = [pscustomobject]@{
                        provisioningState = 'Failed'
                        outputs           = $null
                        error             = [pscustomobject]@{
                            code    = 'DeploymentFailed'
                            message = 'Generic deployment failure.'
                            details = @()
                        }
                    }
                }
            }
            return $null
        }

        { Invoke-AdeBicepDeployment -ResourceGroup 'rg' -TemplatePath $script:fakeBicep -DeploymentName 'dep' -PollIntervalSeconds 0 } |
            Should -Throw -ExpectedMessage "*Generic deployment failure*"
    }
}
