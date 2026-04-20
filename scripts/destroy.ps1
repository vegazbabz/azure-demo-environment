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
if ($LASTEXITCODE -ne 0) { throw "Failed to list resource groups — check az login and subscription access." }

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

if (-not $Force -and -not $WhatIfPreference) {
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

[array]$ordered = foreach ($mod in $destroyOrder) {
    $rgName = "$Prefix-$mod-rg"
    if ($targetGroups -contains $rgName) { $rgName }
}
# Append any not in the known list (custom modules)
foreach ($rg in $targetGroups) {
    if ($rg -notin $ordered) { $ordered += $rg }
}
# AKS creates a node resource group outside the tagged set. Include it when
# the containers module is being destroyed so it is not orphaned.
# Query the actual name from the cluster — it is immutable and may differ
# from any naming convention (e.g. the default MC_<rg>_<cluster>_<region>).
if ("$Prefix-containers-rg" -in $ordered) {
    $aksName = "$Prefix-aks"
    $aksNodesRg = az aks show --name $aksName --resource-group "$Prefix-containers-rg" --query nodeResourceGroup --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $aksNodesRg -and $aksNodesRg -notin $ordered) {
        $aksNodesRg = $aksNodesRg.Trim()
        $ordered += $aksNodesRg
        Write-AdeLog "Including AKS node resource group: $aksNodesRg" -Level Info
    }
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

# Track KV purge background jobs so purging starts as soon as each vault becomes
# soft-deleted — running in parallel with any still-deleting RGs.
$kvPurgeJobs    = [System.Collections.Generic.List[pscustomobject]]::new()
$kvPurgeStarted = [System.Collections.Generic.HashSet[string]]::new()

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
        # As soon as a vault appears in the soft-deleted registry, kick off its purge
        # in the background so it runs in parallel with the remaining RG deletions.
        $freshDeleted = az keyvault list-deleted --resource-type vault `
            --query "[?starts_with(name, '${Prefix}-kv-') || starts_with(name, '${Prefix}-ml-kv-')].[name, properties.location]" `
            -o tsv 2>$null
        if ($freshDeleted) {
            foreach ($kvLine in $freshDeleted) {
                if (-not $kvLine) { continue }
                $kvParts = $kvLine.Trim() -split '\t'
                $kvName  = $kvParts[0]
                $kvLoc   = if ($kvParts.Count -gt 1) { $kvParts[1] } else { '' }
                if ($kvPurgeStarted.Contains($kvName)) { continue }
                $null = $kvPurgeStarted.Add($kvName)
                Write-AdeLog "Key Vault '$kvName' is soft-deleted — starting background purge in parallel..." -Level Warning
                $kvNameArg = $kvName
                $kvLocArg  = $kvLoc
                $kvJob = Start-Job -ScriptBlock {
                    $n = $using:kvNameArg
                    $loc = $using:kvLocArg
                    $a = @('keyvault', 'purge', '--name', $n, '--output', 'none')
                    if ($loc) { $a += '--location'; $a += $loc }
                    $null = & az @a 2>&1
                    return $LASTEXITCODE
                }
                $kvPurgeJobs.Add([pscustomobject]@{ Job = $kvJob; Name = $kvName })
            }
        }
    }
    if ($remaining.Count -gt 0) {
        Write-AdeLog "Timed out waiting for: $($remaining -join ', ')" -Level Warning
        $failedRgs += $remaining
    } else {
        Write-AdeLog "All resource groups deleted." -Level Success
    }
}

