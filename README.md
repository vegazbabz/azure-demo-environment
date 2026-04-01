# Azure Demo Environment (ADE)

A fully-scripted Azure demo environment for security benchmark testing — designed to deploy **out-of-the-box Azure defaults** (for CIS/MCSB baseline measurement) or a **CIS/MCSB-hardened** configuration at the flip of a switch.

---

## What it deploys

12 independent Bicep modules, each targeting its own resource group:

| Module | Resources |
| --- | --- |
| `monitoring` | Log Analytics Workspace, Application Insights, Action Group |
| `networking` | VNet, subnets, NSGs, Bastion (Developer SKU), optional AppGW / Firewall / VPN |
| `security` | Key Vault, User-Assigned Managed Identity, optional Defender for Cloud + Sentinel |
| `compute` | Windows Server 2022 VM, Ubuntu 22.04 VM, optional VMSS / Availability Set |
| `storage` | General-purpose v2 Storage Account, optional Data Lake Gen2, File Shares |
| `databases` | Azure SQL (Serverless), Cosmos DB (Serverless), PostgreSQL Flexible Server |
| `appservices` | App Service Plan (B1), Windows + Linux Web Apps, Function App, Static Web App, Logic App |
| `containers` | Container Registry (Basic), AKS (1-node), Container Apps, Container Instances |
| `integration` | Service Bus (Standard), Event Hub (Basic), Event Grid, SignalR |
| `ai` | Azure AI Services, Azure OpenAI, Cognitive Search *(off by default)* |
| `data` | Data Factory, Synapse, Databricks *(off by default)* |
| `governance` | Automation Account (start/stop runbooks), Budget alerts, optional Resource Locks + Policy |

---

## Quick start

### Prerequisites

