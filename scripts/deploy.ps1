#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Demo Environment (ADE) — Main Deployment Orchestrator

.DESCRIPTION
    Deploys a complete Azure demo environment.

    Use -Mode default (the default) for out-of-the-box Azure settings with no hardening.
    Designed for CIS / MCSB benchmark testing to observe the baseline.

    Use -Mode hardened to deploy the CIS/MCSB-aligned modules from bicep/hardened/.
    Hardened mode enforces TLS 1.2, disables public network access, enables purge protection,
    Defender for Cloud, Sentinel, resource locks, and policy assignments in enforcement mode.

    Modules are deployed in dependency order:
      monitoring -> networking -> security -> compute -> storage ->
      databases -> appservices -> containers -> integration -> ai -> data -> governance

.PARAMETER Profile
    Deployment profile. Built-in options:
      full             All resource types (complete CIS coverage)
      minimal          VM + storage + monitoring (low cost)
      compute-only     VMs, VMSS (CIS Compute benchmark)
      databases-only   SQL + Cosmos DB
      networking-only  VNet, NSGs, AppGW, Bastion
      security-focus   Key Vault, Defender, Sentinel (CIS Security sections)
    Or pass an absolute/relative path to a custom JSON profile.

.PARAMETER Location
    Azure region. Default: westeurope
    List regions: az account list-locations --query "[].name" -o tsv

.PARAMETER Prefix
    Short prefix for resource names (2-8 lowercase alphanum). Default: ade
    Example: 'myco' -> resource groups like 'myco-networking-rg', 'myco-compute-rg'

.PARAMETER SubscriptionId
    Target subscription ID. If omitted, uses the current az account.

.PARAMETER AdminUsername
    Admin username for VMs. Default: adeadmin

.PARAMETER AdminPassword
    Override the VM admin password (SecureString). Must meet Azure complexity requirements
    (min 12 chars, upper + lower + digit + symbol).
    If omitted, a secure 12-character password is auto-generated and printed to the terminal.

.PARAMETER Mode
    Deployment mode.
      default   Use bicep/modules/ — DEFAULT Azure settings, no hardening (benchmark baseline).
      hardened  Use bicep/hardened/ — CIS/MCSB-aligned settings with enforcement.
    Default: default

.PARAMETER LogFile
    Optional path to write a plain-text copy of all log output.
    The file is created (or overwritten) at the start of the run.
    Example: -LogFile ./logs/deploy-$(Get-Date -f yyyyMMdd-HHmmss).log

.PARAMETER Force
    Skip deployment confirmation prompt.

.PARAMETER ContinueOnError
    Continue deploying remaining modules even if one fails.
    Without this switch the script prompts interactively (or aborts in CI) when a module fails.

.PARAMETER WhatIf
    Run Bicep what-if on each module without deploying.

.PARAMETER SkipModules
    Array of module names to skip regardless of profile settings.
    Example: -SkipModules containers,governance

.PARAMETER EnableModules
    Array of module names to forcibly enable (overrides profile setting).
    Example: -EnableModules sentinel

.EXAMPLE
    # Deploy the full environment to West Europe
    ./deploy.ps1 -Profile full -Location westeurope -Prefix ade

.EXAMPLE
    # Deploy only compute resources, skip confirmation
    ./deploy.ps1 -Profile compute-only -Location northeurope -Prefix demo -Force

.EXAMPLE
    # What-if dry run of the full profile
    ./deploy.ps1 -Profile full -WhatIf

.EXAMPLE
    # Use a custom profile file
    ./deploy.ps1 -Profile ./my-custom-profile.json

.EXAMPLE
    # Deploy hardened environment (CIS/MCSB-aligned)
    ./deploy.ps1 -Profile hardened -Mode hardened -Location westeurope -Prefix hdn

.NOTES
    Tooling: Azure CLI (all Azure API calls) + PowerShell 7+ (orchestration only).
    No Az PowerShell module is used.
    Reference: https://github.com/vegazbabz/azure-demo-environment
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Profile = 'full',

    [Parameter(Mandatory = $false)]
    [string]$Location = 'westeurope',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
    [string]$Prefix = 'ade',

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = '',

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername = 'adeadmin',

    [Parameter(Mandatory = $false)]
    [SecureString]$AdminPassword,

    [Parameter(Mandatory = $false)]
    [switch]$AutoGeneratePassword,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$ContinueOnError,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [string[]]$SkipModules = @(),

    [Parameter(Mandatory = $false)]
    [string[]]$EnableModules = @(),

    [Parameter(Mandatory = $false)]
    [ValidateSet('default', 'hardened')]
    [string]$Mode = 'default',

    [Parameter(Mandatory = $false)]
    [string]$LogFile = '',

    [Parameter(Mandatory = $false)]
    [string]$BudgetAlertEmail = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Bootstrap ───────────────────────────────────────────────────────────────
$scriptRoot = $PSScriptRoot
. "$scriptRoot\helpers\common.ps1"
. "$scriptRoot\helpers\validate.ps1"

# Honour the standard -Verbose switch: enables Debug-level console output
$script:AdeVerbose = ($VerbosePreference -eq 'Continue')
$startTime = Get-Date

if ($LogFile) {
    $resolvedLog = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $resolvedLog)
    Set-Content -LiteralPath $resolvedLog -Value @(
        "# ADE Deployment Log",
        "# Started  : $($startTime.ToString('yyyy-MM-dd HH:mm:ss UTC'))",
        "# Mode     : $Mode",
        "# Profile  : $Profile  |  Prefix: $Prefix  |  Location: $Location",
        "# " + ('─' * 57)
    )
    $script:AdeLogFile = $resolvedLog
}

Write-AdeSection "Azure Demo Environment — Deployment ($Mode mode)"
Write-AdeLog "Started at $($startTime.ToString('yyyy-MM-dd HH:mm:ss UTC'))" -Level Info

