// ─── integration.bicep ───────────────────────────────────────────────────────
// Deploys: Service Bus (Standard), Event Hub (Basic), Event Grid System Topic,
//          SignalR Service (Free), API Management (optional — ~$50/mo Developer).
//
// DEFAULT MODE: Public endpoints, default settings, no diagnostic settings.
//               API Management off by default due to cost.
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

@description('API Management SKU. Developer ~$50/mo, Standard ~$750/mo.')
@allowed(['Developer', 'Basic', 'Standard'])
param apimSku string = 'Developer'

@description('API Management publisher email.')
param apimPublisherEmail string = 'admin@example.com'

@description('API Management publisher name.')
param apimPublisherName string = 'ADE Demo'

@description('Integration subnet resource ID for future VNet-integration of PaaS messaging services.')
#disable-next-line no-unused-params
param subnetId string = ''

@description('Private endpoint subnet resource ID (hardened mode).')
#disable-next-line no-unused-params
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource ID for Service Bus (privatelink.servicebus.windows.net; hardened mode).')
#disable-next-line no-unused-params
param serviceBusDnsZoneId string = ''

@description('Private DNS zone resource ID for Event Hub (privatelink.servicebus.windows.net; hardened mode).')
#disable-next-line no-unused-params
param eventHubDnsZoneId string = ''

@description('Resource tags.')
param tags object = {}

// ─── Service Bus ──────────────────────────────────────────────────────────────

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = if (deployServiceBus) {
  name: '${prefix}-sb'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
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

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2023-01-01-preview' = if (deployEventHub) {
  name: '${prefix}-eh'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
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

resource eventGridTopic 'Microsoft.EventGrid/topics@2023-12-15-preview' = if (deployEventGrid) {
  name: '${prefix}-egt'
  location: location
  tags: tags
  properties: {
    publicNetworkAccess: 'Enabled'
    inputSchema: 'EventGridSchema'
  }
}

// ─── SignalR Service ──────────────────────────────────────────────────────────

resource signalR 'Microsoft.SignalRService/signalR@2023-08-01-preview' = if (deploySignalR) {
  name: '${prefix}-signalr'
  location: location
  tags: tags
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
      allowedOrigins: ['*']
    }
    publicNetworkAccess: 'Enabled'
  }
}

// ─── API Management ───────────────────────────────────────────────────────────
// Off by default. Developer ~$50/mo. Standard ~$750/mo (VERY EXPENSIVE).

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = if (deployApim) {
  name: '${prefix}-apim'
  location: location
  tags: tags
  sku: {
    name: apimSku
    capacity: 1
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    virtualNetworkType: 'None'
    publicNetworkAccess: 'Enabled'
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
