# ADE Test Plan

## 1. Current Status

| Suite | File | Passing | Skipped | Status |
| --- | --- | --- | --- | --- |
| Helper unit tests | `tests/helpers/common.Tests.ps1` | 38 | 0 | ✅ Complete |
| Helper unit tests | `tests/helpers/validate.Tests.ps1` | 30 | 0 | ✅ Complete |
| Helper unit tests | `tests/helpers/seed-data.Tests.ps1` | 14 | 0 | ✅ Complete |
| Policy tests | `tests/policies/Deploy-AdePolicies.Tests.ps1` | 49 | 0 | ✅ Complete |
| Config profile schema | `tests/config/profiles.Tests.ps1` | 56 | 0 | ✅ Complete |
| destroy.ps1 | `tests/destroy.Tests.ps1` | 13 | 0 | ✅ Complete |
| Runbooks | `tests/runbooks/Runbooks.Tests.ps1` | 23 | 0 | ✅ Complete |
| Dashboard | `tests/dashboard/Dashboard.Tests.ps1` | 12 | 0 | ✅ Complete |
| Bicep smoke tests | `tests/bicep/Build-BicepModules.Tests.ps1` | 112 | 28\* | ✅ Complete |
| **Total** | | **347** | **28** | **0 failures** |

\* The 28 skipped tests are `az bicep build --file` compile checks that require Azure CLI to be installed. They run automatically in CI where the CLI is present.

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

## 2. Fix Policy Tests (38 failures, 2 root causes)

### 2a. `foreach` variable capture bug (32 failures)

`BeforeAll` blocks capture `$file` at discovery time; by execution time the variable is out of scope.

**Fix:** replace `foreach ($file in $definitionFiles) { Context ... { BeforeAll { ... $file ... } } }` with Pester 5 `-TestCases`.

Affected: every `It` inside "Policy definition JSON files" (8 tests × 4 files = 32 tests).

### 2b. Missing `az` stub (6 failures)

`Deploy-AdePolicies.ps1` calls `az` directly; when Azure CLI is absent Pester throws `CommandNotFoundException` before `Mock az` can intercept.

**Fix:** add `function script:az {}` to the outer `BeforeAll` (same pattern as `validate.Tests.ps1`).

Affected: "Successful run without assignment" (4 tests), "Successful run with -Assign" (1 test), "az account set fails" (1 test).

### Expected result after fixes: 120/120 passing

---

## 3. Untested Scripts

### 3a. `config/profiles/*.json` — schema validation

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

### 3b. `scripts/deploy.ps1` — `Deploy-AdeModule` function

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

### 3c. `scripts/destroy.ps1`

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

### 3d. `scripts/runbooks/Start-AdeResources.ps1` and `Stop-AdeResources.ps1`

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

### 3e. `scripts/dashboard/Get-AdeCostDashboard.ps1` — `Show-AdeDashboard`

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

## 4. Bicep Build Smoke Tests

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

## 5. Test Infrastructure Gaps

| Gap | Description | Fix |
| --- | --- | --- |
| PS7 not pre-installed on dev machines | `Invoke-PesterSuite.ps1` requires PS7; machines without it cannot run tests | Document install step in `README`; CI already uses PS7 |
| Pester 5 not in base image | `Install-Module Pester -RequiredVersion 5.7.1` must run before tests | Add to CI job `steps:` before `Invoke-PesterSuite.ps1` |
| No test results directory | `tests/results/` does not exist; JUnit XML output fails in CI | Add `New-Item -ItemType Directory -Force tests/results` in runner |
| `#Requires -Version 7.0` removed from test files | `common.Tests.ps1` and `seed-data.Tests.ps1` had the directive removed to run on PS 5.1 during debugging | Re-add once CI is confirmed on PS7 |

---

## 6. Summary Roadmap

| Phase | Work | Tests | Status |
| --- | --- | --- | --- |
| **Bug fixes** | Fix policy test `foreach` + `az` stub (§2) | 49 | ✅ Done |
| **Sprint 1** | Config profile schema tests (§3a) | 56 | ✅ Done |
| **Sprint 1** | `New-AdeResourceGroup` + `Invoke-AdeBicepDeployment` unit tests (§3b) | 5 | ✅ Done |
| **Sprint 2** | `destroy.ps1` + `Remove-AdeResourceGroup` tests (§3c) | 13 | ✅ Done |
| **Sprint 2** | Runbook source analysis tests (§3d) | 23 | ✅ Done |
| **Sprint 2** | Dashboard source analysis tests (§3e) | 12 | ✅ Done |
| **Sprint 2** | Bicep build smoke tests (§4) | 112 (+28 skipped) | ✅ Done |
| **Total** | | **337 passing, 28 skipped** | |
