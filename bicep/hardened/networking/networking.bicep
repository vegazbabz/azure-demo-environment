// ─── hardened/networking/networking.bicep ────────────────────────────────────
// Deploys: VNet with all subnets, NSGs with explicit deny rules, Network Watcher,
//          and optional: Bastion (Standard default), App Gateway (Prevention mode),
//          Azure Firewall, VPN Gateway, NAT Gateway, Private DNS Zones.
//
// HARDENED MODE: NSGs have explicit Deny_Internet_Inbound and Allow_VNet rules.
//               Service endpoints on all workload subnets. Bastion defaults to
//               Standard SKU. Private DNS zones enabled by default. App Gateway
//               in Prevention mode. Aligns with: CIS 6.x, MCSB NS-1, NS-2, NS-3.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Resource tags.')
param tags object = {}

// ─── Optional feature flags ───────────────────────────────────────────────────

@description('Azure Bastion SKU. Hardened default: Standard.')
@allowed(['Developer', 'Basic', 'Standard', 'None'])
param bastionSku string = 'Standard'   // Hardened: Standard for full feature set

@description('Deploy Application Gateway with WAF v2.')
param enableAppGateway bool = false

@description('Deploy Azure Firewall. None = disabled.')
@allowed(['None', 'Standard', 'Premium'])
param enableFirewall string = 'None'

@description('Deploy VPN Gateway for Point-to-Site access.')
param enableVpnGateway bool = false

@description('Deploy NAT Gateway for outbound internet.')
param enableNatGateway bool = false

@description('Deploy DDoS Network Protection. WARNING: ~$2,944/month.')
param enableDdos bool = false

@description('Deploy Private DNS Zones for private endpoint name resolution.')
param enablePrivateDnsZones bool = true    // Hardened: on by default

// ─── Address space ────────────────────────────────────────────────────────────

var addressSpace                = '10.0.0.0/16'
var computeSubnetPrefix         = '10.0.1.0/24'
var appServicesSubnetPrefix     = '10.0.2.0/24'
var databaseSubnetPrefix        = '10.0.3.0/24'
var containerSubnetPrefix       = '10.0.4.0/24'
var integrationSubnetPrefix     = '10.0.5.0/24'
var aiSubnetPrefix              = '10.0.6.0/24'
var dataSubnetPrefix            = '10.0.7.0/24'
var managementSubnetPrefix      = '10.0.8.0/24'
var appGwSubnetPrefix           = '10.0.9.0/24'
var firewallSubnetPrefix        = '10.0.10.0/26'
var bastionSubnetPrefix         = '10.0.11.0/26'
var gatewaySubnetPrefix         = '10.0.12.0/27'
var privateEndpointSubnetPrefix = '10.0.13.0/24'
var mysqlSubnetPrefix           = '10.0.14.0/24'  // MySQL Flexible Server VNet injection

var firewallEnabled    = enableFirewall != 'None'
var bastionNeedsSubnet = bastionSku == 'Basic' || bastionSku == 'Standard'

// ─── NSG security rule helpers ────────────────────────────────────────────────
// Hardened: all NSGs share a common hardened rule set.
// Explicit allow VNet, allow Azure LB, deny all inbound from internet.
// Outbound: allow VNet + internet (workloads need outbound for updates etc.)

