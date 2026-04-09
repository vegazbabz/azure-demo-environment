# Benchmark Guide

How ADE supports CIS Microsoft Azure Foundations Benchmark v5.0.0 and Microsoft Cloud Security Benchmark (MCSB)
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

## CIS Microsoft Azure Foundations Benchmark v5.0.0 — Control Coverage

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
2. Select **CIS Microsoft Azure Foundations Benchmark v5.0.0** or **Microsoft Cloud Security Benchmark**
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

## Audit Queries

The queries below can be run against a deployed ADE environment to verify individual CIS v5.0.0
controls. Known issues with deprecated or broken queries are called out inline.

---

### 6.1.1.5 / 7.5 — NSG Flow Logs

> **⚠ Deprecated — cannot be satisfied on current subscriptions**
>
> Microsoft blocked new NSG flow log creation on **30 June 2025** and will retire the feature
> entirely on **30 September 2027**. These two controls cannot be met on any subscription created
> after that date. Auditors should mark them **Not Applicable** rather than Non-Compliant, and
> should not attempt remediation — the ARM API will reject the request.
>
> The replacement technology is **VNet flow logs** (GA since late 2024), which captures traffic at
> the VNet level rather than per-NSG. VNet flow log coverage is assessed under separate controls.

---

### 6.1.2.1–6.1.2.10 — Activity Log Alerts

Verify that alert rules exist **and are enabled**. Rules that exist but are disabled are not
compliant; omitting the `enabled` filter produces false-positive results.

```bash
# CLI — list all Activity Log alert rules that are enabled
az monitor activity-log alert list \
  --subscription <subscription-id> \
  --query "[?enabled==\`true\`].{name:name, condition:condition.allOf[0].equals, rg:resourceGroup}" \
  --output table
```

```powershell
# PowerShell
Get-AzActivityLogAlert | Where-Object { $_.Enabled -eq $true } |
    Select-Object Name, ResourceGroupName,
        @{ N='Operation'; E={ ($_.ConditionAllOf | Where-Object Field -eq 'operationName').EqualsValue } }
```

For a full compliant deployment, hardened mode creates rules for all ten operations:
`Microsoft.Authorization/policyAssignments/write`, `Microsoft.Network/networkSecurityGroups/write`,
`Microsoft.Network/networkSecurityGroups/delete`, `Microsoft.Network/networkSecurityGroups/securityRules/write`,
`Microsoft.Network/networkSecurityGroups/securityRules/delete`, `Microsoft.Sql/servers/firewallRules/write`,
`Microsoft.Sql/servers/firewallRules/delete`, `Microsoft.Security/tasks/activate/action`,
`Microsoft.Security/tasks/dismiss/action`, `Microsoft.Security/securitySolutions/write`.

---

### 6.1.5 — No Basic or Consumption SKUs

> **⚠ Known broken queries in older guidance**
>
> The PowerShell command `Get-AzResource | ?{ $_.Sku -EQ "Basic" }` is non-functional.
> `$_.Sku` is a `PSResourceSku` object, not a string; comparing it to `"Basic"` with `-eq` always
> returns `$false` regardless of what is deployed. The result is always an empty list.
>
> The Resource Graph `contains` operator on the `sku` field is also unreliable — `sku` is a JSON
> object, not a string, and `contains` behaviour is inconsistent across resource types. Some SKUs
> (e.g. App Service Free tier `sku.name = "F1"`) are never matched.

Use Resource Graph with explicit field comparisons instead:

```bash
# CLI
az graph query -q "
Resources
| where sku.name =~ 'Basic'
   or sku.tier =~ 'Basic'
   or sku.name =~ 'Free'
   or sku.tier =~ 'Free'
   or sku.name =~ 'Consumption'
   or sku.tier =~ 'Consumption'
| project name, type, resourceGroup, subscriptionId, sku
| order by type asc"
```

```powershell
# PowerShell — requires Az.ResourceGraph module
Search-AzGraph -Query @"
Resources
| where sku.name =~ 'Basic'
   or sku.tier =~ 'Basic'
   or sku.name =~ 'Free'
   or sku.tier =~ 'Free'
   or sku.name =~ 'Consumption'
   or sku.tier =~ 'Consumption'
| project name, type, resourceGroup, subscriptionId, sku
| order by type asc
"@
```

Resource types where Basic/Consumption SKUs introduce material security limitations:

| Resource type | Basic/Free limitation |
|---|---|
| Azure Bastion | No native client, no copy/paste, no session recording |
| Application Gateway | No WAF, no autoscaling, no zone redundancy |
| Virtual Network Gateway (VPN) | No BGP, no zone redundancy (being deprecated) |
| Azure Container Registry | No geo-replication, no retention policies, no Private Link |
| Event Hubs | No Kafka, no geo-disaster recovery, no Private Link |
| Service Bus | No geo-disaster recovery, no Private Link |
| API Management | Consumption has no VNet integration |
| Log Analytics workspace | Free tier: 500 MB/day cap, 7-day retention only |

---

### 8.1.4.1 — Defender for Containers

> **⚠ `ContainerRegistry` plan no longer exists on new subscriptions**
>
> Older audit commands targeting the `ContainerRegistry` Defender plan will fail silently or
> return an error on subscriptions created after Microsoft merged it into the unified
> `Containers` plan. Querying `ContainerRegistry` will not assess container security posture.

Use the `Containers` plan name:

```bash
# CLI — check Defender for Containers plan is enabled
az security pricing show \
  --subscription <subscription-id> \
  --name Containers \
  --query "{plan:name, pricingTier:pricingTier}" \
  --output table
```

```powershell
# PowerShell
Get-AzSecurityPricing -Name 'Containers' |
    Select-Object Name, PricingTier
```

A compliant result returns `pricingTier: Standard`. The ADE hardened `security` module enables
this plan explicitly.

---

## Benchmark References

- [CIS Azure Foundations Benchmark v5.0.0](https://www.cisecurity.org/benchmark/azure)
- [Microsoft Cloud Security Benchmark v1](https://learn.microsoft.com/en-us/security/benchmark/azure/overview)
- [Defender for Cloud — Regulatory compliance](https://learn.microsoft.com/en-us/azure/defender-for-cloud/regulatory-compliance-dashboard)
- [Azure Policy built-in definitions for CIS](https://learn.microsoft.com/en-us/azure/governance/policy/samples/cis-azure-foundations-benchmark)
