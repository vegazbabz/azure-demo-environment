# ADE Reference

Feature flags, script parameters, custom profiles, and repository layout. Moved here from the README to keep it scannable; content is authoritative.

---

## Feature flags

Every profile JSON controls exactly which sub-features are deployed within each module. These are the available flags:

### `monitoring`

Log Analytics Workspace, Application Insights, and Action Group are **always deployed** by the monitoring module — they cannot be toggled off.

| Flag | Default | Description |
| --- | --- | --- |
| `alertRules` | `false` | Pre-built alert rules (high CPU, disk, etc.) |
| `alertEmail` | `""` | Email address for alert Action Group notifications. Leave empty to skip email delivery. |

### `networking`

| Flag | Default | Description |
| --- | --- | --- |
| `bastionSku` | `"Developer"` | `None` = no Bastion deployed. `Developer` = free (shared, no dedicated subnet). `Basic`/`Standard` = dedicated subnet + hourly cost |
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
| `allowedCidrRanges` | `[]` | IP/CIDR ranges permitted through the Key Vault firewall. Empty = no network rule (Azure default — open to all). |

### `compute`

| Flag | Default | Description |
| --- | --- | --- |
| `windowsVm` | `true` | Windows Server 2022 VM |
| `linuxVm` | `false` | Ubuntu 22.04 LTS VM — opt-in only |
| `vmss` | `false` | VM Scale Set |
| `enableAutoShutdown` | varies per profile | Daily auto-shutdown at 19:00 UTC (saves cost) |
| `vmSku` | `"Standard_B2s"` | VM size — change to `Standard_D2s_v3` or larger if needed |
| `domainController` | `false` | Deploy an Active Directory Domain Controller (Windows Server 2022). Installs AD DS and promotes the VM to a forest root DC. Static IP `10.0.15.4` in the management subnet. VNet DNS is automatically pointed at the DC when enabled. |
| `domainName` | `""` | FQDN for the AD forest (e.g. `corp.contoso.local`). Defaults to `<prefix>.local` when left empty. |

### `storage`

A General-purpose v2 Storage Account (including Blob, Queue, Table, and File services) is **always deployed**. It cannot be disabled independently of the module.

| Flag | Default | Description |
| --- | --- | --- |
| `dataLakeGen2` | varies | Hierarchical namespace (ADLS Gen2) storage account |
| `enableSoftDelete` | `false` | Blob soft delete (7-day retention) |
| `enableVersioning` | `false` | Blob versioning (independent of soft delete) |
| `allowedCidrRanges` | `[]` | IP/CIDR ranges permitted through the storage account firewall. Empty = no network rule (Azure default — open to all). |

### `databases`

| Flag | Default | Description |
| --- | --- | --- |
| `sqlDatabase` | `true` | Azure SQL Server + Serverless Database (AdventureWorksLT) |
| `sqlVm` | `false` | SQL Server 2022 on a Windows VM (IaaS) — opt-in only |
| `cosmosDb` | `true` | Cosmos DB (NoSQL, serverless) |
| `postgresql` | `false` | PostgreSQL Flexible Server — opt-in only |
| `mysql` | `false` | MySQL Flexible Server — opt-in only |
| `redis` | `false` | Redis Cache (~$16/month Basic C0) — opt-in only |
| `sqlManagedInstance` | `false` | Azure SQL Managed Instance (~$1,000+/month) — opt-in only, very expensive |
| `allowAllSqlIngress` | `false` | Create the `AllowAll` (0.0.0.0–255.255.255.255) SQL firewall rule — **opens the SQL server to the entire internet**. Opt-in only, for reproducing the CIS 4.1.2 baseline finding. By default the firewall is scoped to Azure services + the deployer's public IP. |

### `appservices`

| Flag | Default | Description |
| --- | --- | --- |
| `windowsWebApp` | `true` | Windows Web App (B1 App Service Plan) |
| `functionApp` | `true` | Function App (Consumption plan) |
| `logicApp` | `true` | Logic App (Standard) |

### `containers`

