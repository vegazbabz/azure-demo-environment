# Azure Demo Environment (ADE)

A fully automated, modular Azure infrastructure project for **security benchmark testing** and **environment provisioning**. Deploy a complete multi-tier Azure environment in minutes — either with out-of-the-box Azure defaults (to measure your baseline CIS/MCSB score) or with CIS/MCSB-hardened configuration (to measure remediations).

> [!WARNING]
> **Deploying resources from this repository will incur real costs in your Azure subscription.**
> Every module provisions billable Azure resources. Some — such as Azure Firewall, DDoS Protection, and VPN Gateway — are expensive even when idle. See [Cost guidance](#cost-guidance) for estimates.
> **The author of this repository accepts no responsibility for any Azure costs, charges, or overspend incurred by anyone using this project.** You are solely responsible for monitoring and managing spend in your own subscription. Before deploying, set up [Azure Cost Management budgets and alerts](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets) to cap unexpected spend.

**New to Azure?** Start with [Prerequisites](#prerequisites) and [Your first deployment](#your-first-deployment).  
**Just want to see what this deploys?** Skip to [What gets deployed](#what-gets-deployed).  
**Setting up CI/CD?** Jump to [GitHub Actions setup](#github-actions-setup).  

---

## Table of contents

- [What gets deployed](#what-gets-deployed)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Your first deployment](#your-first-deployment)
- [Deployment profiles](#deployment-profiles)
- [Feature flags](#feature-flags)
- [Deployment modes](#deployment-modes)
- [All deploy.ps1 parameters](#all-deployps1-parameters)
- [Tearing down](#tearing-down)
- [Custom profiles](#custom-profiles)
- [Scripts reference](#scripts-reference)
- [Cost guidance](#cost-guidance)
- [Seed data](#seed-data)
- [Auto start/stop](#auto-startstop)
- [Cost dashboard](#cost-dashboard)
- [Running tests](#running-tests)
- [GitHub Actions setup](#github-actions-setup)
- [Repository structure](#repository-structure)
- [CIS / MCSB benchmark guide](#cis--mcsb-benchmark-guide)
- [License](#license)

---

## What gets deployed

12 independent Bicep modules are available. Each module deploys into its own dedicated resource group (e.g. `ade-compute-rg`). Modules are **independently toggleable** — you only pay for what you enable.

| Module | Default resources | Notable opt-in features |
| --- | --- | --- |
| `monitoring` | Log Analytics Workspace, Action Group | Application Insights, alert rules |
| `networking` | VNet (10.0.0.0/16), all subnets, NSGs, Bastion (Developer SKU — free) | Application Gateway, Azure Firewall, VPN Gateway, NAT Gateway, DDoS Protection, Private DNS Zones |
| `security` | Key Vault (RBAC model), User-Assigned Managed Identity | Defender for Cloud (all plans), Microsoft Sentinel |
| `compute` | Windows Server 2022 VM (`Standard_B2s`) | Ubuntu 22.04 VM, VM Scale Set |
| `storage` | General-purpose v2 Storage Account | Data Lake Gen2, File Shares, soft delete, versioning |
| `databases` | Azure SQL Server + Serverless Database (AdventureWorksLT) | SQL Server on VM (IaaS), Cosmos DB (serverless), PostgreSQL Flexible Server, MySQL Flexible Server, Redis Cache |
| `appservices` | App Service Plan (B1), Windows Web App, Linux Web App, Function App, Static Web App, Logic App | — |
| `containers` | Container Registry (Basic), AKS (1-node, free tier), Container Apps, Container Instances | — |
| `integration` | Service Bus (Standard), Event Hub (Basic), Event Grid, SignalR | — |
| `ai` | Azure AI Services, Azure OpenAI, Cognitive Search | — |
| `data` | Data Factory, Synapse Analytics, Databricks | — |
| `governance` | Automation Account (auto-stop/start), Budget alerts | Resource locks, Azure Policy initiative assignments |

> `ai` and `data` are disabled in all built-in profiles by default due to cost and quota requirements. Enable them in a custom profile when needed.

---

## How it works

```text
deploy.ps1  ──reads──>  profile JSON  ──decides which──>  Bicep modules to deploy
                                                                      │
                                              each module ──deploys──> its own resource group
                                              passes outputs ──downstream──> next module
```

1. You run `deploy.ps1` with a **profile** (which modules to enable and which features to turn on) and a **mode** (`default` = baseline, `hardened` = CIS/MCSB-aligned).
2. The script deploys modules in strict dependency order: `monitoring → networking → security → compute → storage → databases → appservices → containers → integration → ai → data → governance`.
3. Each module's Bicep receives outputs from upstream modules (e.g. the subnet ID from networking, the Key Vault ID from security) as parameters.
4. After deployment, an optional seed-data step populates databases and storage with realistic sample data.

The orchestration is **pure PowerShell 7 + Azure CLI**. No Azure PowerShell module (`Az.*`) is required.

---

## Prerequisites

### Required software

| Tool | Minimum version | Install |
| --- | --- | --- |
| PowerShell | 7.4 | [github.com/PowerShell/PowerShell](https://github.com/PowerShell/PowerShell/releases) |
| Azure CLI | 2.60 | [learn.microsoft.com/cli/azure/install-azure-cli](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Bicep CLI | latest | `az bicep install` (run once after installing Azure CLI) |

**Windows note:** PowerShell 7 is separate from Windows PowerShell 5.1. Install it from the link above. Scripts will refuse to run on 5.1.

### Required Azure access

- An Azure **subscription** with at least **Contributor** role
- For governance features (policy assignments, resource locks): **User Access Administrator** role as well

### Check you are ready

```powershell
# Verify PowerShell version — must say 7.x or higher
$PSVersionTable.PSVersion

# Verify Azure CLI is installed
az version

# Log in to Azure
az login

# Set the subscription you want to deploy into
az account set --subscription "<your-subscription-id>"

# Confirm the right subscription is active
az account show --query "{name:name, id:id}" -o table
```

---

## Your first deployment

### Step 1 — Clone the repository

```bash
git clone https://github.com/vegazbabz/azure-demo-environment.git
cd azure-demo-environment
```

### Step 2 — Deploy the minimal profile

The `minimal` profile is the lowest-cost starting point. It deploys: monitoring, networking, security (Key Vault + managed identity), one Windows VM, storage, and budget alerts. Estimated cost: **~$15–30/month** with auto-shutdown enabled.

```powershell
# PowerShell 7 — run from the repo root
./scripts/deploy.ps1 -Profile minimal -Location westeurope -Prefix ade
```

You will be prompted for a VM admin password if you do not provide one. The password must be at least 12 characters with uppercase, lowercase, a digit, and a symbol.

The script will:

1. Print a summary of what will be deployed and the estimated cost.
2. Ask for confirmation (press **Y** to proceed, **N** to abort).
3. Deploy each module in order, printing live progress.
4. Print a summary of all deployed resources when finished.

### Step 3 — Tear it down when done

```powershell
./scripts/destroy.ps1 -Prefix ade -Force
```

This deletes all resource groups whose names start with `ade-` and that are tagged as ADE-managed.

---

## Deployment profiles

Profiles live in `config/profiles/`. Pass the profile name (no path, no `.json`) or the path to a custom JSON file.

### Built-in profiles

| Profile | Modules enabled | Estimated cost | Best for |
| --- | --- | --- | --- |
| `minimal` | monitoring, networking, security, compute (Windows VM), storage, governance | ~$15–30/month | First run, orientation, low-cost baseline |
| `compute-only` | monitoring, networking, security, compute (Windows + Linux + VMSS), governance | ~$60–100/month | CIS Compute sections, VM hardening testing |
| `networking-only` | monitoring, networking (+ App Gateway), governance | ~$200–300/month | Network topology and connectivity testing |
| `databases-only` | monitoring, networking, security, databases (SQL + Cosmos DB + PostgreSQL + MySQL), governance | ~$80–150/month | Database benchmark testing |
| `security-focus` | monitoring, networking, security (+ Defender + Sentinel), compute (Windows + Linux), storage, databases (SQL only), governance (+ locks) | ~$100–200/month | Security posture and Defender coverage testing |
| `full` | All 12 modules (ai and data excluded) | ~$300–500/month | Complete CIS/MCSB coverage |

```powershell
./scripts/deploy.ps1 -Profile minimal      -Location westeurope -Prefix ade
./scripts/deploy.ps1 -Profile compute-only -Location westeurope -Prefix ade
./scripts/deploy.ps1 -Profile full         -Location westeurope -Prefix ade
```

---

## Feature flags

Every profile JSON controls exactly which sub-features are deployed within each module. These are the available flags:

### `monitoring`

| Flag | Default | Description |
| --- | --- | --- |
| `logAnalyticsWorkspace` | `true` | Log Analytics Workspace (required by most other modules) |
| `applicationInsights` | varies | Application Insights |
| `actionGroup` | `true` | Action Group for alert notifications |
| `alertRules` | `false` | Pre-built alert rules (high CPU, disk, etc.) |

### `networking`

| Flag | Default | Description |
| --- | --- | --- |
| `bastionSku` | `"Developer"` | `Developer` = free (shared, no dedicated subnet). `Basic`/`Standard` = dedicated subnet + hourly cost |
| `enableAppGateway` | `false` | Application Gateway WAF v2 (~$200–300/month) |
| `enableFirewall` | `"None"` | `Standard` (~$900/month) or `Premium` (~$1,500/month) |
| `enableVpnGateway` | `false` | VPN Gateway for Point-to-Site (~$140/month) |
| `enableNatGateway` | `false` | NAT Gateway for outbound internet (~$32/month) |
| `enableDdos` | `false` | DDoS Network Protection — **~$2,944/month. Use with extreme caution.** |
| `enablePrivateDnsZones` | `false` | Private DNS Zones for private endpoint resolution |

All subnets (compute, databases, containers, app services, management, App Gateway, Firewall, etc.) are **always provisioned** regardless of which resources are enabled. This prevents address-space redesign when toggling optional features later.

### `security`

| Flag | Default | Description |
| --- | --- | --- |
| `keyVault` | `true` | Key Vault (RBAC authorization model) |
| `managedIdentity` | `true` | User-assigned Managed Identity used by other modules |
| `defenderForCloud` | varies | All Defender plans (Servers, Databases, Storage, AppServices, Containers, KeyVault, DNS) |
| `sentinel` | varies | Microsoft Sentinel (requires Log Analytics Workspace) |

### `compute`

| Flag | Default | Description |
| --- | --- | --- |
| `windowsVm` | `true` | Windows Server 2022 VM |
| `linuxVm` | `false` | Ubuntu 22.04 LTS VM — opt-in only |
| `vmss` | `false` | VM Scale Set |
| `enableAutoShutdown` | varies per profile | Daily auto-shutdown at 19:00 UTC (saves cost) |
| `vmSku` | `"Standard_B2s"` | VM size — change to `Standard_D2s_v3` or larger if needed |

### `storage`

| Flag | Default | Description |
| --- | --- | --- |
| `generalPurposeStorage` | `true` | Standard LRS general-purpose v2 storage account |
| `dataLakeGen2` | varies | Hierarchical namespace storage account |
| `fileShares` | varies | Azure File Shares |
| `enableSoftDelete` | `false` | Blob/file soft delete (retention 7 days) |
| `enableVersioning` | `false` | Blob versioning |

### `databases`

| Flag | Default | Description |
| --- | --- | --- |
| `sqlDatabase` | `true` | Azure SQL Server + Serverless Database (AdventureWorksLT) |
| `sqlVm` | `false` | SQL Server 2022 on a Windows VM (IaaS) — opt-in only |
| `cosmosDb` | `false` | Cosmos DB (NoSQL, serverless) — opt-in only |
| `postgresql` | `false` | PostgreSQL Flexible Server — opt-in only |
| `mysql` | `false` | MySQL Flexible Server — opt-in only |
| `redis` | `false` | Redis Cache — opt-in only |

### `appservices`

| Flag | Default | Description |
| --- | --- | --- |
| `windowsWebApp` | `true` | Windows Web App (B1 App Service Plan) |
| `linuxWebApp` | `true` | Linux Web App |
| `functionApp` | `true` | Function App (Consumption plan) |
| `staticWebApp` | `true` | Static Web App |
| `logicApp` | `true` | Logic App (Standard) |

### `containers`

| Flag | Default | Description |
| --- | --- | --- |
| `containerRegistry` | `true` | Azure Container Registry (Basic SKU) |
| `kubernetesService` | `true` | AKS (1-node, free tier control plane, `Standard_B2s`) |
| `containerApps` | `true` | Container Apps Environment + sample Container App |
| `containerInstances` | `true` | Container Instances |

### `governance`

| Flag | Default | Description |
| --- | --- | --- |
| `automationAccount` | varies | Automation Account with auto-stop/start runbooks and daily schedules |
| `budget` | `true` | Monthly budget with email alerts at 80% and 100% spend |
| `budgetAmount` | varies | Monthly budget limit in USD |
| `resourceLocks` | `false` | ReadOnly lock on the networking resource group |
| `policyAssignments` | `false` | CIS Benchmark + MCSB policy initiative assignments (audit mode) |

---

## Deployment modes

| Mode | Bicep path | Purpose |
| --- | --- | --- |
| `default` (default) | `bicep/modules/` | Out-of-the-box Azure settings — no hardening, no enforced TLS, public network access at defaults. Use this to establish a pre-hardening **benchmark baseline**. |
| `hardened` | `bicep/hardened/` | CIS/MCSB-aligned: TLS 1.2 minimum, public network access disabled, purge protection on Key Vault, all Defender plans enabled, Sentinel, resource locks, policy assignments in Enforce mode. |

```powershell
# Baseline (default) — measure "before" score
./scripts/deploy.ps1 -Profile full -Mode default -Location westeurope -Prefix ade

# Hardened — measure "after" score
./scripts/deploy.ps1 -Profile full -Mode hardened -Location westeurope -Prefix ade
```

You can also deploy both side-by-side using different prefixes:

```powershell
./scripts/deploy.ps1 -Profile full -Mode default  -Prefix ade-base
./scripts/deploy.ps1 -Profile full -Mode hardened -Prefix ade-hard
```

---

## All deploy.ps1 parameters

```powershell
./scripts/deploy.ps1 [parameters]
```

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `-Profile` | string | `full` | Built-in profile name or path to a custom JSON file |
| `-Location` | string | `westeurope` | Azure region. Use `az account list-locations --query "[].name" -o tsv` to list all. |
| `-Prefix` | string | `ade` | 2–8 lowercase alphanumeric characters. Becomes part of every resource group name and most resource names. |
| `-SubscriptionId` | string | current account | Target subscription. Defaults to whatever `az account show` returns. |
| `-AdminUsername` | string | `adeadmin` | VM and database administrator username |
| `-AdminPassword` | SecureString | prompted | VM admin password. Must meet Azure complexity: 12+ chars, upper, lower, digit, symbol. |
| `-Mode` | string | `default` | `default` or `hardened` |
| `-WhatIf` | switch | — | Run Bicep what-if on each module without actually deploying anything |
| `-Force` | switch | — | Skip the deployment confirmation prompt |
| `-SkipModules` | string[] | — | Module names to skip. Example: `-SkipModules containers,ai` |
| `-EnableModules` | string[] | — | Module names to force-enable regardless of profile. Example: `-EnableModules sentinel` |
| `-LogFile` | string | — | Path for a plain-text log file. Example: `-LogFile ./logs/deploy-$(Get-Date -f yyyyMMdd).log` |

### Examples

```powershell
# Minimal environment with a custom prefix in North Europe
./scripts/deploy.ps1 -Profile minimal -Location northeurope -Prefix demo

# Full environment, skip confirmation, log output to file
./scripts/deploy.ps1 -Profile full -Force -LogFile ./deploy.log

# What-if dry run — shows what would be created without deploying
./scripts/deploy.ps1 -Profile full -WhatIf

# Full environment but skip the containers and AI modules
./scripts/deploy.ps1 -Profile full -SkipModules containers,ai

# Deploy with a custom profile file
./scripts/deploy.ps1 -Profile ./my-profile.json -Location westeurope -Prefix myco

# Hardened mode
./scripts/deploy.ps1 -Profile full -Mode hardened -Location westeurope -Prefix ade
```

---

## Tearing down

```powershell
# Destroy everything with the 'ade' prefix
./scripts/destroy.ps1 -Prefix ade

# Destroy only specific modules
./scripts/destroy.ps1 -Prefix ade -Modules compute,containers

# Destroy asynchronously (faster, no per-group confirmation)
./scripts/destroy.ps1 -Prefix ade -NoWait -Force
```

The destroy script:

1. Removes any resource locks on matching resource groups first.
2. Deletes each matching resource group.
3. By default waits for each deletion to complete before continuing (so errors are visible).

> **Tip:** If a resource group deletion fails due to a lock or a protected resource, re-run the script — it will retry cleanly.

---

## Custom profiles

Copy any built-in profile and modify it. The profile schema is documented in `config/schema.json`.

```powershell
# Copy minimal as a starting point
Copy-Item config/profiles/minimal.json config/profiles/my-profile.json
```

Minimal valid profile structure:

```json
{
  "profileName": "my-profile",
  "description": "My custom profile.",
  "version": "2.0.0",
  "modules": {
    "monitoring": {
      "enabled": true,
      "features": {
        "logAnalyticsWorkspace": true,
        "applicationInsights": false,
        "actionGroup": true,
        "alertRules": false
      }
    },
    "networking": {
      "enabled": true,
      "features": {
        "bastionSku": "Developer",
        "enableAppGateway": false,
        "enableFirewall": "None",
        "enableVpnGateway": false,
        "enableDdos": false,
        "enableNatGateway": false,
        "enablePrivateDnsZones": false
      }
    },
    "security":    { "enabled": false },
    "compute":     { "enabled": false },
    "storage":     { "enabled": false },
    "databases":   { "enabled": false },
    "appservices": { "enabled": false },
    "containers":  { "enabled": false },
    "integration": { "enabled": false },
    "ai":          { "enabled": false },
    "data":        { "enabled": false },
    "governance": {
      "enabled": true,
      "features": {
        "automationAccount": false,
        "budget": true,
        "budgetAmount": 50,
        "resourceLocks": false,
        "policyAssignments": false
      }
    }
  },
  "seedDummyData": false
}
```

Any module that does not need features (just on/off) can use `"enabled": true` with no `features` object. To add opt-in features on top of defaults, provide only the feature keys you want to override — all others take Bicep parameter defaults.

To enable Cosmos DB and PostgreSQL in your custom profile's databases module:

```json
"databases": {
  "enabled": true,
  "features": {
    "sqlDatabase": true,
    "sqlVm": false,
    "cosmosDb": true,
    "postgresql": true,
    "mysql": false,
    "redis": false
  }
}
```

---

## Scripts reference

| Script | Purpose |
| --- | --- |
| `scripts/deploy.ps1` | Main deployment orchestrator. See [All deploy.ps1 parameters](#all-deployps1-parameters). |
| `scripts/destroy.ps1` | Deletes all ADE resource groups for a given prefix. |
| `scripts/seed-data.ps1` | Seeds SQL, Cosmos DB, Blob storage, and Key Vault secrets after deployment. Called automatically by `deploy.ps1` when `seedDummyData: true` in the profile. |
| `scripts/helpers/common.ps1` | Shared logging, Azure CLI wrappers, and utility functions. Sourced by all other scripts. Not meant to be called directly. |
| `scripts/helpers/validate.ps1` | Pre-deployment validation: checks Azure CLI login, subscription access, resource group name availability, and expensive-resource warnings. |
| `scripts/runbooks/Start-AdeResources.ps1` | Automation Account runbook — starts all ADE-tagged VMs and scale sets. |
| `scripts/runbooks/Stop-AdeResources.ps1` | Automation Account runbook — stops (deallocates) all ADE-tagged VMs, scale sets, and AKS clusters. |
| `scripts/dashboard/Get-AdeCostDashboard.ps1` | Terminal dashboard for live cost and resource status. See [Cost dashboard](#cost-dashboard). |

---

## Cost guidance

> [!IMPORTANT]
> **Disclaimer:** Deploying resources from this repository will create billable Azure resources in your subscription. The author of this project accepts **no responsibility** for any charges, costs, or overspend incurred by anyone using this code. Always configure [Azure Cost Management budgets](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets) with email alerts before deploying, and tear down environments when they are not in use.

Most modules are inexpensive at rest. The following resources carry meaningful ongoing cost:

| Resource | Approximate monthly cost |
| --- | --- |
| Azure Firewall Standard | ~$900 |
| Azure Firewall Premium | ~$1,500 |
| DDoS Network Protection | ~$2,944 — **enable only when you explicitly need it** |
| VPN Gateway (VpnGw1) | ~$140 |
| Application Gateway WAF v2 (idle) | ~$200–300 |
| Bastion Basic/Standard | ~$140–200 (Developer SKU is free) |
| AKS (1-node `Standard_B2s`) | ~$30–50 |
| SQL Managed Instance | ~$1,000+ |
| Defender for Servers (per VM) | ~$15/VM/month |
| Microsoft Sentinel (per GB) | ~$2.46/GB ingested |

The deployment script warns you before deploying any expensive resources and shows an estimated cost total. The `governance` module creates a budget alert that emails you when spend reaches 80% and 100% of the configured threshold.

### Keeping costs low during testing

- Use the `minimal` profile to start.
- Enable `autoShutdown: true` — VMs are deallocated every evening at 19:00 UTC automatically.
- Destroy the environment when not in use: `./scripts/destroy.ps1 -Prefix ade -Force`
- Use [the cost dashboard](#cost-dashboard) to spot unexpected spend.

---

## Seed data

When `seedDummyData: true` is set in a profile (or when the `seed_data` input is enabled in the GitHub Actions workflow), the deployment automatically runs `scripts/seed-data.ps1` after all modules are deployed.

What gets seeded:

| Target | Data |
| --- | --- |
| Azure Blob Storage | Sample text and JSON files (`data/blob/`) |
| Cosmos DB | Sample JSON documents (`data/cosmos/`) |
| Azure SQL | AdventureWorksLT sample database (built into the SQL resource itself — no script required) |
| Key Vault | Demo secrets for connection strings (read by the web app at runtime) |

You can also run the seed script manually against an already-deployed environment:

```powershell
./scripts/seed-data.ps1 -Prefix ade -SubscriptionId "<sub-id>"
```

---

## Auto start/stop

The `governance` module deploys an **Automation Account** with two runbooks and daily schedules:

- **Stop-AdeResources** — runs every evening (19:00 UTC by default). Deallocates all ADE-tagged VMs, scale sets, and AKS clusters.
- **Start-AdeResources** — runs every weekday morning (08:00 UTC). Starts them again if `autoStartEnabled` is `true` in the governance features.

The runbooks use the Automation Account's **system-assigned managed identity** — no passwords or secrets stored anywhere.

You can trigger them manually:

```powershell
# Stop all VMs immediately via the dashboard
./scripts/dashboard/Get-AdeCostDashboard.ps1 -Prefix ade -StopAll

# Start all VMs immediately
./scripts/dashboard/Get-AdeCostDashboard.ps1 -Prefix ade -StartAll
```

---

## Cost dashboard

A terminal-based live dashboard shows real-time resource status and current-month costs:

```powershell
# Show dashboard once
./scripts/dashboard/Get-AdeCostDashboard.ps1 -Prefix ade

# Auto-refresh every 60 seconds
./scripts/dashboard/Get-AdeCostDashboard.ps1 -Prefix ade -Watch
```

The dashboard shows:

- Current month cost per resource group and estimated month-end projection
- VM running/deallocated/stopped status
- Database and AKS cluster status
- Budget alert utilisation percentage

---

## Running tests

The test suite uses [Pester 5](https://pester.dev/) and runs entirely without Azure credentials — all Azure CLI calls are mocked.

```powershell
# Install Pester (one-time setup)
Install-Module Pester -RequiredVersion 5.7.1 -Force -Scope CurrentUser

# Run the full suite
./tests/Invoke-PesterSuite.ps1

# Run with CI-style output (used by GitHub Actions)
./tests/Invoke-PesterSuite.ps1 -CI
```

Current state: **442 passing, 0 failing, 28 skipped**.

Test coverage includes:

- Profile JSON schema validation
- `deploy.ps1` and `destroy.ps1` parameter validation
- Module deployment orchestration logic (module ordering, feature flag propagation)
- `validate.ps1` pre-flight checks
- JSON config correctness for all built-in profiles

---

## GitHub Actions setup

Three workflows are included:

| Workflow | File | Trigger | What it does |
| --- | --- | --- | --- |
| ADE — Lint | `lint.yml` | Every push and PR | Bicep lint, PSScriptAnalyzer, JSON validation, Pester tests |
| ADE — Deploy | `deploy.yml` | Manual (`workflow_dispatch`) | Deploys a chosen profile to Azure |
| ADE — Destroy | `destroy.yml` | Manual (`workflow_dispatch`) | Destroys all resource groups for a given prefix |

All workflows use **OIDC federated identity** — no long-lived secrets or service principal passwords. You set this up once.

### Step 1 — Create an App Registration

```bash
az ad app create --display-name "ade-github-actions"
```

Note the `appId` (client ID) and `id` (object ID) from the JSON output.

### Step 2 — Create a service principal

```bash
az ad sp create --id <appId>
```

### Step 3 — Add a federated credential

This configures Azure to trust tokens that GitHub Actions mints when running under a specific environment. The `subject` field must match exactly — including the environment name (`demo`).

```bash
az ad app federated-credential create \
  --id <objectId> \
  --parameters '{
    "name": "ade-github-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<your-github-org>/<your-repo-name>:environment:demo",
    "audiences": ["api://AzureADTokenAudience"]
  }'
```

**Why `environment:demo`?** The deploy and destroy workflows specify `environment: demo`, which scopes OIDC tokens to that environment. If you name the GitHub environment differently, update the `subject` to match.

### Step 4 — Assign roles to the service principal

```bash
# Required for deploying all resources
az role assignment create \
  --assignee <appId> \
  --role Contributor \
  --scope /subscriptions/<subscription-id>

# Required for governance module (policy assignments, resource locks)
az role assignment create \
  --assignee <appId> \
  --role "User Access Administrator" \
  --scope /subscriptions/<subscription-id>
```

### Step 5 — Create the GitHub environment

In your repo: **Settings → Environments → New environment**

- Name it exactly `demo`
- Set **Deployment branches** to `main` only
- Add yourself as a **required reviewer** (strongly recommended — prevents accidental deploys triggered by a misclick)

### Step 6 — Add secrets to the `demo` environment

In **Settings → Environments → demo → Environment secrets → Add secret**:

| Secret name | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | The `appId` from Step 1 |
| `AZURE_TENANT_ID` | Run: `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | Run: `az account show --query id -o tsv` |
| `ADE_ADMIN_PASSWORD` | VM admin password (min 12 chars, must contain uppercase, lowercase, digit, and symbol) |

Store these at **environment** scope, not repository scope. Environment-scoped secrets are only accessible to workflow jobs that have passed the environment's protection rules (your review gate).

### Step 7 — (Optional) Set Actions variables

In **Settings → Secrets and variables → Actions → Variables → New repository variable**:

| Variable name | Example value |
| --- | --- |
| `ADE_DEFAULT_LOCATION` | `westeurope` |
| `ADE_DEFAULT_PREFIX` | `ade` |

These pre-fill the workflow dispatch inputs so you don't have to type them every time.

### Step 8 — Verify OIDC setup

```bash
az ad app federated-credential list --id <objectId> --query "[].subject" -o tsv
```

Expected output:

```text
repo:<your-github-org>/<your-repo-name>:environment:demo
```

### Triggering a deploy from GitHub

1. Go to **Actions → ADE — Deploy → Run workflow**
2. Select profile, mode, region, prefix
3. Approve the deployment in the `demo` environment review gate
4. Watch the live log

---

## Repository structure

```text
azure-demo-environment/
├── bicep/
│   ├── modules/                  Default (out-of-box) Bicep modules — one folder per module
│   └── hardened/                 CIS/MCSB-hardened variants of each module
├── config/
│   ├── profiles/                 Built-in deployment profiles (JSON)
│   │   ├── full.json
│   │   ├── minimal.json
│   │   ├── compute-only.json
│   │   ├── databases-only.json
│   │   ├── networking-only.json
│   │   └── security-focus.json
│   └── schema.json               JSON Schema for custom profile validation
├── data/
│   ├── blob/                     Sample blob files for storage seeding
│   ├── cosmos/                   Sample Cosmos DB documents
│   └── sql/                      SQL scripts (if any supplementary SQL is needed)
├── docs/
│   ├── architecture.md           Detailed architecture + module dependency diagram
│   ├── benchmark-guide.md        CIS/MCSB benchmark testing methodology
│   ├── test-plan.md              Test coverage and Pester suite structure
│   └── usage.md                  Extended usage examples and advanced scenarios
├── policies/
│   ├── definitions/              Custom Azure Policy definition JSON files
│   ├── initiatives/              Custom policy set (initiative) definitions
│   └── Deploy-AdePolicies.ps1    Script to assign policies outside of a full deploy
├── scripts/
│   ├── deploy.ps1                Main deployment orchestrator
│   ├── destroy.ps1               Environment teardown
│   ├── seed-data.ps1             Post-deploy data seeding
│   ├── helpers/
│   │   ├── common.ps1            Shared logging + Azure CLI utility functions
│   │   └── validate.ps1          Pre-deployment validation and confirmation
│   ├── runbooks/
│   │   ├── Start-AdeResources.ps1  Auto-start runbook (Automation Account)
│   │   └── Stop-AdeResources.ps1   Auto-stop runbook (Automation Account)
│   └── dashboard/
│       └── Get-AdeCostDashboard.ps1  Live cost and status dashboard
├── tests/
│   ├── Invoke-PesterSuite.ps1    Test runner entry point
│   ├── deploy.Tests.ps1          Tests for deploy.ps1 logic
│   ├── destroy.Tests.ps1         Tests for destroy.ps1 logic
│   └── helpers/                  Test helpers and mock setup
├── .github/
│   └── workflows/
│       ├── lint.yml              Lint pipeline (Bicep + PS + JSON + Pester)
│       ├── deploy.yml            Deploy pipeline (manual trigger)
│       └── destroy.yml           Destroy pipeline (manual trigger)
├── .config/
│   └── PSScriptAnalyzerSettings.psd1  PSScriptAnalyzer rule configuration
└── README.md
```

---

## CIS / MCSB benchmark guide

### The before/after approach

ADE is designed for **paired benchmark comparisons**:

1. Deploy with `-Mode default` — Azure out-of-the-box settings, no hardening.
2. Run a compliance scan and record the score.
3. Deploy with `-Mode hardened` to the same subscription (same prefix or a parallel prefix).
4. Re-run the scan and compare.

### CIS Azure Foundations Benchmark v2.0 — control coverage

| CIS Section | Topic | ADE module | Hardened control |
| --- | --- | --- | --- |
| 1.x | Identity and access management | `security`, `governance` | Key Vault RBAC, managed identity |
| 2.1 | Microsoft Defender for Cloud | `security` | All Defender plans enabled |
| 2.2 | Defender recommendations | `governance` | Policy assignments in Enforce mode |
| 3.x | Storage accounts | `storage` | HTTPS-only, public access disabled, infrastructure encryption |
| 4.x | Databases | `databases` | TLS 1.2, Azure AD auth, Transparent Data Encryption, Threat Detection |
| 5.x | Logging and monitoring | `monitoring`, `governance` | Diagnostic settings, Activity Log alerts, Sentinel |
| 6.x | Networking | `networking` | NSG rules, Bastion, no management ports exposed |
| 7.x | Virtual machines | `compute` | AMA extension, Defender for Endpoint, disk encryption, no public IPs |
| 8.x | App services | `appservices` | HTTPS-only, TLS 1.2, managed identity, FTP disabled |
| 9.x | Key Vault | `security` | Purge protection, soft delete, private endpoints |

> **Not in scope:** Section 1.x Entra ID tenant-level settings (MFA, SSPR, Conditional Access, guest access) require tenant-admin permissions and cannot be managed with subscription-scoped IaC.

### Running a compliance scan

#### Option 1 — Defender for Cloud (Azure portal)

1. Open **Microsoft Defender for Cloud → Regulatory compliance**
2. Select **CIS Azure Foundations Benchmark v2.0** or **Microsoft Cloud Security Benchmark**
3. Expand controls to see compliant vs. non-compliant resources

#### Option 2 — Azure Policy via CLI

```bash
# Overall compliance summary for the subscription
az policy state summarize \
  --subscription <subscription-id> \
  --query "results.policyDetails[].{policy:policyDefinitionId,compliant:results.compliantResources,noncompliant:results.nonCompliantResources}" \
  -o table

# Compliance for all ADE resource groups only (filter by prefix)
az policy state list \
  --subscription <subscription-id> \
  --filter "resourceGroup eq 'ade-compute-rg'" \
  --query "[?complianceState=='NonCompliant'].{resource:resourceId,policy:policyDefinitionId}" \
  -o table
```

---

## License

MIT
