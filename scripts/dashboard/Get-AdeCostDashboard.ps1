<#
.SYNOPSIS
    Azure Demo Environment (ADE) — Cost & Status Dashboard

.DESCRIPTION
    Displays a terminal dashboard showing:
      - Current month cost per resource group
      - Estimated month-end projected cost
      - Running/deallocated/stopped VM status
      - Database and AKS cluster status
      - Budget alert utilisation

.PARAMETER Prefix
    The prefix used during deployment. Default: ade

.PARAMETER SubscriptionId
    Target subscription ID. Defaults to current az account.

.PARAMETER StopAll
    Stop (deallocate) all VMs and scale sets immediately.

.PARAMETER StartAll
    Start all VMs and scale sets immediately.

.PARAMETER Watch
    Refresh the dashboard every 60 seconds.

.EXAMPLE
    ./dashboard/Get-AdeCostDashboard.ps1 -Prefix ade
    ./dashboard/Get-AdeCostDashboard.ps1 -Prefix ade -StopAll
    ./dashboard/Get-AdeCostDashboard.ps1 -Prefix ade -Watch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Prefix = 'ade',

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = '',

    [Parameter(Mandatory = $false)]
    [switch]$StopAll,

    [Parameter(Mandatory = $false)]
    [switch]$StartAll,

    [Parameter(Mandatory = $false)]
    [switch]$Watch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. "$scriptRoot\..\helpers\common.ps1"

# Honour the standard -Verbose switch: enables Debug-level console output
$script:AdeVerbose = ($VerbosePreference -eq 'Continue')

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --output none
}
$sub = az account show --output json | ConvertFrom-Json
$SubscriptionId = $sub.id

