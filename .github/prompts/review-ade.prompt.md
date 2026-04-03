---
mode: agent
description: Full architecture and DevOps review of the Azure Demo Environment (ADE) project. Covers IaC quality, security posture, networking design, deployment pipeline, operational readiness, and cost efficiency.
---

You are acting as a **senior Azure Solutions Architect and DevOps Engineer** with hands-on Bicep/ARM, Azure networking, security hardening (CIS, MCSB), and CI/CD pipeline experience.

Review this repository end-to-end. Your goal is to find real issues — not surface-level lint — that would cause failures in production or that a senior reviewer at a customer engagement would flag. Be blunt and prioritise findings by severity.

## Scope of Review

Work through each area below in order. Use file reads and searches to gather evidence before drawing conclusions. Do not guess — cite specific file paths and line numbers.

---

### 1. IaC Structure & Bicep Quality

- Are modules cleanly separated with sensible resource group boundaries?
- Are there any Bicep anti-patterns: hardcoded secrets, missing `@secure()`, unsafe `any()` casts, unused params, or use of deprecated API versions?
- Are conditional deployments wired correctly (`= if (flag)` plus safe `!` null-forgiving accesses for outputs)?
- Are resource names collision-safe? Check for missing `uniqueString()` on globally unique names (storage accounts, Key Vault, Cognitive Services, etc.).
- Are `dependsOn` relationships explicit where needed, or are there implicit ordering risks?
- Do all modules expose meaningful outputs that the orchestrator (`deploy.ps1`) actually consumes?

### 2. Networking & Connectivity

- Is the VNet address space and subnet layout sensible for the intended workload mix?
- Are all NSGs correct? Specifically: reserved subnets (AppGatewaySubnet, AzureBastionSubnet, GatewaySubnet, AzureFirewallSubnet) carry the required service-specific rules.
- Are private endpoints deployed for every service with `publicNetworkAccess: 'Disabled'`? If a PE is missing, the resource is completely unreachable — flag this as critical.
- Are Private DNS zones created AND linked to the VNet? Verify all PE DNS zone groups reference the correct zone IDs.
- Is VNet integration (`virtualNetworkSubnetId` + `vnetRouteAllEnabled: true`) wired on every App Service / Function App that needs to reach private endpoints?
- For database services (PostgreSQL, MySQL), is VNet injection correctly set up (dedicated delegated subnet + private DNS zone)?
- Are UDRs only created when Azure Firewall is enabled? Verify the firewall next-hop IP matches the actual Firewall private IP.
- Is the DC subnet DNS override (`dhcpOptions.dnsServers`) only applied when `deployDomainController = true`?

### 3. Security & Hardening (hardened mode only)

- In `bicep/hardened/` modules: is `publicNetworkAccess: 'Disabled'` set consistently, and does every affected resource also have a corresponding private endpoint?
- Are `networkAcls` (Key Vault, Storage Account) set to `defaultAction: 'Deny'` with `bypass: 'AzureServices'`? Verify the new `allowedCidrRanges` param correctly populates `ipRules` and controls `publicNetworkAccess`.
- Is Cosmos DB `disableLocalAuth: true`? Does this break the seeder (`seed-data.ps1`)?
- Is Service Bus using a SKU that supports private endpoints (Premium)? Is Event Hub on Standard or above?
- Are all compute VMs configured with: no public IP, encryption at host, Trusted Launch, AMA extension, auto-shutdown?
- Is Key Vault purge protection enabled? Is soft-delete retention ≥ 90 days?
- Are RBAC role assignments scoped correctly (least privilege)? Look for any `Owner` or `Contributor` assignments when a data-plane role would suffice.
- Does the WAF Application Gateway use `firewallMode: 'Prevention'` in hardened mode?
- Does Defender for Cloud cover all relevant resource types? Check `defenderPlans` in the security module.

### 4. Deployment Orchestration (`deploy.ps1` / `destroy.ps1`)

- Is every module output properly captured into `$state` and passed as a parameter to dependent modules? Look for any parameter that should come from a prior module but is passed as empty string.
- Are plaintext passwords handled safely? Check for any case where `adminPassword` is logged, stored in a variable longer than necessary, or passed to a command that might echo it.
- Does the `destroy.ps1` script handle resource locks before deletion? Does it tear down in reverse dependency order?
- Are `--parameters` passed to `az deployment group create` via `ArgumentList` (array) rather than string interpolation, to prevent whitespace and injection issues?
- Is the `WhatIf` mode wired through all code paths correctly?
- Does `Invoke-AdeBicepDeployment` correctly handle `[array]` parameters (JSON-serialised)? Verify the fix in `common.ps1`.

### 5. CI/CD Pipelines (`.github/workflows/`)

- Are workflow triggers appropriate (e.g., no accidental `push` to `main` auto-deploy on a shared repo)?
- Are Azure credentials stored as GitHub secrets and referenced correctly — no hardcoded credentials in workflow YAML?
- Are environment protection rules or manual approval gates in place before `deploy` runs against a live subscription?
- Is there a `lint.yml` / Bicep build step to catch template errors before deployment?
- Does the destroy workflow require explicit confirmation to prevent accidental teardown?
- Are workflow permissions set to least privilege (`contents: read`, etc.)?

### 6. Profiles & Configuration

- Do all 7 profiles define consistent feature flags? Cross-check that every feature flag consumed by `deploy.ps1` exists in all relevant profiles.
- Is `allowedCidrRanges` present in every profile's `security` and `storage` features?
- Are expensive resources (DDoS, APIM, Premium SKUs) correctly defaulted to `false` / `off` in non-hardened profiles to control cost?
- Are the `hardened` and `full` profiles internally consistent — same overall intent, different security settings?

### 7. Seed Data & Operational Scripts

- Does `seed-data.ps1` work correctly in hardened mode (all endpoints private, Cosmos `disableLocalAuth: true`, storage `allowSharedKeyAccess: false`)?
- Are seed operations idempotent? Would re-running the script duplicate data or fail?
- Does `Get-AdeCostDashboard.ps1` correctly enumerate all expected resource groups and handle missing ones gracefully?

### 8. Tests

- Do the Pester tests in `tests/` provide meaningful coverage, or are they just smoke tests?
- Are there tests for the Bicep modules themselves (build tests), the profile schema, and the deploy/destroy scripts?
- Are test results and coverage reports excluded from git (`.gitignore`)?

---

## Output Format

For each area, produce:

1. **Critical** — would cause a deployment failure or security breach. Must fix before any real use.
2. **Major** — significant functional gap or architectural concern. Should fix soon.
3. **Minor** — improvement or best-practice gap. Can defer.
4. **Observation** — informational; no action required but worth noting.

Group findings by area. For each finding include:
- Severity badge
- File path + line number (where applicable)
- What the problem is
- What the correct fix is

End with a **Summary Scorecard** (1–5 scale) rating the project on: IaC Quality, Security Posture, Operational Readiness, Pipeline Maturity, and Test Coverage.