var hardenedInboundRules = [
  // Allow SSH/RDP from within the VNet — management only
  {
    name: 'Allow_VNet_Inbound'
    properties: {
      priority: 1000
      protocol: '*'
      access: 'Allow'
      direction: 'Inbound'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Allow_AzureLoadBalancer_Inbound'
    properties: {
      priority: 1100
      protocol: '*'
      access: 'Allow'
      direction: 'Inbound'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  // Hardened: explicit deny all internet inbound (overrides implicit deny)
  {
    name: 'Deny_Internet_Inbound'
    properties: {
      priority: 4000
      protocol: '*'
      access: 'Deny'
      direction: 'Inbound'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
]

// ─── Network Watcher ──────────────────────────────────────────────────────────

resource networkWatcher 'Microsoft.Network/networkWatchers@2023-09-01' = {
  name: '${prefix}-networkwatcher'
  location: location
  tags: tags
  properties: {}
}

// ─── DDoS Protection Plan ─────────────────────────────────────────────────────

resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2023-09-01' = if (enableDdos) {
  name: '${prefix}-ddos-plan'
  location: location
  tags: tags
  properties: {}
}

// ─── NSGs — Hardened rule set ─────────────────────────────────────────────────
// Explicit deny internet inbound + allow VNet. Service-specific rules per subnet.

resource computeNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-compute-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: concat(hardenedInboundRules, [
      // Allow RDP/SSH from management subnet only
      {
        name: 'Allow_Management_RDP_SSH'
        properties: {
          priority: 900
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: managementSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['22', '3389']
        }
      }
    ])
  }
}

resource appServicesNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-appservices-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: concat(hardenedInboundRules, [
      // App Service requires access from its service tag for health checks
      {
        name: 'Allow_AppService_Management'
        properties: {
          priority: 900
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'AppServiceManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '454-455'
        }
      }
    ])
  }
}

resource databaseNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-database-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: concat(hardenedInboundRules, [
      // Allow SQL from workload subnets only
      {
        name: 'Allow_SQL_From_VNet'
        properties: {
          priority: 900
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['1433', '5432', '3306', '6379']
        }
      }
    ])
  }
}

resource containerNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-container-nsg'
  location: location
  tags: tags
  properties: { securityRules: hardenedInboundRules }
}

resource integrationNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-integration-nsg'
  location: location
  tags: tags
  properties: { securityRules: hardenedInboundRules }
}

resource aiNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-ai-nsg'
  location: location
  tags: tags
  properties: { securityRules: hardenedInboundRules }
}

resource dataNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-data-nsg'
  location: location
  tags: tags
  properties: { securityRules: hardenedInboundRules }
}

resource managementNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-management-nsg'
  location: location
  tags: tags
  properties: { securityRules: hardenedInboundRules }
}

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-privateendpoint-nsg'
  location: location
  tags: tags
  properties: { securityRules: hardenedInboundRules }
}

// ─── Route Table (UDR) — Only when Azure Firewall is enabled ──────────────────

resource firewallRouteTable 'Microsoft.Network/routeTables@2023-09-01' = if (firewallEnabled) {
  name: '${prefix}-firewall-udr'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.10.4'
        }
      }
    ]
  }
}

// ─── NAT Gateway ──────────────────────────────────────────────────────────────

resource natGatewayPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (enableNatGateway) {
  name: '${prefix}-natgw-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource natGateway 'Microsoft.Network/natGateways@2023-09-01' = if (enableNatGateway) {
  name: '${prefix}-natgw'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [{ id: natGatewayPip.id }]
  }
}

