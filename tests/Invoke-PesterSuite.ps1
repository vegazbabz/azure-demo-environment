#Requires -Version 7.0
<#
.SYNOPSIS
    ADE Pester test runner.

.DESCRIPTION
    Runs the full Pester suite (or a filtered subset) and outputs results to the console
    and optionally to a JUnit XML file for CI integration.

.PARAMETER Path
    Folder or file to run. Defaults to the 'tests/' directory next to this script.

.PARAMETER Tag
    Only run tests tagged with these values (e.g. -Tag unit, integration).

.PARAMETER ExcludeTag
    Skip tests with these tags.

.PARAMETER OutputFile
    Path for JUnit XML output (consumed by GitHub Actions, Azure DevOps, etc.).
    Default: tests/results/pester-results.xml

.PARAMETER CI
    Switch for CI mode: sets stricter thresholds and writes the XML report automatically.

.EXAMPLE
    # Run everything locally
    ./tests/Invoke-PesterSuite.ps1

    # CI mode — writes XML and fails on any test failure
    ./tests/Invoke-PesterSuite.ps1 -CI

    # Run only validate.ps1 tests
    ./tests/Invoke-PesterSuite.ps1 -Path ./tests/helpers/validate.Tests.ps1
#>

[CmdletBinding()]
param (
    [string]   $Path        = '',
    [string[]] $Tag         = @(),
    [string[]] $ExcludeTag  = @(),
    [string]   $OutputFile  = '',
    [switch]   $CI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Resolve paths ────────────────────────────────────────────────────────────

$repoRoot  = Split-Path -Path $PSScriptRoot -Parent
$testsRoot = $PSScriptRoot

if (-not $Path) {
    $Path = $testsRoot
}

if (-not $OutputFile) {
    $resultsPath = Join-Path -Path $testsRoot -ChildPath 'results'
    $OutputFile  = Join-Path -Path $resultsPath -ChildPath 'pester-results.xml'
}

$resultsDir = Split-Path -Path $OutputFile -Parent
if (-not (Test-Path $resultsDir)) {
    $null = New-Item -ItemType Directory -Path $resultsDir -Force
}

# ─── Ensure Pester 5+ is available ───────────────────────────────────────────

$pesterModule = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object -Property Version -Descending |
    Select-Object -First 1

if (-not $pesterModule) {
    Write-Host '[ADE Tests] Pester 5+ not found. Installing from PSGallery...' -ForegroundColor Yellow
    Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser -Repository PSGallery
}

Import-Module -Name Pester -MinimumVersion 5.0.0 -Force

# ─── Build Pester configuration ───────────────────────────────────────────────

$config = New-PesterConfiguration

$config.Run.Path = $Path

if ($Tag.Count -gt 0) {
    $config.Filter.Tag = $Tag
}
if ($ExcludeTag.Count -gt 0) {
    $config.Filter.ExcludeTag = $ExcludeTag
}

# Output
$config.Output.Verbosity = if ($CI) { 'Detailed' } else { 'Normal' }

# JUnit XML report (always written; GitHub Actions uploads it with test-reporter)
$config.TestResult.Enabled    = $true
$config.TestResult.OutputPath = $OutputFile
$config.TestResult.OutputFormat = 'JUnitXml'

# Fail on first error in CI mode; show all failures locally
$config.Run.Exit     = $CI.IsPresent   # exit 1 on failure when running in CI
$config.Run.PassThru = $true

# Code coverage (opt-in in CI)
if ($CI) {
    $config.CodeCoverage.Enabled    = $true
    $config.CodeCoverage.Path       = @(
        (Join-Path -Path $repoRoot -ChildPath 'scripts/helpers/validate.ps1'),
        (Join-Path -Path $repoRoot -ChildPath 'scripts/helpers/common.ps1'),
        (Join-Path -Path $repoRoot -ChildPath 'scripts/destroy.ps1'),
        (Join-Path -Path $repoRoot -ChildPath 'scripts/deploy.ps1')
    )
    $config.CodeCoverage.OutputPath   = Join-Path -Path $resultsDir -ChildPath 'coverage.xml'
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
    $config.CodeCoverage.CoveragePercentTarget = 70
}

# ─── Run ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '─────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host '  ADE Pester Test Suite' -ForegroundColor White
Write-Host "  Path   : $Path" -ForegroundColor Gray
Write-Host "  Report : $OutputFile" -ForegroundColor Gray
Write-Host "  CI     : $($CI.IsPresent)" -ForegroundColor Gray
Write-Host '─────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

$result = Invoke-Pester -Configuration $config

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '─────────────────────────────────────────────────' -ForegroundColor DarkGray
$icon = if ($result.FailedCount -eq 0) { '✅' } else { '❌' }
Write-Host "  $icon  Passed: $($result.PassedCount)   Failed: $($result.FailedCount)   Skipped: $($result.SkippedCount)" -ForegroundColor $(
    if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' }
)
Write-Host '─────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

# Non-CI: exit with code so callers can detect failures
if (-not $CI -and $result.FailedCount -gt 0) {
    exit 1
}
