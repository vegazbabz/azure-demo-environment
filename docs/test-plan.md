# ADE Test Plan

## 1. Current Status

| Suite | File | Passing | Skipped | Status |
| --- | --- | --- | --- | --- |
| deploy.ps1 | `tests/deploy.Tests.ps1` | 60 | 0 | ✅ Complete |
| destroy.ps1 | `tests/destroy.Tests.ps1` | 35 | 0 | ✅ Complete |
| Helper unit tests | `tests/helpers/common.Tests.ps1` | 49 | 0 | ✅ Complete |
| Helper unit tests | `tests/helpers/validate.Tests.ps1` | 35 | 0 | ✅ Complete |
| Helper unit tests | `tests/helpers/seed-data.Tests.ps1` | 28 | 0 | ✅ Complete |
| Policy tests | `tests/policies/Deploy-AdePolicies.Tests.ps1` | 49 | 0 | ✅ Complete |
| Config profile schema | `tests/config/profiles.Tests.ps1` | 56 | 0 | ✅ Complete |
| Runbooks | `tests/runbooks/Runbooks.Tests.ps1` | 23 | 0 | ✅ Complete |
| Dashboard | `tests/dashboard/Dashboard.Tests.ps1` | 16 | 0 | ✅ Complete |
| Data files | `tests/data/DataFiles.Tests.ps1` | 34 | 0 | ✅ Complete |
| Bicep smoke tests | `tests/bicep/Build-BicepModules.Tests.ps1` | 160 | 0 | ✅ Complete |
| **Total** | | **545** | **0** | **0 failures** |

Run the full suite:

```powershell
./tests/Invoke-PesterSuite.ps1
```

Or directly with Pester:

```powershell
Import-Module Pester -RequiredVersion 5.7.1 -Force
Invoke-Pester -Path ./tests/ -Output Normal
```

---

## 2. Untested Scripts

### 2a. `config/profiles/*.json` — schema validation

**Priority: High** — pure JSON, no mocks, instant to write.

7 profile files: `full`, `minimal`, `compute-only`, `databases-only`, `networking-only`, `security-focus`, `hardened`.

Proposed test file: `tests/config/profiles.Tests.ps1`

Tests per profile:

- Parses as valid JSON
- Has required top-level keys: `profileName`, `description`, `modules`
- `modules.monitoring.enabled` is a boolean
- Every module entry has an `enabled` boolean
- If any module other than `monitoring` is enabled, `monitoring` is also enabled (mirrors `Test-AdeProfile` logic)
- `profileName` matches the filename (without extension)

Estimated: ~7 tests × 7 files = **49 tests**.

---

### 2b. `scripts/deploy.ps1` — `Deploy-AdeModule` function

**Priority: High** — the only exported function; all `az deployment group create` calls flow through it.

`Deploy-AdeModule` is declared at line 260 and is not dot-sourced by any test yet. It can be isolated and mocked.

Proposed test file: `tests/Deploy-AdeModule.Tests.ps1`

Tests:

- Calls `az deployment group create` with correct `--template-file` path
- Passes `--parameters` flag for every key in the params hashtable
- Throws when `az` returns exit 1
- Uses `--mode Incremental` by default
- Uses hardened template path when `$Mode -eq 'hardened'`
- Does not call `az` when `$WhatIf` is set

Estimated: **~10 tests**.

Dependencies to mock: `az`, `Write-AdeLog`, `Write-AdeSection`.

---

### 2c. `scripts/destroy.ps1`

**Priority: Medium** — orchestration logic is similar to `deploy.ps1`.

Proposed test file: `tests/destroy.Tests.ps1`

Tests:

- Calls `az group delete` for each enabled module's resource group
- Calls with `--yes --no-wait` when `-Force` is set
- Prompts for confirmation without `-Force`
- Processes modules in reverse dependency order
- Skips resource groups that don't exist (exit 0 from `az group show`)

Estimated: **~8 tests**.

---

### 2d. `scripts/runbooks/Start-AdeResources.ps1` and `Stop-AdeResources.ps1`