# ─── Subscription ─────────────────────────────────────────────────────────────
# Set before pre-flight so the login check displays the correct target subscription.
if ($SubscriptionId) {
    Write-AdeLog "az account set --subscription $SubscriptionId" -Level Debug
    az account set --subscription $SubscriptionId --output none
    if ($LASTEXITCODE -ne 0) { throw "Could not set subscription: $SubscriptionId" }
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
$null = Test-AdePrerequisites -Mode $Mode -StopOnError

$currentSub = az account show --output json | ConvertFrom-Json
$SubscriptionId = $currentSub.id

$sub = Test-AdeSubscription -SubscriptionId $SubscriptionId

# ─── Profile ──────────────────────────────────────────────────────────────────
$deployProfile = Get-AdeProfile -ProfileNameOrPath $Profile

# Guard: the 'hardened' profile must always be deployed with -Mode hardened.
# The workflow enforces this for CI runs; this check also catches local runs.
if ($deployProfile.profileName -eq 'hardened' -and $Mode -ne 'hardened') {
    throw "Profile 'hardened' requires -Mode hardened. Add -Mode hardened or choose a different profile."
}

# Apply overrides from -SkipModules / -EnableModules
foreach ($mod in $SkipModules) {
    if ($deployProfile.modules.PSObject.Properties[$mod]) {
        $deployProfile.modules.$mod.enabled = $false
        Write-AdeLog "Module '$mod' DISABLED via -SkipModules" -Level Warning
    } else {
        Write-AdeLog "Unknown module '$mod' in -SkipModules (ignored)" -Level Warning
    }
}
foreach ($mod in $EnableModules) {
    if ($deployProfile.modules.PSObject.Properties[$mod]) {
        $wasDisabled = ($deployProfile.modules.$mod.enabled -eq $false)
        $deployProfile.modules.$mod.enabled = $true
        # When a module was disabled in the profile, its feature flags are typically all false
        # (nothing to deploy). Auto-enable every boolean false feature so that an explicit
        # -EnableModules request actually provisions resources, not just an empty resource group.
        if ($wasDisabled -and $deployProfile.modules.$mod.PSObject.Properties['features']) {
            $autoEnabled = [System.Collections.Generic.List[string]]::new()
            foreach ($feat in $deployProfile.modules.$mod.features.PSObject.Properties) {
                if ($feat.Value -is [bool] -and $feat.Value -eq $false) {
                    $deployProfile.modules.$mod.features.$($feat.Name) = $true
                    $autoEnabled.Add($feat.Name)
                }
            }
            if ($autoEnabled.Count -gt 0) {
                Write-AdeLog "Module '$mod' was disabled in profile — auto-enabling features: $($autoEnabled -join ', ')" -Level Info
            }
        }
        Write-AdeLog "Module '$mod' ENABLED via -EnableModules" -Level Info
    } else {
        Write-AdeLog "Unknown module '$mod' in -EnableModules (ignored)" -Level Warning
    }
}

Test-AdeProfile -Profile $deployProfile

# ─── Location auto-detection ────────────────────────────────────────────────
# If resource groups with this prefix already exist (incremental profile stack-up
# e.g. minimal → databases-only) use their location automatically so the caller
# does not need to remember or re-specify the original region.
Write-AdeLog "az group list --query (looking for existing '${Prefix}-*-rg' resource groups)" -Level Debug
$existingRgLocation = az group list `
    --query "[?starts_with(name, '${Prefix}-') && ends_with(name, '-rg')].location | [0]" `
    -o tsv 2>$null
if ($existingRgLocation -and $existingRgLocation -ne $Location) {
    Write-AdeLog "Existing '$Prefix' environment detected in '$existingRgLocation'. Overriding -Location '$Location' → '$existingRgLocation' to match." -Level Warning
    $Location = $existingRgLocation
}

# ─── Permission preflight ────────────────────────────────────────────────────
# Check UAA/Owner up front when the Automation Account role assignment will run.
# Fails early so the caller gets a clear error before any resources are created.
$adeCanAssignRoles = $false
$govModPre         = $deployProfile.modules.PSObject.Properties['governance']
$govFeatPre        = if ($null -ne $govModPre -and $null -ne $govModPre.Value.PSObject.Properties['features']) { $govModPre.Value.features } else { $null }
$automationWanted  = $null -ne $govModPre -and
                   $govModPre.Value.enabled -eq $true -and
                   (Get-FeatureFlag -Features $govFeatPre -Name 'automationAccount') -eq $true
if ($automationWanted) {
    $null = Test-AdePermissions -SubscriptionId $SubscriptionId -StopOnError
    $adeCanAssignRoles = $true
}

# ─── Admin password ───────────────────────────────────────────────────────────
# Only generated when a module that actually uses it (compute, databases, data) is enabled.
# Password is generated here (before confirmation) only to validate -AdminPassword early
# if the user supplied one. Display and SecureString conversion happen after confirmation.
$needsAdminPassword = @('compute', 'databases', 'data') | Where-Object {
    $m = $deployProfile.modules.PSObject.Properties[$_]
    $null -ne $m -and $m.Value.enabled -eq $true
}
if ($AutoGeneratePassword -and $AdminPassword) {
    throw "-AutoGeneratePassword cannot be combined with -AdminPassword."
}
if ($AdminPassword) {
    $adminPasswordPlain = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
    if ($adminPasswordPlain.Length -lt 12) {
        throw "Admin password must be at least 12 characters."
    }
    $adminPasswordPlain = $null   # discard plaintext immediately after validation
}

# ─── Confirmation ─────────────────────────────────────────────────────────────
try {
    Confirm-AdeDeployment -Profile $deployProfile -Location $Location `
        -Prefix $Prefix -SubscriptionId $SubscriptionId -Mode $Mode -Force:$Force
} catch {
    if ($_.Exception.Message -match 'cancelled') {
        Write-AdeLog "Deployment cancelled by user." -Level Warning
        exit 0
    }
    throw
}

# ─── Generate and display password (after user confirms) ──────────────────────
if (($needsAdminPassword -or $AutoGeneratePassword) -and -not $AdminPassword) {
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghjkmnpqrstuvwxyz'
    $digits  = '23456789'
    $symbols = '!@#$%^&*'
    $rng     = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes   = [byte[]]::new(32)
    $rng.GetBytes($bytes)
    $pwChars = @(
        $upper[$bytes[0]  % $upper.Length]
        $upper[$bytes[1]  % $upper.Length]
        $upper[$bytes[2]  % $upper.Length]
        $upper[$bytes[3]  % $upper.Length]
        $lower[$bytes[4]  % $lower.Length]
        $lower[$bytes[5]  % $lower.Length]
        $lower[$bytes[6]  % $lower.Length]
        $lower[$bytes[7]  % $lower.Length]
        $digits[$bytes[8] % $digits.Length]
        $digits[$bytes[9] % $digits.Length]
        $symbols[$bytes[10] % $symbols.Length]
        $symbols[$bytes[11] % $symbols.Length]
    )
    # Shuffle with Fisher-Yates using crypto bytes
    for ($i = $pwChars.Count - 1; $i -gt 0; $i--) {
        $j = $bytes[$i % $bytes.Length] % ($i + 1)
        $tmp = $pwChars[$i]; $pwChars[$i] = $pwChars[$j]; $pwChars[$j] = $tmp
    }
    $generatedPw = -join $pwChars
    $AdminPassword = ConvertTo-SecureString $generatedPw -AsPlainText -Force
    $generatedPw   = $null   # discard plaintext from memory
    $script:_adePasswordWasGenerated = $true
} else {
    $script:_adePasswordWasGenerated = $false
}


# ─── Global state tracker ─────────────────────────────────────────────────────
# Collects output values from each module for cross-module parameter passing
$state = @{
    prefix            = $Prefix
    location          = $Location
    subscriptionId    = $SubscriptionId
    adminUsername     = $AdminUsername
    adminPassword     = $AdminPassword

    # Populated as modules deploy:
    logAnalyticsId       = ''
    appInsightsId        = ''
    appInsightsKey       = ''
    dataCollectionRuleId = ''

    vnetId                  = ''
    computeSubnetId         = ''
    appServicesSubnetId     = ''
    databaseSubnetId        = ''
    containerSubnetId       = ''
    appGatewayPublicIp      = ''
    privateEndpointSubnetId = ''

    keyVaultId              = ''
    keyVaultName            = ''
    managedIdentityId       = ''
    managedIdentityClientId = ''
    diskEncryptionSetId     = ''

    automationAccountId     = ''
    automationAccountName   = ''

    # New modules (v2)
    integrationSubnetId     = ''
    mysqlSubnetId           = ''
    postgresDnsZoneId       = ''
    mysqlDnsZoneId          = ''
    aiSubnetId              = ''
    dataSubnetId            = ''
    serviceBusId            = ''
    eventHubId              = ''
    dataFactoryId           = ''
    dcSubnetId              = ''
    storageAccountName      = ''

    # Private DNS zone IDs (populated from networking outputs when enablePrivateDnsZones = true)
    blobDnsZoneId           = ''
    sqlDnsZoneId            = ''
    cosmosDnsZoneId         = ''
    keyVaultDnsZoneId       = ''
    serviceBusDnsZoneId     = ''
    eventHubDnsZoneId       = ''
    redisDnsZoneId          = ''
    fileDnsZoneId           = ''
}

# ─── State hydration (best-effort) ───────────────────────────────────────────
# Recover cross-module output values from any resources already in Azure.
# This makes partial re-deploys (e.g. databases-only → full, or a retry after
# a mid-run failure) work correctly — downstream modules receive real IDs
# instead of empty strings, exactly as they would in a single full deploy.
# Every query is non-fatal: a missing resource leaves the value as '' and the
# module will create it on this run as normal.
function Initialize-AdeState {
    param([hashtable]$AdeState, [string]$Prefix, [string]$SubscriptionId)

    Write-AdeLog 'Hydrating state from existing Azure resources (best-effort)...' -Level Info
    $queriesOk  = 0   # number of successful Azure queries
    $keysSet    = 0   # number of individual state keys populated
    $notFound   = 0   # exit code ≠ 0 (resource doesn't exist yet — normal on first run)

    # ── Monitoring ────────────────────────────────────────────────────────────
    if (-not $AdeState.logAnalyticsId) {
        Write-AdeLog "az monitor log-analytics workspace show --name ${Prefix}-law --resource-group ${Prefix}-monitoring-rg" -Level Debug
        $v = az monitor log-analytics workspace show `
                 --name "${Prefix}-law" `
                 --resource-group "${Prefix}-monitoring-rg" `
                 --query id -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { $AdeState.logAnalyticsId = $v.Trim(); $queriesOk++; $keysSet++ }
        elseif ($LASTEXITCODE -eq 0)     { Write-AdeLog "  ✗ log-analytics workspace (empty result)" -Level Debug }
        else                             { Write-AdeLog "  ✗ log-analytics workspace (exit $LASTEXITCODE)" -Level Debug; $notFound++ }
    }
    if (-not $AdeState.appInsightsId) {
        Write-AdeLog "az monitor app-insights component show --app ${Prefix}-appi --resource-group ${Prefix}-monitoring-rg (id)" -Level Debug
        $v = az monitor app-insights component show `
                 --app "${Prefix}-appi" `
                 --resource-group "${Prefix}-monitoring-rg" `
                 --query id -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { $AdeState.appInsightsId = $v.Trim(); $queriesOk++; $keysSet++ }
        elseif ($LASTEXITCODE -eq 0)     { Write-AdeLog "  ✗ app-insights id (empty result)" -Level Debug }
        else                             { Write-AdeLog "  ✗ app-insights id (exit $LASTEXITCODE)" -Level Debug; $notFound++ }
    }
    if (-not $AdeState.appInsightsKey) {
        Write-AdeLog "az monitor app-insights component show --app ${Prefix}-appi --resource-group ${Prefix}-monitoring-rg (key)" -Level Debug
        $v = az monitor app-insights component show `
                 --app "${Prefix}-appi" `
                 --resource-group "${Prefix}-monitoring-rg" `
                 --query instrumentationKey -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { $AdeState.appInsightsKey = $v.Trim(); $keysSet++ }
    }

    # ── Networking — single VNet call; derive all subnet IDs from its resource ID ──
    # Subnet resource IDs are always <vnetId>/subnets/<name> — no extra API calls needed.
    if (-not $AdeState.vnetId) {
        Write-AdeLog "az network vnet show --name ${Prefix}-vnet --resource-group ${Prefix}-networking-rg" -Level Debug
        $v = az network vnet show `
                 --name "${Prefix}-vnet" `
                 --resource-group "${Prefix}-networking-rg" `
                 --query id -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) {
            $vId = $v.Trim()
            $AdeState.vnetId                  = $vId
            $AdeState.computeSubnetId         = "$vId/subnets/compute"
            $AdeState.appServicesSubnetId     = "$vId/subnets/appservices"
            $AdeState.databaseSubnetId        = "$vId/subnets/databases"
            $AdeState.containerSubnetId       = "$vId/subnets/containers"
            $AdeState.integrationSubnetId     = "$vId/subnets/integration"
            $AdeState.aiSubnetId              = "$vId/subnets/ai"
            $AdeState.dataSubnetId            = "$vId/subnets/data"
            $AdeState.privateEndpointSubnetId = "$vId/subnets/privateendpoints"
            $AdeState.mysqlSubnetId           = "$vId/subnets/mysql"
            $AdeState.dcSubnetId              = "$vId/subnets/dc"
            $queriesOk++; $keysSet += 11
        } elseif ($LASTEXITCODE -eq 0) {
            Write-AdeLog "  ✗ vnet (empty result)" -Level Debug
        } else {
            Write-AdeLog "  ✗ vnet (exit $LASTEXITCODE)" -Level Debug; $notFound++
        }
    }

    # ── Private DNS zones — one probe determines whether all zones were deployed ──
    # All ADE private DNS zones live in the same networking RG, so if blob exists
    # the others do too (they're all created together by networking.bicep).
    if (-not $AdeState.blobDnsZoneId) {
        Write-AdeLog "az network private-dns zone show --name privatelink.blob.core.windows.net --resource-group ${Prefix}-networking-rg" -Level Debug
        $probe = az network private-dns zone show `
                     --name 'privatelink.blob.core.windows.net' `
                     --resource-group "${Prefix}-networking-rg" `
                     --query id -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $probe) {
            $zBase = "/subscriptions/$SubscriptionId/resourceGroups/${Prefix}-networking-rg" +
                     '/providers/Microsoft.Network/privateDnsZones'
            $AdeState.blobDnsZoneId       = "$zBase/privatelink.blob.core.windows.net"
            $AdeState.fileDnsZoneId       = "$zBase/privatelink.file.core.windows.net"
            $AdeState.sqlDnsZoneId        = "$zBase/privatelink.database.windows.net"
            $AdeState.cosmosDnsZoneId     = "$zBase/privatelink.documents.azure.com"
            $AdeState.postgresDnsZoneId   = "$zBase/privatelink.postgres.database.azure.com"
            $AdeState.mysqlDnsZoneId      = "$zBase/privatelink.mysql.database.azure.com"
            $AdeState.keyVaultDnsZoneId   = "$zBase/privatelink.vaultcore.azure.net"
            $AdeState.serviceBusDnsZoneId = "$zBase/privatelink.servicebus.windows.net"
            $AdeState.eventHubDnsZoneId   = "$zBase/privatelink.eventhub.windows.net"
            $AdeState.redisDnsZoneId      = "$zBase/privatelink.redis.cache.windows.net"
            $queriesOk++; $keysSet += 10
        } elseif ($LASTEXITCODE -eq 0) {
            Write-AdeLog "  ✗ private-dns zones (empty result — zones not deployed)" -Level Debug
        } else {
            Write-AdeLog "  ✗ private-dns zones (exit $LASTEXITCODE)" -Level Debug; $notFound++
        }
    }

    # ── Security ──────────────────────────────────────────────────────────────
    # KV name includes uniqueString(RG.id) — query by RG rather than constructing.
    if (-not $AdeState.keyVaultName) {
        Write-AdeLog "az keyvault list --resource-group ${Prefix}-security-rg" -Level Debug
        $v = az keyvault list `
                 --resource-group "${Prefix}-security-rg" `
                 --query '[0].name' -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) {
            $AdeState.keyVaultName = $v.Trim()
            Write-AdeLog "az keyvault show --name $($v.Trim()) --resource-group ${Prefix}-security-rg" -Level Debug
            $vId = az keyvault show `
                       --name $AdeState.keyVaultName `
                       --resource-group "${Prefix}-security-rg" `
                       --query id -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and $vId) { $AdeState.keyVaultId = $vId.Trim(); $keysSet++ }
            $queriesOk++; $keysSet++  # keyVaultName
        } elseif ($LASTEXITCODE -eq 0) {
            Write-AdeLog "  ✗ keyvault (no vault in RG yet)" -Level Debug
        } else {
            Write-AdeLog "  ✗ keyvault list (exit $LASTEXITCODE)" -Level Debug; $notFound++
        }
    }
    if (-not $AdeState.managedIdentityId) {
        Write-AdeLog "az identity show --name ${Prefix}-identity --resource-group ${Prefix}-security-rg" -Level Debug
        $v = az identity show `
                 --name "${Prefix}-identity" `
                 --resource-group "${Prefix}-security-rg" `
                 --query id -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) {
            $AdeState.managedIdentityId = $v.Trim()
            $cId = az identity show `
                       --name "${Prefix}-identity" `
                       --resource-group "${Prefix}-security-rg" `
                       --query clientId -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and $cId) { $AdeState.managedIdentityClientId = $cId.Trim(); $keysSet++ }
            $queriesOk++; $keysSet++  # managedIdentityId
        } elseif ($LASTEXITCODE -eq 0) {
            Write-AdeLog "  ✗ managed-identity (empty result)" -Level Debug
        } else {
            Write-AdeLog "  ✗ managed-identity (exit $LASTEXITCODE)" -Level Debug; $notFound++
        }
    }

    # ── Storage — account name has uniqueString suffix, query by RG ──────────
    if (-not $AdeState.storageAccountName) {
        Write-AdeLog "az storage account list --resource-group ${Prefix}-storage-rg" -Level Debug
        $v = az storage account list `
                 --resource-group "${Prefix}-storage-rg" `
                 --query '[0].name' -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { $AdeState.storageAccountName = $v.Trim(); $queriesOk++; $keysSet++ }
        elseif ($LASTEXITCODE -eq 0)     { Write-AdeLog "  ✗ storage account (no account in RG yet)" -Level Debug }
        else                             { Write-AdeLog "  ✗ storage account list (exit $LASTEXITCODE)" -Level Debug; $notFound++ }
    }

    if ($queriesOk -gt 0) {
        Write-AdeLog "State hydration complete: $queriesOk quer$(if ($queriesOk -eq 1) {'y'} else {'ies'}) succeeded, $keysSet state key$(if ($keysSet -eq 1) {''} else {'s'}) pre-populated (cross-module dependencies only)." -Level Info
    } elseif ($notFound -gt 0) {
        Write-AdeLog "State hydration: resources not yet deployed (first run or clean environment). All modules will deploy fresh." -Level Info
    } else {
        Write-AdeLog "State hydration: no existing ADE resources found — all modules will deploy fresh." -Level Info
    }
}

Initialize-AdeState -AdeState $state -Prefix $Prefix -SubscriptionId $SubscriptionId

# ─── Module deployment ────────────────────────────────────────────────────────
$deploymentOrder = Get-AdeDeploymentOrder -Profile $deployProfile
$bicepRoot       = Join-Path $scriptRoot ('..\bicep\' + $(if ($Mode -eq 'hardened') { 'hardened' } else { 'modules' }))
$totalModules    = $deploymentOrder.Count
$currentModule   = 0

function Deploy-AdeModule {
    param(
        [string]$ModuleName,
        [string]$BicepFile,
        [hashtable]$Parameters
    )

    $rgName = "$Prefix-$($ModuleName.ToLower())-rg"
    $moduleTags = Build-AdeTags -Profile $deployProfile -Module $ModuleName
    New-AdeResourceGroup -Name $rgName -Location $Location -Tags $moduleTags -WhatIf:$WhatIf

    # Inject module-specific tags into every deployment so all resources carry the module tag
    if (-not $Parameters.ContainsKey('tags')) {
        $Parameters['tags'] = $moduleTags
    }

    Write-AdeLog "Deploying module: $ModuleName -> $rgName" -Level Step

    $result = Invoke-AdeBicepDeployment `
        -ResourceGroup  $rgName `
        -TemplatePath   $BicepFile `
        -DeploymentName "ade-$ModuleName-$(Get-Date -Format 'yyyyMMddHHmmss')" `
        -Parameters     $Parameters `
        -WhatIf:$WhatIf

    # Propagate the new-resources flag so the calling loop can pick the right message.
    $script:_adeModuleHadNewResources = if ($result -and $result.PSObject.Properties['HasNewResources']) { $result.HasNewResources } else { $false }
    return $(if ($result -and $result.PSObject.Properties['Outputs']) { $result.Outputs } else { $result })
}

