# ADE Pre-Release Manual Test Checklist

> **Purpose:** Creator-run checklist before making the repository public.
> Run with prefix `ade`, location `westeurope`, profile `full`, mode `default` first; then repeat relevant sections with mode `hardened`.
> Live deployment in subscription must be active. Mark each item `[x]` when verified.
>
> **CIS reference:** CIS Microsoft Azure Foundations Benchmark v5.0.0 (sections 2–9; section 1 Entra/IAM excluded).

---

## Part 1 — Local Pre-flight

| # | Check | Command / How to verify |
|---|-------|------------------------|
| 1.1 | PowerShell 7 is default shell for this repo | `$PSVersionTable.PSVersion` → `7.x` |
| 1.2 | Azure CLI ≥ 2.60 installed | `az version` |
| 1.3 | Bicep CLI present | `az bicep version` |
| 1.4 | Authenticated and correct subscription active | `az account show --query "{name:name,id:id}" -o table` |
| 1.5 | Caller has Contributor + User Access Administrator | `az role assignment list --assignee <your-oid> --include-inherited --query "[].roleDefinitionName" -o tsv` |
| 1.6 | `EncryptionAtHost` feature registered (required for hardened compute) | `az feature show --name EncryptionAtHost --namespace Microsoft.Compute --query properties.state -o tsv` → `Registered` |
| 1.7 | Pester 5 installed locally | `(Get-Module Pester -ListAvailable) | Select-Object Version` → ≥ 5.0 |
| 1.8 | PSScriptAnalyzer installed | `Get-Module PSScriptAnalyzer -ListAvailable` |

---

## Part 2 — Automated Test Suite Pass

| # | Check | Command |
|---|-------|---------|
| 2.1 | All Bicep files lint clean | `find bicep -name '*.bicep' | xargs -I{} az bicep lint --file {} --no-restore` (0 errors) |
| 2.2 | All PS1 files pass PSScriptAnalyzer (Error severity) | `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Error` (0 errors) |
| 2.3 | All config JSON files parse correctly | `Get-ChildItem config -Recurse -Filter *.json | ForEach-Object { $null = Get-Content $_ | ConvertFrom-Json }` |
| 2.4 | Full Pester suite passes | `./tests/Invoke-PesterSuite.ps1` → 0 failures |
| 2.5 | GitHub Actions lint workflow passes on PR | Push a test branch, open a PR to main, confirm all three CI checks green |

---

## Part 3 — Default Mode Deployment (`-Profile full -Mode default`)

### 3.0 — Pre-deployment
| # | Check | How to verify |
|---|-------|---------------|
| 3.0.1 | WhatIf completes without fatal errors | `./scripts/deploy.ps1 -Profile full -Mode default -Prefix ade -Location westeurope -WhatIf -Force` |
| 3.0.2 | Confirmation prompt appears (non-force run) | Run without `-Force`; verify summary table and prompt; press N to cancel |

### 3.1 — Monitoring module (`ade-monitoring-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.1.1 | Log Analytics Workspace exists | `az monitor log-analytics workspace show -g ade-monitoring-rg -n ade-logs -o table` |
| 3.1.2 | Application Insights exists | `az monitor app-insights component show -g ade-monitoring-rg --app ade-appinsights -o table` |
| 3.1.3 | Action Group exists | `az monitor action-group show -g ade-monitoring-rg -n ade-action-group -o table` |

### 3.2 — Networking module (`ade-networking-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.2.1 | VNet `10.0.0.0/16` exists | `az network vnet show -g ade-networking-rg -n ade-vnet --query addressSpace -o table` |
| 3.2.2 | All 16 subnets provisioned | `az network vnet subnet list -g ade-networking-rg --vnet-name ade-vnet --query "[].{Name:name,Prefix:addressPrefix}" -o table` |
| 3.2.3 | Bastion (Developer SKU) exists | `az network bastion show -g ade-networking-rg -n ade-bastion -o table` |
| 3.2.4 | Network Watcher exists | `az network watcher show -g ade-networking-rg -n ade-networkwatcher -o table` |
| 3.2.5 | All NSGs associated to their subnets | `az network vnet subnet list -g ade-networking-rg --vnet-name ade-vnet --query "[?networkSecurityGroup].{Subnet:name}" -o table` |
| 3.2.6 | CIS 6.x baseline: NSGs have NO explicit allow rules for 0.0.0.0/0 on ports 22/3389 | `az network nsg rule list -g ade-networking-rg --nsg-name ade-compute-nsg --query "[?access=='Allow' && (destinationPortRange=='22' || destinationPortRange=='3389')]" -o table` → empty |

