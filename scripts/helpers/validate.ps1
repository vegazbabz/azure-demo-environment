#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-flight validation for the Azure Demo Environment.
    Run before any deployment to catch missing dependencies early.
#>

Set-StrictMode -Version Latest

function Test-AdePrerequisites {
    <#
    .SYNOPSIS
        Checks all required tools and Azure auth are in place.
        Returns $true if all checks pass, throws on first failure if -StopOnError.
    #>
    param(
        [string]$Mode = 'default',
        [switch]$StopOnError
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    Write-AdeSection "Pre-flight Checks"

    # ── PowerShell version ────────────────────────────────────────────────────
    Write-AdeLog "PowerShell version: $($PSVersionTable.PSVersion)" -Level Info
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $failures.Add("PowerShell 7+ required. Current: $($PSVersionTable.PSVersion). Install from https://aka.ms/powershell")
    } else {
        Write-AdeLog "PowerShell $($PSVersionTable.PSVersion) ✓" -Level Success
    }

    # ── Azure CLI ─────────────────────────────────────────────────────────────
    $azVerJson = az version --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $azVerJson) {
        $failures.Add("Azure CLI not found. Install from https://aka.ms/installazurecliwindows")
    } else {
        $azVer = ($azVerJson | ConvertFrom-Json).'azure-cli'
        Write-AdeLog "Azure CLI $azVer ✓" -Level Success
    }

    # ── Bicep CLI ─────────────────────────────────────────────────────────────
    $bicepVersion = az bicep version 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-AdeLog "Bicep not installed — attempting install via 'az bicep install'" -Level Warning
        $null = az bicep install 2>$null
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("Bicep CLI could not be installed automatically. Run: az bicep install")
        } else {
            Write-AdeLog "Bicep installed ✓" -Level Success
        }
    } else {
        Write-AdeLog "Bicep $($bicepVersion -replace 'Bicep CLI version ','') ✓" -Level Success
    }

    # ── Azure CLI login ───────────────────────────────────────────────────────
    $accountJson = az account show --output json 2>$null
    $account = if ($accountJson) { $accountJson | ConvertFrom-Json } else { $null }
    if ($LASTEXITCODE -ne 0 -or -not $account) {
        $failures.Add("Not logged in to Azure CLI. Run: az login")
    } else {
        Write-AdeLog "Logged in as: $($account.user.name)" -Level Success
        Write-AdeLog "Subscription: $($account.name) [$($account.id)]" -Level Info
    }

    # ── EncryptionAtHost feature (hardened mode only) ─────────────────────────
    # Required for hardened compute: VMs deployed with EncryptionAtHost = true will
    # fail with an opaque ARM error if the feature is not registered on the subscription.
    if ($Mode -eq 'hardened') {
        Write-AdeLog "Checking EncryptionAtHost feature registration (required for hardened compute)..." -Level Info
        $featureState = az feature show --name EncryptionAtHost --namespace Microsoft.Compute --query properties.state -o tsv 2>$null
        if ($featureState -eq 'Registered') {
            Write-AdeLog "EncryptionAtHost feature Registered ✓" -Level Success
        } else {
            $failures.Add("EncryptionAtHost feature is '$featureState' on this subscription — required for hardened compute (encryption at host). Run: az feature register --name EncryptionAtHost --namespace Microsoft.Compute && az provider register -n Microsoft.Compute  (allow 15-30 min to propagate)")
        }
    }

    # ── Result ────────────────────────────────────────────────────────────────
    if ($failures.Count -gt 0) {
        Write-Host ""
        foreach ($failure in $failures) {
            Write-AdeLog $failure -Level Error
        }
        if ($StopOnError) {
            throw "Pre-flight checks failed. Resolve the issues above and retry."
        }
        return $false
    }

    Write-AdeLog "All pre-flight checks passed." -Level Success
    return $true
}

function Test-AdeSubscription {
    <#
    .SYNOPSIS
        Validates the target subscription exists and the caller has Contributor+.
    #>
    param([Parameter(Mandatory)][string]$SubscriptionId)

    Write-AdeLog "Validating subscription: $SubscriptionId" -Level Info

    $rawJson = az account show --subscription $SubscriptionId --output json 2>$null
    $sub = if ($rawJson) { $rawJson | ConvertFrom-Json } else { $null }
    if ($LASTEXITCODE -ne 0 -or -not $sub) {
        throw "Subscription '$SubscriptionId' not found or not accessible."
    }

    # Check caller has at least Contributor at subscription scope.
    # az ad signed-in-user show only works for interactive users; fall back to
    # SP object ID lookup when running under OIDC (e.g. GitHub Actions).
    $callerId = az ad signed-in-user show --query id -o tsv 2>$null
    if (-not $callerId) {
        $appId    = az account show --query 'user.name' -o tsv 2>$null
        $callerId = az ad sp show --id $appId --query id -o tsv 2>$null
    }
    if ($callerId) { $callerId = $callerId.Trim().Trim('"') }

    if (-not $callerId) {
        Write-AdeLog "Could not resolve caller object ID — skipping Contributor check." -Level Warning
    } else {
        $assignments = az role assignment list `
            --assignee $callerId `
            --subscription $SubscriptionId `
            --include-inherited `
            --query "[?roleDefinitionName == 'Owner' || roleDefinitionName == 'Contributor'].roleDefinitionName" `
            -o tsv 2>$null

        if (-not $assignments) {
            Write-AdeLog "WARNING: Could not confirm Contributor/Owner role on subscription '$SubscriptionId'. Deployment may fail." -Level Warning
        } else {
            Write-AdeLog "Role confirmed: $($assignments -split "`n" | Select-Object -First 1) on $($sub.name)" -Level Success
        }
    }

    return $sub
}

