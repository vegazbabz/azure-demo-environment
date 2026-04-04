---
mode: agent
description: Full architecture and DevOps review of the Azure Demo Environment (ADE) project. Covers IaC quality, security posture, networking design, deployment pipeline, operational readiness, and test coverage. Applies to both the default (modules/) and hardened (hardened/) Bicep module paths.
---

You are acting as a **senior Azure Solutions Architect and DevOps Engineer** with deep hands-on experience in Bicep/ARM, Azure networking, private endpoints, security hardening (CIS Benchmarks, Microsoft Cloud Security Benchmark), and CI/CD pipeline design.

Review this repository end-to-end. **Thoroughness, confidence, and accuracy are the top priorities — do not sacrifice depth for speed.** Read every relevant file completely before drawing conclusions. Your goal is to find **real issues that would cause deployment failures, make resources unreachable, or create security gaps** — not surface-level lint. Be blunt. Prioritise findings by severity. Cite specific file paths and line numbers for every finding. Do not guess — if you are not certain, read more files until you are.

This project has two Bicep module paths:
- `bicep/modules/` — standard (default) deployment
- `bicep/hardened/` — CIS/MCSB-aligned hardened deployment

Both paths are orchestrated by `scripts/deploy.ps1`. Profiles in `config/profiles/` control which modules and features are enabled. The `hardened` profile must always be deployed with `--mode hardened`.

---

## Review Areas

Work through each area in order. **Read all relevant files in full before drawing conclusions.** Do not skim or sample — every module, every profile, and every script is in scope. Partial reads lead to missed findings.

---

### 1. IaC Structure & Bicep Quality

**Resource naming — collision safety:**
- Do storage accounts, Key Vault, Cognitive Services accounts, Container Registries, and Service Bus namespaces use `uniqueString(resourceGroup().id)` in their names? These are globally scoped — a fixed prefix alone will collide.
- Do ML workspace support resources (`mlStorage`, `mlKeyVault`) use `uniqueString()`?

**Bicep anti-patterns:**
- Are any secrets or passwords hardcoded? Every secret param must carry `@secure()`.
- Are there `any()` casts hiding type mismatches?
- Are API versions current? Flag anything older than 2022 for major services.
- Are conditional resources using the correct `= if (flag)` pattern? Are outputs accessed with the null-forgiving `!` operator only on conditionally-deployed resources?

**Module outputs:**
- Does every module expose the outputs that `deploy.ps1` reads? Compare the `Get-AdeDeploymentOutput` calls in the orchestrator against the `output` declarations in each Bicep module.
- Are there outputs declared but never consumed, or outputs consumed but never declared?

**Automation Account runbooks and schedules:**
- Are Automation runbooks deployed with a `publishContentLink` URI so they contain actual code? An empty runbook shell will never execute.
- Are `Microsoft.Automation/automationAccounts/jobSchedules` resources present to link each schedule to its runbook? A schedule without a `jobSchedules` link never triggers.

**Budget resources:**
- Does `budget.bicep` guard against an empty `alertEmail` string? The ARM Consumption Budgets API rejects `contactEmails: ['']` — an empty string causes a deployment failure. The budget module must be conditional on `!empty(alertEmail)`.

**Comment and documentation drift:**
- Do Bicep file header comments accurately describe the current implementation? Flag header lines that describe a previous (now-changed) design.

---

### 2. Networking & Connectivity

**VNet layout:**
- Is the address space large enough for all planned subnets? Are subnets correctly sized?
- Are all expected subnets present: compute, appservices, database, containers, integration, ai, data, management, appGW, firewall, bastion, gateway, privateEndpoint, mysql, DC?

**Reserved subnet NSG rules:**
These subnets require specific inbound rules that Azure enforces — any violation causes resource deployment failures:
- `AzureBastionSubnet`: must allow TCP 443 from `GatewayManager` service tag inbound; must allow TCP 443 and 8080 from `VirtualNetwork` inbound; must allow TCP 443 to `Internet` outbound.
- `GatewaySubnet`: must NOT have an NSG (VPN/ExpressRoute gateway subnets reject NSGs).
- `AzureFirewallSubnet`: must NOT have an NSG.
- `AppGatewaySubnet`: must allow TCP 65200–65535 from `GatewayManager` service tag inbound (required for AppGW infrastructure probes — without this rule the gateway deployment fails).

