# ADE Command Reference

## Prerequisites

```powershell
az login
az account set --subscription '<subscription-id>'
```

---

## Unit Tests (no Azure required)

```powershell
# Fast — skips Bicep compile tests
Invoke-Pester tests/ -Output Minimal -ExcludePath tests/bicep

# Full suite including Bicep lint
pwsh -NonInteractive -File tests/Invoke-PesterSuite.ps1

# Static analysis (PowerShell scripts)
Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings .config/PSScriptAnalyzerSettings.psd1
```

---

## Deploy

```powershell
# Smallest / cheapest (~$80–120/month in westeurope)
./scripts/deploy.ps1 -Profile minimal -Prefix ade -Location westeurope -Force

# Full environment — default (benchmark baseline)
./scripts/deploy.ps1 -Profile full -Prefix ade -Location westeurope -Force

# Full environment — hardened (CIS/MCSB-aligned)
./scripts/deploy.ps1 -Profile full -Mode hardened -Prefix ade -Location westeurope -Force

# Skip specific modules
./scripts/deploy.ps1 -Profile full -SkipModules ai,data,integration -Prefix ade -Force

# Preview changes without deploying
./scripts/deploy.ps1 -Profile full -Prefix ade -WhatIf
```

---

## Seed Sample Data

```powershell
# Run after a successful deploy
./scripts/seed-data.ps1 -Prefix ade
```

---

## Cost Dashboard

```powershell
./scripts/dashboard/Get-AdeCostDashboard.ps1 -Prefix ade
```

---

## Start / Stop Resources (cost saving)

```powershell
# Stop all ADE VMs and AKS node pools
./scripts/runbooks/Stop-AdeResources.ps1 -Prefix ade -SubscriptionId '<sub-id>'

# Start them again
./scripts/runbooks/Start-AdeResources.ps1 -Prefix ade -SubscriptionId '<sub-id>'
```

---

## Deploy Custom Policies

```powershell
# Create definitions + initiative (no assignment)
./policies/Deploy-AdePolicies.ps1 -SubscriptionId '<sub-id>' -Prefix ade

# Create + assign at subscription scope (audit/DoNotEnforce mode)
./policies/Deploy-AdePolicies.ps1 -SubscriptionId '<sub-id>' -Prefix ade -Assign
```

---

## Teardown

```powershell
# Preview which resource groups will be deleted
./scripts/destroy.ps1 -Prefix ade -WhatIf

# Destroy all ade-*-rg resource groups
./scripts/destroy.ps1 -Prefix ade -Force
```

---

## Useful Azure CLI Spot Checks

```powershell
# List all ADE resource groups
az group list --query "[?starts_with(name,'ade-')].{Name:name,Location:location,State:properties.provisioningState}" -o table

# List resources in a specific module RG
az resource list --resource-group ade-networking-rg --query '[].{name:name,type:type}' -o table

# Check Bastion SKU and state
az network bastion show -g ade-networking-rg -n ade-bastion --query "{SKU:sku.name,State:provisioningState}" -o table

# Verify Defender plans
az security pricing list --query "[].{Name:name,PricingTier:pricingTier}" -o table

# List activity log alert rules (enabled only)
az monitor activity-log alert list --query "[?enabled==\`true\`].{name:name}" -o table
```