function Test-AdeProfile {
    <#
    .SYNOPSIS
        Validates a loaded profile object for required fields and logical consistency.
    #>
    param([Parameter(Mandatory)][psobject]$Profile)

    Write-AdeLog "Validating profile: $($Profile.profileName)" -Level Info

    # monitoring must be enabled if ANY other module is enabled
    $anyNonMonitoring = $Profile.modules.PSObject.Properties |
        Where-Object { $_.Name -ne 'monitoring' -and $_.Value.enabled -eq $true }

    if ($anyNonMonitoring -and $Profile.modules.monitoring.enabled -ne $true) {
        throw "Profile '$($Profile.profileName)': 'monitoring' must be enabled whenever any other module is enabled (Log Analytics is a shared dependency)."
    }

    # networking must be enabled if compute, databases, containers, appservices, integration, ai, or data are enabled
    $requiresNetworking = @('compute', 'databases', 'containers', 'appservices', 'integration', 'ai', 'data')
    $netProp    = $Profile.modules.PSObject.Properties['networking']
    $netEnabled = $null -ne $netProp -and $netProp.Value.enabled -eq $true
    foreach ($mod in $requiresNetworking) {
        $modProp = $Profile.modules.PSObject.Properties[$mod]
        if ($null -ne $modProp -and $modProp.Value.enabled -eq $true -and -not $netEnabled) {
            throw "Profile '$($Profile.profileName)': '$mod' requires 'networking' to be enabled."
        }
    }

    # security (Key Vault) is recommended for compute and containers
    $requiresSecurity = @('compute', 'containers')
    $secProp    = $Profile.modules.PSObject.Properties['security']
    $secEnabled = $null -ne $secProp -and $secProp.Value.enabled -eq $true
    foreach ($mod in $requiresSecurity) {
        $modProp = $Profile.modules.PSObject.Properties[$mod]
        if ($null -ne $modProp -and $modProp.Value.enabled -eq $true -and -not $secEnabled) {
            Write-AdeLog "Profile '$($Profile.profileName)': '$mod' is enabled without 'security'. Key Vault-backed secrets will be skipped." -Level Warning
        }
    }

    Write-AdeLog "Profile validation passed." -Level Success
}

