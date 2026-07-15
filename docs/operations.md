# ADE Operations

Day-2 operations: seeding data, auto start/stop, the cost dashboard, and CI/CD setup.

---

## Seed data

When `seedDummyData: true` is set in a profile (or when the `seed_data` input is enabled in the GitHub Actions workflow), the deployment automatically runs `scripts/seed-data.ps1` after all modules are deployed.

What gets seeded:

| Target | Data | Notes |
| --- | --- | --- |
| Blob Storage | Sample JSON and CSV files (`data/blob/`) uploaded to `data`, `logs`, `public` containers | — |
| Storage Queue | `demo-tasks` queue with sample task messages | — |
| Storage Table | `demotable` with sample device and config entities | — |
| Storage File Share | `welcome.txt` uploaded to the provisioned share | — |
| Cosmos DB | Sample order documents from `data/cosmos/` | — |
| Azure SQL | AdventureWorksLT sample database (built into the resource — no script needed) | Password fetched from Key Vault (`sql-admin-password`) or `-DatabaseAdminPassword` |
| PostgreSQL | `demo_products` + `demo_orders` tables with sample rows | Password from Key Vault (`postgres-admin-password`) or `-DatabaseAdminPassword`; requires `psql` client — see note below |
| MySQL | `demo_events` + `demo_devices` tables with sample rows | Password from Key Vault (`mysql-admin-password`) or `-DatabaseAdminPassword`; requires `mysql` client — see note below |
| Redis Cache | Demo keys set via TLS RESP connection | — |
| Key Vault | Demo secrets, RSA 2048 encryption key, and self-signed TLS certificate | Requires Key Vault Administrator role |
| Service Bus | Test messages sent to the `orders` queue | — |
| Event Hub | Telemetry events sent to the `telemetry` hub via REST | — |
| Event Grid | Demo events published to the custom topic | — |

> [!NOTE]
> **Hardened-mode environments:** SQL, PostgreSQL, and MySQL are deployed behind private endpoints in `hardened` mode. Seeding requires running `seed-data.ps1` from within the VNet — for example, via Bastion or a jump VM. Seeding from a public workstation will result in connection timeouts for those three targets.

> [!NOTE]
> **PostgreSQL and MySQL seeding** requires the native client tools (`psql` for PostgreSQL, `mysql` for MySQL) to be installed on the machine running `seed-data.ps1`. If the tools are not found, seeding is skipped automatically with an informational message — no error is raised. These are **not** installed by this project.
>
> **Recommended alternatives if you don't have the clients installed:**
> - **Azure Cloud Shell** — both `psql` and `mysql` are pre-installed. Run `seed-data.ps1` from there.
> - **Install locally** — [PostgreSQL client tools](https://www.postgresql.org/download/) (includes `psql`) or [MySQL Shell](https://dev.mysql.com/downloads/shell/).
> - **Azure Portal** — use the built-in query editor for PostgreSQL or MySQL to run the seed SQL files manually from `data/postgres/seed.sql` / `data/mysql/seed.sql`.
>
> PostgreSQL and MySQL are **opt-in** in all profiles (`postgresql: false`, `mysql: false` by default). Enable them explicitly in your profile's `databases.features` if needed.

SQL, PostgreSQL, and MySQL passwords are fetched automatically from the environment Key Vault (written there by `deploy.ps1`); pass `-DatabaseAdminPassword` only to override. A service is skipped automatically when neither source is available. All other targets are seeded without credentials.

You can run the seed script manually against an already-deployed environment:

```powershell
# Seed all targets — database passwords fetched from the environment Key Vault
./scripts/seed-data.ps1 -Prefix ade

# Override the database password explicitly (e.g. no Key Vault in the profile)
./scripts/seed-data.ps1 -Prefix ade -DatabaseAdminPassword 'YourPassword123!'

# Seed only specific targets
./scripts/seed-data.ps1 -Prefix ade -Modules storage,redis,keyvault -Force
```

> [!NOTE]
> Wrap the password in **single quotes** so PowerShell does not expand special characters such as `$`. The script exits with code **1** and prints a `[WARN]` summary if any SQL / PostgreSQL / MySQL seed step fails, so callers and CI pipelines can detect partial failures.

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

## GitHub Actions setup

Four workflows are included:

| Workflow | File | Trigger | What it does |
| --- | --- | --- | --- |
| ADE — Lint | `lint.yml` | Every push and PR | Bicep lint, PSScriptAnalyzer, JSON validation, Pester tests |
| ADE — Deploy | `deploy.yml` | Manual (`workflow_dispatch`) | Deploys a chosen profile to Azure |
| ADE — Destroy | `destroy.yml` | Manual (`workflow_dispatch`) | Destroys all resource groups for a given prefix |
| ADE — Release | `release.yml` | Push of `v*.*.*` tag | Extracts the matching CHANGELOG.md section and creates a GitHub Release |

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
| `ADE_ADMIN_PASSWORD` | Admin password used for all services in CI deploys (min 12 chars, must contain uppercase, lowercase, digit, and symbol). Stored per-service in the environment Key Vault by the deploy step; the seed step reads it from there. |

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