### 3.3 — Security module (`ade-security-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.3.1 | Key Vault exists with RBAC model | `az keyvault show -g ade-security-rg --query "{name:name,rbac:properties.enableRbacAuthorization}" -o table` → rbac=true |
| 3.3.2 | KV soft-delete enabled | `az keyvault show -g ade-security-rg --query "properties.enableSoftDelete" -o tsv` → true |
| 3.3.3 | User-Assigned Managed Identity exists | `az identity show -g ade-security-rg -n ade-identity -o table` |
| 3.3.4 | CIS 8.x baseline: KV purge protection NOT enabled (default mode — CIS 8.4 finding expected) | `az keyvault show -g ade-security-rg --query "properties.enablePurgeProtection" -o tsv` → null/false |
| 3.3.5 | CIS 8.x baseline: KV soft delete is only 7 days (CIS 8.4 finding expected) | `az keyvault show -g ade-security-rg --query "properties.softDeleteRetentionInDays" -o tsv` → 7 |

### 3.4 — Compute module (`ade-compute-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.4.1 | Windows VM running | `az vm show -g ade-compute-rg -n ade-win-vm --query "provisioningState" -o tsv` → Succeeded |
| 3.4.2 | Linux VM running | `az vm show -g ade-compute-rg -n ade-linux-vm --query "provisioningState" -o tsv` → Succeeded |
| 3.4.3 | Availability Set exists | `az vm availability-set show -g ade-compute-rg -n ade-avset -o table` |
| 3.4.4 | VMs have public IPs (default — CIS 7.x finding expected) | `az vm list-ip-addresses -g ade-compute-rg -o table` → IPs present |
| 3.4.5 | CIS 7.5 baseline: Linux VM password auth enabled (CIS 7.5 finding expected) | `az vm show -g ade-compute-rg -n ade-linux-vm --query "osProfile.linuxConfiguration.disablePasswordAuthentication" -o tsv` → false |
| 3.4.6 | CIS 7.7: No disk encryption configured (default — finding expected) | `az vm show -g ade-compute-rg -n ade-win-vm --query "storageProfile.osDisk.encryptionSettings" -o tsv` → null |
| 3.4.7 | Boot diagnostics enabled | `az vm show -g ade-compute-rg -n ade-win-vm --query "diagnosticsProfile.bootDiagnostics.enabled" -o tsv` → true |

### 3.5 — Storage module (`ade-storage-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.5.1 | Storage account exists | `az storage account list -g ade-storage-rg -o table` |
| 3.5.2 | CIS 3.1 baseline: HTTPS NOT enforced (finding expected) | `az storage account show -g ade-storage-rg -n <name> --query "enableHttpsTrafficOnly" -o tsv` → false |
| 3.5.3 | CIS 3.2 baseline: TLS 1.0 allowed (finding expected) | `az storage account show -g ade-storage-rg -n <name> --query "minimumTlsVersion" -o tsv` → TLS1_0 |
| 3.5.4 | CIS 3.5 baseline: Public blob access allowed (finding expected) | `az storage account show -g ade-storage-rg -n <name> --query "allowBlobPublicAccess" -o tsv` → true |
| 3.5.5 | CIS 3.8 baseline: Blob soft delete disabled (finding expected) | `az storage account blob-service-properties show -g ade-storage-rg -n <name> --query "deleteRetentionPolicy.enabled" -o tsv` → false |
| 3.5.6 | Data Lake Gen2 account exists (HNS enabled) | `az storage account list -g ade-storage-rg --query "[?kind=='StorageV2' && isHnsEnabled==\`true\`].name" -o tsv` |

### 3.6 — Databases module (`ade-databases-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.6.1 | SQL server + database exist | `az sql server list -g ade-databases-rg -o table` |
| 3.6.2 | AdventureWorksLT sample data loaded | `az sql db show -g ade-databases-rg -s <sql-server> -n ade-sqldb --query "sampleName" -o tsv` → AdventureWorksLT |
| 3.6.3 | CIS 4.1.2 baseline: AllowAll firewall rule exists (finding expected) | `az sql server firewall-rule list -g ade-databases-rg -s <sql-server> -o table` → 0.0.0.0–255.255.255.255 rule present |
| 3.6.4 | CIS 4.1.1 baseline: TLS min not enforced (finding expected) | `az sql server show -g ade-databases-rg -n <sql-server> --query "minimalTlsVersion" -o tsv` → None |
| 3.6.5 | Cosmos DB exists (serverless) | `az cosmosdb show -g ade-databases-rg --query "[{name:name,kind:kind}]" -o table` |
| 3.6.6 | PostgreSQL Flexible Server exists | `az postgres flexible-server list -g ade-databases-rg -o table` |
| 3.6.7 | CIS 4.3.x baseline: PostgreSQL Entra auth disabled (finding expected) | `az postgres flexible-server show -g ade-databases-rg -n <pg-server> --query "authConfig.activeDirectoryAuth" -o tsv` → Disabled |