function Confirm-AdeDeployment {
    <#
    .SYNOPSIS
        Displays a deployment summary and asks for user confirmation (unless -Force).
    #>
    param(
        [Parameter(Mandatory)][psobject]$Profile,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$Mode = 'default',
        [switch]$Force
    )

    $enabledModules = ($Profile.modules.PSObject.Properties |
        Where-Object { $_.Value.enabled -eq $true }).Name

    # Governance features (v2 schema)
    $govFeatProp   = $Profile.modules.PSObject.Properties['governance']
    $govFeatures   = if ($null -ne $govFeatProp -and $null -ne $govFeatProp.Value.PSObject.Properties['features']) { $govFeatProp.Value.features } else { $null }
    $budgetAmount  = Get-FeatureFlag -Features $govFeatures -Name 'budgetAmount' -Default 300
    $autoShutdown  = if ((Get-FeatureFlag -Features $govFeatures -Name 'automationAccount') -eq $true) { '19:00 UTC (weekdays)' } else { 'disabled' }
    $expensiveOn   = @()
    $netModProp    = $Profile.modules.PSObject.Properties['networking']
    $netFeatures   = if ($null -ne $netModProp -and $null -ne $netModProp.Value.PSObject.Properties['features']) { $netModProp.Value.features } else { $null }
    if ($netFeatures) {
        $fwValue = Get-FeatureFlag -Features $netFeatures -Name 'enableFirewall' -Default 'None'
        if ($fwValue -ne 'None') { $expensiveOn += "Firewall ($fwValue)" }
        if ((Get-FeatureFlag -Features $netFeatures -Name 'enableAppGateway') -eq $true) { $expensiveOn += 'AppGateway' }
        if ((Get-FeatureFlag -Features $netFeatures -Name 'enableVpnGateway') -eq $true) { $expensiveOn += 'VpnGateway' }
        if ((Get-FeatureFlag -Features $netFeatures -Name 'enableDdos') -eq $true)       { $expensiveOn += 'DDoS ⚠️' }
    }
    $secModProp  = $Profile.modules.PSObject.Properties['security']
    $secFeatures = if ($null -ne $secModProp -and $null -ne $secModProp.Value.PSObject.Properties['features']) { $secModProp.Value.features } else { $null }
    if ((Get-FeatureFlag -Features $secFeatures -Name 'defenderForCloud') -eq $true) { $expensiveOn += 'Defender' }
    if ((Get-FeatureFlag -Features $secFeatures -Name 'sentinel') -eq $true)         { $expensiveOn += 'Sentinel ⚠️' }
    $intModProp  = $Profile.modules.PSObject.Properties['integration']
    $intFeatures = if ($null -ne $intModProp -and $null -ne $intModProp.Value.PSObject.Properties['features']) { $intModProp.Value.features } else { $null }
    if ((Get-FeatureFlag -Features $intFeatures -Name 'apiManagement') -eq $true)    { $expensiveOn += 'APIM' }

    Write-AdeSection "Deployment Summary"
    Write-Host "  Profile          : " -NoNewline; Write-Host $Profile.profileName -ForegroundColor Cyan
    Write-Host "  Mode             : " -NoNewline; Write-Host $Mode -ForegroundColor $(if ($Mode -eq 'hardened') { 'Yellow' } else { 'Cyan' })
    Write-Host "  Description      : " -NoNewline; Write-Host $Profile.description -ForegroundColor Gray
    Write-Host "  Location         : " -NoNewline; Write-Host $Location -ForegroundColor Cyan
    Write-Host "  Resource prefix  : " -NoNewline; Write-Host $Prefix -ForegroundColor Cyan
    Write-Host "  Subscription     : " -NoNewline; Write-Host $SubscriptionId -ForegroundColor Cyan
    Write-Host "  Modules enabled  : " -NoNewline; Write-Host ($enabledModules -join ', ') -ForegroundColor Green
    Write-Host "  Auto-shutdown    : " -NoNewline; Write-Host $autoShutdown -ForegroundColor Yellow
    Write-Host "  Budget alert     : " -NoNewline; Write-Host "`$$budgetAmount/month" -ForegroundColor Yellow
    if ($expensiveOn.Count -gt 0) {
        Write-Host "  Costly resources : " -NoNewline; Write-Host ($expensiveOn -join ', ') -ForegroundColor Red
    }
    Write-Host ""

    if (-not $Force) {
        $confirm = Read-Host "Proceed with deployment? [y/N]"
        if ($confirm -notmatch '^[Yy]$') {
            throw "Deployment cancelled by user."
        }
    }
}

function Test-AdePermissions {
    <#
    .SYNOPSIS
        Checks the caller has 'User Access Administrator' (or 'Owner') at subscription scope.
        Required when the Automation Account managed-identity role assignment will be deployed.
        Throws when -StopOnError is set and the permission is missing.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [switch]$StopOnError
    )

    Write-AdeLog "Checking role-assignment permissions on subscription '$SubscriptionId'" -Level Info

    # Resolve caller object ID — works for interactive users and OIDC service principals.
    $callerId = az ad signed-in-user show --query id -o tsv 2>$null
    if (-not $callerId) {
        $appId    = az account show --query 'user.name' -o tsv 2>$null
        $callerId = az ad sp show --id $appId --query id -o tsv 2>$null
    }
    if ($callerId) { $callerId = $callerId.Trim().Trim('"') }

    if (-not $callerId) {
        Write-AdeLog "Could not resolve caller object ID — skipping UAA check." -Level Warning
        return $false
    }

    $assignments = az role assignment list `
        --assignee $callerId `
        --subscription $SubscriptionId `
        --include-inherited `
        --query "[?roleDefinitionName == 'Owner' || roleDefinitionName == 'User Access Administrator'].roleDefinitionName" `
        -o tsv 2>$null

    if (-not $assignments) {
        $grantCmd = "az role assignment create --assignee $callerId --role 'User Access Administrator' --scope /subscriptions/$SubscriptionId"
        $message  = "Caller '$callerId' lacks 'Owner' or 'User Access Administrator' at subscription '$SubscriptionId'. " +
                    "This role is required to create the Automation Account managed-identity role assignment. " +
                    "Grant it with: $grantCmd"
        if ($StopOnError) { throw $message }
        Write-AdeLog $message -Level Error
        return $false
    }

    $grantedRole = ($assignments -split "`n")[0].Trim()
    Write-AdeLog "Permission confirmed: '$grantedRole' on '$SubscriptionId' ✓" -Level Success
    return $true
}

Write-AdeLog "validate.ps1 loaded" -Level Debug
