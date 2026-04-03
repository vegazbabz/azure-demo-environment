// ─── hardened/integration/integration.bicep ──────────────────────────────────
// Deploys: Service Bus (Standard), Event Hub (Standard), Event Grid System Topic,
//          SignalR Service (Free), API Management (optional).
//
// HARDENED MODE: TLS 1.2 on all messaging services. Local auth disabled
//               (Entra ID RBAC only). Public network access disabled on service
//               bus and event hub. SignalR CORS restricted (no wildcard).
//               Aligns with: MCSB IM-3, DP-3, NS-1.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
@minLength(3)
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Deploy Service Bus namespace.')
param deployServiceBus bool = true

@description('Deploy Event Hub namespace.')
param deployEventHub bool = true

@description('Deploy Event Grid system topic.')
param deployEventGrid bool = true

@description('Deploy SignalR Service.')
param deploySignalR bool = true

@description('Deploy API Management. Off by default (~$50/month Developer tier).')
param deployApim bool = false

@description('API Management SKU.')
@allowed(['Developer', 'Basic', 'Standard'])
param apimSku string = 'Developer'

@description('API Management publisher email.')
param apimPublisherEmail string = 'admin@example.com'

@description('API Management publisher name.')
param apimPublisherName string = 'ADE Demo'

@description('Private endpoint subnet resource ID for Service Bus and Event Hub private endpoints.')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource ID for Service Bus (privatelink.servicebus.windows.net).')
param serviceBusDnsZoneId string = ''

@description('Private DNS zone resource ID for Event Hub (privatelink.eventhub.windows.net).')
param eventHubDnsZoneId string = ''

@description('Resource tags.')
param tags object = {}

// ─── Service Bus ──────────────────────────────────────────────────────────────
// Hardened: TLS 1.2, local auth disabled, public access disabled (MCSB IM-3, NS-1).

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = if (deployServiceBus) {
  name: '${prefix}-sb'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    // Hardened: TLS 1.2 minimum (MCSB DP-3)
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    // Hardened: local auth disabled — Entra ID RBAC only (MCSB IM-3)
    disableLocalAuth: true
  }
}

resource serviceBusQueue1 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = if (deployServiceBus) {
  parent: serviceBusNamespace
  name: 'orders'
  properties: {
    maxSizeInMegabytes: 1024
    requiresDuplicateDetection: false
    requiresSession: false
    defaultMessageTimeToLive: 'P14D'
    deadLetteringOnMessageExpiration: true
  }
}

resource serviceBusQueue2 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = if (deployServiceBus) {
  parent: serviceBusNamespace
  name: 'notifications'
  properties: {
    maxSizeInMegabytes: 1024
    requiresDuplicateDetection: false
    requiresSession: false
    defaultMessageTimeToLive: 'P14D'
    deadLetteringOnMessageExpiration: true
  }
}

resource serviceBusTopic 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = if (deployServiceBus) {
  parent: serviceBusNamespace
  name: 'events'
  properties: {
    maxSizeInMegabytes: 1024
    requiresDuplicateDetection: false
    defaultMessageTimeToLive: 'P14D'
  }
}

resource serviceBusTopicSubscription 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = if (deployServiceBus) {
  parent: serviceBusTopic
  name: 'all-events'
  properties: {
    maxDeliveryCount: 10
    defaultMessageTimeToLive: 'P14D'
    deadLetteringOnMessageExpiration: true
  }
}

// ─── Event Hub ─────────────────────────────────────────────────────────────────
// Hardened: Standard SKU (supports private endpoints), TLS 1.2, local auth disabled.

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2023-01-01-preview' = if (deployEventHub) {
  name: '${prefix}-eh'
  location: location
  tags: tags
  sku: {
    // Hardened: Standard SKU (Basic does not support disableLocalAuth or private link)
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    // Hardened: TLS 1.2 minimum
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    // Hardened: local auth disabled
    disableLocalAuth: true
  }
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2023-01-01-preview' = if (deployEventHub) {
  parent: eventHubNamespace
  name: '${prefix}-telemetry'
  properties: {
    messageRetentionInDays: 1
    partitionCount: 2
  }
}

resource eventHubConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2023-01-01-preview' = if (deployEventHub) {
  parent: eventHub
  name: 'demo-consumer'
  properties: {}
}

// ─── Event Grid ───────────────────────────────────────────────────────────────
// Hardened: disable local auth, restrict public access.

