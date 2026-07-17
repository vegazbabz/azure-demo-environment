#Requires -Version 7.0
<#
.SYNOPSIS
    Stages a clean, publishable copy of the AzureDemoEnvironment module.
.DESCRIPTION
    Publish-PSResource packages the entire contents of the target folder, so
    publishing straight from the repo root would ship tests, docs, workflows
    and local working-tree clutter. This script stages exactly the module
    runtime files into <OutputPath>/AzureDemoEnvironment and validates the
    result:

      AzureDemoEnvironment.psd1 / .psm1
      scripts/  bicep/  config/  data/
      LICENSE  README.md

    Local working trees may contain compiled ARM output (bicep/**/*.json is
    gitignored) — those files are stripped from the stage so local and CI
    builds produce identical packages.

    Used by the release workflow before Publish-PSResource, and locally for
    dry-run packaging tests.
.PARAMETER OutputPath
    Directory to stage into (created if missing). The module lands in
    <OutputPath>/AzureDemoEnvironment. Defaults to ./out.
.EXAMPLE
    ./tools/Build-ModulePackage.ps1 -OutputPath $env:RUNNER_TEMP
#>
[CmdletBinding()]
param(
    [string]$OutputPath = './out'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$stageDir = Join-Path $OutputPath 'AzureDemoEnvironment'

if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

# Module runtime files only — keep this list in sync with the layout the
# scripts expect ($PSScriptRoot-relative: scripts/ reaches ../bicep, ../config
# and ../data, so the four directories must sit side by side under the root).
$rootFiles = @('AzureDemoEnvironment.psd1', 'AzureDemoEnvironment.psm1', 'LICENSE', 'README.md')
$dirs      = @('scripts', 'bicep', 'config', 'data')

foreach ($f in $rootFiles) {
    $src = Join-Path $repoRoot $f
    if (-not (Test-Path $src)) { throw "Missing required module file: $f" }
    Copy-Item $src -Destination $stageDir
}
foreach ($d in $dirs) {
    $src = Join-Path $repoRoot $d
    if (-not (Test-Path $src)) { throw "Missing required module directory: $d" }
    Copy-Item $src -Destination $stageDir -Recurse
}

# Strip files that must never ship: compiled ARM output (gitignored, but
# present in local working trees after az bicep build), placeholder files,
# and any stray logs.
$strip = @(
    Get-ChildItem -Path (Join-Path $stageDir 'bicep') -Recurse -Filter '*.json' -File
    Get-ChildItem -Path $stageDir -Recurse -Force -Include '.gitkeep', '*.log', '*.tmp' -File
)
$strip | Remove-Item -Force
if ($strip.Count -gt 0) {
    Write-Host ("Stripped {0} non-package file(s) (compiled ARM JSON, .gitkeep, logs)." -f $strip.Count)
}

# Validate the staged module standalone: manifest parses, the wrappers import,
# and the asset directories the scripts resolve at runtime are present.
$manifest = Test-ModuleManifest (Join-Path $stageDir 'AzureDemoEnvironment.psd1')
$staged   = Get-ChildItem $stageDir -Recurse -File
Write-Host ("Staged {0} v{1}: {2} file(s) -> {3}" -f $manifest.Name, $manifest.Version, $staged.Count, $stageDir)

foreach ($required in @('scripts/deploy.ps1', 'scripts/helpers/common.ps1',
                        'bicep/modules', 'bicep/hardened',
                        'config/profiles/full.json', 'config/defaults.json',
                        'data/sql')) {
    if (-not (Test-Path (Join-Path $stageDir $required))) {
        throw "Staged module is missing required asset: $required"
    }
}

Import-Module (Join-Path $stageDir 'AzureDemoEnvironment.psd1') -Force
$expected = @('Deploy-AdeEnvironment', 'Remove-AdeEnvironment', 'Initialize-AdeSeedData', 'Get-AdeCostDashboard')
foreach ($fn in $expected) {
    if (-not (Get-Command $fn -Module AzureDemoEnvironment -ErrorAction SilentlyContinue)) {
        throw "Staged module import did not export $fn."
    }
}
Remove-Module AzureDemoEnvironment -Force
Write-Host "Staged module imports cleanly and exports all four commands."

# Emit the staged path for callers (the only pipeline output).
$stageDir
