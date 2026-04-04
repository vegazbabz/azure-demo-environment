# Security Policy

## Supported Versions

This is a demonstration and learning project. Only the latest commit on `main` is supported.

| Version | Supported |
|---------|-----------|
| `main` (latest) | ✅ |
| Older snapshots | ❌ |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

To report a security issue, use one of the following channels:

- **GitHub private vulnerability reporting** (preferred): [Report a vulnerability](../../security/advisories/new) — available under the *Security* tab of this repository.
- **Email**: Contact the repository owner via GitHub profile if private reporting is unavailable.

Please include:
- A description of the vulnerability and potential impact
- Steps to reproduce
- Which file(s) or workflow(s) are affected
- Any suggested remediation

You can expect an initial response within **72 hours**. If confirmed, a fix will be prioritised and a GitHub Security Advisory will be published after the patch is released.

## Security Design Notes

This project deploys real Azure infrastructure and includes GitHub Actions workflows that authenticate to Azure via **OIDC federated identity** (no stored service principal passwords).

### What secrets are used

| Secret | Scope | Purpose |
|--------|-------|---------|
| `AZURE_CLIENT_ID` | Environment: `demo` | OIDC client ID |
| `AZURE_TENANT_ID` | Environment: `demo` | Azure AD tenant |
| `AZURE_SUBSCRIPTION_ID` | Environment: `demo` | Target subscription |
| `ADE_ADMIN_PASSWORD` | Environment: `demo` | VM / DB admin password |

All secrets are scoped to the `demo` **environment** (not repository-level), so they are only exposed to jobs that have passed the environment's protection rules (required reviewers).

### AKS API server access

By default, `aksAuthorizedIpRanges` is empty (unrestricted) in all profiles. Before deploying to a production-like environment, populate `containers.features.aksAuthorizedIpRanges` in your profile JSON with the CIDR ranges of your deployer/CI runner.

### Hardened mode vs Default mode

The `hardened` mode deploys CIS Benchmark / MCSB-aligned configuration. The `default` mode deploys baseline Azure configuration intentionally without all hardening. Do not use `default` mode for any production workload.

### Costs and resource lifecycle

Running the `full` profile or `hardened` profile incurs real Azure costs. Always run `destroy.ps1` (or the Destroy workflow) when the environment is no longer needed.
