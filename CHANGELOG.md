# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed
- `bicep/hardened/databases/databases.bicep`: every hardened deployment with `sqlDatabase: true` failed ARM preflight on two counts — (1) the `AllowAllWindowsAzureIps` firewall rule is rejected when `publicNetworkAccess` is `Disabled` (`DenyPublicEndpointEnabled`); the rule is removed since access is private-endpoint-only, and (2) the classic vulnerability-assessment resource requires a storage container (`storageContainerPath` cannot be empty); replaced with Defender for SQL express configuration (`Microsoft.Sql/servers/sqlVulnerabilityAssessments`), which stores scan results in the database and needs no storage account

---

## [2.0.0] - 2026-07-14

### Security
- Per-service admin passwords stored in Key Vault: `deploy.ps1` now generates a separate cryptographically random password for each service (VM/VMSS/DC, SQL, PostgreSQL, MySQL, Synapse) and stores them in the environment Key Vault (`vm-admin-password`, `sql-admin-password`, `postgres-admin-password`, `mysql-admin-password`, `synapse-admin-password`) instead of one shared password printed to the terminal. Existing secrets are reused on redeploy (no rotation); unreadable secrets fail closed. `seed-data.ps1` fetches passwords from Key Vault automatically — `-DatabaseAdminPassword` is now an optional override. `-AdminPassword` keeps its legacy meaning (one value for all services) and is also synced to Key Vault. Profiles without a Key Vault fall back to the previous single-password console-banner behavior
- `data` module (default mode): the predictable `SynapseDemo#<uniqueString>` fallback password is replaced by the stored `synapse-admin-password` secret whenever the synapse feature is enabled
- `databases` module: the internet-wide `AllowAll` SQL firewall rule (0.0.0.0–255.255.255.255) is no longer created by default — now opt-in via `databases.features.allowAllSqlIngress` (kept for reproducing the CIS 4.1.2 baseline finding). The default firewall is scoped to Azure services plus a single-IP `AllowDeployerIp` rule detected at deploy time (`Get-AdeDeployerPublicIp`), so `seed-data.ps1` keeps working. `deploy.ps1` also removes a stale `AllowAll` rule left by deployments made before this change
- `deploy.ps1`: irreversible pre-flight operations (Failed-state Container Apps Environment delete, ML workspace permanent delete) now require interactive confirmation via `Confirm-AdeDestructiveAction` (default No); auto-approved under `-Force`/CI with a logged warning

### Changed
- CI workflows (`deploy.yml`, `lint.yml`): Bicep CLI pinned to v0.44.1 instead of installing the latest release on every run — reproducible lint/deploy results, no unreviewed-release drift