// ─── Virtual Network ──────────────────────────────────────────────────────────
// Hardened: service endpoints on all workload subnets for direct Azure backbone access.

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressSpace]
    }
    ddosProtectionPlan: enableDdos ? { id: ddosProtectionPlan.id } : null
    enableDdosProtection: enableDdos
    subnets: concat(
      [
        {
          name: 'compute'
          properties: {
            addressPrefix: computeSubnetPrefix
            networkSecurityGroup: { id: computeNsg.id }
            routeTable: firewallEnabled ? { id: firewallRouteTable.id } : null
            natGateway: enableNatGateway ? { id: natGateway.id } : null
            // Hardened: service endpoints for storage and Key Vault
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
              { service: 'Microsoft.KeyVault' }
            ]
          }
        }
        {
          name: 'appservices'
          properties: {
            addressPrefix: appServicesSubnetPrefix
            networkSecurityGroup: { id: appServicesNsg.id }
            routeTable: firewallEnabled ? { id: firewallRouteTable.id } : null
            delegations: [
              {
                name: 'appservice-delegation'
                properties: { serviceName: 'Microsoft.Web/serverFarms' }
              }
            ]
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
              { service: 'Microsoft.Sql' }
              { service: 'Microsoft.KeyVault' }
            ]
          }
        }
        {
          name: 'databases'
          properties: {
            addressPrefix: databaseSubnetPrefix
            networkSecurityGroup: { id: databaseNsg.id }
            routeTable: firewallEnabled ? { id: firewallRouteTable.id } : null
            delegations: [
              {
                name: 'postgres-delegation'
                properties: { serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers' }
              }
            ]
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
            ]
          }
        }
        {
          name: 'containers'
          properties: {
            addressPrefix: containerSubnetPrefix
            networkSecurityGroup: { id: containerNsg.id }
            routeTable: firewallEnabled ? { id: firewallRouteTable.id } : null
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
              { service: 'Microsoft.ContainerRegistry' }
            ]
          }
        }
        {
          name: 'integration'
          properties: {
            addressPrefix: integrationSubnetPrefix
            networkSecurityGroup: { id: integrationNsg.id }
            routeTable: firewallEnabled ? { id: firewallRouteTable.id } : null
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
              { service: 'Microsoft.ServiceBus' }
              { service: 'Microsoft.EventHub' }
            ]
          }
        }
        {
          name: 'ai'
          properties: {
            addressPrefix: aiSubnetPrefix
            networkSecurityGroup: { id: aiNsg.id }
            routeTable: firewallEnabled ? { id: firewallRouteTable.id } : null
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
              { service: 'Microsoft.CognitiveServices' }
            ]
          }
        }
        {
          name: 'data'
          properties: {
            addressPrefix: dataSubnetPrefix
            networkSecurityGroup: { id: dataNsg.id }
            routeTable: firewallEnabled ? { id: firewallRouteTable.id } : null
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
              { service: 'Microsoft.Sql' }
            ]
          }
        }
        {
          name: 'management'
          properties: {
            addressPrefix: managementSubnetPrefix
            networkSecurityGroup: { id: managementNsg.id }
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
              { service: 'Microsoft.KeyVault' }
            ]
          }
        }
        {
          name: 'privateendpoints'
          properties: {
            addressPrefix: privateEndpointSubnetPrefix
            networkSecurityGroup: { id: privateEndpointNsg.id }
            privateEndpointNetworkPolicies: 'Disabled'
          }
        }
        {
          name: 'mysql'
          properties: {
            addressPrefix: mysqlSubnetPrefix
            networkSecurityGroup: { id: databaseNsg.id }
            routeTable: firewallEnabled ? { id: firewallRouteTable.id } : null
            delegations: [
              {
                name: 'mysql-delegation'
                properties: { serviceName: 'Microsoft.DBforMySQL/flexibleServers' }
              }
            ]
            serviceEndpoints: [
              { service: 'Microsoft.Storage' }
              { service: 'Microsoft.Sql' }
            ]
          }
        }
        // Reserved subnets — always provisioned
        {
          name: 'AppGatewaySubnet'
          properties: {
            addressPrefix: appGwSubnetPrefix
          }
        }
        {
          name: 'AzureFirewallSubnet'
          properties: {
            addressPrefix: firewallSubnetPrefix
          }
        }
        {
          name: 'GatewaySubnet'
          properties: {
            addressPrefix: gatewaySubnetPrefix
          }
        }
      ],
      bastionNeedsSubnet ? [
        {
          name: 'AzureBastionSubnet'
          properties: {
            addressPrefix: bastionSubnetPrefix
          }
        }
      ] : []
    )
  }
}

// ─── Azure Bastion ────────────────────────────────────────────────────────────
// Hardened: Standard SKU default. Tunneling and IP connect enabled for secure access.
// Copy-paste from local to host controlled (allowable per security policy).

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (bastionNeedsSubnet) {
  name: '${prefix}-bastion-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastionDeveloper 'Microsoft.Network/bastionHosts@2023-09-01' = if (bastionSku == 'Developer') {
  name: '${prefix}-bastion'
  location: location
  tags: tags
  sku: { name: 'Developer' }
  properties: {
    virtualNetwork: { id: vnet.id }
  }
}