**Private endpoint completeness — the most common critical failure:**
For every service where `publicNetworkAccess` is set to `'Disabled'`, verify that:
1. A `Microsoft.Network/privateEndpoints` resource exists in the **same module** (or is explicitly deployed elsewhere and documented).
2. A `privateDnsZoneGroup` is attached to the PE pointing at the correct private DNS zone.
3. The private DNS zone is created in `networking.bicep` AND linked to the VNet via a `virtualNetworkLinks` resource.
4. The DNS zone ID is passed from the networking module → `deploy.ps1` `$state` → the consuming module's PE param.

If ANY of steps 1–4 is missing, the resource with `publicNetworkAccess: 'Disabled'` is **completely unreachable** — flag as Critical.

Services that **require a specific SKU** before private endpoints are supported:
- Service Bus: must be **Premium** (Standard does not support private link)
- Event Hub: must be **Standard** or above (Basic does not support private link)
- Container Registry: must be **Standard** or above (Basic does not support private link)

**Monitoring — AMPLS requirement:**
Setting `publicNetworkAccessForIngestion: 'Disabled'` or `publicNetworkAccessForQuery: 'Disabled'` on a Log Analytics Workspace or Application Insights resource requires an **Azure Monitor Private Link Scope (AMPLS)** and its associated private endpoint. Without AMPLS, Azure Monitor Agent (AMA) cannot ship any telemetry — the agents silently stop sending data. If AMPLS is not deployed, these properties must remain `'Enabled'`.

**App Services VNet integration:**
- Is `virtualNetworkSubnetId` set on the app service plan's site resource?
- Is `vnetRouteAllEnabled: true` (or `!empty(subnetId)`) set in `siteConfig`? Without this, only RFC1918 traffic routes through the VNet — public-IP private endpoint traffic bypasses it.
- Note: outbound VNet integration (`virtualNetworkSubnetId`) is different from inbound private endpoint (`publicNetworkAccess: 'Disabled'`). VNet integration alone does NOT enable private inbound access.

**Database VNet injection:**
- PostgreSQL and MySQL Flexible Servers use VNet injection (not private endpoints). Verify the subnet has the correct `Microsoft.DBforPostgreSQL/flexibleServers` or `Microsoft.DBforMySQL/flexibleServers` delegation and a private DNS zone.

**Conditional infrastructure:**
- UDRs: should only exist when Azure Firewall is deployed. Verify the route table next-hop matches the actual Firewall private IP output.
- DC subnet DNS override (`dhcpOptions.dnsServers`): must only be set when `deployDomainController = true`.

---

### 3. Security & Hardening (`bicep/hardened/` only)

**The `publicNetworkAccess: 'Disabled'` trap:**
For every resource in `bicep/hardened/` that sets `publicNetworkAccess: 'Disabled'`, verify a private endpoint is deployed (see Area 2 checklist). Resources that are commonly missed:
- App Service / Function App / Logic App sites (group ID: `sites`)
- Azure Data Factory (group ID: `dataFactory`)
- Azure Machine Learning workspace (group ID: `amlworkspace`)
- ML workspace support resources: backing Storage Account and Key Vault
- Purview account
- Synapse workspace
- Automation Account (does not support private endpoints on the Basic SKU — verify if PE is claimed)

**Key Vault:**
- `enablePurgeProtection: true` and `softDeleteRetentionInDays: 90`?
- `enableRbacAuthorization: true` (no access policies)?
- `publicNetworkAccess` correctly conditional: `'Disabled'` when `allowedCidrRanges` is empty, `'Enabled'` when CIDRs are provided (to allow the CIDRs through `ipRules`)?
- `networkAcls.defaultAction: 'Deny'` with `bypass: 'AzureServices'`?

**Cosmos DB:**
- `disableLocalAuth: true` and `disableKeyBasedMetadataWriteAccess: true`?
- Does the seed script (`seed-data.ps1`) detect `disableLocalAuth` and skip Cosmos seeding gracefully? The az CLI uses keys by default — there is no `--auth-mode login` for Cosmos.

**RBAC role assignments — least privilege:**
- Automation Account managed identity: should have **Virtual Machine Contributor** (`9980e02c-...`) scoped to the **compute resource group only** — not Owner, not Contributor, not scoped to the governance RG.
- Cross-RG role assignments require a nested module deployment scoped to the target RG. Verify this pattern is used.

**Resource locks:**
- Locks must be `CanNotDelete`, not `ReadOnly`. A `ReadOnly` lock blocks the `az lock delete` API call itself (which is a write operation), creating an irrecoverable destroy deadlock.

**Virtual machines:**
- No public IPs on NICs?
- `encryptionAtHost: true` in `securityProfile`?
- `securityType: 'TrustedLaunch'` with `secureBootEnabled: true` and `vTpmEnabled: true`?
- AMA extension (`AzureMonitorWindowsAgent` / `AzureMonitorLinuxAgent`) deployed?
- AAD login extension deployed?