| Flag | Default | Description |
| --- | --- | --- |
| `containerRegistry` | `true` | Azure Container Registry (Basic SKU) |
| `kubernetesService` | `true` | AKS (1-node, free tier control plane, `Standard_B2s`) |
| `containerApps` | `true` | Container Apps Environment + sample Container App |
| `containerInstances` | `true` | Container Instances |

### `integration`

| Flag | Default | Description |
| --- | --- | --- |
| `serviceBus` | `true` | Service Bus namespace (Standard tier) with two sample queues |
| `eventHub` | `true` | Event Hub namespace (Basic tier) with a sample hub |
| `eventGrid` | `true` | Event Grid system topic |
| `signalR` | `true` | SignalR Service (Free tier) |
| `apiManagement` | `false` | API Management gateway (~$50/month Developer tier) |
| `apimSku` | `"Developer"` | APIM SKU: `Developer` (~$50/mo), `Basic`, or `Standard` (~$750/mo). Only used when `apiManagement` is `true`. |

### `ai`

> All AI resources are **off by default** due to quota requirements and unpredictable cost. Enable individually in a custom profile.

| Flag | Default | Description |
| --- | --- | --- |
| `aiServices` | `false` | Azure AI Services multi-service account (S0) |
| `openAi` | `false` | Azure OpenAI Service with GPT-4o deployment. Requires quota approval in your subscription. |
| `cognitiveSearch` | `false` | Azure Cognitive Search (~$250/month Standard) |
| `cognitiveSearchSku` | `"basic"` | Cognitive Search SKU: `free` (1 per subscription), `basic` (~$75/mo), `standard` (~$250/mo), `standard2`, `standard3`. All paid SKUs have limited availability in some regions — if you hit `ResourcesForSkuUnavailable`, try a different SKU or deploy to a different region. |
| `machineLearning` | `false` | Azure Machine Learning workspace |

### `data`

| Flag | Default | Description |
| --- | --- | --- |
| `dataFactory` | `false` | Azure Data Factory with a sample linked service to the storage module |
| `synapse` | `false` | Azure Synapse Analytics workspace (costs vary by usage) |
| `databricks` | `false` | Azure Databricks workspace (costs vary by cluster usage) |
| `purview` | `false` | Microsoft Purview account (~$50+/month) |

### `governance`

| Flag | Default | Description |
| --- | --- | --- |
| `automationAccount` | varies | Automation Account with auto-stop/start runbooks and daily schedules |
| `budget` | `true` | Monthly budget with email alerts at 80% and 100% spend. Requires `budgetAlertEmail` or `-BudgetAlertEmail`; otherwise budget deployment is skipped. |
| `budgetAmount` | varies | Monthly budget limit in USD |
| `budgetAlertEmail` | `""` | Email address for budget alert notifications. If omitted in an interactive run, `deploy.ps1` prompts before showing the deployment summary. In `-Force`, `-WhatIf`, CI, and GitHub Actions runs, no prompt is shown and budget deployment is skipped unless `-BudgetAlertEmail` is provided. |
| `resourceLocks` | `false` | CanNotDelete lock on the networking resource group |
| `policyAssignments` | `false` | CIS Benchmark + MCSB policy initiative assignments (audit mode) |
| `autoShutdownTime` | `"1900"` | Daily auto-shutdown time in HHMM format (e.g. `"1900"` = 19:00 UTC). |
| `autoShutdownTimezone` | `"UTC"` | Timezone for the auto-shutdown/start schedules. |
| `autoStartEnabled` | `false` | Enable daily auto-start at 08:00 on weekdays. Requires `automationAccount: true`. |

---

## All deploy.ps1 parameters