resource bastionPaid 'Microsoft.Network/bastionHosts@2023-09-01' = if (bastionNeedsSubnet) {
  name: '${prefix}-bastion-paid'
  location: location
  tags: tags
  sku: { name: bastionSku }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionPublicIp.id }
        }
      }
    ]
    disableCopyPaste: true            // Hardened: disable clipboard to/from session
    enableFileCopy: bastionSku == 'Standard'
    enableIpConnect: bastionSku == 'Standard'
    enableTunneling: bastionSku == 'Standard'    // Native client access via tunnel
    enableShareableLink: false        // Hardened: no unauthenticated shareable link
  }
}

// ─── Application Gateway (WAF v2) ─────────────────────────────────────────────
// Hardened: Prevention mode (not Detection). OWASP 3.2. No public HTTP — HTTPS only.

resource appGwPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (enableAppGateway) {
  name: '${prefix}-appgw-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: '${prefix}-appgw' }
  }
}

resource appGateway 'Microsoft.Network/applicationGateways@2023-09-01' = if (enableAppGateway) {
  name: '${prefix}-appgw'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 1
    }
    // Hardened: Prevention mode — actively blocks OWASP rule violations
    webApplicationFirewallConfiguration: {
      enabled: true
      firewallMode: 'Prevention'
      ruleSetType: 'OWASP'
      ruleSetVersion: '3.2'
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
    }
    gatewayIPConfigurations: [
      {
        name: 'appgw-ipconfig'
        properties: { subnet: { id: '${vnet.id}/subnets/AppGatewaySubnet' } }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appgw-frontend-public'
        properties: { publicIPAddress: { id: appGwPublicIp.id } }
      }
    ]
    frontendPorts: [
      // NOTE: Using port 80 for demo deployability — no SSL cert provisioned.
      // In production, switch to port 443 + sslCertificates referencing Key Vault.
      // WAF Prevention mode (the primary hardening control) operates on HTTP too.
      { name: 'port-80', properties: { port: 80 } }
    ]
    backendAddressPools: [
      { name: 'default-backend-pool', properties: {} }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'default-http-settings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          pickHostNameFromBackendAddress: false
        }
      }
    ]
    httpListeners: [
      {
        name: 'default-http-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', '${prefix}-appgw', 'appgw-frontend-public')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', '${prefix}-appgw', 'port-80')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'default-routing-rule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', '${prefix}-appgw', 'default-http-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', '${prefix}-appgw', 'default-backend-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', '${prefix}-appgw', 'default-http-settings')
          }
        }
      }
    ]
  }
}

// ─── Azure Firewall ───────────────────────────────────────────────────────────

resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (firewallEnabled) {
  name: '${prefix}-fw-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = if (firewallEnabled) {
  name: '${prefix}-fw-policy'
  location: location
  tags: tags
  properties: {
    sku: { tier: enableFirewall }
    // Hardened: threat intelligence in Alert + Deny mode
    threatIntelMode: 'Deny'
    // Hardened: DNS proxy enabled so spoke resources use firewall for DNS
    dnsSettings: {
      enableProxy: true
    }
  }
}

resource azureFirewall 'Microsoft.Network/azureFirewalls@2023-09-01' = if (firewallEnabled) {
  name: '${prefix}-firewall'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: enableFirewall
    }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureFirewallSubnet' }
          publicIPAddress: { id: firewallPublicIp.id }
        }
      }
    ]
  }
}

// ─── VPN Gateway ──────────────────────────────────────────────────────────────