### 3.7 — App Services module (`ade-appservices-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.7.1 | Web App, Function App, Logic App exist | `az webapp list -g ade-appservices-rg -o table` |
| 3.7.2 | CIS 9.2 baseline: HTTPS-only disabled (finding expected) | `az webapp show -g ade-appservices-rg -n ade-win-app --query "httpsOnly" -o tsv` → false |
| 3.7.3 | CIS 9.3 baseline: TLS 1.0 (finding expected) | `az webapp config show -g ade-appservices-rg -n ade-win-app --query "minTlsVersion" -o tsv` → 1.0 |
| 3.7.4 | CIS 9.10 baseline: FTPS allowed (finding expected) | `az webapp config show -g ade-appservices-rg -n ade-win-app --query "ftpsState" -o tsv` → AllAllowed |
| 3.7.5 | Function App is running | `az functionapp show -g ade-appservices-rg -n ade-funcapp --query "state" -o tsv` → Running |

### 3.8 — Containers module (`ade-containers-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.8.1 | Container Registry exists | `az acr show -g ade-containers-rg -n <acr-name> -o table` |
| 3.8.2 | CIS 8.x: ACR admin user enabled (finding expected) | `az acr show -g ade-containers-rg -n <acr-name> --query "adminUserEnabled" -o tsv` → true |
| 3.8.3 | AKS cluster running | `az aks show -g ade-containers-rg -n ade-aks --query "provisioningState" -o tsv` → Succeeded |
| 3.8.4 | AKS RBAC enabled | `az aks show -g ade-containers-rg -n ade-aks --query "enableRbac" -o tsv` → true |
| 3.8.5 | Container Apps environment + app exist | `az containerapp list -g ade-containers-rg -o table` |
| 3.8.6 | Container Instance exists | `az container show -g ade-containers-rg -n ade-aci --query "provisioningState" -o tsv` → Succeeded |

### 3.9 — Integration module (`ade-integration-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.9.1 | Service Bus namespace (`ade-sbus`) exists | `az servicebus namespace show -g ade-integration-rg -n ade-sbus -o table` |
| 3.9.2 | Event Hub namespace exists | `az eventhubs namespace show -g ade-integration-rg -n ade-eh -o table` |
| 3.9.3 | Event Grid topic exists | `az eventgrid topic show -g ade-integration-rg -n ade-evgtopic -o table` |
| 3.9.4 | SignalR service exists | `az signalr show -g ade-integration-rg -n ade-signalr -o table` |

### 3.10 — Governance module (`ade-governance-rg`)
| # | Check | Command |
|---|-------|---------|
| 3.10.1 | Automation Account exists | `az automation account show -g ade-governance-rg -n ade-automation -o table` |
| 3.10.2 | Runbooks published | `az automation runbook list -g ade-governance-rg --automation-account-name ade-automation -o table` → Stop-AdeResources and Start-AdeResources with state Published |
| 3.10.3 | Job schedules linked | `az rest --method GET --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/ade-governance-rg/providers/Microsoft.Automation/automationAccounts/ade-automation/jobSchedules?api-version=2023-11-01" --query "value[].properties.runbook.name" -o tsv` |

---

## Part 4 — CIS Azure Foundations Benchmark v3.0.0 Spot Checks

> Run these against the **default** deployment to confirm expected non-compliant baseline, then re-run against **hardened** to confirm remediation.

> CIS v5.0.0 section numbering: 1=IAM (excluded), 2=Defender for Cloud, 3=Storage, 4=Databases, 5=Logging & Monitoring, 6=Networking, 7=Virtual Machines, 8=Key Vault, 9=App Services.

### CIS Section 2 — Microsoft Defender for Cloud

| # | CIS Control | Expected in Default | Command |
|---|------------|---------------------|---------|
| 4.1 | 2.1 — Defender for Servers enabled | ❌ FAIL | `az security pricing show -n VirtualMachines --query "pricingTier" -o tsv` → Free |
| 4.2 | 2.1 — Defender for SQL enabled | ❌ FAIL | `az security pricing show -n SqlServers --query "pricingTier" -o tsv` → Free |
| 4.3 | 2.1 — Defender for Storage enabled | ❌ FAIL | `az security pricing show -n StorageAccounts --query "pricingTier" -o tsv` → Free |
| 4.4 | 2.1 — Defender for Containers enabled | ❌ FAIL | `az security pricing show -n Containers --query "pricingTier" -o tsv` → Free |
| 4.5 | 2.1 — Defender for Key Vault enabled | ❌ FAIL | `az security pricing show -n KeyVaults --query "pricingTier" -o tsv` → Free |
| 4.6 | 2.1 — Defender for App Services enabled | ❌ FAIL | `az security pricing show -n AppServices --query "pricingTier" -o tsv` → Free |
| 4.7 | 2.14 — Auto-provisioning MMA/AMA | ❌ FAIL | `az security auto-provisioning-setting show -n mma --query "autoProvision" -o tsv` → Off |
| 4.8 | 2.x — Security contact email configured | ❌ FAIL | `az security contact list --query "[].email" -o tsv` |
| 4.9 | **Hardened:** All Defender plans Standard | ✅ PASS | Re-run items 4.1–4.6 → StandardV2/Standard |