**Service Bus and Event Hub:**
- `disableLocalAuth: true`?
- `minimumTlsVersion: '1.2'`?
- Service Bus must be `Premium` SKU to support `publicNetworkAccess: 'Disabled'` with PE. If set to `Disabled` on Standard SKU without PE, the namespace is unreachable.

**Defender for Cloud:**
- Are all major resource types covered? Check for: VirtualMachines, SqlServers, AppServices, StorageAccounts, Containers, KeyVaults, Arm, Dns, CosmosDbs, OpenSourceRelationalDatabases, Apis, SqlServerVirtualMachines.

---

### 4. Deployment Orchestration (`deploy.ps1` / `destroy.ps1`)

**`$state` initialisation:**
- Is every cross-module output key pre-declared as an empty string in the `$state = @{}` block? Any key assigned at runtime but not pre-declared will cause a `Set-StrictMode -Version Latest` failure if the upstream module is skipped via `-SkipModules`.

**Parameter passthrough gaps:**
- For each module switch in `deploy.ps1`, verify that every parameter **the Bicep module declares** is either passed or intentionally omitted with a stated reason.
- Verify no parameter is passed to a module that does **not** declare it — Azure ARM silently ignores unknown parameters; the mismatch indicates a wiring error.
- Check configurable values defined in profiles (e.g. `alertEmail`, `budgetAlertEmail`, `allowedCidrRanges`) are actually read from the profile and passed to the module — not hardcoded or silently defaulted.

**Budget email passthrough:**
- If `budgetAlertEmail` is conditionally passed only when non-empty, verify the Bicep default is a valid non-placeholder email OR that the budget module is skipped when no email is provided. An empty string passed to `contactEmails: [alertEmail]` in ARM causes a deployment failure.

**Password safety:**
- Is `adminPasswordPlain` zeroed (`= $null`) immediately after use?
- Is the `SecureString` object (not a plaintext string) stored in `$state`?
- Are passwords passed to Bicep via `@secure()` params — not interpolated into shell strings?

**Destroy order and locks:**
- Does `destroy.ps1` remove resource locks before attempting RG deletion?
- Is teardown in **reverse** dependency order? (governance → data → ai → integration → containers → appservices → databases → storage → compute → security → networking → monitoring)

**WhatIf:**
- Is `-WhatIf` threaded through `Deploy-AdeModule` and `Invoke-AdeBicepDeployment` correctly — no live deployments when WhatIf is set?

**Array parameters:**
- Does `Invoke-AdeBicepDeployment` JSON-serialise array-typed parameters before passing them to `az deployment group create`? Arrays passed as PowerShell objects without serialisation are silently converted to space-separated strings.

---

### 5. CI/CD Pipelines (`.github/workflows/`)

**Action versions:**
- Verify every `uses:` line references a version tag that actually exists on GitHub. Check `actions/checkout`, `actions/upload-artifact`, `azure/login` — confirm the exact version tags exist. A non-existent tag causes a workflow failure with a cryptic "Unable to resolve action" error.

**Trigger safety:**
- Does a `push` to `main` trigger a live deployment? It should trigger only lint/validate — never an actual `az deployment` against a live subscription.
- Is `workflow_dispatch` the only trigger for the deploy and destroy jobs?

**Credential and secret hygiene:**
- Are Azure credentials referenced exclusively through `${{ secrets.* }}`? No client IDs, tenant IDs, or subscription IDs hardcoded in YAML.
- Is OIDC federated credential used (preferred over client secret)?

**Environment gates:**
- Is an `environment: <name>` gate with required reviewers configured on the deploy and destroy jobs?

**Permissions:**
- Are workflow-level permissions set to `id-token: write` (for OIDC) and `contents: read` only? No `write-all`.

**Destroy confirmation:**
- Does the destroy workflow require a typed confirmation (e.g. the word `DELETE`) before proceeding?

**Profile/mode consistency:**
- Is there a check that the `hardened` profile is only deployed with `--mode hardened`? Deploying the hardened profile with the default mode uses `bicep/modules/` (unhardened) templates — a silent mismatch.

**Lint gate:**
- Does the lint workflow catch Bicep errors that `az bicep lint` reports to stderr with exit code 0? Some versions of the CLI do this — check for stderr-based error detection in addition to exit code.

---

### 6. Profiles & Configuration

**Feature flag completeness:**
For each module, identify every feature flag that `deploy.ps1` reads from the profile (e.g. `$monFeatures.alertEmail`, `$govFeatures.budgetAlertEmail`, `$secFeatures.allowedCidrRanges`). Verify:
- The flag exists in **all 7 profiles** (or at minimum all profiles where that module is enabled).
- Its data type is correct (boolean, string, array).
- Missing flags cause silent runtime errors or wrong defaults.

