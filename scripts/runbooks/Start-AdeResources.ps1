#Requires -Version 7.0
<#
.SYNOPSIS
    ADE Auto-Start Runbook — Starts all VMs, VMSS, and AKS clusters.
    Intended to run as an Azure Automation runbook on a weekday morning schedule.

.PARAMETER ResourcePrefix
    The resource prefix used during ADE deployment. Default: ade

.PARAMETER SubscriptionId
    Override subscription. If empty, uses the Automation Account's default context.

.PARAMETER DryRun
    Log what would be started without executing.
#>
param(
    [string]$ResourcePrefix = 'ade',
    [string]$SubscriptionId = '',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output "=== ADE Auto-Start Runbook started at $(Get-Date -Format 'o') ==="
Write-Output "ResourcePrefix: $ResourcePrefix | DryRun: $DryRun"

# Authenticate using managed identity
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

# ── Start VMs ─────────────────────────────────────────────────────────────────
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

        if ($powerState -notlike '*running*') {
            Write-Output "Starting: $($vm.Name) in $($vm.ResourceGroupName)"
            if (-not $DryRun) {
                Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -NoWait | Out-Null
            }
        } else {
            Write-Output "Already running: $($vm.Name)"
        }
    }
}

# ── Start VMSS ────────────────────────────────────────────────────────────────
Write-Output ""
Write-Output "--- VM Scale Sets ---"

$vmssList = Get-AzVmss | Where-Object {
    $_.Tags['managedBy'] -eq 'ade' -and $_.ResourceGroupName -like "$ResourcePrefix-*"
}

if (-not $vmssList) {
    Write-Output "No matching VMSS found."
} else {
    foreach ($vmss in $vmssList) {
        Write-Output "Starting VMSS: $($vmss.Name) in $($vmss.ResourceGroupName)"
        if (-not $DryRun) {
            Start-AzVmss -ResourceGroupName $vmss.ResourceGroupName -VMScaleSetName $vmss.Name | Out-Null
        }
    }
}

# ── Start AKS Clusters ────────────────────────────────────────────────────────
Write-Output ""
Write-Output "--- AKS Clusters ---"

$aksClusters = Get-AzAksCluster | Where-Object {
    $_.Tags['managedBy'] -eq 'ade' -and $_.ResourceGroupName -like "$ResourcePrefix-*"
}

if (-not $aksClusters) {
    Write-Output "No matching AKS clusters found."
} else {
    foreach ($aks in $aksClusters) {
        if ($aks.PowerState.Code -ne 'Running') {
            Write-Output "Starting AKS: $($aks.Name) in $($aks.ResourceGroupName)"
            if (-not $DryRun) {
                Start-AzAksCluster -ResourceGroupName $aks.ResourceGroupName -Name $aks.Name | Out-Null
            }
        } else {
            Write-Output "Already running: $($aks.Name)"
        }
    }
}

Write-Output ""
Write-Output "=== ADE Auto-Start completed at $(Get-Date -Format 'o') ==="