### CIS Section 3 — Storage Accounts

| # | CIS Control | Expected in Default | Command |
|---|------------|---------------------|---------|
| 4.10 | 3.1 — Secure transfer (HTTPS-only) | ❌ FAIL | `az storage account list -g ade-storage-rg --query "[].{Name:name,HTTPS:enableHttpsTrafficOnly}" -o table` |
| 4.11 | 3.2 — TLS 1.2 minimum | ❌ FAIL | `az storage account list -g ade-storage-rg --query "[].{Name:name,TLS:minimumTlsVersion}" -o table` |
| 4.12 | 3.5 — Public blob access | ❌ FAIL | `az storage account list -g ade-storage-rg --query "[?allowBlobPublicAccess==\`true\`].name" -o tsv` |
| 4.13 | 3.7 — Shared key auth | ❌ FAIL | `az storage account list -g ade-storage-rg --query "[?allowSharedKeyAccess!=\`false\`].name" -o tsv` |
| 4.14 | 3.8 — Blob soft delete | ❌ FAIL | `az storage account blob-service-properties show -g ade-storage-rg -n <name> --query "deleteRetentionPolicy" -o table` |
| 4.15 | 3.9 — Blob versioning | ❌ FAIL | `az storage account blob-service-properties show -g ade-storage-rg -n <name> --query "isVersioningEnabled" -o tsv` |
| 4.16 | **Hardened:** All 3.x controls pass | ✅ PASS | Re-run 4.10–4.15 |

### CIS Section 4 — Database Services

| # | CIS Control | Expected in Default | Command |
|---|------------|---------------------|---------|
| 4.17 | 4.1.1 — SQL TLS 1.2 | ❌ FAIL | `az sql server show -g ade-databases-rg -n <srv> --query "minimalTlsVersion" -o tsv` → None |
| 4.18 | 4.1.2 — No AllowAll firewall rule | ❌ FAIL | `az sql server firewall-rule list -g ade-databases-rg -s <srv> --query "[?endIpAddress=='255.255.255.255']" -o table` |
| 4.19 | 4.1.3 — SQL auditing enabled | ❌ FAIL | `az sql server audit-policy show -g ade-databases-rg -n <srv> --query "state" -o tsv` → Disabled |
| 4.20 | 4.2.1 — Defender for SQL (threat detection) | ❌ FAIL | `az sql server security-alert-policy show -g ade-databases-rg -n <srv> --query "state" -o tsv` → Disabled |
| 4.21 | 4.3.x — PostgreSQL Entra auth | ❌ FAIL | `az postgres flexible-server show -g ade-databases-rg -n <pg> --query "authConfig.activeDirectoryAuth" -o tsv` |
| 4.22 | 4.4.1 — Redis SSL-only | ❌ FAIL (when redis enabled) | `az redis show -g ade-databases-rg -n <redis> --query "enableNonSslPort" -o tsv` → true |
| 4.23 | **Hardened:** SQL AllowAll rule absent | ✅ PASS | Re-run 4.18 → empty |
| 4.24 | **Hardened:** SQL auditing + threat detection | ✅ PASS | Re-run 4.19, 4.20 → Enabled |

### CIS Section 5 — Logging and Monitoring

| # | CIS Control | Expected in Default | Command |
|---|------------|---------------------|---------|
| 4.25 | 5.1.x — Activity Log diagnostic setting to Log Analytics | ❌ FAIL | `az monitor diagnostic-settings subscription list --query "value[?contains(workspaceId, 'ade-logs')]" -o table` |
| 4.26 | 5.2.x — Activity Log alert: Create/Update security policy | ❌ FAIL | `az monitor activity-log alert list -g ade-monitoring-rg -o table` |
| 4.27 | 5.3 — Log Analytics retention ≥ 90 days | ❌ FAIL (default 30 days) | `az monitor log-analytics workspace show -g ade-monitoring-rg -n ade-logs --query "retentionInDays" -o tsv` → 30 |
| 4.28 | **Hardened:** retention + alerts configured | Review hardened monitoring.bicep | Verify `az monitor activity-log alert list` |

### CIS Section 6 — Networking

| # | CIS Control | Expected in Default | Command |
|---|------------|---------------------|---------|
| 4.29 | 6.2 — No RDP/22 from Internet on NSGs | ✅ PASS (no explicit allow rule) | `az network nsg rule list -g ade-networking-rg --nsg-name ade-compute-nsg --query "[?access=='Allow' && sourceAddressPrefix=='*' && (destinationPortRange=='22' || destinationPortRange=='3389')]" -o table` → empty |
| 4.30 | 6.3 — SSH/RDP not open via management port | ✅ PASS (Bastion is the access path) | Confirm no VM has a JIT rule permitting internet-sourced RDP/SSH |
| 4.31 | 6.4 — NSG flow logs enabled | ❌ FAIL | `az network watcher flow-log list -l westeurope --query "[?contains(storageId,'ade')]" -o table` → empty |
| 4.32 | 6.5 — Network Watcher enabled | ✅ PASS | `az network watcher show -g ade-networking-rg -n ade-networkwatcher -o table` |
| 4.33 | 6.6 — Bastion is the access method (no public management ports) | ✅ PASS | Confirm Bastion exists and is reachable |

