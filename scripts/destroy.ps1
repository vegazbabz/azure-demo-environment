#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Demo Environment (ADE) — Teardown Script

.DESCRIPTION
    Deletes all resource groups created by deploy.ps1 for a given prefix.
    Removes resource locks first. Supports per-module teardown.

.PARAMETER Prefix
    The prefix used during deployment. Default: ade

.PARAMETER Modules
    Specific modules to destroy. If omitted, all ADE resource groups matching
    the prefix are destroyed.

.PARAMETER SubscriptionId
    Target subscription ID. If omitted, uses the current az account.

.PARAMETER NoWait
    Delete resource groups asynchronously (faster but no confirmation each completed).

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER LogFile
    Optional path to write a plain-text copy of all log output.
    The file is created (or overwritten) at the start of the run.
    Example: -LogFile ./logs/destroy-$(Get-Date -f yyyyMMdd-HHmmss).log

.EXAMPLE
    # Destroy everything
    ./destroy.ps1 -Prefix ade -Force

.EXAMPLE
    # Destroy only compute and containers
    ./destroy.ps1 -Prefix ade -Modules compute,containers
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
    [string]$Prefix = 'ade',

    [Parameter(Mandatory = $false)]
    [string[]]$Modules = @(),

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = '',

    [Parameter(Mandatory = $false)]
    [switch]$NoWait,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$LogFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. "$scriptRoot\helpers\common.ps1"

# Honour the standard -Verbose switch: enables Debug-level console output
$script:AdeVerbose = ($VerbosePreference -eq 'Continue')

if ($LogFile) {
    $resolvedLog = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $resolvedLog)
    Set-Content -LiteralPath $resolvedLog -Value @(
        "# ADE Teardown Log",
        "# Started  : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss UTC'))",
        "# Prefix   : $Prefix",
        "# " + ('─' * 57)
    )
    $script:AdeLogFile = $resolvedLog
}

Write-AdeSection "Azure Demo Environment — Teardown"

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --output none
    if ($LASTEXITCODE -ne 0) { throw "Could not set subscription: $SubscriptionId" }
}

# Find all resource groups that belong to this ADE prefix
$rgQuery  = -join ('[', "?tags.managedBy=='ade' && starts_with(name, '", $Prefix, "-')].name")
$allGroups = az group list `
    --query $rgQuery `
    -o tsv 2>$null

if (-not $allGroups) {
    Write-AdeLog "No ADE resource groups found with prefix '$Prefix'. Nothing to destroy." -Level Warning
    exit 0
}

$targetGroups = if ($Modules.Count -gt 0) {
    $allGroups | Where-Object { $mod = ($_ -replace "^$Prefix-" -replace '-rg$'); $mod -in $Modules }
} else {
    $allGroups
}

if (-not $targetGroups) {
    Write-AdeLog "No matching resource groups for modules: $($Modules -join ', ')" -Level Warning
    exit 0
}

Write-Host ""
Write-Host "  The following resource groups will be PERMANENTLY DELETED:" -ForegroundColor Red
foreach ($rg in $targetGroups) {
    Write-Host "    - $rg" -ForegroundColor Yellow
}
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Type 'DELETE' to confirm destruction of all resources above"
    if ($confirm -ne 'DELETE') {
        Write-AdeLog "Teardown cancelled." -Level Warning
        exit 0
    }
}

# Destroy in reverse dependency order
$destroyOrder = @('governance', 'data', 'ai', 'integration', 'containers',
                  'appservices', 'databases', 'storage', 'compute',
                  'security', 'networking', 'monitoring')

$ordered = foreach ($mod in $destroyOrder) {
    $rgName = "$Prefix-$mod-rg"
    if ($targetGroups -contains $rgName) { $rgName }
}
# Append any not in the known list (custom modules)
foreach ($rg in $targetGroups) {
    if ($rg -notin $ordered) { $ordered += $rg }
}

$failedRgs = @()
foreach ($rg in $ordered) {
    try {
        Remove-AdeResourceGroup -Name $rg -NoWait:$NoWait
        Write-AdeLog "Deletion completed: $rg" -Level Success
    } catch {
        Write-AdeLog "Failed to delete '$rg': $_" -Level Error
        $failedRgs += $rg
    }
}

if ($failedRgs.Count -gt 0) {
    Write-AdeLog "The following resource groups could NOT be deleted: $($failedRgs -join ', ')" -Level Error
    exit 1
}

if ($NoWait) {
    Write-AdeLog "Deletions running in background. Check status in the Azure Portal or run: az group list -o table" -Level Info
} else {
    Write-AdeLog "All resource groups deleted." -Level Success
}
