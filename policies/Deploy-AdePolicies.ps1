# ─────────────────────────────────────────────────────────────────────────────
# Deploy-AdePolicies.ps1
#
# Creates ADE custom policy definitions and the governance initiative in the
# target subscription. Optionally assigns the initiative at subscription scope.
#
# Usage:
#   ./policies/Deploy-AdePolicies.ps1 `
#       -SubscriptionId '<sub-id>' `
#       -Prefix         'ade'
#
#   ./policies/Deploy-AdePolicies.ps1 `
#       -SubscriptionId '<sub-id>' `
#       -Prefix         'ade' `
#       -Assign                        # also creates an assignment
#
# Prerequisites:
#   - Azure CLI logged in (`az login`)
#   - Contributor + Resource Policy Contributor on the subscription
# ─────────────────────────────────────────────────────────────────────────────

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
    [string] $Prefix,

    # If set, assigns the governance initiative at subscription scope after creating it.
    [switch] $Assign
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Write-Step ([string]$Message) {
    Write-Host "  → $Message" -ForegroundColor Cyan
}

function Write-Ok ([string]$Message) {
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Fail ([string]$Message) {
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

# ─── Validate subscription ────────────────────────────────────────────────────

Write-Host "`n[ADE] Deploying custom policy definitions" -ForegroundColor White
Write-Host "  Subscription : $SubscriptionId"
Write-Host "  Prefix       : $Prefix"
Write-Host "  Assign       : $($Assign.IsPresent)"

$null = az account set --subscription $SubscriptionId 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Could not set subscription. Run 'az login' first."
    exit 1
}

# ─── Deploy policy definitions ───────────────────────────────────────────────

$definitionsDir = Join-Path $ScriptDir 'definitions'
$definitions     = Get-ChildItem -Path $definitionsDir -Filter '*.json' | Sort-Object Name

Write-Host "`n  Creating policy definitions..."

foreach ($defFile in $definitions) {
    $rawJson = Get-Content $defFile.FullName -Raw | ConvertFrom-Json
    $name    = $rawJson.name

    Write-Step "az policy definition create: $name"

    # Pass policyRule and parameters via temp files — inline JSON arguments lose
    # double-quotes on Windows PowerShell 7.0-7.2 before az CLI receives them
    # (same quoting issue fixed in PR #106 for az keyvault certificate create).
    $rulesFile  = [System.IO.Path]::GetTempFileName() + '.json'
    $paramsFile = [System.IO.Path]::GetTempFileName() + '.json'
    try {
        $rawJson.properties.policyRule | ConvertTo-Json -Depth 20 -Compress |
            Set-Content -Path $rulesFile  -Encoding utf8NoBOM
        $rawJson.properties.parameters | ConvertTo-Json -Depth 20 -Compress |
            Set-Content -Path $paramsFile -Encoding utf8NoBOM

        az policy definition create `
            --subscription  $SubscriptionId `
            --name          $name `
            --display-name  $rawJson.properties.displayName `
            --description   $rawJson.properties.description `
            --mode          $rawJson.properties.mode `
            --rules         "@$rulesFile" `
            --params        "@$paramsFile" `
            --output none
    } finally {
        Remove-Item $rulesFile, $paramsFile -Force -ErrorAction SilentlyContinue
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to create policy definition: $name"
        exit 1
    }

    Write-Ok $name
}

# ─── Deploy initiative ────────────────────────────────────────────────────────

Write-Host "`n  Creating governance initiative..."

$initiativeFile = Join-Path $ScriptDir 'initiatives' 'ade-governance-initiative.json'
$initiativeJson = (Get-Content $initiativeFile -Raw) `
    -replace '\{SUBSCRIPTION_ID\}', $SubscriptionId

$initiative = $initiativeJson | ConvertFrom-Json

Write-Step "az policy set-definition create: $($initiative.name)"

# Same Windows JSON-quoting fix — pass definitions and parameters via temp files.
$defsFile    = [System.IO.Path]::GetTempFileName() + '.json'
$iParamsFile = [System.IO.Path]::GetTempFileName() + '.json'
try {
    $initiative.properties.policyDefinitions | ConvertTo-Json -Depth 20 -Compress |
        Set-Content -Path $defsFile    -Encoding utf8NoBOM
    $initiative.properties.parameters        | ConvertTo-Json -Depth 20 -Compress |
        Set-Content -Path $iParamsFile -Encoding utf8NoBOM

    az policy set-definition create `
        --subscription    $SubscriptionId `
        --name            $initiative.name `
        --display-name    $initiative.properties.displayName `
        --description     $initiative.properties.description `
        --definitions     "@$defsFile" `
        --params          "@$iParamsFile" `
        --output none
} finally {
    Remove-Item $defsFile, $iParamsFile -Force -ErrorAction SilentlyContinue
}

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to create initiative."
    exit 1
}

Write-Ok $initiative.name

# ─── Optional: assign initiative ─────────────────────────────────────────────

if ($Assign) {
    Write-Host "`n  Assigning initiative at subscription scope..."

    $initiativeId       = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policySetDefinitions/$($initiative.name)"
    $assignmentName     = "$Prefix-governance-baseline"
    $subscriptionScope  = "/subscriptions/$SubscriptionId"

    Write-Step "az policy assignment create: $assignmentName"

    az policy assignment create `
        --subscription   $SubscriptionId `
        --scope          $subscriptionScope `
        --name           $assignmentName `
        --display-name   "[ADE] Governance Baseline — $Prefix" `
        --policy-set-definition $initiativeId `
        --enforcement-mode DoNotEnforce `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to create assignment."
        exit 1
    }

    Write-Ok "$assignmentName (DoNotEnforce — audit only)"
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n[ADE] Policy deployment complete." -ForegroundColor Green
Write-Host "  Definitions : $($definitions.Count)"
Write-Host "  Initiative  : $($initiative.name)"
if ($Assign) {
    Write-Host "  Assignment  : $Prefix-governance-baseline (DoNotEnforce)"
}
Write-Host ""
