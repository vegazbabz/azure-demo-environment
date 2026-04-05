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
      databases-only   SQL, Cosmos, PostgreSQL, MySQL, Redis
      networking-only  VNet, NSGs, AppGW, Bastion
      security-focus   Key Vault, Defender, Sentinel (CIS Security sections)
    Or pass an absolute/relative path to a custom JSON profile.

.PARAMETER Location
    Azure region. Default: westeurope
    List regions: az account list-locations --query "[].name" -o tsv

.PARAMETER Prefix
    Short prefix for resource names (3-6 lowercase alphanum). Default: ade
    Example: 'myco' -> resource groups like 'myco-networking-rg', 'myco-compute-rg'

.PARAMETER SubscriptionId
    Target subscription ID. If omitted, uses the current az account.

.PARAMETER AdminUsername
    Admin username for VMs. Default: adeadmin

.PARAMETER AdminPassword
    Admin password for VMs (SecureString). Must meet Azure complexity requirements.
    If omitted, you will be prompted interactively.

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
    Reference: https://github.com/your-org/azure-demo-environment
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
    [switch]$Force,

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

# Safe feature flag accessor — works under Set-StrictMode -Version Latest.
# Returns $Default when the property doesn't exist on the object (avoids PropertyNotFoundException).
function Get-FeatureFlag {
    param(
        [object]$Features,
        [string]$Name,
        $Default = $false
    )
    if ($null -eq $Features) { return $Default }
    $prop = $Features.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

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

# ─── Pre-flight ───────────────────────────────────────────────────────────────
$null = Test-AdePrerequisites -StopOnError

# ─── Subscription ─────────────────────────────────────────────────────────────
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --output none
    if ($LASTEXITCODE -ne 0) { throw "Could not set subscription: $SubscriptionId" }
}
$currentSub = az account show --output json | ConvertFrom-Json
$SubscriptionId = $currentSub.id

$sub = Test-AdeSubscription -SubscriptionId $SubscriptionId

# ─── Profile ──────────────────────────────────────────────────────────────────
$deployProfile = Get-AdeProfile -ProfileNameOrPath $Profile

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
        $deployProfile.modules.$mod.enabled = $true
        Write-AdeLog "Module '$mod' ENABLED via -EnableModules" -Level Info
    } else {
        Write-AdeLog "Unknown module '$mod' in -EnableModules (ignored)" -Level Warning
    }
}

Test-AdeProfile -Profile $deployProfile

# ─── Permission preflight ────────────────────────────────────────────────────
# Check UAA/Owner up front when the Automation Account role assignment will run.
# Fails early so the caller gets a clear error before any resources are created.
$adeCanAssignRoles = $false
$govModPre         = $deployProfile.modules.PSObject.Properties['governance']
$govFeatPre        = if ($null -ne $govModPre -and $null -ne $govModPre.Value.PSObject.Properties['features']) { $govModPre.Value.features } else { $null }
$automationWanted  = $null -ne $govModPre -and
                   $govModPre.Value.enabled -eq $true -and
                   (Get-FeatureFlag $govFeatPre 'automationAccount') -eq $true
if ($automationWanted) {
    $null = Test-AdePermissions -SubscriptionId $SubscriptionId -StopOnError
    $adeCanAssignRoles = $true
}

# ─── Admin password ───────────────────────────────────────────────────────────
if (-not $AdminPassword) {
    $AdminPassword = Read-Host -AsSecureString "Enter VM admin password (min 12 chars, upper+lower+digit+symbol)"
}
$adminPasswordPlain = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
if ($adminPasswordPlain.Length -lt 12) {
    throw "Admin password must be at least 12 characters."
}
$adminPasswordPlain = $null   # discard plaintext immediately after validation

# ─── Confirmation ─────────────────────────────────────────────────────────────
Confirm-AdeDeployment -Profile $deployProfile -Location $Location `
    -Prefix $Prefix -SubscriptionId $SubscriptionId -Mode $Mode -Force:$Force

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
    New-AdeResourceGroup -Name $rgName -Location $Location -Tags $moduleTags

    # Inject module-specific tags into every deployment so all resources carry the module tag
    if (-not $Parameters.ContainsKey('tags')) {
        $Parameters['tags'] = $moduleTags
    }

    Write-AdeLog "Deploying module: $ModuleName -> $rgName" -Level Step

    $outputs = Invoke-AdeBicepDeployment `
        -ResourceGroup  $rgName `
        -TemplatePath   $BicepFile `
        -DeploymentName "ade-$ModuleName-$(Get-Date -Format 'yyyyMMddHHmmss')" `
        -Parameters     $Parameters `
        -WhatIf:$WhatIf

    return $outputs
}