**Priority: Medium** — uses `Connect-AzAccount -Identity` (requires `Az.Accounts` module mock).

Proposed test file: `tests/runbooks/AdeResources.Tests.ps1`

Tests (shared, parametrized by Start vs. Stop):

- `-DryRun` logs intent but calls zero `az` commands
- Calls correct `az vm start` / `az vm deallocate` per discovered VM
- Handles empty resource group gracefully (no VMs found = no error)
- Connects via managed identity on first call (`Connect-AzAccount -Identity`)

Blocker: `Connect-AzAccount` requires the `Az.Accounts` module. Either add it as a dev dependency or stub it with `function Connect-AzAccount {}` before dot-sourcing.

Estimated: **~8 tests**.

---

### 2e. `scripts/dashboard/Get-AdeCostDashboard.ps1` — `Show-AdeDashboard`

**Priority: Low** — output-only, no side effects, benefits least from unit tests.

The `Show-AdeDashboard` function calls `az consumption budget list`, `az monitor metrics list`, and `az vm list`. A smoke test that mocks all three and verifies the function completes without throwing would provide useful regression coverage.

Proposed test file: `tests/dashboard/Get-AdeCostDashboard.Tests.ps1`

Tests:

- Does not throw when all `az` calls succeed
- `-StopAll` calls `az vm deallocate` for each running VM
- `-StartAll` calls `az vm start` for each deallocated VM
- `-Watch` flag triggers a loop (test that it calls `Show-AdeDashboard` more than once with a short `-Limit`)

Estimated: **~5 tests**.

---

## 3. Bicep Build Smoke Tests

**Priority: Medium** — validates that all 22 `.bicep` files compile cleanly, catching future regressions after template edits.

Proposed test file: `tests/bicep/Build-BicepModules.Tests.ps1`

Approach: for each `.bicep` file, run `az bicep build --file <path> --stdout` and assert `$LASTEXITCODE -eq 0`.

```text
bicep/modules/   12 files
bicep/hardened/  10 files
```

Tests:

- Each file: compiles without errors (22 tests)
- Each file: produces no warnings containing "BCP" error codes

Estimated: **~22 tests**.

Prerequisite: `az bicep` installed (already verified by `Test-AdePrerequisites`).

---

## 4. Test Infrastructure Gaps

| Gap | Description | Fix |
| --- | --- | --- |
| PS7 not pre-installed on dev machines | `Invoke-PesterSuite.ps1` requires PS7; machines without it cannot run tests | Document install step in `README`; CI already uses PS7 |
| Pester 5 not in base image | `Install-Module Pester -RequiredVersion 5.7.1` must run before tests | Add to CI job `steps:` before `Invoke-PesterSuite.ps1` |
| No test results directory | `tests/results/` does not exist; JUnit XML output fails in CI | Add `New-Item -ItemType Directory -Force tests/results` in runner |
| `#Requires -Version 7.0` removed from test files | `common.Tests.ps1` and `seed-data.Tests.ps1` had the directive removed to run on PS 5.1 during debugging | Re-add once CI is confirmed on PS7 |

---

## 5. Summary Roadmap

| Phase | Work | Tests | Status |
| --- | --- | --- | --- |
| **Bug fixes** | Fix policy test `foreach` + `az` stub | 49 | ✅ Done |
| **Sprint 1** | Config profile schema tests | 56 | ✅ Done |
| **Sprint 1** | `deploy.ps1` source analysis tests | 60 | ✅ Done |
| **Sprint 2** | `destroy.ps1` tests | 35 | ✅ Done |
| **Sprint 2** | Runbook source analysis tests | 23 | ✅ Done |
| **Sprint 2** | Dashboard source analysis tests | 16 | ✅ Done |
| **Sprint 2** | Data file tests | 34 | ✅ Done |
| **Sprint 2** | Helper unit tests | 112 | ✅ Done |
| **Sprint 2** | Bicep build smoke tests | 160 | ✅ Done |
| **Total** | | **545 passing, 0 skipped** | |