```powershell
./scripts/deploy.ps1 [parameters]
```

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `-Profile` | string | `full` | Built-in profile name or path to a custom JSON file |
| `-Location` | string | `westeurope` | Azure region. Use `az account list-locations --query "[].name" -o tsv` to list all. |
| `-Prefix` | string | `ade` | 2–8 lowercase alphanumeric characters (e.g. `ade`, `demo`, `contoso`). Becomes part of every resource group name and most resource names. |
| `-SubscriptionId` | string | current account | Target subscription. Defaults to whatever `az account show` returns. |
| `-AdminUsername` | string | `adeadmin` | VM and database administrator username |
| `-AdminPassword` | SecureString | per-service generated | Optional override: one password for ALL services (VM / SQL / PostgreSQL / MySQL / Synapse), also stored per-service in the environment Key Vault. Must meet Azure complexity: 12+ chars, upper, lower, digit, symbol. When omitted, a separate password is generated per service and stored in Key Vault (`vm-admin-password`, `sql-admin-password`, `postgres-admin-password`, `mysql-admin-password`, `synapse-admin-password`). |
| `-AutoGeneratePassword` | switch | — | Force password generation even when no password-bearing module is enabled. With a Key Vault the password lands in the `vm-admin-password` secret; without one it is printed in a highlighted console banner. Cannot be combined with `-AdminPassword`. |
| `-Mode` | string | `default` | `default` or `hardened` |
| `-WhatIf` | switch | — | Run Bicep what-if on each module without actually deploying anything |
| `-Force` | switch | — | Skip the deployment confirmation prompt |
| `-ContinueOnError` | switch | — | Continue deploying remaining modules even if one fails. Without this switch the script prompts interactively (or aborts in CI) when a module fails. |
| `-SkipModules` | string[] | — | Module names to skip. Example: `-SkipModules containers,ai` |
| `-EnableModules` | string[] | — | Module names to force-enable regardless of profile. Example: `-EnableModules data`. When a disabled module is force-enabled, its boolean features are enabled too. |
| `-BudgetAlertEmail` | string | `""` | Email address for budget alert notifications. Overrides `budgetAlertEmail` in the profile. If omitted in interactive runs, `deploy.ps1` prompts before the deployment summary; non-interactive runs skip budget deployment unless this is set. |
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
./scripts/deploy.ps1 -Profile hardened -Mode hardened -Location westeurope -Prefix ade
```

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
        "alertRules": false,
        "alertEmail": ""
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
        "budgetAlertEmail": "",
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
| `scripts/destroy.ps1` | Deletes all ADE resource groups and discovered module-owned managed resource groups for a given prefix. |
| `scripts/seed-data.ps1` | Seeds 13 resource targets (Blob, Queue, Table, File Share, Cosmos DB, SQL, PostgreSQL, MySQL, Redis, Key Vault, Service Bus, Event Hub, Event Grid) after deployment. Called automatically by `deploy.ps1` when `seedDummyData: true` in the profile. See [Seed data](operations.md#seed-data). |
| `scripts/helpers/common.ps1` | Shared logging, Azure CLI wrappers, and utility functions. Sourced by all other scripts. Not meant to be called directly. |
| `scripts/helpers/validate.ps1` | Pre-deployment validation: checks Azure CLI login, subscription access, resource group name availability, and expensive-resource warnings. |
| `scripts/runbooks/Start-AdeResources.ps1` | Automation Account runbook — starts all ADE-tagged VMs and scale sets. |
| `scripts/runbooks/Stop-AdeResources.ps1` | Automation Account runbook — stops (deallocates) all ADE-tagged VMs, scale sets, and AKS clusters. |
| `scripts/dashboard/Get-AdeCostDashboard.ps1` | Terminal dashboard for live cost and resource status. See [Cost dashboard](operations.md#cost-dashboard). |

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
│   │   ├── security-focus.json
│   │   └── hardened.json
│   └── schema.json               JSON Schema for custom profile validation
├── data/
│   ├── blob/                     Sample blob files for storage seeding
│   ├── cosmos/                   Sample Cosmos DB documents
│   └── sql/                      SQL scripts (if any supplementary SQL is needed)
├── docs/
│   ├── architecture.md           Detailed architecture + module dependency diagram
│   ├── benchmark-guide.md        CIS/MCSB benchmark testing methodology
│   ├── commands.md               Common local command reference
│   ├── network-topology.mmd      Mermaid network topology diagram
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
│       ├── destroy.yml           Destroy pipeline (manual trigger)
│       └── release.yml           Release pipeline (tag trigger)
├── .config/
│   └── PSScriptAnalyzerSettings.psd1  PSScriptAnalyzer rule configuration
└── README.md
```

---