foreach ($moduleName in $deploymentOrder) {
    $currentModule++
    $pct = [int](($currentModule / $totalModules) * 100)
    Write-Progress -Activity "ADE Deployment" -Status "[$currentModule/$totalModules] $moduleName" -PercentComplete $pct

    Write-AdeSection "$moduleName Module [$currentModule/$totalModules]"

    try {

        switch ($moduleName) {

            # ── MONITORING ──────────────────────────────────────────────────
            'monitoring' {
                $bicep = Join-Path $bicepRoot 'monitoring\monitoring.bicep'
                $monFeatures = if ($null -ne $deployProfile.modules.monitoring.features) { $deployProfile.modules.monitoring.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix   = $Prefix
                    location = $Location
                }
                $monAlertEmail = Get-FeatureFlag $monFeatures 'alertEmail' ''
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
                $netFeatures = if ($null -ne $deployProfile.modules.networking.features) { $deployProfile.modules.networking.features } else { [pscustomobject]@{} }
                # Guard: compute may be disabled (no features key) on profiles like databases-only, networking-only.
                # Accessing compute.features directly throws with Set-StrictMode when the key is absent.
                $computeModProp   = $deployProfile.modules.PSObject.Properties['compute']
                $computeFeatures  = if ($null -ne $computeModProp -and
                                        $null -ne $computeModProp.Value.PSObject.Properties['features']) {
                                        $deployProfile.modules.compute.features
                                    } else {
                                        [pscustomobject]@{}
                                    }
                $params = @{
                    prefix                 = $Prefix
                    location               = $Location
                    bastionSku             = Get-FeatureFlag $netFeatures 'bastionSku' 'Developer'
                    enableAppGateway       = (Get-FeatureFlag $netFeatures 'enableAppGateway').ToString().ToLower()
                    enableFirewall         = Get-FeatureFlag $netFeatures 'enableFirewall' 'None'
                    enableVpnGateway       = (Get-FeatureFlag $netFeatures 'enableVpnGateway').ToString().ToLower()
                    enableNatGateway       = (Get-FeatureFlag $netFeatures 'enableNatGateway').ToString().ToLower()
                    enableDdos             = (Get-FeatureFlag $netFeatures 'enableDdos').ToString().ToLower()
                    enablePrivateDnsZones  = (Get-FeatureFlag $netFeatures 'enablePrivateDnsZones').ToString().ToLower()
                    deployDomainController = (Get-FeatureFlag $computeFeatures 'domainController').ToString().ToLower()
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
                    prefix            = $Prefix
                    location          = $Location
                    logAnalyticsId    = $state.logAnalyticsId
                    enableDefender    = (Get-FeatureFlag $secFeatures 'defenderForCloud').ToString().ToLower()
                    enableSentinel    = (Get-FeatureFlag $secFeatures 'sentinel').ToString().ToLower()
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
                    $kvCidrs = Get-FeatureFlag $secFeatures 'allowedCidrRanges' $null
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
                $compFeatures = if ($null -ne $deployProfile.modules.compute.features) { $deployProfile.modules.compute.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    subnetId            = $state.computeSubnetId
                    adminUsername       = $state.adminUsername
                    adminPassword       = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    deployWindowsVm     = (Get-FeatureFlag $compFeatures 'windowsVm').ToString().ToLower()
                    deployLinuxVm       = (Get-FeatureFlag $compFeatures 'linuxVm').ToString().ToLower()
                    deployVmss          = (Get-FeatureFlag $compFeatures 'vmss').ToString().ToLower()
                    enableAutoShutdown  = (Get-FeatureFlag $compFeatures 'enableAutoShutdown').ToString().ToLower()
                    vmSize              = Get-FeatureFlag $compFeatures 'vmSku' 'Standard_B2s'
                    deployDomainController = (Get-FeatureFlag $compFeatures 'domainController').ToString().ToLower()
                    dcSubnetId          = if ($state.dcSubnetId) { $state.dcSubnetId } else { '' }
                    domainName          = Get-FeatureFlag $compFeatures 'domainName' "${Prefix}.local"
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId']       = $state.logAnalyticsId
                    $params['dataCollectionRuleId'] = $state.dataCollectionRuleId
                }
                $null = Deploy-AdeModule -ModuleName 'compute' -BicepFile $bicep -Parameters $params
            }

            # ── STORAGE ─────────────────────────────────────────────────────
            'storage' {
                $bicep = Join-Path $bicepRoot 'storage\storage.bicep'
                $stFeatures = if ($null -ne $deployProfile.modules.storage.PSObject.Properties['features']) { $deployProfile.modules.storage.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix            = $Prefix
                    location          = $Location
                    enableDataLake    = (Get-FeatureFlag $stFeatures 'dataLakeGen2').ToString().ToLower()
                    enableSoftDelete  = (Get-FeatureFlag $stFeatures 'enableSoftDelete').ToString().ToLower()
                    privateEndpointSubnetId = $state.privateEndpointSubnetId
                    blobDnsZoneId           = $state.blobDnsZoneId
                    fileDnsZoneId           = $state.fileDnsZoneId
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                    # allowedCidrRanges: public IPs (CIDR) permitted through Storage network ACLs
                    $stCidrs = Get-FeatureFlag $stFeatures 'allowedCidrRanges' $null
                    if ($stCidrs -and $stCidrs.Count -gt 0) { $params['allowedCidrRanges'] = $stCidrs }
                }
                $outputs = Deploy-AdeModule -ModuleName 'storage' -BicepFile $bicep -Parameters $params
                $state.storageAccountName = Get-AdeDeploymentOutput $outputs 'storageAccountName'
            }

            # ── DATABASES ───────────────────────────────────────────────────
            'databases' {
                $bicep = Join-Path $bicepRoot 'databases\databases.bicep'
                $dbFeatures = if ($null -ne $deployProfile.modules.databases.features) { $deployProfile.modules.databases.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix            = $Prefix
                    location          = $Location
                    subnetId          = $state.databaseSubnetId
                    sqlAdminLogin     = $state.adminUsername
                    sqlAdminPassword  = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    pgAdminLogin      = $state.adminUsername
                    pgAdminPassword   = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    deploySql         = (Get-FeatureFlag $dbFeatures 'sqlDatabase').ToString().ToLower()
                    deployCosmos      = (Get-FeatureFlag $dbFeatures 'cosmosDb').ToString().ToLower()
                    deployPostgresql  = (Get-FeatureFlag $dbFeatures 'postgresql').ToString().ToLower()
                    postgresDnsZoneId = $state.postgresDnsZoneId
                    deployMysql       = (Get-FeatureFlag $dbFeatures 'mysql').ToString().ToLower()
                    mysqlSubnetId     = $state.mysqlSubnetId
                    mysqlDnsZoneId    = $state.mysqlDnsZoneId
                    deployRedis       = (Get-FeatureFlag $dbFeatures 'redis').ToString().ToLower()
                    privateEndpointSubnetId = $state.privateEndpointSubnetId
                    sqlDnsZoneId      = $state.sqlDnsZoneId
                    cosmosDnsZoneId   = $state.cosmosDnsZoneId
                    redisDnsZoneId    = $state.redisDnsZoneId
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                }
                $null = Deploy-AdeModule -ModuleName 'databases' -BicepFile $bicep -Parameters $params
            }

            # ── APP SERVICES ────────────────────────────────────────────────
            'appservices' {
                $bicep = Join-Path $bicepRoot 'appservices\appservices.bicep'
                $appFeatures = if ($null -ne $deployProfile.modules.appservices.features) { $deployProfile.modules.appservices.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix                = $Prefix
                    location              = $Location
                    appServiceSubnetId    = $state.appServicesSubnetId
                    deployWindowsApp      = (Get-FeatureFlag $appFeatures 'windowsWebApp').ToString().ToLower()
                    deployLinuxApp        = (Get-FeatureFlag $appFeatures 'linuxWebApp').ToString().ToLower()
                    deployFunctionApp     = (Get-FeatureFlag $appFeatures 'functionApp').ToString().ToLower()
                    deployStaticWebApp    = (Get-FeatureFlag $appFeatures 'staticWebApp').ToString().ToLower()
                    deployLogicApp        = (Get-FeatureFlag $appFeatures 'logicApp').ToString().ToLower()
                }
                $null = Deploy-AdeModule -ModuleName 'appservices' -BicepFile $bicep -Parameters $params
            }

            # ── CONTAINERS ──────────────────────────────────────────────────
            'containers' {
                $bicep = Join-Path $bicepRoot 'containers\containers.bicep'
                $ctFeatures = if ($null -ne $deployProfile.modules.containers.features) { $deployProfile.modules.containers.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    subnetId                = $state.containerSubnetId
                    deployAcr               = (Get-FeatureFlag $ctFeatures 'containerRegistry').ToString().ToLower()
                    deployAks               = (Get-FeatureFlag $ctFeatures 'kubernetesService').ToString().ToLower()
                    deployContainerApps     = (Get-FeatureFlag $ctFeatures 'containerApps').ToString().ToLower()
                    deployContainerInstances = (Get-FeatureFlag $ctFeatures 'containerInstances').ToString().ToLower()
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                    $aksIpRanges = Get-FeatureFlag $ctFeatures 'aksAuthorizedIpRanges' $null
                    if ($null -ne $aksIpRanges) { $params['aksAuthorizedIpRanges'] = $aksIpRanges }
                }
                $null = Deploy-AdeModule -ModuleName 'containers' -BicepFile $bicep -Parameters $params
            }

            # ── INTEGRATION ─────────────────────────────────────────────────
            'integration' {
                $bicep = Join-Path $bicepRoot 'integration\integration.bicep'
                $intFeatures = if ($null -ne $deployProfile.modules.integration.features) { $deployProfile.modules.integration.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    deployServiceBus    = (Get-FeatureFlag $intFeatures 'serviceBus').ToString().ToLower()
                    deployEventHub      = (Get-FeatureFlag $intFeatures 'eventHub').ToString().ToLower()
                    deployEventGrid     = (Get-FeatureFlag $intFeatures 'eventGrid').ToString().ToLower()
                    deploySignalR       = (Get-FeatureFlag $intFeatures 'signalR').ToString().ToLower()
                    deployApim          = (Get-FeatureFlag $intFeatures 'apiManagement').ToString().ToLower()
                    apimSku             = Get-FeatureFlag $intFeatures 'apimSku' 'Developer'
                    apimPublisherEmail  = Get-FeatureFlag $intFeatures 'apimPublisherEmail' 'admin@example.com'
                    apimPublisherName   = Get-FeatureFlag $intFeatures 'apimPublisherName' 'ADE Demo'
                    privateEndpointSubnetId = $state.privateEndpointSubnetId
                    serviceBusDnsZoneId     = $state.serviceBusDnsZoneId
                    eventHubDnsZoneId       = $state.eventHubDnsZoneId
                }
                $outputs = Deploy-AdeModule -ModuleName 'integration' -BicepFile $bicep -Parameters $params
                $state.serviceBusId   = Get-AdeDeploymentOutput $outputs 'serviceBusId'
                $state.eventHubId     = Get-AdeDeploymentOutput $outputs 'eventHubNamespaceId'
            }

            # ── AI ──────────────────────────────────────────────────────────
            'ai' {
                $bicep = Join-Path $bicepRoot 'ai\ai.bicep'
                $aiFeatures = $deployProfile.modules.ai.features
                # Guard: profile may have ai.enabled=true but no features object
                if ($null -eq $aiFeatures) { $aiFeatures = [pscustomobject]@{} }
                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    deployAiServices        = (Get-FeatureFlag $aiFeatures 'aiServices').ToString().ToLower()
                    deployOpenAi            = (Get-FeatureFlag $aiFeatures 'openAi').ToString().ToLower()
                    deployCognitiveSearch   = (Get-FeatureFlag $aiFeatures 'cognitiveSearch').ToString().ToLower()
                    deployMachineLearning   = (Get-FeatureFlag $aiFeatures 'machineLearning').ToString().ToLower()
                }
                $null = Deploy-AdeModule -ModuleName 'ai' -BicepFile $bicep -Parameters $params
            }

            # ── DATA ────────────────────────────────────────────────────────
            'data' {
                $bicep = Join-Path $bicepRoot 'data\data.bicep'
                $dataFeatures = if ($null -ne $deployProfile.modules.data.features) { $deployProfile.modules.data.features } else { [pscustomobject]@{} }
                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    deployDataFactory   = (Get-FeatureFlag $dataFeatures 'dataFactory').ToString().ToLower()
                    deploySynapse       = (Get-FeatureFlag $dataFeatures 'synapse').ToString().ToLower()
                    deployDatabricks    = (Get-FeatureFlag $dataFeatures 'databricks').ToString().ToLower()
                    deployPurview       = (Get-FeatureFlag $dataFeatures 'purview').ToString().ToLower()
                    storageAccountName  = if ($state.storageAccountName) { $state.storageAccountName } else { '' }
                }
                if ($Mode -eq 'hardened') {
                    $params['synapseAdminPassword'] = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                }
                $outputs = Deploy-AdeModule -ModuleName 'data' -BicepFile $bicep -Parameters $params
                $state.dataFactoryId = Get-AdeDeploymentOutput $outputs 'dataFactoryId'
            }

            # ── GOVERNANCE ──────────────────────────────────────────────────
            'governance' {
                $bicep = Join-Path $bicepRoot 'governance\governance.bicep'
                $govFeatures = if ($null -ne $deployProfile.modules.governance.features) { $deployProfile.modules.governance.features } else { [pscustomobject]@{} }

                # Budget requires a notification email — silently downgrade to disabled if not set.
                # -BudgetAlertEmail (workflow input) takes precedence over the profile value.
                $effectiveBudgetEmail = if (-not [string]::IsNullOrEmpty($BudgetAlertEmail)) { $BudgetAlertEmail } else { Get-FeatureFlag $govFeatures 'budgetAlertEmail' '' }
                $budgetEmailSet = -not [string]::IsNullOrEmpty($effectiveBudgetEmail)
                $budgetEnabled  = (Get-FeatureFlag $govFeatures 'budget') -eq $true -and $budgetEmailSet
                if ((Get-FeatureFlag $govFeatures 'budget') -eq $true -and -not $budgetEmailSet) {
                    Write-AdeLog "Budget is enabled but 'budgetAlertEmail' is not set — skipping budget deployment. Set governance.features.budgetAlertEmail in your profile to activate cost alerts." -Level Warning
                }

                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    logAnalyticsId          = $state.logAnalyticsId
                    enableAutomation        = (Get-FeatureFlag $govFeatures 'automationAccount').ToString().ToLower()
                    enableBudget            = $budgetEnabled.ToString().ToLower()
                    budgetAmount            = Get-FeatureFlag $govFeatures 'budgetAmount' 300
                    enableResourceLocks     = (Get-FeatureFlag $govFeatures 'resourceLocks').ToString().ToLower()
                    enablePolicyAssignments = (Get-FeatureFlag $govFeatures 'policyAssignments').ToString().ToLower()
                    computeResourceGroupName = "$Prefix-compute-rg"
                    runbooksBaseUrl         = 'https://raw.githubusercontent.com/vegazbabz/azure-demo-environment/main'
                }
                if ($budgetEmailSet) { $params['budgetAlertEmail'] = $effectiveBudgetEmail }

                $params['enableAutomationRoleAssignment'] = ($adeCanAssignRoles).ToString().ToLower()
                $outputs = Deploy-AdeModule -ModuleName 'governance' -BicepFile $bicep -Parameters $params
                $state.automationAccountId   = Get-AdeDeploymentOutput $outputs 'automationAccountId'
                $state.automationAccountName = Get-AdeDeploymentOutput $outputs 'automationAccountName'
            }

        }

        Write-AdeLog "Module '$moduleName' deployed successfully." -Level Success

    } catch {
        Write-AdeLog "Module '$moduleName' FAILED: $_" -Level Error
        Write-Host ""
        $isNonInteractive = [bool]$env:CI -or [bool]$env:GITHUB_ACTIONS -or $Force
        $continue = if ($isNonInteractive) { 'N' } else { Read-Host "Continue with remaining modules? [y/N]" }
        if ($continue -notmatch '^[Yy]$') {
            throw "Deployment aborted after failure in module '$moduleName'."
        }
    }
}

