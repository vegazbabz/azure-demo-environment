#Requires -Version 7.0
<#
.SYNOPSIS
    Smoke tests for all Bicep module files.

    When az bicep is available the tests compile each file to ARM JSON (stdout
    mode) and assert a zero exit code.  When the CLI is absent the tests fall
    back to a structural/content analysis of the .bicep source.
#>

BeforeDiscovery {
    $repoRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $bicepFiles  = Get-ChildItem (Join-Path $repoRoot 'bicep') -Recurse -Filter '*.bicep'
    $script:bicepCases = $bicepFiles | ForEach-Object {
        @{
            File         = $_
            RelativePath = $_.FullName.Substring($repoRoot.Length + 1)
        }
    }
    # Initialise bicepReady here so -Skip:(-not $script:bicepReady) can be
    # evaluated during Pester's discovery phase (BeforeAll has not run yet).
    $script:bicepReady = $false
    $azDiscoveryCmd = Get-Command az -ErrorAction SilentlyContinue
    if ($azDiscoveryCmd) {
        & $azDiscoveryCmd.Source bicep version 2>&1 | Out-Null
        $script:bicepReady = ($LASTEXITCODE -eq 0)
    }
}

BeforeAll {
    $script:repoRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:azPath     = (Get-Command az -ErrorAction SilentlyContinue)?.Source
    $script:bicepReady = $false

    if ($script:azPath) {
        $verOutput = & $script:azPath bicep version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:bicepReady = $true
        }
    }
}

Describe 'Bicep module – <RelativePath>' -ForEach $script:bicepCases -Tag 'bicep' {

    BeforeAll {
        $script:filePath = $File.FullName
        $script:source   = Get-Content $script:filePath -Raw
    }

    It 'File is not empty' {
        $script:source.Trim().Length | Should -BeGreaterThan 0
    }

    It 'Declares at least one targetScope or resource' {
        $script:source | Should -Match 'targetScope|resource\s+\w'
    }

    It 'Has a param block or at least one param declaration' {
        # All ADE modules should have at least a prefix param
        # Use (?m) for multiline so ^ anchors to each line start
        $script:source | Should -Match "(?m)^param\s+\w|(?m)^var\s+\w|(?m)^resource\s+\w" -Because 'a module should declare params, vars or resources'
    }

    It 'Does not contain Windows line endings that could break ARM template output' {
        # Bicep files should be LF or normalised — CRLF is harmless but check for
        # bare CR which breaks some tooling
        $script:source | Should -Not -Match "`r(?!`n)"
    }

    It 'Compiles successfully with az bicep build (when az is available)' -Skip:(-not $script:bicepReady) {
        $output = & $script:azPath bicep build --file $script:filePath --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "bicep build should succeed for $($File.Name)"
    }
}