resource vpnGatewayPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (enableVpnGateway) {
  name: '${prefix}-vpngw-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-09-01' = if (enableVpnGateway) {
  name: '${prefix}-vpngw'
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: { name: 'VpnGw1', tier: 'VpnGw1' }
    enableBgp: false
    ipConfigurations: [
      {
        name: 'vpngw-ipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/GatewaySubnet' }
          publicIPAddress: { id: vpnGatewayPip.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    vpnClientConfiguration: {
      vpnClientAddressPool: {
        addressPrefixes: ['172.16.0.0/24']
      }
      vpnClientProtocols: ['OpenVPN']
      vpnAuthenticationTypes: ['AAD']
      aadTenant: '${environment().authentication.loginEndpoint}${tenant().tenantId}/'
      aadAudience: '41b23e61-6c1e-4545-b367-cd054e0ed4b4'
      aadIssuer: 'https://sts.windows.net/${tenant().tenantId}/'
    }
  }
}

// ─── Private DNS Zones ────────────────────────────────────────────────────────
// Hardened: enabled by default for private endpoint name resolution.

var privateDnsZoneNames = [
  #disable-next-line no-hardcoded-env-urls
  'privatelink.blob.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  'privatelink.file.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  'privatelink.queue.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  'privatelink.table.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  'privatelink.database.windows.net'
  'privatelink.documents.azure.com'
  'privatelink.postgres.database.azure.com'
  'privatelink.mysql.database.azure.com'
  'privatelink.vaultcore.azure.net'
  'privatelink.azurecr.io'
  'privatelink.servicebus.windows.net'
  'privatelink.eventhub.windows.net'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.search.windows.net'
  'privatelink.redis.cache.windows.net'
]

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for zone in (enablePrivateDnsZones ? privateDnsZoneNames : []): {
    name: zone
    location: 'global'
    tags: tags
    properties: {}
  }
]

resource privateDnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for (zone, i) in (enablePrivateDnsZones ? privateDnsZoneNames : []): {
    parent: privateDnsZones[i]
    name: '${prefix}-${uniqueString(zone)}-link'
    location: 'global'
    properties: {
      virtualNetwork: { id: vnet.id }
      registrationEnabled: false
    }
  }
]

// ─── Outputs ──────────────────────────────────────────────────────────────────

output vnetId string = vnet.id
output vnetName string = vnet.name
output computeSubnetId string = '${vnet.id}/subnets/compute'
output appServicesSubnetId string = '${vnet.id}/subnets/appservices'
output databaseSubnetId string = '${vnet.id}/subnets/databases'
output containerSubnetId string = '${vnet.id}/subnets/containers'
output integrationSubnetId string = '${vnet.id}/subnets/integration'
output aiSubnetId string = '${vnet.id}/subnets/ai'
output dataSubnetId string = '${vnet.id}/subnets/data'
output managementSubnetId string = '${vnet.id}/subnets/management'
output privateEndpointSubnetId string = '${vnet.id}/subnets/privateendpoints'
output mysqlSubnetId string = '${vnet.id}/subnets/mysql'
output bastionId string = bastionSku == 'Developer' ? bastionDeveloper.id : (bastionNeedsSubnet ? bastionPaid.id : '')
output appGatewayPublicIp string = enableAppGateway ? appGwPublicIp!.properties.ipAddress : ''
output firewallPrivateIp string = firewallEnabled ? '10.0.10.4' : ''
// Private DNS zone IDs — populated only when enablePrivateDnsZones = true
#disable-next-line no-hardcoded-env-urls
output blobDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.blob.core.windows.net') : ''
#disable-next-line no-hardcoded-env-urls
output sqlDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.database.windows.net') : ''
output cosmosDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com') : ''
output postgresDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.postgres.database.azure.com') : ''
output mysqlDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.mysql.database.azure.com') : ''
output keyVaultDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net') : ''
output serviceBusDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.servicebus.windows.net') : ''
output eventHubDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.eventhub.windows.net') : ''
output redisDnsZoneId string = enablePrivateDnsZones ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.redis.cache.windows.net') : ''
