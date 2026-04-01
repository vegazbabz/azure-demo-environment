#Requires -Version 7.0
<#
.SYNOPSIS
    ADE Auto-Stop Runbook — Deallocates all VMs, VMSS, and AKS clusters.
    Intended to run as an Azure Automation runbook on a daily schedule.

.DESCRIPTION
    Uses the Automation Account's system-assigned managed identity (no stored credentials).
    Discovers all resources tagged managedBy=ade under the given prefix.

.PARAMETER ResourcePrefix
    The resource prefix used during ADE deployment. Default: ade

.PARAMETER SubscriptionId
    Override subscription. If empty, uses the Automation Account's default context.

.PARAMETER DryRun
    Log what would be stopped without executing.
#>
param(
    [string]$ResourcePrefix = 'ade',
    [string]$SubscriptionId = '',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output "=== ADE Auto-Stop Runbook started at $(Get-Date -Format 'o') ==="
Write-Output "ResourcePrefix: $ResourcePrefix | DryRun: $DryRun"

# Authenticate using the Automation Account's system-assigned managed identity
try {
    Connect-AzAccount -Identity | Out-Null
    Write-Output "Authenticated via managed identity."
} catch {
    throw "Failed to authenticate via managed identity: $_"
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Output "Switched to subscription: $SubscriptionId"
}

$context = Get-AzContext
Write-Output "Active subscription: $($context.Subscription.Name) [$($context.Subscription.Id)]"

# ── Stop VMs ──────────────────────────────────────────────────────────────────
Write-Output ""
Write-Output "--- Virtual Machines ---"

$vms = Get-AzVM | Where-Object {
    $_.Tags['managedBy'] -eq 'ade' -and $_.ResourceGroupName -like "$ResourcePrefix-*"
}

if (-not $vms) {
    Write-Output "No matching VMs found."
} else {
    foreach ($vm in $vms) {
        $powerState = (Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status).Statuses |
            Where-Object { $_.Code -like 'PowerState/*' } |
            Select-Object -ExpandProperty DisplayStatus

        if ($powerState -like '*running*') {
            Write-Output "Deallocating: $($vm.Name) in $($vm.ResourceGroupName)"
            if (-not $DryRun) {
                Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -NoWait | Out-Null
            }
        } else {
            Write-Output "Already stopped: $($vm.Name) [$powerState]"
        }
    }
}

# ── Stop VMSS ─────────────────────────────────────────────────────────────────
Write-Output ""
Write-Output "--- VM Scale Sets ---"

$vmssList = Get-AzVmss | Where-Object {
    $_.Tags['managedBy'] -eq 'ade' -and $_.ResourceGroupName -like "$ResourcePrefix-*"
}

if (-not $vmssList) {
    Write-Output "No matching VMSS found."
} else {
    foreach ($vmss in $vmssList) {
        Write-Output "Deallocating VMSS: $($vmss.Name) in $($vmss.ResourceGroupName)"
        if (-not $DryRun) {
            Stop-AzVmss -ResourceGroupName $vmss.ResourceGroupName -VMScaleSetName $vmss.Name -Force | Out-Null
        }
    }
}

# ── Stop AKS Clusters ─────────────────────────────────────────────────────────
Write-Output ""
Write-Output "--- AKS Clusters ---"

$aksClusters = Get-AzAksCluster | Where-Object {
    $_.Tags['managedBy'] -eq 'ade' -and $_.ResourceGroupName -like "$ResourcePrefix-*"
}

if (-not $aksClusters) {
    Write-Output "No matching AKS clusters found."
} else {
    foreach ($aks in $aksClusters) {
        if ($aks.PowerState.Code -eq 'Running') {
            Write-Output "Stopping AKS: $($aks.Name) in $($aks.ResourceGroupName)"
            if (-not $DryRun) {
                Stop-AzAksCluster -ResourceGroupName $aks.ResourceGroupName -Name $aks.Name | Out-Null
            }
        } else {
            Write-Output "Already stopped: $($aks.Name) [$($aks.PowerState.Code)]"
        }
    }
}

Write-Output ""
Write-Output "=== ADE Auto-Stop completed at $(Get-Date -Format 'o') ==="