### CIS Section 7 — Virtual Machines

| # | CIS Control | Expected in Default | Command |
|---|------------|---------------------|---------|
| 4.34 | 7.1 — OS disks not unmanaged | ✅ PASS | `az vm show -g ade-compute-rg -n ade-win-vm --query "storageProfile.osDisk.managedDisk" -o tsv` → ID set |
| 4.35 | 7.2 — Disk encryption | ❌ FAIL | `az vm encryption show -g ade-compute-rg -n ade-win-vm -o table` |
| 4.36 | 7.3 — No VHDs in public blob storage | ✅ PASS | All disks are managed |
| 4.37 | 7.4 — Auto-shutdown / trusted launch | ❓ (profile-dependent) | `az vm show -g ade-compute-rg -n ade-win-vm --query "securityProfile" -o table` |
| 4.38 | 7.5 — Linux password auth disabled | ❌ FAIL | `az vm show -g ade-compute-rg -n ade-linux-vm --query "osProfile.linuxConfiguration.disablePasswordAuthentication" -o tsv` → false |
| 4.39 | 7.7 — Azure Monitor Agent or MMA installed | ❌ FAIL (default) | `az vm extension list -g ade-compute-rg --vm-name ade-win-vm --query "[?name=='AzureMonitorWindowsAgent']" -o table` → empty |
| 4.40 | **Hardened:** 7.3 password disabled, AMA installed, no public IP | ✅ PASS | Re-run 4.38, 4.39; confirm no public IP: `az vm list-ip-addresses -g ade-compute-rg -o table` → no public IPs |

### CIS Section 8 — Key Vault

| # | CIS Control | Expected in Default | Command |
|---|------------|---------------------|---------|
| 4.41 | 8.1 — Key Vault firewall enabled | ❌ FAIL | `az keyvault show -g ade-security-rg --query "properties.networkAcls.defaultAction" -o tsv` → Allow |
| 4.42 | 8.4 — Soft delete enabled | ✅ PASS | `az keyvault show -g ade-security-rg --query "properties.enableSoftDelete" -o tsv` → true |
| 4.43 | 8.4 — Purge protection enabled | ❌ FAIL (default) | `az keyvault show -g ade-security-rg --query "properties.enablePurgeProtection" -o tsv` → null |
| 4.44 | 8.5 — RBAC authorization model | ✅ PASS | `az keyvault show -g ade-security-rg --query "properties.enableRbacAuthorization" -o tsv` → true |
| 4.45 | 8.x — Key expiry dates set | Seeded demo key has no expiry (expected) | `az keyvault key list --vault-name <kv> --query "[].{Key:name,Expires:attributes.expires}" -o table` |
| 4.46 | **Hardened:** Purge protection, private endpoint, network ACL deny | ✅ PASS | Re-run 4.41–4.43 |

### CIS Section 9 — App Services

| # | CIS Control | Expected in Default | Command |
|---|------------|---------------------|---------|
| 4.47 | 9.2 — HTTPS-only | ❌ FAIL | `az webapp show -g ade-appservices-rg -n ade-win-app --query "httpsOnly" -o tsv` → false |
| 4.48 | 9.3 — TLS 1.2 minimum | ❌ FAIL | `az webapp config show -g ade-appservices-rg -n ade-win-app --query "minTlsVersion" -o tsv` → 1.0 |
| 4.49 | 9.4 — Client certificates | ❌ FAIL | `az webapp show -g ade-appservices-rg -n ade-win-app --query "clientCertEnabled" -o tsv` → false |
| 4.50 | 9.5 — Managed identity enabled | ❌ FAIL | `az webapp show -g ade-appservices-rg -n ade-win-app --query "identity" -o tsv` → null |
| 4.51 | 9.9 — Remote debugging disabled | ✅ PASS | `az webapp config show -g ade-appservices-rg -n ade-win-app --query "remoteDebuggingEnabled" -o tsv` → false |
| 4.52 | 9.10 — FTP disabled | ❌ FAIL | `az webapp config show -g ade-appservices-rg -n ade-win-app --query "ftpsState" -o tsv` → AllAllowed |
| 4.53 | **Hardened:** all 9.x controls pass | ✅ PASS | Re-run 4.47–4.52 |

---

## Part 5 — Hardened Mode Deployment (`-Profile hardened -Mode hardened`)

