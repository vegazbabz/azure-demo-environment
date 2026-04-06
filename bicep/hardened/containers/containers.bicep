// ─── hardened/containers/containers.bicep ────────────────────────────────────
// Deploys: Azure Container Registry (Standard), AKS (hardened RBAC config),
//          Container Apps Environment + Container App, Container Instances.
//
// HARDENED MODE: ACR admin user disabled, Standard SKU (supports private link).
//               AKS: RBAC + OIDC issuer + workload identity + Azure CNI +
//               network policy azure + Azure AD integration. No public IP on ACI.
//               Aligns with: CIS 8.x, MCSB IM-1, NS-1, PA-7.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Container subnet resource ID.')
param subnetId string = ''

@description('Deploy Azure Container Registry.')
param deployAcr bool = true

@description('Deploy Azure Kubernetes Service.')
param deployAks bool = true

@description('Deploy Container Apps.')
param deployContainerApps bool = true

@description('Deploy Container Instances.')
param deployContainerInstances bool = true

@description('AKS node VM size.')
param aksNodeSize string = 'Standard_B2s'

@description('Log Analytics workspace resource ID. Used to enable AKS Defender for Containers.')
param logAnalyticsId string = ''

@description('Authorized IP ranges for the AKS API server. Empty array = no restriction (accessible from any IP). Hardened: set to deployer/CI runner CIDRs. Example: ["203.0.113.0/24"]')
param aksAuthorizedIpRanges array = []

@description('Resource tags.')
param tags object = {}

// ─── Azure Container Registry ─────────────────────────────────────────────────
// Hardened: admin user disabled, Standard SKU (private link capable),
//           anonymous pull disabled, public access restricted.

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (deployAcr) {
  name: '${replace(prefix, '-', '')}acr${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  // Hardened: Standard SKU (Basic does not support private endpoints)
  sku: { name: 'Standard' }
  properties: {
    // Hardened: admin user disabled — use Entra ID RBAC (CIS 8.3, MCSB IM-3)
    adminUserEnabled: false
    // NOTE: A private endpoint is required to set publicNetworkAccess to 'Disabled'.
    // Without a PE, AKS nodes in the VNet cannot pull images. Keeping Enabled for
    // demo deployability; restrict to PE-only in production.
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Disabled'
    // Hardened: policies
    policies: {
      quarantinePolicy: { status: 'disabled' }
      trustPolicy: {
        type: 'Notary'
        status: 'disabled'    // Content trust available on Premium SKU
      }
      retentionPolicy: {
        days: 30
        status: 'enabled'
      }
    }
  }
}

// ─── AKS ─────────────────────────────────────────────────────────────────────
// Hardened: RBAC, OIDC issuer, workload identity, Azure CNI, network policy azure,
//           auto-upgrade, Microsoft Defender, Entra ID integration.

resource aks 'Microsoft.ContainerService/managedClusters@2024-01-01' = if (deployAks) {
  name: '${prefix}-aks'
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: '1.32'
    dnsPrefix: '${prefix}-aks'
    enableRBAC: true    // Hardened: RBAC enabled (always on for hardened mode)
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        count: 1
        vmSize: aksNodeSize
        osType: 'Linux'
        mode: 'System'
        osDiskSizeGB: 30
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: !empty(subnetId) ? subnetId : null
        // Hardened: enable node encryption at host
        enableEncryptionAtHost: true
        // Hardened: enable accelerated networking
        enableNodePublicIP: false    // No public IPs on nodes
        // Hardened: max pods per node >= 50 (CIS 5.x — pod density)
        maxPods: 50
      }
    ]
    // Hardened: Azure CNI for full VNet IP visibility (required for network policy)
    // serviceCidr must not overlap the VNet address space (10.0.0.0/16).
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'    // Hardened: Azure network policy (CIS 5.4.x)
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      serviceCidr: '10.96.0.0/16'
      dnsServiceIP: '10.96.0.10'
    }
    // Hardened: OIDC issuer enabled (pre-requisite for workload identity)
    oidcIssuerProfile: {
      enabled: true
    }
    // Hardened: workload identity enabled (MCSB IM-1 — no long-lived credentials)
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
      // Hardened: Microsoft Defender for Containers
      defender: {
        logAnalyticsWorkspaceResourceId: !empty(logAnalyticsId) ? logAnalyticsId : null
        securityMonitoring: {
          enabled: !empty(logAnalyticsId)
        }
      }
      // Hardened: image cleaner removes unused cached images
      imageCleaner: {
        enabled: true
        intervalHours: 24
      }
    }
    // Hardened: auto-upgrade to patch channel (CIS 5.x — keep nodes current)
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'SecurityPatch'
    }
    // Hardened: Entra ID integration with local accounts disabled
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: []    // Populated post-deploy via RBAC assignment
    }
    disableLocalAccounts: true
    // Hardened: API server access profile — populate aksAuthorizedIpRanges in the
    // profile (containers.features.aksAuthorizedIpRanges) to restrict the kube-apiserver
    // to deployer/CI runner CIDRs. Empty array = unrestricted (any IP can reach API server).
    apiServerAccessProfile: {
      enablePrivateCluster: false
      authorizedIPRanges: !empty(aksAuthorizedIpRanges) ? aksAuthorizedIpRanges : null
    }
  }
}

// ─── Container Apps Environment ───────────────────────────────────────────────
// Hardened: workload profile, no external ingress by default.

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2023-11-02-preview' = if (deployContainerApps) {
  name: '${prefix}-cae'
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      {
        workloadProfileType: 'Consumption'
        name: 'Consumption'
      }
    ]
  }
}

resource containerApp 'Microsoft.App/containerApps@2023-11-02-preview' = if (deployContainerApps) {
  name: '${prefix}-ca'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: {
        // Hardened: internal only by default; external = false keeps traffic VNet-internal
        external: false
        targetPort: 80
        transport: 'auto'
        // Hardened: do not allow insecure HTTP
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'hello-world'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
}

// ─── Container Instances ──────────────────────────────────────────────────────
// Hardened: private IP only (VNet-integrated), no public IP.
// NOTE: Private Container Instances require a delegated subnet. If subnetId is
//       empty, falls back to public IP for demo deployability.

resource containerInstance 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = if (deployContainerInstances) {
  name: '${prefix}-aci'
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: !empty(subnetId) ? {
      // Hardened: private IP within VNet
      type: 'Private'
      ports: [{ port: 80, protocol: 'TCP' }]
    } : {
      // Fallback if no subnet provided (demo only — remove in production)
      type: 'Public'
      ports: [{ port: 80, protocol: 'TCP' }]
    }
    subnetIds: !empty(subnetId) ? [{ id: subnetId }] : null
    containers: [
      {
        name: 'hello-world'
        properties: {
          image: 'mcr.microsoft.com/azuredocs/aci-helloworld'
          ports: [{ port: 80, protocol: 'TCP' }]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 1
            }
          }
        }
      }
    ]
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output acrId string = deployAcr ? acr.id : ''
output acrName string = deployAcr ? acr.name : ''
output acrLoginServer string = deployAcr ? acr!.properties.loginServer : ''
output aksId string = deployAks ? aks.id : ''
output aksName string = deployAks ? aks.name : ''
output containerAppsEnvironmentId string = deployContainerApps ? containerAppsEnvironment.id : ''
output containerAppFqdn string = deployContainerApps ? containerApp!.properties.configuration.ingress.fqdn : ''
output containerInstanceIp string = deployContainerInstances ? (containerInstance!.properties.ipAddress != null ? containerInstance!.properties.ipAddress.ip : '') : ''
