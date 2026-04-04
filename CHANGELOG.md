# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-04-04

### Added
- Full Bicep module library: `ai`, `appservices`, `compute`, `containers`, `data`, `databases`, `governance`, `integration`, `monitoring`, `networking`, `security`, `storage`
- Hardened mode (`bicep/hardened/`) with private endpoints, managed identities, AKS RBAC, and Policy assignments
- Deployment profiles: `minimal`, `full`, `compute-only`, `databases-only`, `networking-only`, `security-focus`, `hardened`
- `deploy.ps1` and `destroy.ps1` orchestration scripts with WhatIf, profile, and skip-module support
- `seed-data.ps1` for populating Storage, Cosmos DB, Azure SQL, PostgreSQL, MySQL, Redis, and Key Vault
- Automation runbooks: `Start-AdeResources.ps1`, `Stop-AdeResources.ps1`
- Cost dashboard script `Get-AdeCostDashboard.ps1`
- Azure Policy definitions and initiative (`ade-governance-initiative`)
- CI pipeline: Bicep lint, JSON validation, PSScriptAnalyzer, Pester unit tests (488 tests)
- Deploy and Destroy GitHub Actions workflows with OIDC authentication
- Managed identity role assignments for Function App and Logic App
- Domain Controller VM support in compute and networking modules
- Hardened Cosmos DB: `disableLocalAuth` check before key-based seeding
- AKS authorized IP ranges wired through to `apiServerAccessProfile`
- File share private endpoint and DNS zone group in hardened storage
- GitHub repository hardening: SHA-pinned actions, input validation, concurrency groups, Dependabot
- `LICENSE` (MIT), `SECURITY.md`, `CONTRIBUTING.md`

### Fixed
- `fileDnsZoneId` output propagated from hardened networking to storage
- Admin username no longer hardcoded in `seed-data.ps1`
- Spurious parameters removed from `deploy.ps1`
- Stale section comment in `governance.bicep`

[1.0.0]: https://github.com/vegazbabz/azure-demo-environment/releases/tag/v1.0.0