> Deploy on top of the existing default deployment (same prefix): `./scripts/deploy.ps1 -Profile hardened -Mode hardened -Prefix ade -Location westeurope -Force`

| # | Check | How to verify |
|---|-------|---------------|
| 5.1 | `EncryptionAtHost` feature is **Registered** before deploying | `az feature show --name EncryptionAtHost --namespace Microsoft.Compute --query properties.state -o tsv` → Registered. If Registering, wait. |
| 5.2 | Hardened networking: NSGs have explicit deny-internet-inbound rule | `az network nsg rule list -g ade-networking-rg --nsg-name ade-compute-nsg --query "[?name=='Deny_Internet_Inbound']" -o table` → 1 rule |
| 5.3 | Hardened compute: no public IPs on VMs | `az vm list-ip-addresses -g ade-compute-rg -o table` → no public IPs |
| 5.4 | Hardened compute: encryption at host enabled | `az vm show -g ade-compute-rg -n ade-win-vm --query "securityProfile.encryptionAtHost" -o tsv` → true |
| 5.5 | Hardened compute: Trusted Launch + Secure Boot + vTPM | `az vm show -g ade-compute-rg -n ade-win-vm --query "securityProfile" -o table` |
| 5.6 | Hardened compute: AMA extension installed | `az vm extension list -g ade-compute-rg --vm-name ade-win-vm --query "[?name=='AzureMonitorWindowsAgent'].provisioningState" -o tsv` → Succeeded |
| 5.7 | Hardened compute: DCR association exists | `az rest --method GET --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/ade-compute-rg/providers/Microsoft.Compute/virtualMachines/ade-win-vm/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11" --query "value[].name" -o tsv` |
| 5.8 | Hardened compute: Linux password auth disabled | `az vm show -g ade-compute-rg -n ade-linux-vm --query "osProfile.linuxConfiguration.disablePasswordAuthentication" -o tsv` → true |
| 5.9 | Hardened security: KV purge protection + 90-day soft delete | `az keyvault show -g ade-security-rg --query "{purge:properties.enablePurgeProtection,retentionDays:properties.softDeleteRetentionInDays}" -o table` |
| 5.10 | Hardened security: KV network ACL default deny | `az keyvault show -g ade-security-rg --query "properties.networkAcls.defaultAction" -o tsv` → Deny |
| 5.11 | Hardened security: KV private endpoint exists | `az network private-endpoint list -g ade-security-rg -o table` |
| 5.12 | Hardened security: Defender all plans StandardV2 | `az security pricing list --query "[*].{Name:name,Tier:pricingTier}" -o table` → all Standard* |
| 5.13 | Hardened security: Sentinel solution installed | `az resource list -g ade-security-rg --resource-type "Microsoft.OperationsManagement/solutions" -o table` |
| 5.14 | Hardened storage: HTTPS-only, TLS 1.2 | `az storage account list -g ade-storage-rg --query "[].{Name:name,HTTPS:enableHttpsTrafficOnly,TLS:minimumTlsVersion}" -o table` |
| 5.15 | Hardened storage: shared key disabled | `az storage account list -g ade-storage-rg --query "[?allowSharedKeyAccess!=\`false\`].name" -o tsv` → empty |
| 5.16 | Hardened databases: SQL AllowAll rule absent | `az sql server firewall-rule list -g ade-databases-rg -s <srv> --query "[?endIpAddress=='255.255.255.255']" -o table` → empty |
| 5.17 | Hardened databases: SQL auditing enabled | `az sql server audit-policy show -g ade-databases-rg -n <srv> --query "state" -o tsv` → Enabled |
| 5.18 | Hardened databases: SQL threat detection | `az sql server security-alert-policy show -g ade-databases-rg -n <srv> --query "state" -o tsv` → Enabled |
| 5.19 | Hardened databases: SQL private endpoint exists | `az network private-endpoint list -g ade-databases-rg --query "[?contains(name,'sql')]" -o table` |
| 5.20 | Hardened appservices: HTTPS-only true | `az webapp show -g ade-appservices-rg -n ade-win-app --query "httpsOnly" -o tsv` → true |
| 5.21 | Hardened appservices: TLS 1.2 | `az webapp config show -g ade-appservices-rg -n ade-win-app --query "minTlsVersion" -o tsv` → 1.2 |
| 5.22 | Hardened appservices: FTPS disabled | `az webapp config show -g ade-appservices-rg -n ade-win-app --query "ftpsState" -o tsv` → Disabled |
| 5.23 | Hardened appservices: managed identity | `az webapp show -g ade-appservices-rg -n ade-win-app --query "identity.type" -o tsv` → SystemAssigned |
| 5.24 | Hardened integration: Service Bus disableLocalAuth | `az servicebus namespace show -g ade-integration-rg -n ade-sbus --query "disableLocalAuth" -o tsv` → true |
| 5.25 | Hardened governance: Automation Account disableLocalAuth | Review ARM properties for disableLocalAuth on Automation Account |

