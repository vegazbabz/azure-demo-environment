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
    if ($LASTEXITCODE -ne 0) { throw "Could not switch to subscription '$SubscriptionId'. Verify az login and access." }
}
$sub = az account show --output json | ConvertFrom-Json
$SubscriptionId = $sub.id

# Returns $true when an Azure resource object has tags.managedBy = 'ade'.
# Safe against $null tags or missing keys (common on non-ADE resource groups).
function Test-AdeManagedBy {
    param([psobject]$Resource)
    $null -ne $Resource.tags -and
    $Resource.tags.PSObject.Properties['managedBy'] -and
    $Resource.tags.managedBy -eq 'ade'
}

function Show-AdeDashboard {

    $now    = Get-Date
    $year   = $now.Year
    $month  = $now.Month
    $daysInMonth    = [DateTime]::DaysInMonth($year, $month)
    $daysPassed     = $now.Day
    $budgetRespData = $null  # populated in cost section; reused by budget section

    # ── Header ────────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║       Azure Demo Environment — Cost & Status Dashboard           ║" -ForegroundColor Cyan
    Write-Host "║   Subscription : $($sub.name.PadRight(48))║" -ForegroundColor Cyan
    Write-Host "║   Refreshed    : $(($now.ToString('yyyy-MM-dd HH:mm:ss')).PadRight(48))║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # ── Resource group costs ──────────────────────────────────────────────────
    Write-Host "  COSTS — Current Month ($($now.ToString('MMMM yyyy')))" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Note: Azure Cost Management has an 8–48 h ingestion lag. Freshly" -ForegroundColor DarkGray
    Write-Host "  deployed resources will show `$0.00 until billing data is processed." -ForegroundColor DarkGray

    $rgsRaw = az group list -o json 2>$null | ConvertFrom-Json
    $rgs = $rgsRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.name -like "$Prefix-*" } |
        Select-Object -ExpandProperty name

    if (-not $rgs) {
        Write-Host "  No ADE resource groups found for prefix '$Prefix'." -ForegroundColor Gray
    } else {
        # Pre-fetch the budget amount so cost colours are relative to the budget.
        # Green  actual  = MTD spend is on pace (≤ expected for this day of month)
        # Yellow actual  = slightly over pace (up to 20% above expected)
        # Red    actual  = significantly over pace (>20% above expected)
        # Green  projected = end-of-month will stay below 85% of budget
        # Yellow projected = 85-100% of budget
        # Red    projected = will exceed budget
        $budgetAmount   = 0.0
        $budgetRestUrl  = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets?api-version=2023-11-01"
        $budgetRespData = $null
        try {
            $budgetRaw = az rest --method GET --url $budgetRestUrl 2>$null
            if ($LASTEXITCODE -eq 0 -and $budgetRaw) {
                $budgetRespData = $budgetRaw | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($budgetRespData -and $budgetRespData.value) {
                    $adeBudget = @($budgetRespData.value | Where-Object { $_.name -like "*$Prefix*" }) | Select-Object -First 1
                    if ($adeBudget) { $budgetAmount = [double]$adeBudget.properties.amount }
                }
            }
        } catch {}

        $totalActual    = 0.0
        $totalProjected = 0.0
        $rgCount        = ($rgs | Measure-Object).Count

        # Single REST call to get all RG costs at once (grouped by ResourceGroupName).
        # Uses the Microsoft.CostManagement/query REST API — no CLI extension needed.
        $rgCosts  = @{}   # rg-name → actual cost (DKK/USD etc.)
        $fromDate = "$year-$($month.ToString('D2'))-01"
        $toDate   = $now.ToString('yyyy-MM-dd')
        $costBodyObj = @{
            type      = 'Usage'
            timeframe = 'Custom'
            timePeriod = @{ from = $fromDate; to = $toDate }
            dataset = @{
                granularity = 'None'
                aggregation = @{ totalCost = @{ name = 'PreTaxCost'; function = 'Sum' } }
                grouping    = @( @{ type = 'Dimension'; name = 'ResourceGroupName' } )
            }
        }
        $costBodyFile = [System.IO.Path]::GetTempFileName() + '.json'
        $costBodyObj | ConvertTo-Json -Depth 10 -Compress | Set-Content $costBodyFile -Encoding utf8NoBOM
        try {
            $costUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
            $costRaw = az rest --method POST --url $costUrl --body "@$costBodyFile" --headers 'Content-Type=application/json' 2>$null
            $costEc  = $LASTEXITCODE
            if ($costEc -eq 0 -and $costRaw) {
                $costResp = $costRaw | ConvertFrom-Json -ErrorAction SilentlyContinue
                # Columns: [PreTaxCost, ResourceGroupName, Currency]
                $rgIdx = ($costResp.properties.columns | ForEach-Object { $_.name }).IndexOf('ResourceGroupName')
                $costIdx = ($costResp.properties.columns | ForEach-Object { $_.name }).IndexOf('PreTaxCost')
                if ($rgIdx -ge 0 -and $costIdx -ge 0) {
                    foreach ($row in @($costResp.properties.rows)) {
                        $rgName = [string]$row[$rgIdx]
                        if ($rgName) { $rgCosts[$rgName] = [double]$row[$costIdx] }
                    }
                }
            } else {
                Write-AdeLog "Cost Management query returned no data. Costs will show as zero unless your account has cost-reader access and billing data is available." -Level Warning
            }
        } finally {
            if (Test-Path $costBodyFile) { Remove-Item $costBodyFile -Force -ErrorAction SilentlyContinue }
        }

        foreach ($rg in ($rgs | Sort-Object)) {
            $actual = if ($rgCosts.ContainsKey($rg)) { $rgCosts[$rg] } else { 0.0 }
            $projected = if ($daysPassed -gt 0) { ($actual / $daysPassed) * $daysInMonth } else { 0.0 }

            $totalActual    += $actual
            $totalProjected += $projected

            $moduleName   = $rg -replace "^$Prefix-" -replace '-rg$'
            $bar          = '█' * [Math]::Min([int]$projected, 40)

            # Actual: neutral (it's a backward-looking fact; pace is shown on the TOTAL row)
            $actualColor = 'White'

            # Projected: budget-relative per-RG share when budget is known; else fixed thresholds
            $projectedColor = if ($budgetAmount -gt 0 -and $rgCount -gt 0) {
                $share = $budgetAmount / $rgCount
                if ($projected -gt $share)              { 'Red'    }
                elseif ($projected -gt $share * 0.75)   { 'Yellow' }
                else                                    { 'Green'  }
            } else {
                if ($projected -gt 100) { 'Red' } elseif ($projected -gt 50) { 'Yellow' } else { 'Green' }
            }

            $actualFmt    = $actual.ToString('C2').PadLeft(8)
            $projectedFmt = $projected.ToString('C2').PadLeft(8)

            Write-Host ("  {0,-20} Actual: " -f $moduleName) -NoNewline -ForegroundColor DarkGray
            Write-Host $actualFmt                             -NoNewline -ForegroundColor $actualColor
            Write-Host '  Projected: '                       -NoNewline -ForegroundColor DarkGray
            Write-Host ("{0}  {1}" -f $projectedFmt, $bar)              -ForegroundColor $projectedColor
        }

        Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        $tActualFmt = $totalActual.ToString('C2').PadLeft(8)
        $tProjFmt   = $totalProjected.ToString('C2').PadLeft(8)

        # Total actual: is MTD spend on pace relative to the budget?
        $totalActualColor = if ($budgetAmount -gt 0 -and $daysPassed -gt 0) {
            $expectedNow = $budgetAmount * ($daysPassed / $daysInMonth)
            if ($totalActual -gt $expectedNow * 1.2)  { 'Red'    }
            elseif ($totalActual -gt $expectedNow)    { 'Yellow' }
            else                                      { 'Green'  }
        } else { 'White' }

        # Total projected: will end-of-month spend stay within budget?
        $totalProjectedColor = if ($budgetAmount -gt 0) {
            if ($totalProjected -gt $budgetAmount)              { 'Red'    }
            elseif ($totalProjected -gt $budgetAmount * 0.85)  { 'Yellow' }
            else                                               { 'Green'  }
        } else { 'White' }

        Write-Host "  $('TOTAL'.PadRight(20)) Actual: " -NoNewline -ForegroundColor DarkGray
        Write-Host $tActualFmt                          -NoNewline -ForegroundColor $totalActualColor
        Write-Host '  Projected: '                      -NoNewline -ForegroundColor DarkGray
        Write-Host $tProjFmt                                       -ForegroundColor $totalProjectedColor
    }

    Write-Host ""

    # ── VM Status ─────────────────────────────────────────────────────────────
    Write-Host "  VIRTUAL MACHINES" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $vmsRaw = az vm list -o json 2>$null | ConvertFrom-Json
    $vms = $vmsRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}, @{n='size';e={$_.hardwareProfile.vmSize}}

    if ($vms) {
        foreach ($vm in $vms) {
            $iv         = az vm get-instance-view `
                --resource-group $vm.rg `
                --name $vm.name `
                -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            $powerState = ($iv.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' }).displayStatus

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
    $clusters = $clustersRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
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
    $sbNamespaces = $sbRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='sku';e={$_.sku.name}}, @{n='rg';e={$_.resourceGroup}}

    $ehRaw        = az eventhubs namespace list -o json 2>$null | ConvertFrom-Json
    $ehNamespaces = $ehRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='sku';e={$_.sku.name}}, @{n='rg';e={$_.resourceGroup}}

    $caRaw  = az containerapp env list -o json 2>$null | ConvertFrom-Json
    $caEnvs = $caRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}

    $adfRaw = az resource list --resource-type 'Microsoft.DataFactory/factories' -o json 2>$null | ConvertFrom-Json
    $adfs   = $adfRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
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

    # Reuse the REST response already fetched for cost colouring; fall back to a fresh call
    # if Show-AdeDashboard is called outside the rgs-else block (e.g. no ADE RGs deployed yet).
    $budgetsResp = if ($null -ne $budgetRespData) { $budgetRespData } else {
        try {
            $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets?api-version=2023-11-01"
            az rest --method GET --url $url 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        } catch { $null }
    }
    $budgets = if ($budgetsResp -and $budgetsResp.value) {
        @($budgetsResp.value | Where-Object { $_.name -like "*$Prefix*" } | ForEach-Object {
            [pscustomobject]@{
                name         = $_.name
                amount       = [double]$_.properties.amount
                currentSpend = [double]$_.properties.currentSpend.amount
                timeGrain    = $_.properties.timeGrain
            }
        })
    } else { $null }

    if ($budgets) {
        foreach ($b in $budgets) {
            $pct = if ($b.amount -gt 0) { [int](($b.currentSpend / $b.amount) * 100) } else { 0 }
            $barFilled = '█' * [Math]::Min([int]($pct / 2), 50)
            $barEmpty  = '░' * (50 - $barFilled.Length)
            $color     = if ($pct -ge 100) { 'Red' } elseif ($pct -ge 80) { 'Yellow' } else { 'Green' }

            $spendFmt  = $b.currentSpend.ToString('N0').PadLeft(8)
            $amountFmt = $b.amount.ToString('N0').PadLeft(8)
            $pctFmt    = ([string]$pct).PadLeft(3)
            $budgetLine = ("  {0,-25} [{1}{2}] {3}%" -f $b.name, $barFilled, $barEmpty, $pctFmt) + "  $spendFmt / $amountFmt"
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
if ($StopAll -and $StartAll) {
    throw '-StopAll and -StartAll are mutually exclusive. Specify only one.'
}
if ($StopAll) {
    Write-AdeSection "Stopping All VMs"

    $vmIds = az vm list -o json 2>$null | ConvertFrom-Json |
        Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object -ExpandProperty id

    $vmssIds = az vmss list -o json 2>$null | ConvertFrom-Json |
        Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
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
    $aksNames = $aksRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}

    foreach ($aks in $aksNames) {
        Write-AdeLog "Stopping AKS cluster: $($aks.name)" -Level Warning
        az aks stop --name $aks.name --resource-group $aks.rg --no-wait --output none
    }
}

if ($StartAll) {
    Write-AdeSection "Starting All VMs"

    $vmIds = az vm list -o json 2>$null | ConvertFrom-Json |
        Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object -ExpandProperty id

    $vmssIds = az vmss list -o json 2>$null | ConvertFrom-Json |
        Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
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
    $aksNames = $aksRaw | Where-Object { (Test-AdeManagedBy $_) -and $_.resourceGroup -like "$Prefix-*" } |
        Select-Object name, @{n='rg';e={$_.resourceGroup}}

    foreach ($aks in $aksNames) {
        Write-AdeLog "Starting AKS cluster: $($aks.name)" -Level Info
        az aks start --name $aks.name --resource-group $aks.rg --no-wait --output none
    }
}

# ── Pre-flight: Cost Management provider ──────────────────────────────────────
$providerState = az provider show --namespace Microsoft.CostManagement --query 'registrationState' -o tsv 2>$null
if ($providerState -ne 'Registered') {
    Write-Warning "Microsoft.CostManagement provider is not registered in subscription '$($sub.name)'. Cost data will show as zero. Register with: az provider register --namespace Microsoft.CostManagement"
}

# ── Show dashboard ────────────────────────────────────────────────────────────
Show-AdeDashboard

if ($Watch) {
    while ($true) {
        Start-Sleep -Seconds 60
        Show-AdeDashboard
    }
}
