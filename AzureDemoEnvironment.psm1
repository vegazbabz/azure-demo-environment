# ─────────────────────────────────────────────────────────────────────────────
# AzureDemoEnvironment — PowerShell Gallery module surface
#
# The module exports thin wrapper functions over the repository's entry-point
# scripts. All orchestration logic, parameter defaults, and validation live in
# the scripts themselves — the wrappers mirror parameter names/types (without
# defaults) and forward only the explicitly bound arguments, so script defaults
# apply exactly as they do when the scripts are run directly from a clone.
#
#   Deploy-AdeEnvironment   → scripts/deploy.ps1
#   Remove-AdeEnvironment   → scripts/destroy.ps1
#   Initialize-AdeSeedData  → scripts/seed-data.ps1
#   Get-AdeCostDashboard    → scripts/dashboard/Get-AdeCostDashboard.ps1
#
# tests/module.Tests.ps1 enforces wrapper↔script parameter parity.
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest

function Deploy-AdeEnvironment {
    <#
    .SYNOPSIS
        Deploys the Azure Demo Environment (wraps scripts/deploy.ps1).
    .DESCRIPTION
        Deploys a modular multi-tier Azure demo environment from Bicep templates
        using the Azure CLI. Choose a built-in profile (full, minimal,
        compute-only, databases-only, networking-only, security-focus, hardened)
        or pass a path to a custom profile JSON.

        WARNING: this creates real, billable Azure resources. Run with -WhatIf
        first and tear down with Remove-AdeEnvironment when finished.

        For full parameter documentation run:
        Get-Help "$(Split-Path (Get-Module AzureDemoEnvironment).Path)\scripts\deploy.ps1" -Detailed
    .EXAMPLE
        Deploy-AdeEnvironment -Profile minimal -Location westeurope -Prefix ade
    .EXAMPLE
        Deploy-AdeEnvironment -Profile hardened -Mode hardened -Prefix hdn -WhatIf
    .LINK
        https://github.com/vegazbabz/azure-demo-environment
    #>
    # deploy.ps1 implements -WhatIf as a plain switch driving its own ARM
    # what-if pipeline (no ShouldProcess); the wrapper mirrors that surface.
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '')]
    [CmdletBinding()]
    param(
        [string]$Profile,

        [string]$Location,

        [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
        [string]$Prefix,

        [string]$SubscriptionId,

        [string]$AdminUsername,

        [SecureString]$AdminPassword,

        [switch]$AutoGeneratePassword,

        [switch]$Force,

        [switch]$ContinueOnError,

        [switch]$WhatIf,

        [string[]]$SkipModules,

        [string[]]$EnableModules,

        [ValidateSet('default', 'hardened')]
        [string]$Mode,

        [string]$LogFile,

        [string]$BudgetAlertEmail
    )

    & (Join-Path $PSScriptRoot 'scripts' 'deploy.ps1') @PSBoundParameters
}

function Remove-AdeEnvironment {
    <#
    .SYNOPSIS
        Destroys an Azure Demo Environment (wraps scripts/destroy.ps1).
    .DESCRIPTION
        Deletes all ADE-managed resource groups for the given prefix, including
        Azure-managed side groups, and purges the environment's soft-deleted
        Key Vault. Supports -WhatIf / -Confirm.
    .EXAMPLE
        Remove-AdeEnvironment -Prefix ade -Force
    .EXAMPLE
        Remove-AdeEnvironment -Prefix ade -Modules compute,containers
    .LINK
        https://github.com/vegazbabz/azure-demo-environment
    #>
    # ShouldProcess is implemented by destroy.ps1 (which receives -WhatIf and
    # -Confirm via $PSBoundParameters); the wrapper itself changes no state.
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
        [string]$Prefix,

        [string[]]$Modules,

        [string]$SubscriptionId,

        [switch]$NoWait,

        [switch]$Force,

        [string]$LogFile
    )

    & (Join-Path $PSScriptRoot 'scripts' 'destroy.ps1') @PSBoundParameters
}

function Initialize-AdeSeedData {
    <#
    .SYNOPSIS
        Seeds dummy data into a deployed environment (wraps scripts/seed-data.ps1).
    .DESCRIPTION
        Populates Storage, Cosmos DB, Azure SQL, PostgreSQL, MySQL, Redis,
        Key Vault, Service Bus, Event Hub, and Event Grid with sample data.
        Database passwords are fetched automatically from the environment's
        Key Vault; -DatabaseAdminPassword is an optional override.
    .EXAMPLE
        Initialize-AdeSeedData -Prefix ade
    .EXAMPLE
        Initialize-AdeSeedData -Prefix ade -Modules storage,cosmosdb -Force
    .LINK
        https://github.com/vegazbabz/azure-demo-environment
    #>
    # Interface parity with seed-data.ps1: -DatabaseAdminPassword is a [string]
    # by design (see the PSAvoidUsingPlainTextForPassword rationale in
    # .config/PSScriptAnalyzerSettings.psd1) — the value comes from Key Vault
    # or a CI secret and is never logged.
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [CmdletBinding()]
    param(
        [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
        [string]$Prefix,

        [string]$SubscriptionId,

        [ValidateSet('storage', 'cosmosdb', 'sql', 'postgresql', 'mysql', 'redis',
                     'keyvault', 'servicebus', 'eventhub', 'eventgrid', 'all')]
        [string[]]$Modules,

        [string]$AdminUsername,

        [string]$DatabaseAdminPassword,

        [switch]$Force
    )

    & (Join-Path $PSScriptRoot 'scripts' 'seed-data.ps1') @PSBoundParameters
}

function Get-AdeCostDashboard {
    <#
    .SYNOPSIS
        Terminal cost and status dashboard (wraps scripts/dashboard/Get-AdeCostDashboard.ps1).
    .DESCRIPTION
        Shows current-month cost per resource group, projected month-end cost,
        VM/database/AKS status, and budget utilisation for a deployed
        environment. -StopAll / -StartAll deallocate or start all compute.
    .EXAMPLE
        Get-AdeCostDashboard -Prefix ade
    .EXAMPLE
        Get-AdeCostDashboard -Prefix ade -Watch
    .LINK
        https://github.com/vegazbabz/azure-demo-environment
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
        [string]$Prefix,

        [string]$SubscriptionId,

        [switch]$StopAll,

        [switch]$StartAll,

        [switch]$Watch
    )

    & (Join-Path $PSScriptRoot 'scripts' 'dashboard' 'Get-AdeCostDashboard.ps1') @PSBoundParameters
}

Export-ModuleMember -Function @(
    'Deploy-AdeEnvironment',
    'Remove-AdeEnvironment',
    'Initialize-AdeSeedData',
    'Get-AdeCostDashboard'
)
