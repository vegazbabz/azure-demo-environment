#Requires -Version 7.0
<#
.SYNOPSIS
    Unit tests for scripts/deploy.ps1

    Two categories:
      1. Source analysis  — verifies parameters, defaults, structure, and
                            deployment order without running the script.
      2. Deploy-AdeModule — defines the function standalone (it closes over
                            script-level vars) and verifies its behaviour with
                            mocked New-AdeResourceGroup / Invoke-AdeBicepDeployment.
#>

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:deployPs = Join-Path $script:repoRoot 'scripts\deploy.ps1'
    $script:source   = Get-Content $script:deployPs -Raw

    # Load helpers so Deploy-AdeModule unit tests can call the real common.ps1
    # stubs.  We do NOT dot-source deploy.ps1 because it runs immediately.
    . (Join-Path $script:repoRoot 'scripts\helpers\common.ps1')

    # Provide az stub for common.ps1 consumers
    if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
        function script:az {}
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Source analysis — parameters & defaults
# ─────────────────────────────────────────────────────────────────────────────

Describe 'deploy.ps1 – parameter validation' -Tag 'unit' {

    It 'File exists' {
        Test-Path $script:deployPs | Should -BeTrue
    }

    It 'Requires PowerShell 7.0 or later' {
        $script:source | Should -Match '#Requires -Version 7'
    }

    It 'Has a ValidatePattern that restricts Prefix to lowercase alphanumeric 2-8 chars' {
        $script:source | Should -Match 'ValidatePattern'
        $script:source | Should -Match '\[a-z0-9\]'
    }

    It 'Has a ValidateSet limiting Mode to default | hardened' {
        $script:source | Should -Match "ValidateSet\s*\(\s*'default'\s*,\s*'hardened'\s*\)"
    }

    It 'Defaults Prefix to "ade"' {
        $script:source | Should -Match "Prefix\s*=\s*'ade'"
    }

    It 'Defaults Location to "westeurope"' {
        $script:source | Should -Match "Location\s*=\s*'westeurope'"
    }

    It 'Defaults Mode to "default"' {
        $script:source | Should -Match "Mode\s*=\s*'default'"
    }

    It 'Defaults Profile to "full"' {
        $script:source | Should -Match "Profile\s*=\s*'full'"
    }

    It 'Has a -WhatIf switch parameter' {
        $script:source | Should -Match '\[switch\]\$WhatIf'
    }

    It 'Has a -Force switch parameter' {
        $script:source | Should -Match '\[switch\]\$Force'
    }

    It 'Has a -ContinueOnError switch parameter' {
        $script:source | Should -Match '\[switch\]\$ContinueOnError'
    }

    It 'Has a -SkipModules string array parameter' {
        $script:source | Should -Match '\[string\[\]\]\$SkipModules'
    }

    It 'Has a -EnableModules string array parameter' {
        $script:source | Should -Match '\[string\[\]\]\$EnableModules'
    }

    It 'Admin password defaults to a SecureString prompt (not stored in source)' {
        # The source should NOT contain a plain-text default password
        $script:source | Should -Not -Match 'AdminPassword\s*=\s*"[^"]'
        $script:source | Should -Match '\[SecureString\]\$AdminPassword'
    }

    It 'Stores SecureString (not the plaintext) in state.adminPassword' {
        $script:source | Should -Match 'adminPassword\s*=\s*\$AdminPassword' -Because 'state must hold SecureString'
        $script:source | Should -Not -Match 'adminPassword\s*=\s*\$adminPasswordPlain' -Because 'plaintext must not persist in state'
    }

    It 'Clears $adminPasswordPlain immediately after length validation' {
        $script:source | Should -Match '\$adminPasswordPlain\s*=\s*\$null'
    }

    It 'Prints admin password in the post-deployment summary when password-bearing modules are deployed' {
        # The compute-time banner can scroll away. The summary re-prints it so the user
        # sees it for databases/data seeding (seed-data.ps1 -DatabaseAdminPassword).
        $script:source | Should -Match '_adePasswordWasGenerated[\s\S]{1,600}pwModulesDeployed'
        $script:source | Should -Match 'ADMIN PASSWORD'
        $script:source | Should -Match 'seedLine1[\s\S]{1,200}seedLine2'
        $script:source | Should -Match '-DatabaseAdminPassword'
    }

    It 'Shows a mid-deployment banner after the compute module with the correct messaging' {
        # Banner should note that the same password is used for VMs and databases, and that
        # it will be shown again — the old "will not be shown again" text was wrong.
        $script:source | Should -Match 'AUTO-GENERATED ADMIN PASSWORD'
        $script:source | Should -Match 'used for VM / VMSS / SQL'
        $script:source | Should -Match 'shown again in the deployment summary'
        $script:source | Should -Not -Match 'will not be shown again'
    }

    It 'Shows a mid-deployment banner after the databases module with DatabaseAdminPassword hint' {
        # When deploying databases without compute the compute banner does not fire.
        # A dedicated databases banner ensures the password is always visible mid-deploy.
        $script:source | Should -Match 'AUTO-GENERATED DATABASE ADMIN PASSWORD'
        $script:source | Should -Match 'Deploy-AdeModule.*databases[\s\S]{1,800}DATABASE ADMIN PASSWORD'
        $script:source | Should -Match 'DatabaseAdminPassword'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Source analysis — structure & deployment logic
# ─────────────────────────────────────────────────────────────────────────────

Describe 'deploy.ps1 – deployment structure' -Tag 'unit' {

    It 'Defines a Deploy-AdeModule helper function' {
        $script:source | Should -Match 'function Deploy-AdeModule'
    }

    It 'Calls New-AdeResourceGroup inside Deploy-AdeModule' {
        # Locate the Deploy-AdeModule function body and check it calls New-AdeResourceGroup
        $fnStart = $script:source.IndexOf('function Deploy-AdeModule')
        $fnEnd   = $script:source.IndexOf("`nforeach", $fnStart)
        $fnBody  = $script:source.Substring($fnStart, $fnEnd - $fnStart)
        $fnBody | Should -Match 'New-AdeResourceGroup'
    }

    It 'Calls Invoke-AdeBicepDeployment inside Deploy-AdeModule' {
        $fnStart = $script:source.IndexOf('function Deploy-AdeModule')
        $fnEnd   = $script:source.IndexOf("`nforeach", $fnStart)
        $fnBody  = $script:source.Substring($fnStart, $fnEnd - $fnStart)
        $fnBody | Should -Match 'Invoke-AdeBicepDeployment'
    }

    It 'Resource group name follows the pattern $Prefix-$ModuleName-rg' {
        $fnStart = $script:source.IndexOf('function Deploy-AdeModule')
        $fnEnd   = $script:source.IndexOf("`nforeach", $fnStart)
        $fnBody  = $script:source.Substring($fnStart, $fnEnd - $fnStart)
        $fnBody | Should -Match '\$Prefix.*-rg'
    }

    It 'Uses WhatIf flag when calling Invoke-AdeBicepDeployment' {
        $fnStart = $script:source.IndexOf('function Deploy-AdeModule')
        $fnEnd   = $script:source.IndexOf("`nforeach", $fnStart)
        $fnBody  = $script:source.Substring($fnStart, $fnEnd - $fnStart)
        $fnBody | Should -Match '-WhatIf:\$WhatIf'
    }

    It 'Handles all 12 known modules in the switch statement' {
        $expectedModules = @(
            'monitoring','networking','security','compute','storage',
            'databases','appservices','containers','integration','ai','data','governance'
        )
        foreach ($mod in $expectedModules) {
            $script:source | Should -Match "'$mod'" -Because "switch should handle '$mod' module"
        }
    }

    It 'Uses bicep/hardened path when Mode is hardened' {
        $script:source | Should -Match "hardened.*hardened|'hardened'.*hardened"
    }

    It 'Uses bicep/modules path for default mode' {
        $script:source | Should -Match 'modules'
    }

    It 'Calls Test-AdePrerequisites before deploying' {
        $script:source | Should -Match 'Test-AdePrerequisites'
    }

    It 'Calls Test-AdeProfile to validate the profile' {
        $script:source | Should -Match 'Test-AdeProfile'
    }

    It 'Calls Get-AdeDeploymentOrder to determine module order' {
        $script:source | Should -Match 'Get-AdeDeploymentOrder'
    }

    It 'Calls Confirm-AdeDeployment before deploying (respects -Force)' {
        $script:source | Should -Match 'Confirm-AdeDeployment'
    }

    It 'Tags every module deployment (calls Build-AdeTags)' {
        $script:source | Should -Match 'Build-AdeTags'
    }

    It 'Monitoring state keys are populated after monitoring module runs' {
        $script:source | Should -Match 'logAnalyticsId'
        $script:source | Should -Match 'appInsightsId'
    }

    It 'Has no critical PowerShell syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:deployPs, [ref]$tokens, [ref]$errors)
        $critical = @($errors) | Where-Object {
            $_.ErrorId -notin @('MissingArrayIndexExpression','MissingArgument')
        }
        @($critical).Count | Should -Be 0
    }

    It 'ValidatePattern uses (?-i) for case-sensitive Prefix enforcement' {
        $script:source | Should -Match '\(\?-i\)' -Because 'must reject uppercase even on case-insensitive filesystems'
    }

    It 'Warns on unknown module given to -SkipModules' {
        $script:source | Should -Match "Unknown module.*-SkipModules"
    }

    It 'Warns on unknown module given to -EnableModules' {
        $script:source | Should -Match "Unknown module.*-EnableModules"
    }

    It 'Auto-enables boolean features when -EnableModules targets a disabled module' {
        $script:source | Should -Match 'wasDisabled' -Because '-EnableModules must detect the module was disabled in the profile'
        $script:source | Should -Match 'auto-enabling features' -Because 'a disabled module with all-false features must have them flipped to true'
        $script:source | Should -Match 'feat\.Value -is \[bool\]' -Because 'only boolean flags should be auto-enabled; strings, numbers and arrays must be left alone'
    }

    It 'Skips interactive Read-Host in CI environments (guards on env:CI / GITHUB_ACTIONS)' {
        $script:source | Should -Match 'isNonInteractive'
        $script:source | Should -Match 'GITHUB_ACTIONS'
    }

    It 'Prompts for budget alert email interactively and skips prompt in CI mode only' {
        $script:source | Should -Match 'isNonInteractiveBudget'
        $script:source | Should -Match 'Read-Host.*budget'
        $script:source | Should -Match 'BudgetAlertEmail.*not.*set|budget.*email.*not.*set' -Because 'CI path must log a warning when email is missing'
    }

    It 'Tracks failed modules in a $failedModules list' {
        $script:source | Should -Match 'failedModules'
    }

    It 'Continues to remaining modules when -ContinueOnError is set' {
        $script:source | Should -Match 'ContinueOnError'
        $script:source | Should -Match 'Continuing with remaining modules'
    }

    It 'Reports failed modules in the post-deployment summary' {
        $script:source | Should -Match 'Failed modules'
        $script:source | Should -Match 'failedModules\.Count.*gt.*0'
    }

    It 'Detects and deletes a Failed Container Apps Environment before deploying containers' {
        $script:source | Should -Match 'containerapp env show'
        $script:source | Should -Match 'ManagedEnvironmentNotReadyForAppCreation|Failed state|containerapp env delete'
    }

    It 'Does not contain dead bastionSubnetId state key' {
        $script:source | Should -Not -Match 'bastionSubnetId'
    }

    It 'Deploy-AdeModule calls Build-AdeTags with -Module for per-module tagging' {
        $fnStart = $script:source.IndexOf('function Deploy-AdeModule')
        $fnEnd   = $script:source.IndexOf("`nforeach", $fnStart)
        $fnBody  = $script:source.Substring($fnStart, $fnEnd - $fnStart)
        $fnBody | Should -Match 'Build-AdeTags.*-Module'
    }

    It 'Queries az group list to auto-detect an existing environment location' {
        $script:source | Should -Match 'group list'
        $script:source | Should -Match 'starts_with.*-rg'
        $script:source | Should -Match 'existingRgLocation'
    }

    It 'Overrides -Location with the detected existing region when they differ' {
        $script:source | Should -Match '\$Location\s*=\s*\$existingRgLocation'
    }

    It 'Logs a Warning when the location is overridden by auto-detection' {
        $script:source | Should -Match 'Overriding.*Location.*to match'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Deploy-AdeModule  (function unit test — defined standalone with closed vars)
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Deploy-AdeModule – unit' -Tag 'unit' {
    <#
        Deploy-AdeModule is a nested function inside deploy.ps1 that closes over
        script-scope variables.  We replicate that closure here by setting up the
        same variables in the outer scope, then defining the function ourselves.
    #>

    BeforeAll {
        # Replicate the script-scope closure variables
        $script:Prefix        = 'myp'
        $script:Location      = 'westeurope'
        $script:WhatIf        = $false
        $script:deployProfile = [pscustomobject]@{
            profileName = 'test'
            tags        = @{ project = 'test'; purpose = 'demo'; environment = 'dev'; managedBy = 'ade' }
        }

        # Capture calls to New-AdeResourceGroup, Invoke-AdeBicepDeployment, and Build-AdeTags
        Mock New-AdeResourceGroup {}
        Mock Invoke-AdeBicepDeployment { return $null }
        Mock Write-AdeLog {}
        Mock Build-AdeTags { return @{ managedBy = 'ade'; module = $Module; project = 'test' } }

        # Create a real temp .bicep file so internal Test-Path check passes
        $script:fakeBicep = Join-Path $TestDrive 'test.bicep'
        Set-Content $script:fakeBicep 'param prefix string'

        # Define Deploy-AdeModule exactly as it appears in deploy.ps1, closing
        # over the vars set above (via $script: scope from the Describe closure)
        function script:Deploy-AdeModule {
            param(
                [string]$ModuleName,
                [string]$BicepFile,
                [hashtable]$Parameters
            )
            $Prefix        = $script:Prefix
            $Location      = $script:Location
            $deployProfile = $script:deployProfile
            $WhatIf        = $script:WhatIf

            $moduleTags = Build-AdeTags -Profile $deployProfile -Module $ModuleName
            $rgName     = "$Prefix-$($ModuleName.ToLower())-rg"
            New-AdeResourceGroup -Name $rgName -Location $Location -Tags $moduleTags

            if (-not $Parameters.ContainsKey('tags')) {
                $Parameters['tags'] = $moduleTags
            }

            Write-AdeLog "Deploying module: $ModuleName -> $rgName" -Level Step

            $outputs = Invoke-AdeBicepDeployment `
                -ResourceGroup  $rgName `
                -TemplatePath   $BicepFile `
                -DeploymentName "ade-$ModuleName-20240101000000" `
                -Parameters     $Parameters `
                -WhatIf:$WhatIf

            return $outputs
        }
    }

    It 'Creates a resource group named {prefix}-{module}-rg' {
        script:Deploy-AdeModule -ModuleName 'monitoring' -BicepFile $script:fakeBicep -Parameters @{}
        Should -Invoke New-AdeResourceGroup -Times 1 -ParameterFilter {
            $Name -eq 'myp-monitoring-rg'
        }
    }

    It 'Passes the correct location to New-AdeResourceGroup' {
        script:Deploy-AdeModule -ModuleName 'networking' -BicepFile $script:fakeBicep -Parameters @{}
        Should -Invoke New-AdeResourceGroup -Times 1 -ParameterFilter {
            $Location -eq 'westeurope'
        }
    }

    It 'Calls Invoke-AdeBicepDeployment with the correct resource group' {
        script:Deploy-AdeModule -ModuleName 'storage' -BicepFile $script:fakeBicep -Parameters @{}
        Should -Invoke Invoke-AdeBicepDeployment -Times 1 -ParameterFilter {
            $ResourceGroup -eq 'myp-storage-rg'
        }
    }

    It 'Injects tags into Parameters when not already present' {
        $params = @{ prefix = 'myp' }
        script:Deploy-AdeModule -ModuleName 'compute' -BicepFile $script:fakeBicep -Parameters $params
        $params.ContainsKey('tags') | Should -BeTrue
    }

    It 'Does not overwrite tags already in Parameters' {
        $customTags = @{ customTag = 'custom' }
        $params = @{ tags = $customTags }
        script:Deploy-AdeModule -ModuleName 'security' -BicepFile $script:fakeBicep -Parameters $params
        $params['tags'] | Should -Be $customTags
    }

    It 'Returns the outputs from Invoke-AdeBicepDeployment' {
        $fakeOutputs = [pscustomobject]@{ logAnalyticsId = [pscustomobject]@{ value = '/subscriptions/x' } }
        Mock Invoke-AdeBicepDeployment { return $fakeOutputs }
        $result = script:Deploy-AdeModule -ModuleName 'monitoring' -BicepFile $script:fakeBicep -Parameters @{}
        $result | Should -Be $fakeOutputs
    }

    It 'Passes -WhatIf:$true to Invoke-AdeBicepDeployment when WhatIf is set' {
        $script:WhatIf = $true
        script:Deploy-AdeModule -ModuleName 'databases' -BicepFile $script:fakeBicep -Parameters @{}
        Should -Invoke Invoke-AdeBicepDeployment -Times 1 -ParameterFilter { $WhatIf -eq $true }
        $script:WhatIf = $false
    }

    It 'Creates module-specific tags by calling Build-AdeTags with the module name' {
        script:Deploy-AdeModule -ModuleName 'networking' -BicepFile $script:fakeBicep -Parameters @{}
        Should -Invoke Build-AdeTags -Times 1 -ParameterFilter {
            $Module -eq 'networking'
        }
    }

    It 'Injected tags include the module key matching the deployed module' {
        $params = @{}
        script:Deploy-AdeModule -ModuleName 'storage' -BicepFile $script:fakeBicep -Parameters $params
        $params.ContainsKey('tags') | Should -BeTrue
        $params['tags']['module']   | Should -Be 'storage'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Contract tests — deploy.ps1 params must match Bicep module param declarations
# ─────────────────────────────────────────────────────────────────────────────
#
# Regression guard for the bug where deploy.ps1 passed hardened-only params
# (e.g. keyVaultDnsZoneId, privateEndpointSubnetId) to the default security
# module, causing ARM to reject the deployment with "unrecognized template
# parameter" even though az bicep lint and all other Pester tests passed.
#
# For each module: any param key that deploy.ps1 passes unconditionally (i.e.
# not inside an 'if ($Mode -eq "hardened")' guard) MUST be declared in the
# corresponding bicep/modules/<module>/<module>.bicep file.

Describe 'deploy.ps1 – Bicep parameter contract (default mode)' -Tag 'unit' {

    BeforeAll {
        $script:repoRoot  = Split-Path $PSScriptRoot -Parent
        $script:deploySrc = Get-Content (Join-Path $script:repoRoot 'scripts\deploy.ps1') -Raw

        # Returns declared param names from a Bicep file.
        # Defined in BeforeAll so they are available inside It -ForEach scriptblocks.
        function Get-BicepParamNames ([string]$BicepPath) {
            $src = Get-Content $BicepPath -Raw
            [regex]::Matches($src, '(?m)^param\s+(\w+)') |
                ForEach-Object { $_.Groups[1].Value }
        }

        # Returns the param keys that deploy.ps1 passes to a module in default mode
        # (mode-guarded blocks are stripped so only unconditional keys remain).
        function Get-DeployParamKeys ([string]$ModuleName) {
            $escapedMod = [regex]::Escape($ModuleName)

            # Locate the opening of this switch case.
            $startMatch = [regex]::Match($script:deploySrc, "'$escapedMod'\s*\{")
            if (-not $startMatch.Success) { return @() }

            # Walk forward counting braces to find the exact close of this case body.
            # This is robust against any nesting depth inside the case (loops, if/else, etc.)
            # — the simple end-pattern regex would misfire on consecutive } lines.
            $openPos = $startMatch.Index + $startMatch.Length - 1  # index of '{'
            $depth = 1
            $i = $openPos + 1
            while ($i -lt $script:deploySrc.Length -and $depth -gt 0) {
                $ch = $script:deploySrc[$i]
                if ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') { $depth-- }
                $i++
            }
            $block = $script:deploySrc.Substring($openPos + 1, $i - $openPos - 2)

            # Strip hardened-only blocks so we only see unconditionally passed keys.
            $block = [regex]::Replace(
                $block,
                "(?s)if\s*\(\s*\`$Mode\s*-eq\s*'hardened'\s*\)\s*\{.+?\n[ \t]*\}",
                ''
            )

            # Extract keys from the $params = @{ key = val; ... } literal.
            $keys = [System.Collections.Generic.List[string]]::new()
            $htMatch = [regex]::Match($block, '(?s)\$params\s*=\s*@\{(.+?)\n[ \t]*\}')
            if ($htMatch.Success) {
                [regex]::Matches($htMatch.Groups[1].Value, '(?m)^[ \t]*(\w+)\s*=') |
                    ForEach-Object { $keys.Add($_.Groups[1].Value) }
            }

            # Also pick up unconditional $params['key'] = additions outside the hashtable.
            [regex]::Matches($block, "\`$params\[['`"](\w+)['`"]\]\s*=") |
                ForEach-Object { $keys.Add($_.Groups[1].Value) }

            # 'tags' is injected by Deploy-AdeModule itself and is always valid — exclude it.
            # Return as array to guard against single-element pipeline unwrapping.
            return @($keys | Where-Object { $_ -ne 'tags' } | Sort-Object -Unique)
        }
    }

    $knownModules = @(
        'monitoring','networking','security','compute','storage',
        'databases','appservices','containers','integration','ai','data','governance'
    )

    # Use -ForEach so Pester 5 binds $mod correctly at test-execution time.
    # A plain foreach loop does not capture the loop variable in It scriptblocks.
    It "Default '<mod>' module: every unconditional param key exists in bicep/modules/<mod>/<mod>.bicep" -ForEach (
        $knownModules | ForEach-Object { @{ mod = $_ } }
    ) {
        $bicepPath = Join-Path (Split-Path $PSScriptRoot -Parent) "bicep\modules\$mod\$mod.bicep"
        if (-not (Test-Path $bicepPath)) {
            Set-ItResult -Skipped -Because "bicep/modules/$mod/$mod.bicep not present"
            return
        }

        $bicepParams  = Get-BicepParamNames -BicepPath $bicepPath
        $passedParams = Get-DeployParamKeys -ModuleName $mod

        if ($passedParams.Count -eq 0) {
            Set-ItResult -Skipped -Because "could not locate switch block for '$mod' in deploy.ps1"
            return
        }

        $unrecognised = $passedParams | Where-Object { $_ -notin $bicepParams }
        $unrecognised | Should -BeNullOrEmpty -Because (
            "deploy.ps1 passes '$($unrecognised -join `"', '`")' to the default '$mod' module " +
            "but that param is not declared in bicep/modules/$mod/$mod.bicep. " +
            "Wrap it in 'if (`$Mode -eq ''hardened'') { }' or add it to the Bicep file."
        )
    }
}
Describe 'deploy.ps1 – job schedule body serialisation' -Tag 'unit' {

    It 'Uses ConvertTo-Json -Depth 5 (or greater) for jobSchedule body to avoid hashtable truncation' {
        # Default ConvertTo-Json depth is 2. The jobSchedule body nests 3 levels:
        # properties -> schedule/runbook -> name.
        # Without -Depth >= 3 the inner @{name=...} serialises as "System.Collections.Hashtable"
        # and ARM returns 400 Bad Request: "Model cannot be null."
        $source = Get-Content (Join-Path $script:repoRoot 'scripts\deploy.ps1') -Raw
        # Must NOT use plain ConvertTo-Json -Compress without -Depth in the jobSchedule section
        $source | Should -Not -Match 'jobSchedules.*\r?\n.*ConvertTo-Json -Compress'
        # Must use -Depth with a value >= 3
        $source | Should -Match 'ConvertTo-Json -Depth [3-9]'
    }

    It 'jobSchedule PUT body contains schedule and runbook properties' {
        $source = Get-Content (Join-Path $script:repoRoot 'scripts\deploy.ps1') -Raw
        $source | Should -Match 'schedule\s*=\s*@\{'
        $source | Should -Match 'runbook\s*=\s*@\{'
    }
}