---

## Part 6 — Seed Data Verification

| # | Check | Command |
|---|-------|---------|
| 6.1 | Seed script runs without errors | `./scripts/seed-data.ps1 -Prefix ade -Force` (0 errors) |
| 6.2 | Storage blobs present | `az storage blob list --account-name <sa> --container-name data -o table` |
| 6.3 | Storage queue seeded | `az storage queue list --account-name <sa> -o table` → demo-tasks queue |
| 6.4 | Storage table seeded | `az storage table list --account-name <sa> -o table` → demotable |
| 6.5 | Storage file share seeded | `az storage file list --account-name <sa> --share-name ade-files -o table` → welcome.txt |
| 6.6 | Cosmos DB orders seeded | `az cosmosdb sql document list -g ade-databases-rg -a <cosmos> -d adedb -c orders -o table` |
| 6.7 | Azure SQL seed.sql ran | Connect to SQL (`sqlcmd` or SSMS) → `SELECT TOP 5 * FROM SalesLT.Customer` |
| 6.8 | Key Vault demo secret exists | `az keyvault secret show --vault-name <kv> -n demo-secret -o table` |
| 6.9 | Key Vault RSA key exists | `az keyvault key show --vault-name <kv> -n demo-encryption-key -o table` |
| 6.10 | Key Vault self-signed certificate exists | `az keyvault certificate show --vault-name <kv> -n demo-cert -o table` |
| 6.11 | Service Bus message sent | `az servicebus queue show -g ade-integration-rg -n <ns> --queue-name orders --query "messageCount" -o tsv` → ≥ 1 |
| 6.12 | **Hardened seeding:** re-run `seed-data.ps1` after hardened deploy; verify storage uses `--auth-mode login` path (warning logged) |
| 6.13 | **Hardened seeding:** Cosmos seeding skipped/warned when `disableLocalAuth=true` (expected) | Confirm in seed output log |

---

## Part 7 — GitHub Actions Workflow Tests

| # | Check | How to verify |
|---|-------|---------------|
| 7.1 | Lint workflow runs on PR and passes | Open a PR to main, observe `ADE — Lint` in Checks → all green |
| 7.2 | Bicep lint covers all files | In lint run, confirm all `bicep/**/*.bicep` files appear in job output |
| 7.3 | PSScriptAnalyzer step runs | In lint run, `PS Lint` job produces 0 errors |
| 7.4 | Deploy workflow available in Actions tab | Navigate to Actions → `ADE — Deploy` → trigger manually |
| 7.5 | Deploy workflow input validation rejects bad prefix | Set prefix to `INVALID!` → workflow should fail at "Validate free-text inputs" step |
| 7.6 | Deploy workflow what-if step runs | In `ADE — Deploy` run, confirm `What-if` step executes (may warn, should not fail entire workflow) |
| 7.7 | Deploy workflow OIDC authentication succeeds | In `Azure Login (OIDC)` step, confirm no credential errors |
| 7.8 | Job summary is written | After full deploy run, check Summary tab for module/RG table |
| 7.9 | Destroy workflow requires confirmation | Navigate to `ADE — Destroy` → verify `demo` environment protection gate blocks immediate execution |
| 7.10 | Destroy workflow module input validation | Set `modules=invalidname` → confirm validation step fails with useful error |
| 7.11 | Concurrency group blocks parallel deploy+destroy | Trigger both simultaneously → confirm second run waits for first |
| 7.12 | Release workflow triggers on `v*` tag | Push a `v1.0.0-rc1` tag → confirm release draft created with CHANGELOG extract |

---

## Part 8 — Destroy and Redeployability

| # | Check | Command / How to verify |
|---|-------|------------------------|
| 8.1 | Destroy script lists target RGs before deleting | `./scripts/destroy.ps1 -Prefix ade` (no -Force) → shows RGs, prompts for `DELETE` |
| 8.2 | Destroy script respects `-Modules` subset | `./scripts/destroy.ps1 -Prefix ade -Modules compute,storage -Force` → only those two RGs deleted |
| 8.3 | KV purge runs after full teardown | In destroy output, confirm "Purging soft-deleted Key Vaults" line appears |
| 8.4 | Cognitive Services purge runs (when AI deployed) | Same as 8.3 for Cognitive Services |
| 8.5 | Full destroy completes in < 30 min | Time a full destroy run |
| 8.6 | Fresh re-deploy succeeds after destroy | Run `./scripts/deploy.ps1` immediately after destroy — no "name already exists" errors |
| 8.7 | ⚠️ Re-deploy with same prefix after **partial** destroy | Delete only `ade-security-rg`; re-run deploy.ps1 → state hydration recovers remaining module outputs |

---

## Part 9 — Public Repository Readiness

