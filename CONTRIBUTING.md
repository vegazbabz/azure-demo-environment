# Contributing to Azure Demo Environment

Thank you for your interest in contributing. Please follow these guidelines.

## Prerequisites

- Azure subscription (for testing deployments)
- Azure CLI + Bicep CLI
- PowerShell 7 + PSScriptAnalyzer
- [Pester](https://pester.dev) v5 (for running tests locally)

```bash
# Install Pester
Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
```

## Development workflow

1. **Fork** the repository and create a branch from `main`:
   ```
   git checkout -b fix/my-fix
   ```

2. **Make your changes** — keep them focused and minimal.

3. **Run lint and tests locally** before opening a PR:
   ```powershell
   # PowerShell lint
   Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Error,Warning -Settings .\.config\PSScriptAnalyzerSettings.psd1

   # Pester tests
   ./tests/Invoke-PesterSuite.ps1
   ```

4. **Bicep changes** — build to catch compile errors:
   ```bash
   find bicep -name '*.bicep' | xargs -I{} az bicep lint --file {}
   ```

5. **Open a Pull Request** against `main`. The CI (lint + Pester) will run automatically.

## What to work on

- See open [Issues](../../issues) for ideas.
- PRs adding new profiles, fixing module defaults, or improving documentation are welcome.
- For large changes (new modules, new hardened controls), open an issue first to discuss.

## Code style

| Area | Convention |
|------|-----------|
| Bicep | `camelCase` param/var names; section headers with `// ─── ` dividers |
| PowerShell | Follow the existing `.config/PSScriptAnalyzerSettings.psd1` rules; `PascalCase` function names; `Verb-Noun` convention |
| JSON profiles | All module keys present; boolean values, never string `"true"` |
| Commit messages | `type: short summary` — e.g. `fix: correct AKS API server param` |

## Reporting bugs

Open a [GitHub Issue](../../issues/new) with:
- Which profile and mode you deployed (`full`, `hardened`, etc.)
- The error message and full stack trace
- The Azure region and any non-default settings

## Security vulnerabilities

Please **do not** open a public issue for security vulnerabilities. See [SECURITY.md](SECURITY.md) for the responsible disclosure process.
