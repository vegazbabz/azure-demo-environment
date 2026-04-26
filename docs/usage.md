# Usage Guide

## Prerequisites

| Tool | Minimum version | Purpose |
|---|---|---|
| Azure CLI | 2.57+ | Deployment, policy, resource management |
| Bicep CLI | latest | Installed automatically by `az bicep install` |
| PowerShell | 7.4+ | Orchestration scripts |
| Azure subscription | — | Contributor + Resource Policy Contributor |

```powershell
# Verify CLI
az version
az bicep version
$PSVersionTable.PSVersion
```

---

## Quick Start

```powershell
# 1. Log in
az login
az account set --subscription '<subscription-id>'

# 2. Clone
git clone https://github.com/<org>/azure-demo-environment.git
cd azure-demo-environment

# 3. Deploy minimal environment (default mode)
./scripts/deploy.ps1 `
    -Profile  minimal `
    -Prefix   ade `
    -Location westeurope `
    -Force
```

You will be prompted for an admin password unless you supply `-AdminPassword`.

---

## Deployment Examples

### Full environment — default (benchmark baseline)

```powershell
./scripts/deploy.ps1 `
    -Profile  full `
    -Mode     default `
    -Prefix   ade `
    -Location westeurope `
    -Force
```

### Full environment — hardened (CIS/MCSB-aligned)

```powershell
./scripts/deploy.ps1 `
    -Profile  full `
    -Mode     hardened `
    -Prefix   ade `
    -Location westeurope `
    -Force
```

### Skip specific modules

```powershell
./scripts/deploy.ps1 `
    -Profile      full `
    -SkipModules  ai, data, integration `
    -Prefix       ade `
    -Force
```

### What-if (preview changes without deploying)

```powershell
./scripts/deploy.ps1 -Profile full -Prefix ade -WhatIf
```

### Custom profile (point to your own JSON)

```powershell
./scripts/deploy.ps1 `
    -Profile  ./config/profiles/my-custom-profile.json `
    -Prefix   ade `
    -Force
```

---

## Deploying Custom Policies

After the main environment is deployed, optionally deploy the ADE custom governance policies:

```powershell
# Create definitions + initiative (no assignment)
./policies/Deploy-AdePolicies.ps1 `
    -SubscriptionId '<subscription-id>' `
    -Prefix         ade

# Create + assign at subscription scope (DoNotEnforce / audit only)
./policies/Deploy-AdePolicies.ps1 `
    -SubscriptionId '<subscription-id>' `
    -Prefix         ade `
    -Assign
```

Custom policies created:

| Policy | Default effect |
|---|---|
| Require Environment + Owner tags | Audit |
| Deny NICs with public IPs | Deny |
| Restrict VM SKUs to approved list | Deny |
| Audit storage accounts with public blob access | Audit |

These complement the built-in CIS and MCSB assignments deployed by the `governance` module.

---

## Teardown

```powershell
# Destroy all ADE resource groups for a given prefix
./scripts/destroy.ps1 -Prefix ade -Force

# Preview which resource groups will be deleted (no actual deletion)
./scripts/destroy.ps1 -Prefix ade -WhatIf
```

The destroy script targets all resource groups matching `{prefix}-*-rg` and discovers module-owned
Azure-managed resource groups that use provider naming, such as AKS node RGs and Synapse managed
RGs. It does **not** remove policy definitions/assignments or the Activity Log diagnostic settings
— remove those manually if desired.

---

## Start / Stop Resources (cost saving)

Use the runbooks to start or stop compute resources outside business hours:

```powershell
# Stop all ADE VMs and AKS node pools
./scripts/runbooks/Stop-AdeResources.ps1 -Prefix ade -SubscriptionId '<sub-id>'

# Start them again
./scripts/runbooks/Start-AdeResources.ps1 -Prefix ade -SubscriptionId '<sub-id>'
```

---

## Profile Reference

Profiles live in `config/profiles/*.json`. Each profile specifies:

- `modules` — which modules are enabled and their feature flags
- `profileName` / `description` / `version` — metadata

To create a custom profile, copy an existing file, rename it, and adjust the `modules` block.
Feature flags within a module are passed directly as Bicep parameters.

---

## Estimating Costs

A rough cost guide for `westeurope` with prefix `ade`:

| Profile | Mode | Approximate monthly cost |
|---|---|---|
| `minimal` | default | ~$80–120 |
| `full` | default | ~$600–900 |
| `full` | hardened | ~$700–1,100 (Defender plans add ~$15–50/node) |
| `security-focus` | hardened | ~$50–100 |

Use `./scripts/dashboard/Get-AdeCostDashboard.ps1` to view actual accrued costs.

> Costs vary by region and Azure pricing changes. Always verify with the Azure Pricing Calculator.

---

## Troubleshooting

### Deployment fails on `az bicep lint`

Run `az bicep upgrade` to ensure the Bicep CLI matches the module syntax.

### "Insufficient privileges to complete the operation"

The service principal needs **Contributor** role and **Resource Policy Contributor** for policy
assignments. Assign both at subscription scope.

### VM admin password rejected

ADE passwords must be 12+ characters, include uppercase, lowercase, a digit, and a special
character. Supply via `-AdminPassword` (SecureString) or set the `ADE_ADMIN_PASSWORD` GitHub
Actions secret.

### Resource group already exists from a previous run

`deploy.ps1` is idempotent — re-running upserts all resources. If a module is in a broken state,
destroy that module's resource group manually and re-run:

```powershell
az group delete --name ade-compute-rg --yes
./scripts/deploy.ps1 -Profile full -Prefix ade -Force
```