### Fixed
- `deploy.yml`: the seed step passed a `SecureString` into `seed-data.ps1`'s `[string]$DatabaseAdminPassword` parameter, which binds as the literal text `System.Security.SecureString` — CI database seeding never actually authenticated. The seed step now takes no password and reads the per-service secrets from Key Vault
- `bicep/hardened/monitoring/monitoring.bicep`: the data collection rule used the `Microsoft-SecurityEvent` stream, which ARM only accepts in DCRs created by the Sentinel 'Windows Security Events via AMA' connector — every hardened-mode deployment failed in the monitoring module with `InvalidPayload: Data collection rule is invalid`. Security-channel events now use the standard `Microsoft-Event` stream with the same xPath filter
- `bicep/hardened/networking/networking.bicep`: removed the explicit NetworkWatcher resource — Azure auto-creates one per region (quota = 1), so hardened networking always failed with `ResourceCountExceedsLimitDueToTemplate` on subscriptions that already had the platform-managed watcher. Same fix as the default module (PR #114)
- `bicep/hardened/security/security.bicep`: declared the missing `deployerPrincipalType` parameter (deploy.ps1 passes it in both modes — hardened security deployments failed with an undeclared-parameter error) and the Key Vault Secrets Officer role assignment no longer hard-codes `principalType: 'User'`, fixing service-principal (CI/OIDC) hardened deploys
- `deploy.ps1`: `allowedCidrRanges` / `aksAuthorizedIpRanges` with exactly one entry crashed with `The property 'Count' cannot be found on this object` — PowerShell unwraps single-element JSON arrays to scalars and `.Count` on a string throws under StrictMode; values are now normalized with `@()` so Bicep also always receives an array
- `deploy.ps1`: the ML workspace pre-flight permanent-delete no longer runs when `ai.features.machineLearning` is disabled — previously it could permanently destroy an existing workspace without recreating it
- `deploy.ps1`: `-WhatIf` no longer performs destructive pre-flight operations (Container Apps Environment delete, ML workspace delete, Cognitive Services purge) — a `What if: would ...` line is logged instead
- `seed-data.ps1`: replaced removed `az postgres/mysql flexible-server execute` commands (removed in Azure CLI 2.85.0) with native `psql`/`mysql` CLI calls; seeding is skipped automatically with an informational message when the client tool is not installed
- `seed-data.ps1`: stripped `USE <db>;` statement before SQL batch execution to prevent Azure SQL parse errors
- `postgresql` feature flag set to `false` by default in all profiles (`full`, `hardened`, `databases-only`) — now consistent with `mysql` (opt-in only)
- `destroy.ps1`: `-WhatIf` no longer deletes real resources — `Remove-AdeResourceGroup` now wraps `az group delete` and lock removal in `$PSCmdlet.ShouldProcess()` guards
- `deploy.ps1`: `-EnableModules` no longer creates empty resource groups — all `false` boolean features in a previously-disabled module are auto-enabled when the module is force-enabled via `-EnableModules`
- `deploy.ps1`: interactive prompt added when `budget: true` but `budgetAlertEmail` is not set and running outside CI

### Documentation
- `deploy.ps1` help block: corrected `databases-only` profile description (`SQL + Cosmos DB`, not `SQL, Cosmos, PostgreSQL, MySQL, Redis`)
- `README.md`: corrected `data` module default resources column — all features are opt-in (matches `ai` module)
- `README.md`: updated test count to 577
- `README.md`: documented `bastionSku: "None"` as valid value to skip Bastion deployment
- `README.md`: added cost warning for `-EnableModules data` (auto-enables Synapse, Databricks, Purview)
- `config/schema.json`: added missing feature properties (`alertEmail`, `allowedCidrRanges`, `domainController`, `domainName`, `sqlVm`, `aksAuthorizedIpRanges`, `budgetAlertEmail`, `autoShutdownTime`, `autoShutdownTimezone`, `autoStartEnabled`, `apimPublisherEmail`, `apimPublisherName`) so the schema accurately reflects all valid profile properties

---

## [1.0.0] - 2026-04-09

### Added
- Full Bicep module library: `ai`, `appservices`, `compute`, `containers`, `data`, `databases`, `governance`, `integration`, `monitoring`, `networking`, `security`, `storage`
- Hardened mode (`bicep/hardened/`) with private endpoints, managed identities, AKS RBAC, and Policy assignments
- Deployment profiles: `minimal`, `full`, `compute-only`, `databases-only`, `networking-only`, `security-focus`, `hardened`
- `deploy.ps1` and `destroy.ps1` orchestration scripts with WhatIf, profile, and skip-module support
- `seed-data.ps1` for populating Storage, Cosmos DB, Azure SQL, PostgreSQL, MySQL, Redis, and Key Vault
- Automation runbooks: `Start-AdeResources.ps1`, `Stop-AdeResources.ps1`
- Cost dashboard script `Get-AdeCostDashboard.ps1`
- Azure Policy definitions and initiative (`ade-governance-initiative`)
- CI pipeline: Bicep lint, JSON validation, PSScriptAnalyzer, Pester unit tests (544 passing)
- Deploy and Destroy GitHub Actions workflows with OIDC authentication
- Managed identity role assignments for Function App and Logic App
- Domain Controller VM support in compute and networking modules
- Hardened Cosmos DB: `disableLocalAuth` check before key-based seeding
- AKS authorized IP ranges wired through to `apiServerAccessProfile`
- File share private endpoint and DNS zone group in hardened storage
- GitHub repository hardening: SHA-pinned actions, input validation, concurrency groups, Dependabot
- `LICENSE` (MIT), `SECURITY.md`, `CONTRIBUTING.md`
- Pre-release manual test checklist (`docs/pre-release-checklist.md`) covering all 12 modules and CIS v5.0.0 spot checks

### Fixed
- `fileDnsZoneId` output propagated from hardened networking to storage
- Admin username no longer hardcoded in `seed-data.ps1`
- Spurious parameters removed from `deploy.ps1`
- Stale section comment in `governance.bicep`
- `PSAvoidGlobalVars` lint warnings in test suite — `$global:` replaced with `$script:` in all test files
- `GetNewClosure` missing from external-script Pester mocks causing variable scope leaks
- `New-AdeResourceGroup` now detects location conflicts on existing resource groups and throws a clear error instead of silently using the wrong region
- `destroy.ps1` silent failure bugs: `$LASTEXITCODE` not checked after `az group delete`; failure tracking added; deploy what-if steps now tag RGs with `managedBy=ade`
- Dead-code audit: removed phantom parameters, wired unconnected feature flags, documented integration/ai/data Public-access limitations
- Role check false-positive: `az role assignment list --include-inherited` does not traverse management group boundaries or expand group membership — replaced with multi-principal × multi-scope check covering MG ancestry and transitive group memberships
- Hydration hang in `Initialize-AdeState`: Azure CLI default 300 s timeout on non-existent resources — capped with `--request-timeout 30`
- Verbose logging: `Write-AdeLog` now emits on PowerShell information stream (6) in addition to host, enabling `*>&1 | Tee-Object` capture; `az` calls in key functions now log at Debug level

[1.0.0]: https://github.com/vegazbabz/azure-demo-environment/releases/tag/v1.0.0