function Show-AdeDashboard {

    Clear-Host
    $now    = Get-Date
    $year   = $now.Year
    $month  = $now.Month
    $daysInMonth  = [DateTime]::DaysInMonth($year, $month)
    $daysPassed   = $now.Day

    # ── Header ────────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║       Azure Demo Environment — Cost & Status Dashboard           ║" -ForegroundColor Cyan
    Write-Host "║   Subscription : $($sub.name.PadRight(47))║" -ForegroundColor Cyan
    Write-Host "║   Refreshed    : $(($now.ToString('yyyy-MM-dd HH:mm:ss')).PadRight(47))║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # ── Resource group costs ──────────────────────────────────────────────────
    Write-Host "  COSTS — Current Month ($($now.ToString('MMMM yyyy')))" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $rgs = az group list `
        --query "[?tags.managedBy=='ade' && starts_with(name, '$Prefix-')].name" `
        -o tsv 2>$null

    if (-not $rgs) {
        Write-Host "  No ADE resource groups found for prefix '$Prefix'." -ForegroundColor Gray
    } else {
        $totalActual    = 0.0
        $totalProjected = 0.0

        foreach ($rg in ($rgs | Sort-Object)) {
            # Query cost management API for current month actual cost per resource group
            # az costmanagement query is the modern replacement for the deprecated consumption API
            $fromDate = "$year-$($month.ToString('D2'))-01"
            $toDate   = $now.ToString('yyyy-MM-dd')
            $costJson = az costmanagement query `
                --type  Usage `
                --scope "subscriptions/$SubscriptionId" `
                --timeframe Custom `
                --time-period "from=$fromDate" "to=$toDate" `
                --dataset-aggregation '{"totalCost":{"name":"PreTaxCost","function":"Sum"}}' `
                --dataset-filter "{\"dimensions\":{\"name\":\"ResourceGroupName\",\"operator\":\"In\",\"values\":[\"$rg\"]}}" `
                --dataset-granularity None `
                -o json 2>$null

            $actual = 0.0
            if ($costJson) {
                $costObj = $costJson | ConvertFrom-Json
                if ($costObj.properties.rows -and $costObj.properties.rows.Count -gt 0) {
                    $actual = [double]($costObj.properties.rows[0][0])
                }
            }
            $projected = if ($daysPassed -gt 0) { ($actual / $daysPassed) * $daysInMonth } else { 0.0 }

            $totalActual    += $actual
            $totalProjected += $projected

            $moduleName = $rg -replace "^$Prefix-" -replace '-rg$'
            $bar        = '█' * [Math]::Min([int]$projected, 40)
            $costColor  = if ($projected -gt 100) { 'Red' } elseif ($projected -gt 50) { 'Yellow' } else { 'Green' }

            Write-Host ("  {0,-20} Actual: {1,8:C2}  Projected: {2,8:C2}  {3}" -f $moduleName, $actual, $projected, $bar) -ForegroundColor $costColor
        }

        Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ("  {0,-20} Actual: {1,8:C2}  Projected: {2,8:C2}" -f 'TOTAL', $totalActual, $totalProjected) -ForegroundColor White
    }

    Write-Host ""

    # ── VM Status ─────────────────────────────────────────────────────────────
    Write-Host "  VIRTUAL MACHINES" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $vms = az vm list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].{name:name,rg:resourceGroup,size:hardwareProfile.vmSize}" `
        -o json 2>$null | ConvertFrom-Json

    if ($vms) {
        foreach ($vm in $vms) {
            $powerState = az vm get-instance-view `
                --resource-group $vm.rg `
                --name $vm.name `
                --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" `
                -o tsv 2>$null

            $stateColor = switch -Wildcard ($powerState) {
                '*running*'     { 'Green'  }
                '*deallocated*' { 'Gray'   }
                '*stopped*'     { 'Yellow' }
                default         { 'White'  }
            }

            $indicator = switch -Wildcard ($powerState) {
                '*running*'     { '▶ RUNNING    ' }
                '*deallocated*' { '■ DEALLOCATED' }
                '*stopped*'     { '■ STOPPED    ' }
                default         { '? UNKNOWN    ' }
            }

            Write-Host ("  {0,-30} {1,-15} {2}" -f $vm.name, $vm.size, $indicator) -ForegroundColor $stateColor
        }
    } else {
        Write-Host "  No VMs found." -ForegroundColor Gray
    }

    Write-Host ""

    # ── AKS Clusters ─────────────────────────────────────────────────────────
    Write-Host "  AKS CLUSTERS" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $clusters = az aks list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].{name:name,rg:resourceGroup,powerState:powerState.code,version:kubernetesVersion,nodeCount:agentPoolProfiles[0].count}" `
        -o json 2>$null | ConvertFrom-Json

    if ($clusters) {
        foreach ($c in $clusters) {
            $stateColor = if ($c.powerState -eq 'Running') { 'Green' } else { 'Yellow' }
            Write-Host ("  {0,-30} k8s {1}  Nodes: {2}  [{3}]" -f $c.name, $c.version, $c.nodeCount, $c.powerState) -ForegroundColor $stateColor
        }
    } else {
        Write-Host "  No AKS clusters found." -ForegroundColor Gray
    }

    Write-Host ""

    # ── Integration resources ─────────────────────────────────────────────────
    $sbNamespaces = az servicebus namespace list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].{name:name,sku:sku.name,rg:resourceGroup}" `
        -o json 2>$null | ConvertFrom-Json

    $ehNamespaces = az eventhubs namespace list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].{name:name,sku:sku.name,rg:resourceGroup}" `
        -o json 2>$null | ConvertFrom-Json

    $caEnvs = az containerapp env list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].{name:name,rg:resourceGroup}" `
        -o json 2>$null | ConvertFrom-Json

    $adfs = az resource list `
        --resource-type 'Microsoft.DataFactory/factories' `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].{name:name,rg:resourceGroup}" `
        -o json 2>$null | ConvertFrom-Json

    if ($sbNamespaces -or $ehNamespaces -or $caEnvs -or $adfs) {
        Write-Host "  INTEGRATION & DATA" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

        foreach ($sb in $sbNamespaces) {
            Write-Host ("  [ServiceBus ]  {0,-35} SKU: {1}" -f $sb.name, $sb.sku) -ForegroundColor Cyan
        }
        foreach ($eh in $ehNamespaces) {
            Write-Host ("  [EventHub   ]  {0,-35} SKU: {1}" -f $eh.name, $eh.sku) -ForegroundColor Cyan
        }
        foreach ($ca in $caEnvs) {
            Write-Host ("  [ContainerApp] {0,-35}" -f $ca.name) -ForegroundColor Cyan
        }
        foreach ($adf in $adfs) {
            Write-Host ("  [DataFactory]  {0,-35}" -f $adf.name) -ForegroundColor Cyan
        }
        Write-Host ""
    }

    # ── Budget ────────────────────────────────────────────────────────────────
    Write-Host "  BUDGET ALERTS" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $budgets = az consumption budget list `
        --scope "subscriptions/$SubscriptionId" `
        --query "[?contains(name,'ade')].{name:name,amount:amount,currentSpend:currentSpend.amount,timeGrain:timeGrain}" `
        -o json 2>$null | ConvertFrom-Json

    if ($budgets) {
        foreach ($b in $budgets) {
            $pct = if ($b.amount -gt 0) { [int](($b.currentSpend / $b.amount) * 100) } else { 0 }
            $barFilled = '█' * [Math]::Min([int]($pct / 2), 50)
            $barEmpty  = '░' * (50 - $barFilled.Length)
            $color     = if ($pct -ge 100) { 'Red' } elseif ($pct -ge 80) { 'Yellow' } else { 'Green' }

            Write-Host ("  {0,-25} [{1}{2}] {3,3}%  ${4:N0} / ${5:N0}" -f $b.name, $barFilled, $barEmpty, $pct, $b.currentSpend, $b.amount) -ForegroundColor $color
        }
    } else {
        Write-Host "  No budgets found. Deploy governance module to enable budget alerts." -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  ACTIONS" -ForegroundColor DarkGray
    Write-Host "  -StopAll   Deallocate all VMs + scale sets now" -ForegroundColor DarkGray
    Write-Host "  -StartAll  Start all VMs + scale sets now" -ForegroundColor DarkGray
    Write-Host "  -Watch     Auto-refresh every 60 seconds" -ForegroundColor DarkGray
    Write-Host ""
}

# ── Stop / Start all VMs ──────────────────────────────────────────────────────
if ($StopAll) {
    Write-AdeSection "Stopping All VMs"

    $vmIds = az vm list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].id" `
        -o tsv 2>$null

    $vmssIds = az vmss list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].id" `
        -o tsv 2>$null

    if ($vmIds) {
        Write-AdeLog "Deallocating VMs..." -Level Warning
        az vm deallocate --ids $vmIds --no-wait --output none
        Write-AdeLog "VM stop commands sent." -Level Success
    }

    if ($vmssIds) {
        Write-AdeLog "Deallocating VMSS..." -Level Warning
        az vmss deallocate --ids $vmssIds --no-wait --output none
        Write-AdeLog "VMSS stop commands sent." -Level Success
    }

    # Stop AKS clusters
    $aksNames = az aks list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].{name:name,rg:resourceGroup}" `
        -o json 2>$null | ConvertFrom-Json

    foreach ($aks in $aksNames) {
        Write-AdeLog "Stopping AKS cluster: $($aks.name)" -Level Warning
        az aks stop --name $aks.name --resource-group $aks.rg --no-wait --output none
    }
}