- [PowerShell 7.4+](https://github.com/PowerShell/PowerShell/releases)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with `az bicep install`
- An Azure subscription with Contributor rights

```powershell
az login
az account set --subscription <subscription-id>
```

### Deploy

```powershell
# Minimal environment (VM + storage + monitoring) — good first run
./scripts/deploy.ps1 -Profile minimal -Location westeurope -Prefix ade

# Full environment, all modules
./scripts/deploy.ps1 -Profile full -Location westeurope -Prefix ade

# CIS/MCSB-hardened full environment
./scripts/deploy.ps1 -Profile full -Mode hardened -Location westeurope -Prefix ade

# Preview changes without deploying
./scripts/deploy.ps1 -Profile full -WhatIf
```

### Destroy

```powershell
./scripts/destroy.ps1 -Prefix ade
```

---

## Deployment modes

| Mode | Bicep source | Purpose |
| --- | --- | --- |
| `default` *(default)* | `bicep/modules/` | Out-of-the-box Azure settings — no hardening, no forced diagnostics. Baseline for CIS/MCSB benchmark scoring. |
| `hardened` | `bicep/hardened/` | CIS/MCSB-aligned: TLS 1.2+, public network access disabled, purge protection, Defender for Cloud, Sentinel, resource locks, policy assignments in Enforce mode. |

---

## Profiles

Profiles live in `config/profiles/` and control which modules and features are enabled. Pass a built-in name or a path to a custom JSON file.

| Profile | Description |
| --- | --- |
| `full` | All 12 modules — complete CIS coverage |
| `minimal` | Monitoring + networking + security + one Windows VM |
| `compute-only` | VMs and VMSS — CIS Compute sections |
| `databases-only` | SQL, Cosmos DB, PostgreSQL |
| `networking-only` | VNet, NSGs, AppGW, Bastion |
| `security-focus` | Key Vault, Defender for Cloud, Sentinel |
| `hardened` | Full environment with all hardening flags enabled |

```powershell
# Custom profile
./scripts/deploy.ps1 -Profile ./my-profile.json -Location westeurope -Prefix demo
```

---

## Key parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-Profile` | *(required)* | Built-in profile name or path to custom JSON |
| `-Location` | `westeurope` | Azure region |
| `-Prefix` | `ade` | 3–6 char lowercase prefix for all resource group names |
| `-SubscriptionId` | current account | Target subscription |
| `-Mode` | `default` | `default` or `hardened` |
| `-WhatIf` | — | Bicep what-if only, no deployment |
| `-Force` | — | Skip confirmation prompt |
| `-SkipModules` | — | Comma-separated module names to skip |
| `-EnableModules` | — | Comma-separated module names to force-enable |
| `-LogFile` | — | Path to write a plain-text copy of all output |

---

## Repository structure

```
bicep/
  modules/          # Default (out-of-the-box) Bicep modules
  hardened/         # CIS/MCSB-hardened Bicep modules
config/
  defaults.json     # Master feature flag defaults
  profiles/         # Named deployment profiles
  schema.json       # JSON Schema for profile validation
data/               # Sample seed data (blobs, Cosmos documents, SQL)
docs/               # Architecture, usage, benchmark guide, test plan
policies/           # Custom Azure Policy definitions + initiative
scripts/
  deploy.ps1        # Main deployment orchestrator
  destroy.ps1       # Teardown script
  seed-data.ps1     # Post-deploy data seeding
  helpers/          # Shared functions (common.ps1, validate.ps1)
  runbooks/         # Automation Account runbooks (Start/Stop VMs)
  dashboard/        # Cost dashboard helper
tests/              # Pester 5 unit tests (442 passing, 0 failing)
.github/workflows/  # GitHub Actions (deploy, destroy, lint)
```

---

## GitHub Actions setup

The workflows use **OIDC (federated identity)** — no long-lived client secrets. Follow these steps once before the first workflow run.

### 1. Create an app registration

```bash
az ad app create --display-name "ade-github-actions"
```

Note the `appId` (client ID) and `id` (object ID) from the output.

### 2. Create a service principal

```bash
az ad sp create --id <appId>
```

### 3. Add a federated credential (OIDC trust)

This tells Azure to trust tokens from GitHub Actions running on the `main` branch of your repo.

```bash
az ad app federated-credential create \
  --id <objectId> \
  --parameters '{
    "name": "ade-github-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:vegazbabz/azure-demo-environment:environment:demo",
    "audiences": ["api://AzureADTokenAudience"]
  }'
```

> The `subject` must match exactly — `environment:demo` because the deploy job uses `environment: demo` in the workflow.

### 4. Assign a role

```bash
az role assignment create \
  --assignee <appId> \
  --role Contributor \
  --scope /subscriptions/<subscription-id>
```

For the destroy workflow, `Contributor` is sufficient. For policy assignments (`Deploy-AdePolicies.ps1`), `Resource Policy Contributor` is also needed:

```bash
az role assignment create \
  --assignee <appId> \
  --role "Resource Policy Contributor" \
  --scope /subscriptions/<subscription-id>
```

### 5. Configure the GitHub environment

In **Settings → Environments → New environment**, name it `demo` and configure:

- **Deployment branches**: `main` only
- **Required reviewers**: add yourself (recommended — prevents accidental deploys)

### 6. Add secrets to the `demo` environment

In **Settings → Environments → demo → Add secret**:

| Secret | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | `appId` from step 1 |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
| `ADE_ADMIN_PASSWORD` | VM admin password (min 12 chars, upper+lower+digit+symbol) |

Store these at **environment** scope, not repo scope — they are then only accessible to jobs that have passed the `demo` environment's protection rules.

### 7. (Optional) Set Actions variables

In **Settings → Secrets and variables → Actions → Variables**:

| Variable | Example |
| --- | --- |
| `ADE_DEFAULT_LOCATION` | `westeurope` |
| `ADE_DEFAULT_PREFIX` | `ade` |

These pre-fill the workflow dispatch inputs.

### Verify

```bash
# Confirm the federated credential is set correctly
az ad app federated-credential list --id <objectId> --query "[].subject"
```

Expected output: `["repo:vegazbabz/azure-demo-environment:environment:demo"]`

---

## Tests

```powershell
# Run full suite (requires PowerShell 7 + Pester 5.7+)
Install-Module Pester -RequiredVersion 5.7.1 -Force -Scope CurrentUser
Invoke-Pester ./tests/ -Output Minimal
```

All Azure CLI calls are mocked — no subscription required to run tests.

---

## Cost guidance

Most modules are low-cost at rest. Notable exceptions:

| Resource | Approximate cost |
| --- | --- |
| Azure Firewall Standard | ~$900/month |
| Azure Firewall Premium | ~$1,500/month |
| DDoS Network Protection | ~$2,944/month |
| SQL Managed Instance | ~$1,000+/month |
| VPN Gateway (VpnGw1) | ~$140/month |
| Bastion Basic/Standard | ~$140–200/month |

Cost warnings are embedded in `config/defaults.json` and surfaced during deployment confirmation.

---

## License

MIT
