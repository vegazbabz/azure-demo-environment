#Requires -Version 7.0
<#
.SYNOPSIS
    Unit tests for the AzureDemoEnvironment PowerShell Gallery module.

    Three categories:
      1. Manifest         — AzureDemoEnvironment.psd1 parses, carries the
                            Gallery metadata, and its version matches the
                            latest CHANGELOG release.
      2. Parameter parity — every wrapper function in the psm1 mirrors the
                            parameter surface (names and types) of the script
                            it forwards to, so script defaults keep applying.
      3. Package builder  — tools/Build-ModulePackage.ps1 stages exactly the
                            runtime files (no tests/docs/workflows, no
                            compiled ARM JSON) and the result imports cleanly.
#>

BeforeAll {
    $script:repoRoot     = Split-Path $PSScriptRoot -Parent
    $script:manifestPath = Join-Path $script:repoRoot 'AzureDemoEnvironment.psd1'
    $script:psm1Path     = Join-Path $script:repoRoot 'AzureDemoEnvironment.psm1'
    $script:manifestData = Import-PowerShellDataFile $script:manifestPath

    # Wrapper function → wrapped script, single source of truth for parity tests.
    $script:wrapperMap = @{
        'Deploy-AdeEnvironment'  = Join-Path $script:repoRoot 'scripts\deploy.ps1'
        'Remove-AdeEnvironment'  = Join-Path $script:repoRoot 'scripts\destroy.ps1'
        'Initialize-AdeSeedData' = Join-Path $script:repoRoot 'scripts\seed-data.ps1'
        'Get-AdeCostDashboard'   = Join-Path $script:repoRoot 'scripts\dashboard\Get-AdeCostDashboard.ps1'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Manifest
# ─────────────────────────────────────────────────────────────────────────────

Describe 'AzureDemoEnvironment.psd1 – manifest' -Tag 'unit' {

    It 'Manifest and root module files exist' {
        Test-Path $script:manifestPath | Should -BeTrue
        Test-Path $script:psm1Path     | Should -BeTrue
    }

    It 'Passes Test-ModuleManifest' {
        { Test-ModuleManifest $script:manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'ModuleVersion matches the latest CHANGELOG release' {
        $changelog = Get-Content (Join-Path $script:repoRoot 'CHANGELOG.md') -Raw
        $latest    = [regex]::Match($changelog, '## \[(\d+\.\d+\.\d+)\]').Groups[1].Value
        $script:manifestData.ModuleVersion | Should -Be $latest
    }

    It 'Exports exactly the four wrapper functions' {
        $script:manifestData.FunctionsToExport |
            Should -Be @('Deploy-AdeEnvironment', 'Remove-AdeEnvironment',
                         'Initialize-AdeSeedData', 'Get-AdeCostDashboard')
    }

    It 'Exports no cmdlets, variables, or aliases' {
        $script:manifestData.CmdletsToExport   | Should -BeNullOrEmpty
        $script:manifestData.VariablesToExport | Should -BeNullOrEmpty
        $script:manifestData.AliasesToExport   | Should -BeNullOrEmpty
    }

    It 'Requires PowerShell 7.0 on the Core edition' {
        $script:manifestData.PowerShellVersion    | Should -Be '7.0'
        $script:manifestData.CompatiblePSEditions | Should -Be @('Core')
    }

    It 'Declares no RequiredModules (Azure CLI only, no Az modules)' {
        $script:manifestData.Keys | Should -Not -Contain 'RequiredModules'
    }

    It 'Carries the Gallery compatibility tags' {
        $tags = $script:manifestData.PrivateData.PSData.Tags
        foreach ($t in 'PSEdition_Core', 'Windows', 'Linux', 'MacOS') {
            $tags | Should -Contain $t
        }
    }

    It 'Uses only single-word tags (Gallery requirement)' {
        $script:manifestData.PrivateData.PSData.Tags | Should -Not -Match '\s'
    }

    It 'Has https Gallery URIs' {
        $psdata = $script:manifestData.PrivateData.PSData
        foreach ($key in 'IconUri', 'LicenseUri', 'ProjectUri', 'ReleaseNotes') {
            $psdata[$key] | Should -Match '^https://'
        }
    }

    It 'Description warns about real Azure costs' {
        $script:manifestData.Description | Should -Match 'billable'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Wrapper ↔ script parameter parity
# ─────────────────────────────────────────────────────────────────────────────

Describe 'AzureDemoEnvironment.psm1 – parameter parity' -Tag 'unit' {

    BeforeAll {
        Import-Module $script:manifestPath -Force

        # The engine-injected common parameters (Verbose, ErrorAction, …) exist
        # on both sides; everything else — including a declared -WhatIf and the
        # ShouldProcess-generated WhatIf/Confirm pair — must match exactly.
        $script:commonParams = [System.Management.Automation.PSCmdlet]::CommonParameters

        $script:GetOwnParams = {
            param([System.Management.Automation.CommandInfo]$Command)
            $Command.Parameters.GetEnumerator() |
                Where-Object { $script:commonParams -notcontains $_.Key } |
                Sort-Object -Property Key
        }
    }

    AfterAll {
        Remove-Module AzureDemoEnvironment -Force -ErrorAction SilentlyContinue
    }

    It 'Module imports and exports exactly the four wrapper functions' {
        $exported = (Get-Module AzureDemoEnvironment).ExportedFunctions.Keys | Sort-Object
        $exported | Should -Be ($script:wrapperMap.Keys | Sort-Object)
    }

    It '<_> mirrors the parameter names of its script' -ForEach @(
        'Deploy-AdeEnvironment', 'Remove-AdeEnvironment',
        'Initialize-AdeSeedData', 'Get-AdeCostDashboard'
    ) {
        $wrapper = & $script:GetOwnParams (Get-Command $_ -Module AzureDemoEnvironment)
        $target  = & $script:GetOwnParams (Get-Command $script:wrapperMap[$_])
        @($wrapper).Key | Should -Be @($target).Key
    }

    It '<_> mirrors the parameter types of its script' -ForEach @(
        'Deploy-AdeEnvironment', 'Remove-AdeEnvironment',
        'Initialize-AdeSeedData', 'Get-AdeCostDashboard'
    ) {
        $wrapper = & $script:GetOwnParams (Get-Command $_ -Module AzureDemoEnvironment)
        $target  = & $script:GetOwnParams (Get-Command $script:wrapperMap[$_])
        @($wrapper).ForEach({ $_.Value.ParameterType.FullName }) |
            Should -Be @($target).ForEach({ $_.Value.ParameterType.FullName })
    }

    It 'Wrappers declare no parameter defaults (script defaults stay single-sourced)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:psm1Path, [ref]$null, [ref]$null)
        $withDefaults = $ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $null -ne $n.DefaultValue },
            $true)
        @($withDefaults).ForEach({ $_.Name.VariablePath.UserPath }) | Should -BeNullOrEmpty
    }

    It 'Wrappers forward only bound parameters via @PSBoundParameters' {
        $source = Get-Content $script:psm1Path -Raw
        ([regex]::Matches($source, '@PSBoundParameters')).Count | Should -Be 4
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Package builder
# ─────────────────────────────────────────────────────────────────────────────

Describe 'tools/Build-ModulePackage.ps1 – staged package' -Tag 'unit' {

    BeforeAll {
        $builder = Join-Path $script:repoRoot 'tools\Build-ModulePackage.ps1'
        $script:stageDir = & $builder -OutputPath (Join-Path $TestDrive 'pkg') |
            Select-Object -Last 1
    }

    AfterAll {
        Remove-Module AzureDemoEnvironment -Force -ErrorAction SilentlyContinue
    }

    It 'Stages the manifest, root module, license, and readme' {
        foreach ($f in 'AzureDemoEnvironment.psd1', 'AzureDemoEnvironment.psm1',
                       'LICENSE', 'README.md') {
            Join-Path $script:stageDir $f | Should -Exist
        }
    }

    It 'Stages the four runtime asset directories the scripts resolve' {
        foreach ($p in 'scripts\deploy.ps1', 'scripts\helpers\common.ps1',
                       'bicep\modules', 'bicep\hardened',
                       'config\profiles\full.json', 'config\defaults.json',
                       'data\sql') {
            Join-Path $script:stageDir $p | Should -Exist
        }
    }

    It 'Ships no repository-only content' {
        foreach ($p in 'tests', 'docs', 'tools', '.github', '.config', 'CHANGELOG.md') {
            Join-Path $script:stageDir $p | Should -Not -Exist
        }
    }

    It 'Ships no compiled ARM JSON under bicep/' {
        Get-ChildItem (Join-Path $script:stageDir 'bicep') -Recurse -Filter '*.json' -File |
            Should -BeNullOrEmpty
    }

    It 'Ships no placeholder or log files' {
        Get-ChildItem $script:stageDir -Recurse -Force -Include '.gitkeep', '*.log', '*.tmp' -File |
            Should -BeNullOrEmpty
    }

    It 'Staged manifest version matches the repo manifest' {
        (Import-PowerShellDataFile (Join-Path $script:stageDir 'AzureDemoEnvironment.psd1')).ModuleVersion |
            Should -Be $script:manifestData.ModuleVersion
    }
}