if ($StartAll) {
    Write-AdeSection "Starting All VMs"

    $vmIds = az vm list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].id" `
        -o tsv 2>$null

    $vmssIds = az vmss list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].id" `
        -o tsv 2>$null

    if ($vmIds) {
        Write-AdeLog "Starting VMs..." -Level Info
        az vm start --ids $vmIds --no-wait --output none
        Write-AdeLog "VM start commands sent." -Level Success
    }

    if ($vmssIds) {
        Write-AdeLog "Starting VMSS..." -Level Info
        az vmss start --ids $vmssIds --no-wait --output none
        Write-AdeLog "VMSS start commands sent." -Level Success
    }

    $aksNames = az aks list `
        --query "[?tags.managedBy=='ade' && starts_with(resourceGroup, '$Prefix-')].{name:name,rg:resourceGroup}" `
        -o json 2>$null | ConvertFrom-Json

    foreach ($aks in $aksNames) {
        Write-AdeLog "Starting AKS cluster: $($aks.name)" -Level Info
        az aks start --name $aks.name --resource-group $aks.rg --no-wait --output none
    }
}

# ── Show dashboard ────────────────────────────────────────────────────────────
Show-AdeDashboard

if ($Watch) {
    while ($true) {
        Start-Sleep -Seconds 60
        Show-AdeDashboard
    }
}
