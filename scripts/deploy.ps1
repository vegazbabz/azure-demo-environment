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
    [string]$LogFile = ''
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

# ─── Pre-flight ───────────────────────────────────────────────────────────────
Test-AdePrerequisites -StopOnError

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
    appGatewayPublicIpId    = ''
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
                $params = @{
                    prefix   = $Prefix
                    location = $Location
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
                $netFeatures = $deployProfile.modules.networking.features
                $params = @{
                    prefix                 = $Prefix
                    location               = $Location
                    bastionSku             = if ($null -ne $netFeatures.bastionSku) { $netFeatures.bastionSku } else { 'Developer' }
                    enableAppGateway       = ($netFeatures.enableAppGateway -eq $true).ToString().ToLower()
                    enableFirewall         = if ($null -ne $netFeatures.enableFirewall) { $netFeatures.enableFirewall } else { 'None' }
                    enableVpnGateway       = ($netFeatures.enableVpnGateway -eq $true).ToString().ToLower()
                    enableNatGateway       = ($netFeatures.enableNatGateway -eq $true).ToString().ToLower()
                    enableDdos             = ($netFeatures.enableDdos -eq $true).ToString().ToLower()
                    enablePrivateDnsZones  = ($netFeatures.enablePrivateDnsZones -eq $true).ToString().ToLower()
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
                $state.appGatewayPublicIpId    = Get-AdeDeploymentOutput $outputs 'appGatewayPublicIp'
            }

            # ── SECURITY ────────────────────────────────────────────────────
            'security' {
                $bicep = Join-Path $bicepRoot 'security\security.bicep'
                # Resolve deployer object ID so KV Secrets Officer role can be granted for seed-data.ps1
                $deployerOid = az ad signed-in-user show --query id -o tsv 2>$null
                if (-not $deployerOid) {
                    $callerAppId = az account show --query 'user.name' -o tsv 2>$null
                    $deployerOid = az ad sp show --id $callerAppId --query id -o tsv 2>$null
                }
                $params = @{
                    prefix            = $Prefix
                    location          = $Location
                    logAnalyticsId    = $state.logAnalyticsId
                    enableDefender    = ($deployProfile.modules.security.features.defenderForCloud -eq $true).ToString().ToLower()
                    enableSentinel    = ($deployProfile.modules.security.features.sentinel -eq $true).ToString().ToLower()
                }
                if ($deployerOid) { $params['deployerPrincipalId'] = $deployerOid }
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
                $compFeatures = $deployProfile.modules.compute.features
                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    subnetId            = $state.computeSubnetId
                    adminUsername       = $state.adminUsername
                    adminPassword       = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    deployWindowsVm     = ($compFeatures.windowsVm -eq $true).ToString().ToLower()
                    deployLinuxVm       = ($compFeatures.linuxVm -eq $true).ToString().ToLower()
                    deployVmss          = ($compFeatures.vmss -eq $true).ToString().ToLower()
                    enableAutoShutdown  = ($compFeatures.enableAutoShutdown -eq $true).ToString().ToLower()
                    vmSize              = if ($null -ne $compFeatures.vmSku) { $compFeatures.vmSku } else { 'Standard_B2s' }
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
                $params = @{
                    prefix          = $Prefix
                    location        = $Location
                    enableDataLake  = ($deployProfile.modules.storage.features.dataLakeGen2 -eq $true).ToString().ToLower()
                    enableSoftDelete = ($deployProfile.modules.storage.features.enableSoftDelete -eq $true).ToString().ToLower()
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                }
                $null = Deploy-AdeModule -ModuleName 'storage' -BicepFile $bicep -Parameters $params
            }

            # ── DATABASES ───────────────────────────────────────────────────
            'databases' {
                $bicep = Join-Path $bicepRoot 'databases\databases.bicep'
                $dbFeatures = $deployProfile.modules.databases.features
                $params = @{
                    prefix            = $Prefix
                    location          = $Location
                    subnetId          = $state.databaseSubnetId
                    sqlAdminLogin     = $state.adminUsername
                    sqlAdminPassword  = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    pgAdminLogin      = $state.adminUsername
                    pgAdminPassword   = [System.Net.NetworkCredential]::new('', $state.adminPassword).Password
                    deploySql         = ($dbFeatures.sqlDatabase -eq $true).ToString().ToLower()
                    deploySqlVm       = ($dbFeatures.sqlVm -eq $true).ToString().ToLower()
                    sqlVmSubnetId     = if ($state.computeSubnetId) { $state.computeSubnetId } else { '' }
                    deployCosmos      = ($dbFeatures.cosmosDb -eq $true).ToString().ToLower()
                    deployPostgresql  = ($dbFeatures.postgresql -eq $true).ToString().ToLower()
                    postgresDnsZoneId = $state.postgresDnsZoneId
                    deployMysql       = ($dbFeatures.mysql -eq $true).ToString().ToLower()
                    mysqlSubnetId     = $state.mysqlSubnetId
                    mysqlDnsZoneId    = $state.mysqlDnsZoneId
                    deployRedis       = ($dbFeatures.redis -eq $true).ToString().ToLower()
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                }
                $null = Deploy-AdeModule -ModuleName 'databases' -BicepFile $bicep -Parameters $params
            }

            # ── APP SERVICES ────────────────────────────────────────────────
            'appservices' {
                $bicep = Join-Path $bicepRoot 'appservices\appservices.bicep'
                $appFeatures = $deployProfile.modules.appservices.features
                $params = @{
                    prefix                = $Prefix
                    location              = $Location
                    appServiceSubnetId    = $state.appServicesSubnetId
                    deployWindowsApp      = ($appFeatures.windowsWebApp -eq $true).ToString().ToLower()
                    deployLinuxApp        = ($appFeatures.linuxWebApp -eq $true).ToString().ToLower()
                    deployFunctionApp     = ($appFeatures.functionApp -eq $true).ToString().ToLower()
                    deployStaticWebApp    = ($appFeatures.staticWebApp -eq $true).ToString().ToLower()
                    deployLogicApp        = ($appFeatures.logicApp -eq $true).ToString().ToLower()
                }
                $null = Deploy-AdeModule -ModuleName 'appservices' -BicepFile $bicep -Parameters $params
            }

            # ── CONTAINERS ──────────────────────────────────────────────────
            'containers' {
                $bicep = Join-Path $bicepRoot 'containers\containers.bicep'
                $ctFeatures = $deployProfile.modules.containers.features
                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    subnetId                = $state.containerSubnetId
                    deployAcr               = ($ctFeatures.containerRegistry -eq $true).ToString().ToLower()
                    deployAks               = ($ctFeatures.kubernetesService -eq $true).ToString().ToLower()
                    deployContainerApps     = ($ctFeatures.containerApps -eq $true).ToString().ToLower()
                    deployContainerInstances = ($ctFeatures.containerInstances -eq $true).ToString().ToLower()
                }
                if ($Mode -eq 'hardened') {
                    $params['logAnalyticsId'] = $state.logAnalyticsId
                }
                $null = Deploy-AdeModule -ModuleName 'containers' -BicepFile $bicep -Parameters $params
            }

            # ── INTEGRATION ─────────────────────────────────────────────────
            'integration' {
                $bicep = Join-Path $bicepRoot 'integration\integration.bicep'
                $intFeatures = $deployProfile.modules.integration.features
                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    subnetId            = $state.integrationSubnetId
                    deployServiceBus    = ($intFeatures.serviceBus -eq $true).ToString().ToLower()
                    deployEventHub      = ($intFeatures.eventHub -eq $true).ToString().ToLower()
                    deployEventGrid     = ($intFeatures.eventGrid -eq $true).ToString().ToLower()
                    deploySignalR       = ($intFeatures.signalR -eq $true).ToString().ToLower()
                    deployApim          = ($intFeatures.apiManagement -eq $true).ToString().ToLower()
                    apimSku             = if ($null -ne $intFeatures.apimSku) { $intFeatures.apimSku } else { 'Developer' }
                }
                $outputs = Deploy-AdeModule -ModuleName 'integration' -BicepFile $bicep -Parameters $params
                $state.serviceBusId   = Get-AdeDeploymentOutput $outputs 'serviceBusId'
                $state.eventHubId     = Get-AdeDeploymentOutput $outputs 'eventHubNamespaceId'
            }

            # ── AI ──────────────────────────────────────────────────────────
            'ai' {
                $bicep = Join-Path $bicepRoot 'ai\ai.bicep'
                $aiFeatures = $deployProfile.modules.ai.features
                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    subnetId                = $state.aiSubnetId
                    deployAiServices        = ($aiFeatures.aiServices -eq $true).ToString().ToLower()
                    deployOpenAi            = ($aiFeatures.openAi -eq $true).ToString().ToLower()
                    deployCognitiveSearch   = ($aiFeatures.cognitiveSearch -eq $true).ToString().ToLower()
                    deployMachineLearning   = ($aiFeatures.machineLearning -eq $true).ToString().ToLower()
                }
                $null = Deploy-AdeModule -ModuleName 'ai' -BicepFile $bicep -Parameters $params
            }

            # ── DATA ────────────────────────────────────────────────────────
            'data' {
                $bicep = Join-Path $bicepRoot 'data\data.bicep'
                $dataFeatures = $deployProfile.modules.data.features
                $params = @{
                    prefix              = $Prefix
                    location            = $Location
                    subnetId            = $state.dataSubnetId
                    deployDataFactory   = ($dataFeatures.dataFactory -eq $true).ToString().ToLower()
                    deploySynapse       = ($dataFeatures.synapse -eq $true).ToString().ToLower()
                    deployDatabricks    = ($dataFeatures.databricks -eq $true).ToString().ToLower()
                    deployPurview       = ($dataFeatures.purview -eq $true).ToString().ToLower()
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
                $govFeatures = $deployProfile.modules.governance.features
                $params = @{
                    prefix                  = $Prefix
                    location                = $Location
                    logAnalyticsId          = $state.logAnalyticsId
                    enableAutomation        = ($govFeatures.automationAccount -eq $true).ToString().ToLower()
                    enableBudget            = ($govFeatures.budget -eq $true).ToString().ToLower()
                    budgetAmount            = if ($null -ne $govFeatures.budgetAmount) { $govFeatures.budgetAmount } else { 300 }
                    enableResourceLocks     = ($govFeatures.resourceLocks -eq $true).ToString().ToLower()
                    enablePolicyAssignments = ($govFeatures.policyAssignments -eq $true).ToString().ToLower()
                }
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
