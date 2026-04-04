#Requires -Version 7
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

    $rgsRaw = az group list -o json 2>$null | ConvertFrom-Json
    $rgs = $rgsRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.name -like "$Prefix-*" } |
        Select-Object -ExpandProperty name

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
            $datasetFilter = '{"dimensions":{"name":"ResourceGroupName","operator":"In","values":["' + $rg + '"]}}'
            $costJson = az costmanagement query `
                --type  Usage `
                --scope "subscriptions/$SubscriptionId" `
                --timeframe Custom `
                --time-period "from=$fromDate" "to=$toDate" `
                --dataset-aggregation '{"totalCost":{"name":"PreTaxCost","function":"Sum"}}' `
                --dataset-filter $datasetFilter `
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

            $moduleName   = $rg -replace "^$Prefix-" -replace '-rg$'
            $bar          = '█' * [Math]::Min([int]$projected, 40)
            $costColor    = if ($projected -gt 100) { 'Red' } elseif ($projected -gt 50) { 'Yellow' } else { 'Green' }
            $actualFmt    = $actual.ToString('C2').PadLeft(8)
            $projectedFmt = $projected.ToString('C2').PadLeft(8)

            Write-Host ("  {0,-20} Actual: {1}  Projected: {2}  {3}" -f $moduleName, $actualFmt, $projectedFmt, $bar) -ForegroundColor $costColor
        }

        Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        $tActualFmt = $totalActual.ToString('C2').PadLeft(8)
        $tProjFmt   = $totalProjected.ToString('C2').PadLeft(8)
        Write-Host ("  {0,-20} Actual: {1}  Projected: {2}" -f 'TOTAL', $tActualFmt, $tProjFmt) -ForegroundColor White
    }

    Write-Host ""

    # ── VM Status ─────────────────────────────────────────────────────────────
    Write-Host "  VIRTUAL MACHINES" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $vmsRaw = az vm list -o json 2>$null | ConvertFrom-Json
    $vms = $vmsRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}, @{n='size';e={$_.hardwareProfile.vmSize}}

    if ($vms) {
        foreach ($vm in $vms) {
            $pvQuery    = 'instanceView.statuses[?starts_with(code,''PowerState/'')].displayStatus'
            $powerState = az vm get-instance-view `
                --resource-group $vm.rg `
                --name $vm.name `
                --query $pvQuery `
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

    $clustersRaw = az aks list -o json 2>$null | ConvertFrom-Json
    $clusters = $clustersRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}, @{n='powerState';e={$_.powerState.code}}, @{n='version';e={$_.kubernetesVersion}}, @{n='nodeCount';e={$_.agentPoolProfiles[0].count}}

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
    $sbRaw        = az servicebus namespace list -o json 2>$null | ConvertFrom-Json
    $sbNamespaces = $sbRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='sku';e={$_.sku.name}}, @{n='rg';e={$_.resourceGroup}}

    $ehRaw        = az eventhubs namespace list -o json 2>$null | ConvertFrom-Json
    $ehNamespaces = $ehRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='sku';e={$_.sku.name}}, @{n='rg';e={$_.resourceGroup}}

    $caRaw  = az containerapp env list -o json 2>$null | ConvertFrom-Json
    $caEnvs = $caRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}

    $adfRaw = az resource list --resource-type 'Microsoft.DataFactory/factories' -o json 2>$null | ConvertFrom-Json
    $adfs   = $adfRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}

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

    $budgetQuery = '[?contains(name,''ade'')].{name:name,amount:amount,currentSpend:currentSpend.amount,timeGrain:timeGrain}'
    $budgets = az consumption budget list `
        --scope "subscriptions/$SubscriptionId" `
        --query $budgetQuery `
        -o json 2>$null | ConvertFrom-Json

    if ($budgets) {
        foreach ($b in $budgets) {
            $pct = if ($b.amount -gt 0) { [int](($b.currentSpend / $b.amount) * 100) } else { 0 }
            $barFilled = '█' * [Math]::Min([int]($pct / 2), 50)
            $barEmpty  = '░' * (50 - $barFilled.Length)
            $color     = if ($pct -ge 100) { 'Red' } elseif ($pct -ge 80) { 'Yellow' } else { 'Green' }

            $spendFmt  = $b.currentSpend.ToString('N0').PadLeft(8)
            $amountFmt = $b.amount.ToString('N0').PadLeft(8)
            $pctFmt    = ([string]$pct).PadLeft(3)
            $budgetLine = ("  {0,-25} [{1}{2}] {3}%" -f $b.name, $barFilled, $barEmpty, $pctFmt) + "  `$$spendFmt / `$$amountFmt"
            Write-Host $budgetLine -ForegroundColor $color
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

    $vmIds = az vm list -o json 2>$null | ConvertFrom-Json |
        Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object -ExpandProperty id

    $vmssIds = az vmss list -o json 2>$null | ConvertFrom-Json |
        Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object -ExpandProperty id

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
    $aksRaw   = az aks list -o json 2>$null | ConvertFrom-Json
    $aksNames = $aksRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}

    foreach ($aks in $aksNames) {
        Write-AdeLog "Stopping AKS cluster: $($aks.name)" -Level Warning
        az aks stop --name $aks.name --resource-group $aks.rg --no-wait --output none
    }
}

if ($StartAll) {
    Write-AdeSection "Starting All VMs"

    $vmIds = az vm list -o json 2>$null | ConvertFrom-Json |
        Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object -ExpandProperty id

    $vmssIds = az vmss list -o json 2>$null | ConvertFrom-Json |
        Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object -ExpandProperty id

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

    $aksRaw   = az aks list -o json 2>$null | ConvertFrom-Json
    $aksNames = $aksRaw | Where-Object { $_.tags.managedBy -eq 'ade' -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}

    foreach ($aks in $aksNames) {
        Write-AdeLog "Starting AKS cluster: $($aks.name)" -Level Info
        az aks start --name $aks.name --resource-group $aks.rg --no-wait --output none
    }
}

# ── Pre-flight: Cost Management provider + role ───────────────────────────────
$providerState = az provider show --namespace Microsoft.CostManagement --query 'registrationState' -o tsv 2>$null
if ($providerState -ne 'Registered') {
    Write-Warning "Microsoft.CostManagement provider is not registered in subscription '$($sub.name)'. Cost data will show as zero. Register with: az provider register --namespace Microsoft.CostManagement"
}

$roleAssignments = az role assignment list --assignee (az ad signed-in-user show --query id -o tsv 2>$null) `
    --scope "subscriptions/$SubscriptionId" --query "[].roleDefinitionName" -o json 2>$null | ConvertFrom-Json
$costRoles = @('Cost Management Reader', 'Cost Management Contributor', 'Owner', 'Contributor', 'Reader')
if (-not ($roleAssignments | Where-Object { $_ -in $costRoles })) {
    Write-Warning "Current user may lack 'Cost Management Reader' on this subscription. Cost data may be unavailable."
}

# ── Show dashboard ────────────────────────────────────────────────────────────
Show-AdeDashboard

if ($Watch) {
    while ($true) {
        Start-Sleep -Seconds 60
        Show-AdeDashboard
    }
}
