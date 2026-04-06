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

# Phase 1: Remove locks and start ALL deletions in parallel (no-wait).
# This cuts wall-clock time from (N x avg-delete-time) to ~max-delete-time.
foreach ($rg in $ordered) {
    try {
        Remove-AdeResourceGroup -Name $rg -NoWait  # always async for parallelism
        Write-AdeLog "Deletion started: $rg" -Level Info
    } catch {
        Write-AdeLog "Failed to start deletion of '$rg': $_" -Level Error
        $failedRgs += $rg
    }
}

$allStarted = @($ordered | Where-Object { $_ -notin $failedRgs })

if ($failedRgs.Count -gt 0) {
    Write-AdeLog "The following resource groups could NOT be deleted: $($failedRgs -join ', ')" -Level Error
    exit 1
}

if ($NoWait) {
    Write-AdeLog "Deletions running in background ($($allStarted.Count) RGs). Check status: az group list -o table" -Level Info
} else {
    # Phase 2: Poll until every started RG is gone (or timeout after 30 min).
    Write-AdeLog "Waiting for $($allStarted.Count) resource group(s) to delete in parallel..." -Level Info
    $remaining  = @($allStarted)
    $maxSeconds = 1800
    $elapsed    = 0
    while ($remaining.Count -gt 0 -and $elapsed -lt $maxSeconds) {
        Start-Sleep -Seconds 20
        $elapsed += 20
        $remaining = @($remaining | Where-Object {
            (az group exists --name $_ 2>$null).Trim() -eq 'true'
        })
        if ($remaining.Count -gt 0) {
            Write-AdeLog "Still deleting ($($remaining.Count) remaining): $($remaining -join ', ')" -Level Info
        }
    }
    if ($remaining.Count -gt 0) {
        Write-AdeLog "Timed out waiting for: $($remaining -join ', ')" -Level Warning
        $failedRgs += $remaining
    } else {
        Write-AdeLog "All resource groups deleted." -Level Success
    }
}

# ─── Purge soft-deleted Key Vaults ────────────────────────────────────────────
# Key Vault soft-delete retains vault names in the deleted-vaults registry for
# softDeleteRetentionInDays (default 7). Re-deploying with the same prefix hits
# VaultAlreadyExists because the name is still reserved.
# We list all deleted vaults matching the prefix and purge them immediately.
# This only runs when deletions were synchronous (NoWait = false); in async mode
# the KVs may not yet be in the deleted state when we check.
if (-not $NoWait -and $failedRgs.Count -eq 0) {
    Write-AdeLog "Purging any soft-deleted Key Vaults with prefix '$Prefix'..." -Level Info
    $deletedVaults = az keyvault list-deleted --resource-type vault --query "[?starts_with(name, '${Prefix}-kv-') || starts_with(name, '${Prefix}-ml-kv-')].[name, properties.location]" -o tsv 2>$null
    if ($deletedVaults) {
        foreach ($line in $deletedVaults) {
            if (-not $line) { continue }
            $parts = ($line.Trim() -split '\t')
            $vaultName     = $parts[0]
            $vaultLocation = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            Write-AdeLog "Purging soft-deleted Key Vault: $vaultName (no-wait)" -Level Warning
            $purgeArgs = @('keyvault', 'purge', '--name', $vaultName, '--no-wait', '--output', 'none')
            if ($vaultLocation) { $purgeArgs += '--location'; $purgeArgs += $vaultLocation }
            az $purgeArgs 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-AdeLog "Purge initiated: $vaultName (completes in background; re-deploy in ~30s)" -Level Success
            } else {
                Write-AdeLog "Could not purge '$vaultName' (non-fatal — may already be purging or location required)." -Level Warning
            }
        }
    } else {
        Write-AdeLog "No soft-deleted Key Vaults found for prefix '$Prefix'." -Level Info
    }
}