| # | Check | How to verify |
|---|-------|---------------|
| 9.1 | No subscription IDs hardcoded | `grep -r "[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}" bicep scripts config` → only known role definition GUIDs |
| 9.2 | No tenant IDs hardcoded | Same grep → no tenant GUIDs except `tenant().tenantId` Bicep calls |
| 9.3 | No real passwords or secrets | `grep -ri "password\s*=\s*[^$\$]" bicep scripts` → no literal password strings |
| 9.4 | No personal email addresses | `grep -r "@" bicep scripts config .github` → only `admin@example.com` placeholder |
| 9.5 | OIDC auth in workflows (no stored SP credentials) | Confirm `az login` in all workflow files uses `azure/login@...` with `client-id`, `tenant-id`, `subscription-id` from secrets — no `client-secret` or password |
| 9.6 | GitHub Actions secrets are environment-scoped | In GitHub repo Settings → Environments → `demo` → confirm all 4 secrets listed there, not at repo level |
| 9.7 | Making repo public does NOT expose secret values | Verify: secret VALUES are never visible in workflow YAML or logs; only names are. Public visibility of names (`AZURE_CLIENT_ID` etc.) is expected and not a concern. |
| 9.8 | All workflow action steps use SHA-pinned versions | `grep -r "uses:" .github/workflows/` → all `@<40-char-sha>` |
| 9.9 | `.gitignore` covers sensitive output files | Verify `.env`, `*.pem`, `*.pfx`, `.azure/`, `*.log` are in `.gitignore` |
| 9.10 | `SECURITY.md` exists and has vulnerability reporting path | `cat SECURITY.md` → private reporting link present |
| 9.11 | `LICENSE` file present | `ls LICENSE` → MIT |
| 9.12 | `README.md` cost warning is prominent | Verify `[!WARNING]` cost block appears near the top |
| 9.13 | `CHANGELOG.md` date is not in the future | Check `## [1.0.0] - YYYY-MM-DD` — must be today's date or earlier |
| 9.14 | `benchmark-guide.md` references correct CIS version | File should reference CIS Microsoft Azure Foundations Benchmark v3.0.0, not v2.0 |
| 9.15 | No copilot prompt files committed | `.github/prompts/` should be empty or absent (in `.gitignore`) |
| 9.16 | Dependabot or similar automated PR bot configured | `.github/dependabot.yml` exists |
| 9.17 | Branch protection on `main` requires PR + CI check | Settings → Branches → `main` → require PR, require status checks (lint) |

---

## Part 10 — Known Intentional Findings (for your own reference)

The following items are **by design** in default mode and generate expected CIS findings. Confirm they appear as findings when you run a Defender CSPM scan in default mode, then verify they clear in hardened mode.

| Finding | Default | Hardened | CIS Reference |
|---------|---------|----------|---------------|
| Storage HTTPS not enforced | ❌ | ✅ | CIS 3.1 |
| Storage TLS < 1.2 | ❌ | ✅ | CIS 3.2 |
| Public blob access | ❌ | ✅ | CIS 3.5 |
| Shared key access enabled | ❌ | ✅ | MCSB IM-3 |
| Blob soft delete disabled | ❌ | ✅ | CIS 3.8 |
| SQL AllowAll firewall rule | ❌ | ✅ | CIS 4.1.2 |
| SQL TLS not 1.2 | ❌ | ✅ | CIS 4.1.1 |
| SQL auditing disabled | ❌ | ✅ | CIS 4.1.3 |
| SQL Defender/threat detection off | ❌ | ✅ | CIS 4.2.1 |
| PostgreSQL Entra auth disabled | ❌ | ✅ | CIS 4.3.x |
| Redis non-SSL port open | ❌ | ✅ | CIS 4.4.x |
| App Service HTTPS-only false | ❌ | ✅ | CIS 9.2 |
| App Service TLS 1.0 | ❌ | ✅ | CIS 9.3 |
| App Service FTPS allowed | ❌ | ✅ | CIS 9.10 |
| App Service no managed identity | ❌ | ✅ | CIS 9.5 |
| VM public IPs | ❌ | ✅ | CIS 7.x |
| Linux VM password auth enabled | ❌ | ✅ | CIS 7.5 |
| No disk encryption | ❌ | ✅ | CIS 7.7 |
| No AMA agent | ❌ | ✅ | CIS 7.x / MCSB LT-3 |
| KV purge protection off | ❌ | ✅ | CIS 8.4 |
| KV public network access on | ❌ | ✅ | CIS 8.1 |
| ACR admin user enabled | ❌ | ✅ | CIS 8.x |
| All Defender plans Free | ❌ | ✅ | CIS 2.1 |
| NSG flow logs absent | ❌ | ❌ GAP | CIS 6.4 |
| No Activity Log diagnostic setting | ❌ | ❌ GAP | CIS 5.1 |

> **Gap items** (`❌ GAP`) are architectural gaps not yet implemented in any module. They are documented here for awareness but do not block release.

---

*Generated: based on code review of commit `ed67bc3`. Update the checklist when modules change.*