resource eventGridTopic 'Microsoft.EventGrid/topics@2023-12-15-preview' = if (deployEventGrid) {
  name: '${prefix}-egt'
  location: location
  tags: tags
  // Hardened: managed identity for identity-based event delivery (MCSB IM-1)
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Disabled'
    inputSchema: 'EventGridSchema'
    // Hardened: local auth disabled — Entra ID RBAC only
    disableLocalAuth: true
  }
}

// ─── SignalR Service ──────────────────────────────────────────────────────────
// Hardened: restrict CORS (no wildcard), no public access.

resource signalR 'Microsoft.SignalRService/signalR@2023-08-01-preview' = if (deploySignalR) {
  name: '${prefix}-signalr'
  location: location
  tags: tags
  // Hardened: managed identity (MCSB IM-1)
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Free_F1'
    tier: 'Free'
    capacity: 1
  }
  properties: {
    features: [
      {
        flag: 'ServiceMode'
        value: 'Default'
      }
    ]
    cors: {
      // Hardened: no wildcard CORS — restrict to specific origins (MCSB NS-1)
      // For demo: empty list (no CORS); configure per-application in production
      allowedOrigins: []
    }
    publicNetworkAccess: 'Enabled'    // Free SKU does not support private link
    // Hardened: disable local auth where supported
    disableLocalAuth: true
    disableAadAuth: false
  }
}

// ─── API Management ───────────────────────────────────────────────────────────

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = if (deployApim) {
  name: '${prefix}-apim'
  location: location
  tags: tags
  // Hardened: system-assigned managed identity (MCSB IM-1)
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: apimSku
    capacity: 1
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    // Hardened: External VNet integration for inbound isolation (MCSB NS-1)
    // NOTE: External VNet requires Standard/Premium SKU; Developer SKU supports External VNet
    virtualNetworkType: 'External'
    publicNetworkAccess: 'Disabled'
    // Hardened: minimum API version 2019-12-01 (removes legacy mgmt plane vulnerabilities)
    apiVersionConstraint: {
      minApiVersion: '2019-12-01'
    }
    // Hardened: enforce TLS 1.2 for APIM gateway
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Ssl30': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TripleDes168': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'False'
    }
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output serviceBusId string = deployServiceBus ? serviceBusNamespace.id : ''
output serviceBusName string = deployServiceBus ? serviceBusNamespace.name : ''
output eventHubNamespaceId string = deployEventHub ? eventHubNamespace.id : ''
output eventHubNamespaceName string = deployEventHub ? eventHubNamespace.name : ''
output eventGridTopicId string = deployEventGrid ? eventGridTopic.id : ''
output eventGridTopicEndpoint string = deployEventGrid ? eventGridTopic!.properties.endpoint : ''
output signalRId string = deploySignalR ? signalR.id : ''
output apimId string = deployApim ? apim.id : ''
output apimGatewayUrl string = deployApim ? apim!.properties.gatewayUrl : ''

// ─── Private Endpoints ────────────────────────────────────────────────────────
// Service Bus and Event Hub have publicNetworkAccess: 'Disabled'.
// Private endpoints allow callers inside the VNet to reach these namespaces.

resource sbPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (deployServiceBus && !empty(privateEndpointSubnetId)) {
  name: '${prefix}-sb-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-sb-plsc'
        properties: {
          privateLinkServiceId: serviceBusNamespace.id
          groupIds: ['namespace']
        }
      }
    ]
  }
}

resource sbPeDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (deployServiceBus && !empty(privateEndpointSubnetId) && !empty(serviceBusDnsZoneId)) {
  parent: sbPrivateEndpoint
  name: 'sb-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-servicebus-windows-net'
        properties: { privateDnsZoneId: serviceBusDnsZoneId }
      }
    ]
  }
}

resource ehPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (deployEventHub && !empty(privateEndpointSubnetId)) {
  name: '${prefix}-eh-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-eh-plsc'
        properties: {
          privateLinkServiceId: eventHubNamespace.id
          groupIds: ['namespace']
        }
      }
    ]
  }
}

resource ehPeDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (deployEventHub && !empty(privateEndpointSubnetId) && !empty(eventHubDnsZoneId)) {
  parent: ehPrivateEndpoint
  name: 'eh-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-eventhub-windows-net'
        properties: { privateDnsZoneId: eventHubDnsZoneId }
      }
    ]
  }
}