Write-Progress -Activity "ADE Deployment" -Completed

# ─── Post-deployment summary ──────────────────────────────────────────────────
$elapsed = (Get-Date) - $startTime
Write-AdeSection "Deployment Complete"
Write-Host "  Duration         : " -NoNewline; Write-Host "$([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s" -ForegroundColor Green
Write-Host "  Subscription     : " -NoNewline; Write-Host "$($sub.name) [$SubscriptionId]" -ForegroundColor Cyan
Write-Host "  Profile          : " -NoNewline; Write-Host $deployProfile.profileName -ForegroundColor Cyan
Write-Host "  Mode             : " -NoNewline; Write-Host $Mode -ForegroundColor $(if ($Mode -eq 'hardened') { 'Yellow' } else { 'Cyan' })
Write-Host "  Modules deployed : " -NoNewline; Write-Host ($deploymentOrder -join ', ') -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Groups:" -ForegroundColor White
foreach ($mod in $deploymentOrder) {
    $rgName = "$Prefix-$($mod.ToLower())-rg"
    Write-Host "    https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$rgName" -ForegroundColor DarkCyan
}
Write-Host ""
Write-AdeLog "Run './scripts/dashboard/Get-AdeCostDashboard.ps1' to view costs and resource status." -Level Info
Write-AdeLog "Run './scripts/destroy.ps1 -Prefix $Prefix' to tear down the entire environment." -Level Warning
