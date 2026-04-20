// ─── containers.bicep ────────────────────────────────────────────────────────
// Deploys: Azure Container Registry (Basic), AKS (1-node, Standard tier control plane),
//          Container Apps Environment + Container App, Container Instances.
//
// DEFAULT MODE: Admin user enabled on ACR, public endpoints, no RBAC enforcement,
//               no network policies. Out-of-the-box defaults for benchmark testing.
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

@description('AKS control-plane tier. Free is unavailable in some regions (capacity constraints); Standard is the reliable default.')
@allowed(['Free', 'Standard', 'Premium'])
param aksTier string = 'Standard'

@description('Resource tags.')
param tags object = {}

// ─── Azure Container Registry ─────────────────────────────────────────────────

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (deployAcr) {
  name: '${replace(prefix, '-', '')}acr${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    // Admin user enabled for easy demo access (default-like posture)
    adminUserEnabled: true
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Disabled'
  }
}

// ─── AKS ─────────────────────────────────────────────────────────────────────

resource aks 'Microsoft.ContainerService/managedClusters@2024-01-01' = if (deployAks) {
  name: '${prefix}-aks'
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: aksTier
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: '1.33'
    dnsPrefix: '${prefix}-aks'
    // Override the default MC_<rg>_<cluster>_<region> naming so the node RG
    // follows the ADE convention: <prefix>-aks-nodes-rg
    nodeResourceGroup: '${prefix}-aks-nodes-rg'
    enableRBAC: true
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
      }
    ]
    // Default network plugin (kubenet) — no CNI/Calico by default
    // serviceCidr must not overlap the VNet address space (10.0.0.0/16).
    networkProfile: {
      networkPlugin: 'kubenet'
      loadBalancerSku: 'standard'
      serviceCidr: '10.96.0.0/16'
      dnsServiceIP: '10.96.0.10'
    }
    // No OIDC/Workload Identity by default
    oidcIssuerProfile: {
      enabled: false
    }
    // No auto-upgrade by default
    autoUpgradeProfile: {
      upgradeChannel: 'none'
    }
  }
}

// ─── Container Apps Environment ───────────────────────────────────────────────

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2023-11-02-preview' = if (deployContainerApps) {
  name: '${prefix}-cae'
  location: location
  tags: tags
  properties: {
    // Consumption-only workload profile
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
        external: true
        targetPort: 80
        transport: 'auto'
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

resource containerInstance 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = if (deployContainerInstances) {
  name: '${prefix}-aci'
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: {
      type: 'Public'
      ports: [{ port: 80, protocol: 'TCP' }]
    }
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
output containerInstanceIp string = deployContainerInstances ? containerInstance!.properties.ipAddress.ip : ''

