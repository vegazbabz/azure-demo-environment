# Architecture Overview

Azure Demo Environment (ADE) is a modular, multi-tier infrastructure-as-code project for deploying
a representative Azure workload used as a **benchmark baseline** for security posture assessments
(CIS Azure Foundations, Microsoft Cloud Security Benchmark, Defender CSPM).

---

## Repository Layout

```
azure-demo-environment/
├── bicep/
│   ├── modules/          Default (out-of-box Azure settings) — benchmark baseline
│   └── hardened/         CIS/MCSB-aligned hardened variants
├── config/
│   └── profiles/         Deployment profile JSON files
├── policies/
│   ├── definitions/      Custom Azure Policy definition JSON
│   ├── initiatives/      Custom policy set definition JSON
│   └── Deploy-AdePolicies.ps1
├── scripts/
│   ├── deploy.ps1        Main orchestration script
│   ├── destroy.ps1       Teardown script
│   ├── helpers/          common.ps1, validate.ps1
│   └── runbooks/         Start/Stop automation runbooks
└── .github/workflows/    CI/CD (deploy, destroy, lint)
```

---

## Module Dependency Order

Modules are deployed in strict dependency order so that downstream modules can reference outputs
from upstream ones (e.g. `logAnalyticsWorkspaceId`, `vnetId`, `keyVaultId`).

```
monitoring
    └── networking
            └── security
                    └── compute
                            └── storage
                                    └── databases
                                            └── appservices
                                                    └── containers
                                                            └── integration
                                                                    └── ai
                                                                            └── data
                                                                                    └── governance
```

| Module | Resource Group | Key Resources |
|---|---|---|
| `monitoring` | `{prefix}-monitoring-rg` | Log Analytics Workspace, Application Insights |
| `networking` | `{prefix}-networking-rg` | VNet, NSGs, Bastion, optional App Gateway |
| `security` | `{prefix}-security-rg` | Key Vault, Managed Identity, Defender plans |
| `compute` | `{prefix}-compute-rg` | VMs (Windows + Linux), VMSS, Load Balancer |
| `storage` | `{prefix}-storage-rg` | Storage Accounts, File Shares |
| `databases` | `{prefix}-databases-rg` | Azure SQL, Cosmos DB, PostgreSQL, MySQL, Redis |
| `appservices` | `{prefix}-appservices-rg` | App Service Plan, Web App, Function App |
| `containers` | `{prefix}-containers-rg` | AKS, Container Registry |
| *(AKS node RG)* | `MC_{prefix}-containers-rg_{prefix}-aks_{region}` | **Auto-created by Azure** — see note below |
| `integration` | `{prefix}-integration-rg` | Service Bus, Event Hub, Event Grid, SignalR; optional API Management |
| `ai` | `{prefix}-ai-rg` | OpenAI, Cognitive Services |
| `data` | `{prefix}-data-rg` | Data Factory, Synapse, Databricks |
| `governance` | `{prefix}-governance-rg` | Budgets, Policy Assignments, Activity Alerts |

> **AKS node resource group:** When the `containers` module deploys an AKS cluster, the Azure AKS
> resource provider **automatically creates a second resource group** named
> `MC_<resourceGroup>_<clusterName>_<region>` (e.g. `MC_adetest-containers-rg_adetest-aks_swedencentral`).
> This group holds the underlying node VMs, VMSS, disks, and NICs that AKS manages.
> It does **not** follow the ADE `{prefix}-*-rg` convention because it is created and owned by the
> Azure platform, not by this repo. Do not modify or delete it manually — AKS controls it.
> `destroy.ps1` automatically discovers and deletes it via `az aks show --query nodeResourceGroup`
> when the `containers` module is torn down.
> See [Microsoft docs — Why are two resource groups created with AKS?](https://learn.microsoft.com/en-us/azure/aks/faq#why-are-two-resource-groups-created-with-aks-)

---

## Deployment Modes

### `default` mode (`bicep/modules/`)

Deploys with **out-of-box Azure settings** — no hardening, no enforced TLS version, public network
access left at defaults. This represents what a typical customer sees before any security baseline
is applied. Use this mode to generate a "before" snapshot for benchmark comparisons.

### `hardened` mode (`bicep/hardened/`)

Deploys CIS/MCSB-aligned configuration:

| Control area | Hardened setting |
|---|---|
| TLS | Minimum TLS 1.2 enforced everywhere |
| Public network access | Disabled by default; private endpoints used |
| Key Vault | Purge protection + soft delete enabled; RBAC authorization |
| Defender for Cloud | All plans enabled; auto-provisioning on |
| Diagnostic settings | All resources emit to Log Analytics |
| Resource locks | `CanNotDelete` locks applied to critical resources |
| Policy | Assignments in `Enforce` mode (not `DoNotEnforce`) |
| VM extensions | AMA, Defender for Endpoint, dependency agent |
| Storage | HTTPS only, infrastructure encryption, public blob access off |

---

## Profile System

Profiles (in `config/profiles/`) control **which modules are deployed**. Mode controls **how** they
are deployed. These are orthogonal — you can run `compute-only` profile in `hardened` mode.

| Profile | Modules enabled | Intended use |
|---|---|---|
| `full` | 10 standard modules (`ai` and `data` disabled) | Complete standard CIS coverage without quota-heavy AI/data services |
| `minimal` | monitoring, networking, security, compute, storage | Cost-conscious demo |
| `compute-only` | monitoring, networking, security, compute | CIS Compute sections |
| `databases-only` | monitoring, networking, security, databases | CIS Database sections |
| `networking-only` | monitoring, networking | CIS Network sections 6.x |
| `security-focus` | monitoring, networking, security, compute, storage, databases, governance | CIS IAM + Logging plus Defender coverage |
| `hardened` | 10 standard modules (hardened templates; `ai` and `data` disabled) | Hardened deployment without quota-heavy AI/data services |

---

## CI/CD Workflows

| Workflow | File | Trigger |
|---|---|---|
| Lint + what-if | `.github/workflows/lint.yml` | PR, push to `main` |
| Deploy | `.github/workflows/deploy.yml` | Manual (`workflow_dispatch`) |
| Destroy | `.github/workflows/destroy.yml` | Manual |

The deploy workflow requires three GitHub Actions secrets:
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `ADE_ADMIN_PASSWORD`

Authentication uses **OIDC federated credentials** — no long-lived secrets stored in GitHub.
