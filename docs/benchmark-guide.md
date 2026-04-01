# Benchmark Guide

How ADE supports CIS Azure Foundations Benchmark v2.0 and Microsoft Cloud Security Benchmark (MCSB)
assessments — what it deploys, how to generate a compliance report, and how to read the results.

---

## Methodology

ADE is designed for **before/after benchmark comparisons**:

1. Deploy in **`default` mode** — out-of-box Azure settings, no hardening
2. Run a compliance scan (Defender CSPM, Microsoft Secure Score, or `az policy state`)
3. Record the baseline score
4. Deploy in **`hardened` mode** (same prefix, same profile)
5. Re-run the same scan
6. Compare scores and remediation gaps

Both modes assign the CIS and MCSB policy initiatives in **`DoNotEnforce`** (audit-only) mode so
the scan reflects the actual resource configuration rather than blocked deployments.

---

## CIS Azure Foundations Benchmark v2.0 — Control Coverage

The table below maps CIS sections to ADE modules. Coverage is indicated by the **hardened** mode
configuration; default mode intentionally leaves these controls in a non-compliant state.

| CIS Section | Topic | ADE Module | Hardened control |
|---|---|---|---|
| 1.x | Identity and access management | `security`, `governance` | Entra ID conditional access notes; Key Vault RBAC |
| 2.1 | Microsoft Defender for Cloud | `security` | All Defender plans enabled |
| 2.2 | Microsoft Defender for Cloud — recommendations | `governance` | Policy assignments in Enforce mode |
| 3.x | Storage accounts | `storage` | HTTPS-only, public access off, infrastructure encryption |
| 4.x | Databases | `databases` | TLS 1.2, AD auth, Transparent Data Encryption, Threat Detection |
| 5.x | Logging and monitoring | `monitoring`, `governance` | Diagnostic settings, Activity Log alerts, Sentinel |
| 6.x | Networking | `networking` | NSG rules, Bastion, no management ports exposed |
| 7.x | Virtual machines | `compute` | AMA, Defender for Endpoint, disk encryption, no public IPs |
| 8.x | App services | `appservices` | HTTPS-only, TLS 1.2, managed identity, no FTP |
| 9.x | Key Vault | `security` | Purge protection, soft delete, private endpoints |

> **Not covered**: Section 1.x Entra ID tenant-level settings (MFA, SSPR, guest access) require
> tenant admin permissions and are out of scope for subscription-scoped IaC.

---

## MCSB Control Coverage

MCSB (Microsoft Cloud Security Benchmark) v1 supersedes the Azure Security Benchmark. Key pillars:

| MCSB Pillar | ADE coverage |
|---|---|
| Network security (NS) | VNet segmentation, NSGs, private endpoints, Firewall option |
| Identity management (IM) | Managed identities, Key Vault RBAC, no standing admin credentials |
| Privileged access (PA) | Bastion for VM access, no public management ports |
| Data protection (DP) | Encryption at rest + in transit, Key Vault for secrets |
| Asset management (AM) | Tags, resource locks, governance module |
| Logging and threat detection (LT) | Log Analytics, Sentinel, Defender alerts, diagnostic settings |
| Incident response (IR) | Action Groups, alert rules, Sentinel automation rules |
| Posture and vulnerability management (PV) | Defender for Cloud CSPM, Qualys/Defender for Servers |
| Endpoint security (ES) | Defender for Endpoint auto-provisioning, AMA |
| Backup and recovery (BR) | Not covered (add Recovery Services Vault to extend) |
| DevOps security (DS) | GitHub Actions OIDC, no long-lived secrets, branch policies |

---

## Generating a Compliance Report

### Option 1 — Defender CSPM (portal)

1. Navigate to **Microsoft Defender for Cloud → Regulatory compliance**
2. Select **CIS Azure Foundations Benchmark v2.0** or **Microsoft Cloud Security Benchmark**
3. Expand failing controls to see the non-compliant resources

### Option 2 — Azure Policy compliance state (CLI)

```bash
# Overall summary for the subscription
az policy state summarize \
  --subscription <subscription-id> \
  --query "results.policyAssignments[].{Name:policyAssignmentId,Compliant:results.nonCompliantResources}" \
  --output table

# All non-compliant resources under a specific assignment
az policy state list \
  --subscription <subscription-id> \
  --filter "policyAssignmentName eq 'ade-cis-foundations' and complianceState eq 'NonCompliant'" \
  --query "[].{Resource:resourceId,Policy:policyDefinitionName}" \
  --output table
```

### Option 3 — Microsoft Secure Score

Navigate to **Microsoft Defender for Cloud → Secure Score**. The hardened deployment should
increase the score by addressing:

- Defender plans for all resource types
- Log Analytics agent auto-provisioning
- Resource diagnostic settings
- Storage and database TLS/encryption controls

---

## Expected Score Improvement

These figures are approximate and depend on existing tenant configuration:

| Profile | Mode | Typical Secure Score range |
|---|---|---|
| `full` | default | 30–45% |
| `full` | hardened | 65–80% |
| `security-focus` | hardened | 70–85% |

The gap between default and hardened demonstrates the controls that ADE specifically addresses.
Controls dependent on tenant-level Entra ID settings (MFA, privileged identity management) are
not affected by ADE and must be addressed separately.

---

## Extending Coverage

To cover additional CIS/MCSB controls not in ADE's current scope:

| Gap area | Suggested extension |
|---|---|
| Recovery Services Vault (CIS 9.x) | Add `backup` module to `bicep/hardened/` |
| Azure Firewall (CIS 6.x advanced) | Enable `enableFirewall: 'Standard'` in networking profile |
| DDoS Protection Standard | Enable `enableDdos: true` in networking profile |
| Private DNS Zones | Enable `enablePrivateDnsZones: true` in networking profile |
| Entra ID PIM | Out of scope — configure in Entra admin center |
| Entra ID MFA | Out of scope — configure in Entra admin center |

---

## Benchmark References

- [CIS Azure Foundations Benchmark v2.0](https://www.cisecurity.org/benchmark/azure)
- [Microsoft Cloud Security Benchmark v1](https://learn.microsoft.com/en-us/security/benchmark/azure/overview)
- [Defender for Cloud — Regulatory compliance](https://learn.microsoft.com/en-us/azure/defender-for-cloud/regulatory-compliance-dashboard)
- [Azure Policy built-in definitions for CIS](https://learn.microsoft.com/en-us/azure/governance/policy/samples/cis-azure-foundations-benchmark)
