#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
<#
.SYNOPSIS
    Schema validation tests for every config/profiles/*.json file.

    Pure JSON tests — no az CLI, no mocks, no Azure subscription required.
    Guards against accidental schema breaks when editing profiles.
#>

BeforeDiscovery {
    $profileCases = Get-ChildItem (Join-Path $PSScriptRoot '..\..\config\profiles') -Filter '*.json' |
        ForEach-Object { @{ ProfileFile = $_ } }
}

# ─── Required top-level keys ─────────────────────────────────────────────────

Describe 'Profile schema — <ProfileFile.BaseName>' -ForEach $profileCases {

    BeforeAll {
        $script:profile = Get-Content $ProfileFile.FullName -Raw | ConvertFrom-Json
    }

    It 'Parses as valid JSON' {
        $script:profile | Should -Not -BeNullOrEmpty
    }

    It 'Has required top-level keys: profileName, description, version, modules' {
        $script:profile.profileName | Should -Not -BeNullOrEmpty
        $script:profile.description | Should -Not -BeNullOrEmpty
        $script:profile.version     | Should -Not -BeNullOrEmpty
        $script:profile.modules     | Should -Not -BeNullOrEmpty
    }

    It 'profileName matches the filename (without extension)' {
        $script:profile.profileName | Should -Be $ProfileFile.BaseName
    }

    It 'version follows semver (x.y.z)' {
        $script:profile.version | Should -Match '^\d+\.\d+\.\d+$'
    }

    # ─── Module presence ───────────────────────────────────────────────────────

    It 'Contains all 12 required module keys' {
        $requiredModules = @(
            'monitoring', 'networking', 'security', 'compute', 'storage',
            'databases', 'appservices', 'containers', 'integration', 'ai', 'data', 'governance'
        )
        foreach ($mod in $requiredModules) {
            $script:profile.modules.PSObject.Properties.Name | Should -Contain $mod -Because "'$mod' must be present in every profile"
        }
    }

    It 'Every module has a boolean enabled field' {
        foreach ($prop in $script:profile.modules.PSObject.Properties) {
            $prop.Value.enabled | Should -BeOfType [bool] -Because "'$($prop.Name).enabled' must be a boolean"
        }
    }

    # ─── Dependency invariant (mirrors Test-AdeProfile logic) ─────────────────

    It 'monitoring is enabled whenever any other module is enabled' {
        $anyNonMonitoringEnabled = $script:profile.modules.PSObject.Properties |
            Where-Object { $_.Name -ne 'monitoring' -and $_.Value.enabled -eq $true }
        if ($anyNonMonitoringEnabled) {
            $script:profile.modules.monitoring.enabled | Should -Be $true -Because 'monitoring must be enabled when any other module is on'
        } else {
            $true | Should -Be $true  # nothing enabled — trivially passes
        }
    }

    It 'networking is enabled whenever a networking-dependent module is enabled' {
        $netDependants = @('compute', 'databases', 'containers', 'appservices', 'integration', 'ai', 'data')
        $anyDependantEnabled = $script:profile.modules.PSObject.Properties |
            Where-Object { $_.Name -in $netDependants -and $_.Value.enabled -eq $true }
        if ($anyDependantEnabled) {
            $script:profile.modules.networking.enabled | Should -Be $true -Because 'networking must be enabled when a dependent module is on'
        } else {
            $true | Should -Be $true
        }
    }
}