# ─── Purge soft-deleted resources ────────────────────────────────────────────
# Key Vault and Cognitive Services (AI Services, OpenAI) use soft-delete.
# After RG deletion the name is reserved in the deleted registry and blocks
# re-deployment with the same prefix. We purge and wait for completion.
if (-not $NoWait -and $failedRgs.Count -eq 0 -and -not $WhatIfPreference) {

    # ── Key Vaults ──────────────────────────────────────────────────────────
    # Background purge jobs were started opportunistically during RG polling.
    # Catch any vaults that only became soft-deleted after the last poll, then
    # wait for all jobs and report results.
    $deletedVaults = az keyvault list-deleted --resource-type vault `
        --query "[?starts_with(name, '${Prefix}-kv-') || starts_with(name, '${Prefix}-ml-kv-')].[name, properties.location]" `
        -o tsv 2>$null
    if ($deletedVaults) {
        foreach ($line in $deletedVaults) {
            if (-not $line) { continue }
            $parts         = ($line.Trim() -split '\t')
            $vaultName     = $parts[0]
            $vaultLocation = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            if ($kvPurgeStarted.Contains($vaultName)) { continue }   # job already running
            $null = $kvPurgeStarted.Add($vaultName)
            Write-AdeLog "Starting purge of Key Vault: $vaultName (this can take several minutes)..." -Level Warning
            $kvNameArg = $vaultName
            $kvLocArg  = $vaultLocation
            $kvJob = Start-Job -ScriptBlock {
                $n = $using:kvNameArg
                $loc = $using:kvLocArg
                $a = @('keyvault', 'purge', '--name', $n, '--output', 'none')
                if ($loc) { $a += '--location'; $a += $loc }
                $null = & az @a 2>&1
                return $LASTEXITCODE
            }
            $kvPurgeJobs.Add([pscustomobject]@{ Job = $kvJob; Name = $vaultName })
        }
    }
    if ($kvPurgeJobs.Count -gt 0) {
        Write-AdeLog "Waiting for $($kvPurgeJobs.Count) Key Vault purge(s) to complete..." -Level Info
        foreach ($kvEntry in $kvPurgeJobs) {
            $kvExitCode = Receive-Job $kvEntry.Job -Wait
            Remove-Job  $kvEntry.Job
            if ($null -ne $kvExitCode -and [int]$kvExitCode -eq 0) {
                Write-AdeLog "Key Vault purged: $($kvEntry.Name). Safe to re-deploy immediately." -Level Success
            } else {
                Write-AdeLog "Could not purge '$($kvEntry.Name)' (non-fatal)." -Level Warning
            }
        }
    } else {
        Write-AdeLog "No soft-deleted Key Vaults found for prefix '$Prefix'." -Level Info
    }

    # ── Cognitive Services (AI Services + OpenAI) ────────────────────────────
    # Purge endpoint requires: name + location + original resource-group name.
    # We extract all three from the deleted account's ARM resource ID:
    #   .../providers/Microsoft.CognitiveServices/locations/{loc}/resourceGroups/{rg}/deletedAccounts/{name}
    Write-AdeLog "Purging any soft-deleted Cognitive Services accounts with prefix '$Prefix'..." -Level Info
    $deletedCognitive = az cognitiveservices account list-deleted --query "[?starts_with(name, '${Prefix}-')].[name, location, id]" -o tsv 2>$null
    if ($deletedCognitive) {
        foreach ($line in $deletedCognitive) {
            if (-not $line) { continue }
            $parts    = ($line.Trim() -split '\t')
            $acctName = $parts[0]
            $acctLoc  = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $acctId   = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            # Extract original RG name from ARM ID
            $acctRg   = if ($acctId -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { '' }
            if (-not $acctLoc -or -not $acctRg) {
                Write-AdeLog "Could not determine location/RG for '$acctName' — skipping." -Level Warning
                continue
            }
            Write-AdeLog "Purging soft-deleted Cognitive Services account: $acctName (rg: $acctRg)" -Level Warning
            az cognitiveservices account purge --name $acctName --resource-group $acctRg --location $acctLoc --output none 2>$null
            if ($LASTEXITCODE -eq 0) { Write-AdeLog "Purged: $acctName" -Level Success }
            else { Write-AdeLog "Could not purge '$acctName' (non-fatal)." -Level Warning }
        }
    } else {
        Write-AdeLog "No soft-deleted Cognitive Services accounts found for prefix '$Prefix'." -Level Info
    }

    # ── Subscription-scope Budget ────────────────────────────────────────────
    # Budgets live at subscription scope (Microsoft.Consumption/budgets) and are
    # NOT deleted when resource groups are removed. Delete it explicitly so that
    # a re-deploy can create a fresh budget and to leave the subscription clean.
    $budgetName = "$Prefix-monthly-budget"
    Write-AdeLog "Checking for subscription-scope budget: $budgetName" -Level Info
    $subId = (az account show --query id -o tsv 2>$null).Trim()
    if ($subId) {
        $budgetUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Consumption/budgets/${budgetName}?api-version=2023-11-01"
        $budgetCheck = az rest --method GET --url $budgetUrl 2>$null
        if ($LASTEXITCODE -eq 0 -and $budgetCheck) {
            Write-AdeLog "Deleting subscription-scope budget: $budgetName" -Level Warning
            az rest --method DELETE --url $budgetUrl --output none 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-AdeLog "Budget '$budgetName' deleted." -Level Success
            } else {
                Write-AdeLog "Could not delete budget '$budgetName' (non-fatal)." -Level Warning
            }
        } else {
            Write-AdeLog "No budget found with name '$budgetName' — nothing to delete." -Level Info
        }
    } else {
        Write-AdeLog "Could not determine subscription ID — skipping budget cleanup." -Level Warning
    }
}