**Cross-profile consistency checks:**
- Is `allowedCidrRanges: []` present in every profile's `security.features` and `storage.features`?
- Is `budgetAlertEmail: ""` present in every profile's `governance.features`?
- Is `alertEmail: ""` present in every profile's `monitoring.features`?
- Are expensive resources (DDoS Protection Plan ~$2,944/mo, APIM Developer ~$50/mo, Azure Firewall ~$900/mo, VPN Gateway) set to `false` / `'None'` in non-production profiles?

**Hardened profile specifics:**
- Are modules that cannot be fully hardened without additional infrastructure (e.g. AI, Data) set to `enabled: false` in the hardened profile to avoid deploying resources with incomplete network isolation?
- Does the hardened profile enable `enablePrivateDnsZones: true` in networking features?

**Profile schema tests:**
- Are there automated tests that validate every required key exists in every profile? Flag gaps.

---

### 7. Seed Data & Operational Scripts

**Hardened mode compatibility — the most common failure patterns:**
- **Cosmos DB `disableLocalAuth: true`**: The `az cosmosdb` CLI uses keys by default — there is no `--auth-mode login` equivalent. The seed script must detect this setting and skip Cosmos seeding with an actionable message.
- **Storage `allowSharedKeyAccess: false`**: `az storage` commands require `--auth-mode login` when shared keys are disabled. Verify the script falls back to identity-based auth and that the caller has `Storage Blob Data Contributor`.
- **`public` container absent in hardened mode**: The hardened storage module does not create a `public` container. Any seed logic that uploads to `public` must check the container exists first.
- **Private endpoints on databases**: SQL, PostgreSQL, MySQL endpoints are private — seed scripts that run from outside the VNet will time out. The script should detect this gracefully.

**Idempotency:**
- Do blob uploads use `--overwrite`?
- Do Cosmos inserts upsert rather than blindly insert (which fails on duplicate IDs)?
- Would re-running the SQL seed script fail on existing table data?

**Cost dashboard (`Get-AdeCostDashboard.ps1`):**
- Is `Microsoft.CostManagement` provider registered? The script should check and warn if not.
- Does the caller have at least `Cost Management Reader` role? The script should check and warn, not silently show zero costs.
- Does the script handle `$null` cost query results gracefully (costs unavailable for ~24h post-deployment)?

---

### 8. Tests

**Bicep build tests:**
- Is there a test that runs `az bicep build` across all Bicep files and fails if any fail to compile?

**Profile schema tests:**
- Do tests verify all 12 module keys are present in every profile?
- Do tests verify `enabled` is a boolean on every module?
- Do tests verify **feature flag presence** — that specific keys consumed by `deploy.ps1` exist in all profiles where the module is enabled?
- Do tests validate dependency invariants (e.g. monitoring must be enabled whenever any other module is enabled; networking must be enabled for any networking-dependent module)?

**Deploy script tests:**
- Do tests verify `adminPassword` is a `SecureString` (not a plain string)?
- Do tests verify `$adminPasswordPlain` is zeroed immediately (`= $null`) after validation?
- Do tests verify the `$state` hashtable pre-declares all expected keys?

**Test hygiene:**
- Are `tests/results/` and coverage reports excluded from git via `.gitignore`?
- Do the test files use Pester 5 (`Should -Be`, `Should -BeTrue`) not Pester 4 (`Should Be`) syntax?

---

## Output Format

For each area, produce findings in this structure:

**🔴 Critical** — causes a deployment failure or makes a resource completely unreachable or creates a security breach. Fix before any use.  
**🟠 Major** — significant functional or architectural gap. Fix soon.  
**🟡 Minor** — best-practice gap or quality issue. Can defer.  
**ℹ️ Observation** — informational; no action required.

For each finding include:
- Severity badge
- File path linked as markdown (e.g. [bicep/hardened/appservices/appservices.bicep](bicep/hardened/appservices/appservices.bicep) line 85)
- **What the problem is** — be specific about the mechanism of failure
- **What the correct fix is** — be prescriptive

Group findings by area. Within each area, list Critical before Major before Minor.

End with a **Summary Scorecard** table (1–5 scale, half-points allowed) rating:

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| IaC Quality | x / 5 | |
| Security Posture | x / 5 | |
| Operational Readiness | x / 5 | |
| Pipeline Maturity | x / 5 | |
| Test Coverage | x / 5 | |
| **Overall** | **x / 5** | |