$script:_adeModuleHadNewResources = $false
$failedModules = [System.Collections.Generic.List[string]]::new()
foreach ($moduleName in $deploymentOrder) {
    $currentModule++
    Write-AdeSection "$moduleName Module [$currentModule/$totalModules]"

    try {

        switch ($moduleName) {

            # ── MONITORING ──────────────────────────────────────────────────
            'monitoring' {
                $bicep = Join-Path $bicepRoot 'monitoring\monitoring.bicep'
                $monFeatProp = $deployProfile.modules.monitoring.PSObject.Properties['features']
                $monFeatures = if ($null -ne $monFeatProp) { $monFeatProp.Value } else { [pscustomobject]@{} }
                $params = @{
                    prefix           = $Prefix
                    location         = $Location
                    deployAlertRules = (Get-FeatureFlag -Features $monFeatures -Name 'alertRules').ToString().ToLower()
                }
                $monAlertEmail = Get-FeatureFlag -Features $monFeatures -Name 'alertEmail' -Default ''
                if (-not [string]::IsNullOrEmpty($monAlertEmail)) {
                    $params['alertEmailAddress'] = $monAlertEmail
                }
                $outputs = Deploy-AdeModule -ModuleName 'monitoring' -BicepFile $bicep -Parameters $params
                $state.logAnalyticsId       = Get-AdeDeploymentOutput $outputs 'logAnalyticsId'
                $state.appInsightsId        = Get-AdeDeploymentOutput $outputs 'appInsightsId'
                $state.appInsightsKey       = Get-AdeDeploymentOutput $outputs 'appInsightsInstrumentationKey'
                $state.dataCollectionRuleId = Get-AdeDeploymentOutput $outputs 'dataCollectionRuleId'
            }

            # ── NETWORKING ──────────────────────────────────────────────────
            'networking' {
                $bicep = Join-Path $bicepRoot 'networking\networking.bicep'
                $netFeatProp = $deployProfile.modules.networking.PSObject.Properties['features']
                $netFeatures = if ($null -ne $netFeatProp) { $netFeatProp.Value } else { [pscustomobject]@{} }
                # Guard: compute may be disabled (no features key) on profiles like databases-only, networking-only.
                # Accessing compute.features directly throws with Set-StrictMode when the key is absent.
                $computeModProp   = $deployProfile.modules.PSObject.Properties['compute']
                $computeFeatures  = if ($null -ne $computeModProp -and
                                        $null -ne $computeModProp.Value.PSObject.Properties['features']) {
                                        $computeModProp.Value.features
                                    } else {
                                        [pscustomobject]@{}
                                    }
                $params = @{
                    prefix                 = $Prefix
                    location               = $Location
                    bastionSku             = Get-FeatureFlag -Features $netFeatures -Name 'bastionSku' -Default 'Developer'
                    enableAppGateway       = (Get-FeatureFlag -Features $netFeatures -Name 'enableAppGateway').ToString().ToLower()
                    enableFirewall         = Get-FeatureFlag -Features $netFeatures -Name 'enableFirewall' -Default 'None'
                    enableVpnGateway       = (Get-FeatureFlag -Features $netFeatures -Name 'enableVpnGateway').ToString().ToLower()
                    enableNatGateway       = (Get-FeatureFlag -Features $netFeatures -Name 'enableNatGateway').ToString().ToLower()
                    enableDdos             = (Get-FeatureFlag -Features $netFeatures -Name 'enableDdos').ToString().ToLower()
                    enablePrivateDnsZones  = (Get-FeatureFlag -Features $netFeatures -Name 'enablePrivateDnsZones').ToString().ToLower()
                    deployDomainController = (Get-FeatureFlag -Features $computeFeatures -Name 'domainController').ToString().ToLower()
                }
                $outputs = Deploy-AdeModule -ModuleName 'networking' -BicepFile $bicep -Parameters $params
                $state.vnetId                  = Get-AdeDeploymentOutput $outputs 'vnetId'
                $state.computeSubnetId         = Get-AdeDeploymentOutput $outputs 'computeSubnetId'
                $state.appServicesSubnetId     = Get-AdeDeploymentOutput $outputs 'appServicesSubnetId'
                $state.databaseSubnetId        = Get-AdeDeploymentOutput $outputs 'databaseSubnetId'
                $state.containerSubnetId       = Get-AdeDeploymentOutput $outputs 'containerSubnetId'
                $state.integrationSubnetId     = Get-AdeDeploymentOutput $outputs 'integrationSubnetId'
                $state.aiSubnetId              = Get-AdeDeploymentOutput $outputs 'aiSubnetId'
                $state.dataSubnetId            = Get-AdeDeploymentOutput $outputs 'dataSubnetId'
                $state.privateEndpointSubnetId = Get-AdeDeploymentOutput $outputs 'privateEndpointSubnetId'
                $state.mysqlSubnetId           = Get-AdeDeploymentOutput $outputs 'mysqlSubnetId'
                $state.postgresDnsZoneId       = Get-AdeDeploymentOutput $outputs 'postgresDnsZoneId'
                $state.mysqlDnsZoneId          = Get-AdeDeploymentOutput $outputs 'mysqlDnsZoneId'
                $state.appGatewayPublicIp      = Get-AdeDeploymentOutput $outputs 'appGatewayPublicIp'
                # DNS zone IDs for private endpoints
                $state.blobDnsZoneId           = Get-AdeDeploymentOutput $outputs 'blobDnsZoneId'
                $state.sqlDnsZoneId            = Get-AdeDeploymentOutput $outputs 'sqlDnsZoneId'
                $state.cosmosDnsZoneId         = Get-AdeDeploymentOutput $outputs 'cosmosDnsZoneId'
                $state.keyVaultDnsZoneId       = Get-AdeDeploymentOutput $outputs 'keyVaultDnsZoneId'
                $state.serviceBusDnsZoneId     = Get-AdeDeploymentOutput $outputs 'serviceBusDnsZoneId'
                $state.eventHubDnsZoneId       = Get-AdeDeploymentOutput $outputs 'eventHubDnsZoneId'
                $state.redisDnsZoneId          = Get-AdeDeploymentOutput $outputs 'redisDnsZoneId'
                $state.fileDnsZoneId           = Get-AdeDeploymentOutput $outputs 'fileDnsZoneId'
                $state.dcSubnetId              = Get-AdeDeploymentOutput $outputs 'dcSubnetId'
            }

            # ── SECURITY ────────────────────────────────────────────────────
            'security' {
                $bicep = Join-Path $bicepRoot 'security\security.bicep'
                $secFeatures = if ($null -ne $deployProfile.modules.security.PSObject.Properties['features']) { $deployProfile.modules.security.features } else { [pscustomobject]@{} }
                # Resolve deployer object ID so KV Secrets Officer role can be granted for seed-data.ps1.
                # signed-in-user only works for interactive logins; OIDC/CI falls back to sp show.
                # Track principal type so the Bicep role assignment is valid for both users and SPs.
                $deployerOid  = az ad signed-in-user show --query id -o tsv 2>$null
                $deployerType = 'User'
                if (-not $deployerOid) {
                    $callerAppId  = az account show --query 'user.name' -o tsv 2>$null
                    $deployerOid  = az ad sp show --id $callerAppId --query id -o tsv 2>$null
                    $deployerType = 'ServicePrincipal'
                }
                # Some az CLI versions return the GUID wrapped in double-quotes (e.g. "abc-..."); strip them.
                if ($deployerOid) { $deployerOid = $deployerOid.Trim().Trim('"') }
                $params = @{
                    prefix                = $Prefix
                    location              = $Location
                    logAnalyticsId        = $state.logAnalyticsId
                    deployKeyVault        = (Get-FeatureFlag -Features $secFeatures -Name 'keyVault'          -Default $true).ToString().ToLower()
                    deployManagedIdentity = (Get-FeatureFlag -Features $secFeatures -Name 'managedIdentity'   -Default $true).ToString().ToLower()
                    enableDefender        = (Get-FeatureFlag -Features $secFeatures -Name 'defenderForCloud').ToString().ToLower()
                    enableSentinel        = (Get-FeatureFlag -Features $secFeatures -Name 'sentinel').ToString().ToLower()
                }
                if ($deployerOid) {
                    $params['deployerPrincipalId']   = $deployerOid
                    $params['deployerPrincipalType'] = $deployerType
                }
                # privateEndpointSubnetId, keyVaultDnsZoneId, and allowedCidrRanges are only
                # declared in the hardened security module — do not pass them to the default one.
                if ($Mode -eq 'hardened') {
                    $params['privateEndpointSubnetId'] = $state.privateEndpointSubnetId
                    $params['keyVaultDnsZoneId']       = $state.keyVaultDnsZoneId
                    # allowedCidrRanges: public IPs (CIDR) permitted through KV network ACLs
                    $kvCidrs = Get-FeatureFlag -Features $secFeatures -Name 'allowedCidrRanges' -Default $null
                    if ($kvCidrs -and $kvCidrs.Count -gt 0) { $params['allowedCidrRanges'] = $kvCidrs }
                }
                $outputs = Deploy-AdeModule -ModuleName 'security' -BicepFile $bicep -Parameters $params
                $state.keyVaultId              = Get-AdeDeploymentOutput $outputs 'keyVaultId'
                $state.keyVaultName            = Get-AdeDeploymentOutput $outputs 'keyVaultName'
                $state.managedIdentityId       = Get-AdeDeploymentOutput $outputs 'managedIdentityId'
                $state.managedIdentityClientId = Get-AdeDeploymentOutput $outputs 'managedIdentityClientId'
                $state.diskEncryptionSetId     = ''
            }

            # ── COMPUTE ─────────────────────────────────────────────────────
            'compute' {
                $bicep = Join-Path $bicepRoot 'compute\compute.bicep'
                $compFeatProp = $deployProfile.modules.compute.PSObject.Properties['features']
                $compFeatures = if ($null -ne $compFeatProp) { $compFeatProp.Value } else { [pscustomobject]@{} }
                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    subnetId            = $state.computeSubnetId
                    adminUsername       = $state.adminUsername
                    adminPassword       = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    deployWindowsVm     = (Get-FeatureFlag -Features $compFeatures -Name 'windowsVm').ToString().ToLower()
                    deployLinuxVm       = (Get-FeatureFlag -Features $compFeatures -Name 'linuxVm').ToString().ToLower()
                    deployVmss          = (Get-FeatureFlag -Features $compFeatures -Name 'vmss').ToString().ToLower()
                    enableAutoShutdown  = (Get-FeatureFlag -Features $compFeatures -Name 'enableAutoShutdown').ToString().ToLower()
                    vmSize              = Get-FeatureFlag -Features $compFeatures -Name 'vmSku' -Default 'Standard_B2s'
                    deployDomainController = (Get-FeatureFlag -Features $compFeatures -Name 'domainController').ToString().ToLower()
                    dcSubnetId          = if ($state.dcSubnetId) { $state.dcSubnetId } else { '' }
                    domainName          = Get-FeatureFlag -Features $compFeatures -Name 'domainName' -Default "${Prefix}.local"
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId']       = $state.logAnalyticsId
                    $params['dataCollectionRuleId'] = $state.dataCollectionRuleId
                }
                $null = Deploy-AdeModule -ModuleName 'compute' -BicepFile $bicep -Parameters $params
                if ($script:_adePasswordWasGenerated -and $script:_adeModuleHadNewResources) {
                    $pwPlain = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    Write-Host ""
                    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
                    Write-Host "║   AUTO-GENERATED ADMIN PASSWORD                                  ║" -ForegroundColor Yellow
                    Write-Host "║   Username : " -ForegroundColor Yellow -NoNewline
                    Write-Host $state.adminUsername.PadRight(52) -ForegroundColor White -NoNewline
                    Write-Host "║" -ForegroundColor Yellow
                    Write-Host "║   Password : " -ForegroundColor Yellow -NoNewline
                    Write-Host $pwPlain.PadRight(52) -ForegroundColor White -NoNewline
                    Write-Host "║" -ForegroundColor Yellow
                    Write-Host "║   This password is used for VM / VMSS / SQL / PostgreSQL / MySQL. ║" -ForegroundColor Yellow
                    Write-Host "║   It will be shown again in the deployment summary.               ║" -ForegroundColor Yellow
                    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
                    Write-Host ""
                    $pwPlain = $null
                }
            }

            # ── STORAGE ─────────────────────────────────────────────────────
            'storage' {
                $bicep = Join-Path $bicepRoot 'storage\storage.bicep'
                $stFeatures = if ($null -ne $deployProfile.modules.storage.PSObject.Properties['features']) { $deployProfile.modules.storage.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix            = $Prefix
                    location          = $Location
                    enableDataLake    = (Get-FeatureFlag -Features $stFeatures -Name 'dataLakeGen2').ToString().ToLower()
                    enableSoftDelete  = (Get-FeatureFlag -Features $stFeatures -Name 'enableSoftDelete').ToString().ToLower()
                    enableVersioning  = (Get-FeatureFlag -Features $stFeatures -Name 'enableVersioning').ToString().ToLower()
                    privateEndpointSubnetId = $state.privateEndpointSubnetId
                    blobDnsZoneId           = $state.blobDnsZoneId
                    fileDnsZoneId           = $state.fileDnsZoneId
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                    # allowedCidrRanges: public IPs (CIDR) permitted through Storage network ACLs
                    $stCidrs = Get-FeatureFlag -Features $stFeatures -Name 'allowedCidrRanges' -Default $null
                    if ($stCidrs -and $stCidrs.Count -gt 0) { $params['allowedCidrRanges'] = $stCidrs }
                }
                $outputs = Deploy-AdeModule -ModuleName 'storage' -BicepFile $bicep -Parameters $params
                $state.storageAccountName = Get-AdeDeploymentOutput $outputs 'storageAccountName'
            }

            # ── DATABASES ───────────────────────────────────────────────────
            'databases' {
                $bicep = Join-Path $bicepRoot 'databases\databases.bicep'
                $dbFeatProp = $deployProfile.modules.databases.PSObject.Properties['features']
                $dbFeatures = if ($null -ne $dbFeatProp) { $dbFeatProp.Value } else { [pscustomobject]@{} }
                $params = @{
                    prefix            = $Prefix
                    location          = $Location
                    subnetId          = $state.databaseSubnetId
                    sqlAdminLogin     = $state.adminUsername
                    sqlAdminPassword  = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    pgAdminLogin      = $state.adminUsername
                    pgAdminPassword   = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    mysqlAdminLogin   = $state.adminUsername
                    mysqlAdminPassword = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    deploySql         = (Get-FeatureFlag -Features $dbFeatures -Name 'sqlDatabase').ToString().ToLower()
                    deployCosmos      = (Get-FeatureFlag -Features $dbFeatures -Name 'cosmosDb').ToString().ToLower()
                    deployPostgresql  = (Get-FeatureFlag -Features $dbFeatures -Name 'postgresql').ToString().ToLower()
                    postgresDnsZoneId = $state.postgresDnsZoneId
                    deployMysql       = (Get-FeatureFlag -Features $dbFeatures -Name 'mysql').ToString().ToLower()
                    mysqlSubnetId     = $state.mysqlSubnetId
                    mysqlDnsZoneId    = $state.mysqlDnsZoneId
                    deployRedis       = (Get-FeatureFlag -Features $dbFeatures -Name 'redis').ToString().ToLower()
                    privateEndpointSubnetId = $state.privateEndpointSubnetId
                    sqlDnsZoneId      = $state.sqlDnsZoneId
                    cosmosDnsZoneId   = $state.cosmosDnsZoneId
                    redisDnsZoneId    = $state.redisDnsZoneId
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                }
                $null = Deploy-AdeModule -ModuleName 'databases' -BicepFile $bicep -Parameters $params
                if ($script:_adePasswordWasGenerated) {
                    $pwPlain = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    Write-Host ""
                    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
                    Write-Host "║   AUTO-GENERATED DATABASE ADMIN PASSWORD                         ║" -ForegroundColor Yellow
                    Write-Host "║   Username : " -ForegroundColor Yellow -NoNewline
                    Write-Host $state.adminUsername.PadRight(52) -ForegroundColor White -NoNewline
                    Write-Host "║" -ForegroundColor Yellow
                    Write-Host "║   Password : " -ForegroundColor Yellow -NoNewline
                    Write-Host $pwPlain.PadRight(52) -ForegroundColor White -NoNewline
                    Write-Host "║" -ForegroundColor Yellow
                    $seedLine1 = "   .\scripts\seed-data.ps1 -Prefix $Prefix ``"
                    $seedLine2 = "     -DatabaseAdminPassword '$pwPlain'"
                    Write-Host "║$($seedLine1.PadRight(66))║" -ForegroundColor Yellow
                    Write-Host "║$($seedLine2.PadRight(66))║" -ForegroundColor Yellow
                    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
                    Write-Host ""
                    $pwPlain = $null
                }
            }

            # ── APP SERVICES ────────────────────────────────────────────────
            'appservices' {
                $bicep = Join-Path $bicepRoot 'appservices\appservices.bicep'
                $appFeatProp = $deployProfile.modules.appservices.PSObject.Properties['features']
                $appFeatures = if ($null -ne $appFeatProp) { $appFeatProp.Value } else { [pscustomobject]@{} }
                $params = @{
                    prefix                = $Prefix
                    location              = $Location
                    appServiceSubnetId    = $state.appServicesSubnetId
                    deployWindowsApp      = (Get-FeatureFlag -Features $appFeatures -Name 'windowsWebApp').ToString().ToLower()
                    deployFunctionApp     = (Get-FeatureFlag -Features $appFeatures -Name 'functionApp').ToString().ToLower()
                    deployLogicApp        = (Get-FeatureFlag -Features $appFeatures -Name 'logicApp').ToString().ToLower()
                }
                $null = Deploy-AdeModule -ModuleName 'appservices' -BicepFile $bicep -Parameters $params
            }

            # ── CONTAINERS ──────────────────────────────────────────────────
            'containers' {
                $bicep = Join-Path $bicepRoot 'containers\containers.bicep'

                # If a Container Apps Environment from a previous run is stuck in
                # 'Failed' state, ARM rejects new container app creation with
                # ManagedEnvironmentNotReadyForAppCreation. Delete it so Bicep
                # can recreate it cleanly on this run.
                $caeRg   = "$Prefix-containers-rg"
                $caeName = "$Prefix-cae"
                Write-AdeLog "az containerapp env show --name $caeName (checking for Failed state)" -Level Debug
                $caeState = az containerapp env show --name $caeName --resource-group $caeRg --query 'properties.provisioningState' -o tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and $caeState -eq 'Failed') {
                    Write-AdeLog "Container Apps Environment '$caeName' is in Failed state — deleting so it can be recreated." -Level Warning
                    az containerapp env delete --name $caeName --resource-group $caeRg --yes --output none 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Could not delete failed Container Apps Environment '$caeName'. Delete it manually and retry."
                    }
                    Write-AdeLog "Container Apps Environment '$caeName' deleted." -Level Info
                }

                $ctFeatProp = $deployProfile.modules.containers.PSObject.Properties['features']
                $ctFeatures = if ($null -ne $ctFeatProp) { $ctFeatProp.Value } else { [pscustomobject]@{} }
                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    subnetId                = $state.containerSubnetId
                    deployAcr               = (Get-FeatureFlag -Features $ctFeatures -Name 'containerRegistry').ToString().ToLower()
                    deployAks               = (Get-FeatureFlag -Features $ctFeatures -Name 'kubernetesService').ToString().ToLower()
                    deployContainerApps     = (Get-FeatureFlag -Features $ctFeatures -Name 'containerApps').ToString().ToLower()
                    deployContainerInstances = (Get-FeatureFlag -Features $ctFeatures -Name 'containerInstances').ToString().ToLower()
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                    $aksIpRanges = Get-FeatureFlag -Features $ctFeatures -Name 'aksAuthorizedIpRanges' -Default $null
                    if ($null -ne $aksIpRanges) { $params['aksAuthorizedIpRanges'] = $aksIpRanges }
                }
                $null = Deploy-AdeModule -ModuleName 'containers' -BicepFile $bicep -Parameters $params
            }

            # ── INTEGRATION ─────────────────────────────────────────────────
            'integration' {
                $bicep = Join-Path $bicepRoot 'integration\integration.bicep'
                $intFeatProp = $deployProfile.modules.integration.PSObject.Properties['features']
                $intFeatures = if ($null -ne $intFeatProp) { $intFeatProp.Value } else { [pscustomobject]@{} }
                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    deployServiceBus    = (Get-FeatureFlag -Features $intFeatures -Name 'serviceBus').ToString().ToLower()
                    deployEventHub      = (Get-FeatureFlag -Features $intFeatures -Name 'eventHub').ToString().ToLower()
                    deployEventGrid     = (Get-FeatureFlag -Features $intFeatures -Name 'eventGrid').ToString().ToLower()
                    deploySignalR       = (Get-FeatureFlag -Features $intFeatures -Name 'signalR').ToString().ToLower()
                    deployApim          = (Get-FeatureFlag -Features $intFeatures -Name 'apiManagement').ToString().ToLower()
                    apimSku             = Get-FeatureFlag -Features $intFeatures -Name 'apimSku' -Default 'Developer'
                    apimPublisherEmail  = Get-FeatureFlag -Features $intFeatures -Name 'apimPublisherEmail' -Default 'admin@example.com'
                    apimPublisherName   = Get-FeatureFlag -Features $intFeatures -Name 'apimPublisherName' -Default 'ADE Demo'
                    privateEndpointSubnetId = $state.privateEndpointSubnetId
                    serviceBusDnsZoneId     = $state.serviceBusDnsZoneId
                    eventHubDnsZoneId       = $state.eventHubDnsZoneId
                }
                # Warn when APIM is enabled but the publisher email is still the placeholder.
                # APIM provisioning succeeds with a placeholder, but notification emails won't work.
                $apimEnabled = (Get-FeatureFlag -Features $intFeatures -Name 'apiManagement') -eq $true
                if ($apimEnabled -and $params['apimPublisherEmail'] -eq 'admin@example.com') {
                    Write-AdeLog "APIM publisherEmail is still 'admin@example.com' (placeholder). Set integration.features.apimPublisherEmail in your profile to receive APIM notifications." -Level Warning
                }
                $outputs = Deploy-AdeModule -ModuleName 'integration' -BicepFile $bicep -Parameters $params
                $state.serviceBusId   = Get-AdeDeploymentOutput $outputs 'serviceBusId'
                $state.eventHubId     = Get-AdeDeploymentOutput $outputs 'eventHubNamespaceId'
            }

            # ── AI ──────────────────────────────────────────────────────────
            'ai' {
                $bicep = Join-Path $bicepRoot 'ai\ai.bicep'
                $aiFeatProp = $deployProfile.modules.ai.PSObject.Properties['features']
                $aiFeatures = if ($null -ne $aiFeatProp) { $aiFeatProp.Value } else { [pscustomobject]@{} }
                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    deployAiServices        = (Get-FeatureFlag -Features $aiFeatures -Name 'aiServices').ToString().ToLower()
                    deployOpenAi            = (Get-FeatureFlag -Features $aiFeatures -Name 'openAi').ToString().ToLower()
                    deployCognitiveSearch   = (Get-FeatureFlag -Features $aiFeatures -Name 'cognitiveSearch').ToString().ToLower()
                    deployMachineLearning   = (Get-FeatureFlag -Features $aiFeatures -Name 'machineLearning').ToString().ToLower()
                    cognitiveSearchSku      = (Get-FeatureFlag -Features $aiFeatures -Name 'cognitiveSearchSku' -Default 'basic')
                    subnetId                = $state.aiSubnetId
                }
                $null = Deploy-AdeModule -ModuleName 'ai' -BicepFile $bicep -Parameters $params
            }

            # ── DATA ────────────────────────────────────────────────────────
            'data' {
                $bicep = Join-Path $bicepRoot 'data\data.bicep'
                $dataFeatProp = $deployProfile.modules.data.PSObject.Properties['features']
                $dataFeatures = if ($null -ne $dataFeatProp) { $dataFeatProp.Value } else { [pscustomobject]@{} }

                # ── Purview pre-flight: detect tenant-level location conflict ──────
                # Azure only allows one free-tier Purview account per tenant. Attempting
                # to create one in a region that differs from an existing free-tier account
                # fails with error 39002. Check before deploying and auto-skip if needed.
                $deployPurviewFlag = Get-FeatureFlag -Features $dataFeatures -Name 'purview'
                if ($deployPurviewFlag) {
                    $existingPurview = $null
                    # Use Resource Graph REST API directly (tenant-wide, no extension needed).
                    # az graph query requires the resource-graph CLI extension and only searches
                    # the default subscription scope; az rest hits the ARM endpoint directly and
                    # returns accounts from all accessible subscriptions in the tenant.
                    $graphBody = '{"query":"Resources | where type =~ ''microsoft.purview/accounts'' | project name, location"}'
                    $graphRaw = az rest --method POST `
                        --url 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
                        --body $graphBody --output json 2>$null
                    if ($LASTEXITCODE -eq 0 -and $graphRaw) {
                        try {
                            $graphResult = $graphRaw | ConvertFrom-Json -ErrorAction Stop
                            $existingPurview = $graphResult.data | Where-Object { $_.location -ne $Location } | Select-Object -First 1
                        } catch {}
                    }
                    if (-not $existingPurview) {
                        # Fallback: subscription-level list (catches same-subscription accounts
                        # if the REST call above fails for any reason).
                        $pvJson = az resource list --resource-type Microsoft.Purview/accounts --output json 2>$null
                        if ($LASTEXITCODE -eq 0 -and $pvJson) {
                            try {
                                $pvList = $pvJson | ConvertFrom-Json -ErrorAction Stop
                                $existingPurview = $pvList | Where-Object { $_.location -ne $Location } | Select-Object -First 1
                            } catch {}
                        }
                    }
                    if ($existingPurview) {
                        Write-AdeLog "Purview account '$($existingPurview.name)' already exists in location '$($existingPurview.location)'. Azure only allows one free-tier Purview account per tenant and it cannot be moved to a different region. Skipping Purview for this deployment. To deploy Purview, re-run in region '$($existingPurview.location)' or set 'purview: false' in your profile." -Level Warning
                        $deployPurviewFlag = $false
                    }
                }

                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    deployDataFactory   = (Get-FeatureFlag -Features $dataFeatures -Name 'dataFactory').ToString().ToLower()
                    deploySynapse       = (Get-FeatureFlag -Features $dataFeatures -Name 'synapse').ToString().ToLower()
                    deployDatabricks    = (Get-FeatureFlag -Features $dataFeatures -Name 'databricks').ToString().ToLower()
                    deployPurview       = $deployPurviewFlag.ToString().ToLower()
                    storageAccountName  = if ($state.storageAccountName) { $state.storageAccountName } else { '' }
                    subnetId            = $state.dataSubnetId
                }
                if ($Mode -eq 'hardened') {
                    $params['synapseAdminPassword'] = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                }
                try {
                    $outputs = Deploy-AdeModule -ModuleName 'data' -BicepFile $bicep -Parameters $params
                } catch {
                    # Error 39002: Azure tracks free-tier Purview tenancy in a region even after
                    # the account is deleted. The ghost record can't be found via resource list,
                    # so the pre-flight check misses it. Detect the error here and auto-retry
                    # without Purview — all other data resources still deploy successfully.
                    if ($_.Exception.Message -match '39002') {
                        Write-AdeLog "Purview deployment failed with tenant-level location conflict (error 39002). The tenant already has a free-tier Purview record in a different region. Auto-retrying without Purview. To deploy Purview, re-run from the region shown in the error above." -Level Warning
                        $params['deployPurview'] = 'false'
                        $outputs = Deploy-AdeModule -ModuleName 'data' -BicepFile $bicep -Parameters $params
                    } else {
                        throw
                    }
                }
                $state.dataFactoryId = Get-AdeDeploymentOutput $outputs 'dataFactoryId'
            }

            # ── GOVERNANCE ──────────────────────────────────────────────────
            'governance' {
                $bicep = Join-Path $bicepRoot 'governance\governance.bicep'
                $govFeatProp = $deployProfile.modules.governance.PSObject.Properties['features']
                $govFeatures = if ($null -ne $govFeatProp) { $govFeatProp.Value } else { [pscustomobject]@{} }

                # Budget requires a notification email — silently downgrade to disabled if not set.
                # -BudgetAlertEmail (workflow input) takes precedence over the profile value.
                $effectiveBudgetEmail = if (-not [string]::IsNullOrEmpty($BudgetAlertEmail)) { $BudgetAlertEmail } else { Get-FeatureFlag -Features $govFeatures -Name 'budgetAlertEmail' -Default '' }
                $budgetEmailSet = -not [string]::IsNullOrEmpty($effectiveBudgetEmail)
                $budgetEnabled  = (Get-FeatureFlag -Features $govFeatures -Name 'budget') -eq $true -and $budgetEmailSet
                if ((Get-FeatureFlag -Features $govFeatures -Name 'budget') -eq $true -and -not $budgetEmailSet) {
                    # Before warning, check whether the budget already exists from a prior run.
                    # If it does, treat it as already deployed — no email needed, no warning.
                    $existingBudgetName = "$Prefix-monthly-budget"
                    $budgetCheckUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/${existingBudgetName}?api-version=2023-11-01"
                    $budgetExists = $false
                    $budgetRaw = az rest --method GET --url $budgetCheckUrl 2>$null
                    $budgetCheckEc = $LASTEXITCODE
                    if ($budgetCheckEc -eq 0 -and $budgetRaw) {
                        try {
                            $budgetJson = $budgetRaw | ConvertFrom-Json -ErrorAction SilentlyContinue
                            $budgetExists = $null -ne $budgetJson -and $null -ne $budgetJson.name
                        } catch {}
                    }
                    if ($budgetExists) {
                        Write-AdeLog "Budget '$existingBudgetName' already exists — skipping re-deploy (no email change needed)." -Level Info
                        $budgetEnabled = $false  # Bicep deploy with enableBudget=false is a no-op for an existing budget
                    } else {
                        $isNonInteractiveBudget = [bool]$env:CI -or [bool]$env:GITHUB_ACTIONS
                        if (-not $isNonInteractiveBudget) {
                            Write-Host ""
                            Write-Host "  Budget alert email is not set." -ForegroundColor Yellow
                            $promptedEmail = Read-Host "  Enter an email for budget cost alerts (or press Enter to skip)"
                            if (-not [string]::IsNullOrWhiteSpace($promptedEmail)) {
                                $effectiveBudgetEmail = $promptedEmail.Trim()
                                $budgetEmailSet = $true
                                $budgetEnabled  = $true
                            } else {
                                Write-AdeLog "Budget alert email not provided — skipping budget deployment." -Level Warning
                            }
                        } else {
                            Write-AdeLog "Budget is enabled but 'budgetAlertEmail' is not set — skipping budget deployment. Set governance.features.budgetAlertEmail in your profile or pass -BudgetAlertEmail to activate cost alerts." -Level Warning
                        }
                    }
                }

                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    logAnalyticsId          = $state.logAnalyticsId
                    enableAutomation        = (Get-FeatureFlag -Features $govFeatures -Name 'automationAccount').ToString().ToLower()
                    enableBudget            = $budgetEnabled.ToString().ToLower()
                    budgetAmount            = Get-FeatureFlag -Features $govFeatures -Name 'budgetAmount' -Default 300
                    enableResourceLocks     = (Get-FeatureFlag -Features $govFeatures -Name 'resourceLocks').ToString().ToLower()
                    enablePolicyAssignments = (Get-FeatureFlag -Features $govFeatures -Name 'policyAssignments').ToString().ToLower()
                    computeResourceGroupName = "$Prefix-compute-rg"
                    autoShutdownTime        = Get-FeatureFlag -Features $govFeatures -Name 'autoShutdownTime'     -Default '1900'
                    autoShutdownTimezone    = Get-FeatureFlag -Features $govFeatures -Name 'autoShutdownTimezone' -Default 'UTC'
                    autoStartEnabled        = ((Get-FeatureFlag -Features $govFeatures -Name 'autoStartEnabled') -eq $true).ToString().ToLower()
                }
                if ($budgetEmailSet) { $params['budgetAlertEmail'] = $effectiveBudgetEmail }

                $params['enableAutomationRoleAssignment'] = ($adeCanAssignRoles).ToString().ToLower()
                $outputs = Deploy-AdeModule -ModuleName 'governance' -BicepFile $bicep -Parameters $params
                $state.automationAccountId   = Get-AdeDeploymentOutput $outputs 'automationAccountId'
                $state.automationAccountName = Get-AdeDeploymentOutput $outputs 'automationAccountName'

                # Upload runbook content from local files and publish.
                # This avoids publishContentLink, which requires ARM to synchronously
                # fetch the content from GitHub raw at deploy time — an unreliable
                # network dependency that causes intermittent Bicep failures.
                if ($state.automationAccountName) {
                    $govRg  = "$Prefix-governance-rg"
                    $apiVer = '2023-11-01'
                    foreach ($rbName in @('Stop-AdeResources', 'Start-AdeResources')) {
                        $rbFile = Join-Path $scriptRoot "runbooks\$rbName.ps1"
                        if (Test-Path $rbFile) {
                            Write-AdeLog "Publishing runbook: $rbName" -Level Info
                            $contentUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$govRg/providers/Microsoft.Automation/automationAccounts/$($state.automationAccountName)/runbooks/$rbName/draft/content?api-version=$apiVer"
                            az rest --method PUT --url $contentUri --body "@$rbFile" --headers 'Content-Type=text/powershell' --output none 2>&1 | Out-Null
                            if ($LASTEXITCODE -eq 0) {
                                # Publish via REST to avoid the 'automation' preview extension entirely.
                                $publishUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$govRg/providers/Microsoft.Automation/automationAccounts/$($state.automationAccountName)/runbooks/$rbName/publish?api-version=$apiVer"
                                az rest --method POST --url $publishUri --output none 2>&1 | Out-Null
                                if ($LASTEXITCODE -eq 0) {
                                    Write-AdeLog "Runbook '$rbName' published." -Level Success
                                } else {
                                    Write-AdeLog "Runbook '$rbName' uploaded but publish step failed (non-fatal)." -Level Warning
                                }
                            } else {
                                Write-AdeLog "Could not upload content for '$rbName' — registered as draft (non-fatal)." -Level Warning
                            }
                        }
                    }

                    # Link published runbooks to their schedules.
                    # ARM requires a published runbook to create a jobSchedule — cannot
                    # be done in Bicep where the runbooks have no published version yet.
                    $listUrl    = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$govRg/providers/Microsoft.Automation/automationAccounts/$($state.automationAccountName)/jobSchedules?api-version=$apiVer"
                    $jsListJson = az rest --method GET --url $listUrl | ConvertFrom-Json
                    $existingLinks = @($jsListJson.value | ForEach-Object { $_.properties.runbook.name })

                    $autoShutdownTime = Get-FeatureFlag -Features $govFeatures -Name 'autoShutdownTime' -Default '1900'
                    $autoStartEnabled = (Get-FeatureFlag -Features $govFeatures -Name 'autoStartEnabled') -eq $true
                    $scheduleLinks = @(
                        @{ Schedule = "Daily-Stop-$autoShutdownTime"; Runbook = 'Stop-AdeResources'; Enabled = $true }
                        @{ Schedule = 'Daily-Start-0800';             Runbook = 'Start-AdeResources'; Enabled = $autoStartEnabled }
                    )
                    foreach ($link in ($scheduleLinks | Where-Object { $_.Enabled })) {
                        if ($existingLinks -contains $link.Runbook) {
                            Write-AdeLog "Job schedule already linked: $($link.Runbook) → $($link.Schedule)" -Level Info
                            continue
                        }
                        $seed   = [System.Text.Encoding]::UTF8.GetBytes("$($state.automationAccountName)-$($link.Schedule)")
                        $hash   = [System.Security.Cryptography.MD5]::Create().ComputeHash($seed)
                        $jsGuid = [System.Guid]::new($hash).ToString()
                        $jsUrl  = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$govRg/providers/Microsoft.Automation/automationAccounts/$($state.automationAccountName)/jobSchedules/$($jsGuid)?api-version=$apiVer"
                        $jsBody = @{
                            properties = @{
                                schedule = @{ name = $link.Schedule }
                                runbook  = @{ name = $link.Runbook }
                            }
                        } | ConvertTo-Json -Depth 5 -Compress
                        $jsTmp = [System.IO.Path]::GetTempFileName()
                        try {
                            [System.IO.File]::WriteAllText($jsTmp, $jsBody, [System.Text.UTF8Encoding]::new($false))
                            az rest --method PUT --url $jsUrl --body "@$jsTmp" --headers 'Content-Type=application/json' --output none
                        } finally {
                            Remove-Item -LiteralPath $jsTmp -ErrorAction SilentlyContinue
                        }
                        if ($LASTEXITCODE -eq 0) {
                            Write-AdeLog "Job schedule linked: $($link.Runbook) → $($link.Schedule)" -Level Success
                        } else {
                            Write-AdeLog "Job schedule link failed ($($link.Runbook) → $($link.Schedule)) — non-fatal." -Level Warning
                        }
                    }
                }

            }

        }

        if ($script:_adeModuleHadNewResources) {
            Write-AdeLog "Module '$moduleName' deployed successfully." -Level Success
        } else {
            Write-AdeLog "Module '$moduleName': no changes — all resources already up to date." -Level Info
        }

    } catch {
        Write-AdeLog "Module '$moduleName' FAILED: $_" -Level Error
        $failedModules.Add($moduleName)
        Write-Host ""
        if ($ContinueOnError) {
            Write-AdeLog "Continuing with remaining modules (-ContinueOnError)." -Level Warning
        } else {
            $isNonInteractive = [bool]$env:CI -or [bool]$env:GITHUB_ACTIONS -or $Force
            $continue = if ($isNonInteractive) { 'N' } else { Read-Host "Continue with remaining modules? [y/N]" }
            if ($continue -notmatch '^[Yy]$') {
                Write-AdeLog "Deployment aborted after failure in module '$moduleName'." -Level Warning
                exit 1
            }
        }
    }
}



# ─── Post-deployment summary ──────────────────────────────────────────────────
$elapsed = (Get-Date) - $startTime
Write-AdeSection "Deployment Complete"
Write-Host "  Duration         : " -NoNewline; Write-Host "$([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s" -ForegroundColor Green
Write-Host "  Subscription     : " -NoNewline; Write-Host "$($sub.name) [$SubscriptionId]" -ForegroundColor Cyan
Write-Host "  Profile          : " -NoNewline; Write-Host $deployProfile.profileName -ForegroundColor Cyan
Write-Host "  Mode             : " -NoNewline; Write-Host $Mode -ForegroundColor $(if ($Mode -eq 'hardened') { 'Yellow' } else { 'Cyan' })
Write-Host "  Modules deployed : " -NoNewline; Write-Host ($deploymentOrder -join ', ') -ForegroundColor Green
if ($failedModules.Count -gt 0) {
    Write-Host "  Failed modules   : " -NoNewline
    Write-Host ($failedModules -join ', ') -ForegroundColor Red
    Write-AdeLog "$($failedModules.Count) module(s) failed: $($failedModules -join ', ')" -Level Error
}
Write-Host ""
Write-Host "  Resource Groups:" -ForegroundColor White
foreach ($mod in $deploymentOrder) {
    $rgName = "$Prefix-$($mod.ToLower())-rg"
    Write-Host "    https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$rgName" -ForegroundColor DarkCyan
}
Write-Host ""
Write-AdeLog "Run './scripts/dashboard/Get-AdeCostDashboard.ps1' to view costs and resource status." -Level Info
Write-AdeLog "Run './scripts/destroy.ps1 -Prefix $Prefix' to tear down the entire environment." -Level Warning

# ─── Admin password reminder ──────────────────────────────────────────────────
# Print once more in the summary so it is visible even when the compute banner
# scrolled away. Only shown when -AutoGeneratePassword was used and at least one
# password-bearing module (compute / databases / data) was deployed.
$pwModulesDeployed = $deploymentOrder | Where-Object { $_ -in @('compute', 'databases', 'data') }
if ($script:_adePasswordWasGenerated -and $pwModulesDeployed -and $state.adminPassword) {
    $pwSummary = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║   ADMIN PASSWORD (compute / databases / data)                    ║" -ForegroundColor Yellow
    Write-Host "║   Username : " -ForegroundColor Yellow -NoNewline
    Write-Host $state.adminUsername.PadRight(52) -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Yellow
    Write-Host "║   Password : " -ForegroundColor Yellow -NoNewline
    Write-Host $pwSummary.PadRight(52) -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Yellow
    $seedLine1 = "   .\scripts\seed-data.ps1 -Prefix $Prefix ``"
    $seedLine2 = "     -DatabaseAdminPassword '$pwSummary'"
    Write-Host "║$($seedLine1.PadRight(66))║" -ForegroundColor Yellow
    Write-Host "║$($seedLine2.PadRight(66))║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    $pwSummary = $null
}

if ($failedModules.Count -gt 0) {
    exit 1
}

