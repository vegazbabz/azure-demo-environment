// ─── compute.bicep ───────────────────────────────────────────────────────────
// Deploys: Windows Server 2022 VM, Ubuntu 22.04 LTS VM, VM Scale Set (optional),
//          Availability Set.
//
// DEFAULT MODE: No disk encryption, no agents, no hardening. Public IPs enabled.
//               Boot diagnostics enabled (Azure default). No extensions.
//               Auto-shutdown disabled by default.
// ─────────────────────────────────────────────────────────────────────────────

@description('Resource prefix for naming all resources.')
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Compute subnet resource ID.')
param subnetId string

@description('VM administrator username.')
param adminUsername string = 'adeadmin'

@description('VM administrator password.')
@secure()
param adminPassword string

@description('Deploy Windows Server 2022 VM.')
param deployWindowsVm bool = true

@description('Deploy Ubuntu 22.04 LTS VM. Off by default \u2014 opt-in only.')
param deployLinuxVm bool = false

@description('Deploy VM Scale Set (Windows).')
param deployVmss bool = false

@description('Enable auto-shutdown at 19:00 UTC daily.')
param enableAutoShutdown bool = false

@description('VM size. Standard_B2s is cost-optimised for demo.')
param vmSize string = 'Standard_B2s'

@description('Resource tags.')
param tags object = {}

// ─── Availability Set ─────────────────────────────────────────────────────────

resource availabilitySet 'Microsoft.Compute/availabilitySets@2023-09-01' = {
  name: '${prefix}-avset'
  location: location
  tags: tags
  sku: { name: 'Aligned' }
  properties: {
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
  }
}

// ─── Windows VM ───────────────────────────────────────────────────────────────

resource windowsPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (deployWindowsVm) {
  name: '${prefix}-win-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource windowsNic 'Microsoft.Network/networkInterfaces@2023-09-01' = if (deployWindowsVm) {
  name: '${prefix}-win-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: windowsPublicIp.id }
        }
      }
    ]
  }
}

resource windowsVm 'Microsoft.Compute/virtualMachines@2023-09-01' = if (deployWindowsVm) {
  name: '${prefix}-win-vm'
  location: location
  tags: tags
  properties: {
    availabilitySet: { id: availabilitySet.id }
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: '${prefix}winvm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: windowsNic.id, properties: { primary: true, deleteOption: 'Delete' } }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource windowsAutoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployWindowsVm && enableAutoShutdown) {
  name: 'shutdown-computevm-${prefix}-win-vm'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: '1900' }
    timeZoneId: 'UTC'
    targetResourceId: windowsVm.id
  }
}

// ─── Linux VM ─────────────────────────────────────────────────────────────────

resource linuxPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (deployLinuxVm) {
  name: '${prefix}-linux-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource linuxNic 'Microsoft.Network/networkInterfaces@2023-09-01' = if (deployLinuxVm) {
  name: '${prefix}-linux-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: linuxPublicIp.id }
        }
      }
    ]
  }
}

resource linuxVm 'Microsoft.Compute/virtualMachines@2023-09-01' = if (deployLinuxVm) {
  name: '${prefix}-linux-vm'
  location: location
  tags: tags
  properties: {
    availabilitySet: { id: availabilitySet.id }
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: '${prefix}linuxvm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: linuxNic.id, properties: { primary: true, deleteOption: 'Delete' } }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource linuxAutoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployLinuxVm && enableAutoShutdown) {
  name: 'shutdown-computevm-${prefix}-linux-vm'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: '1900' }
    timeZoneId: 'UTC'
    targetResourceId: linuxVm.id
  }
}

// ─── VM Scale Set (Windows) ───────────────────────────────────────────────────

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = if (deployVmss) {
  name: '${prefix}-vmss'
  location: location
  tags: tags
  sku: {
    name: 'Standard_B2s'
    tier: 'Standard'
    capacity: 2
  }
  properties: {
    overprovision: true
    upgradePolicy: { mode: 'Automatic' }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: '${prefix}vmss'
        adminUsername: adminUsername
        adminPassword: adminPassword
      }
      storageProfile: {
        imageReference: {
          publisher: 'MicrosoftWindowsServer'
          offer: 'WindowsServer'
          sku: '2022-datacenter-azure-edition'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: { storageAccountType: 'Premium_LRS' }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: '${prefix}-vmss-nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig1'
                  properties: {
                    subnet: { id: subnetId }
                  }
                }
              ]
            }
          }
        ]
      }
    }
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output windowsVmId string = deployWindowsVm ? windowsVm.id : ''
output windowsVmName string = deployWindowsVm ? windowsVm.name : ''
output linuxVmId string = deployLinuxVm ? linuxVm.id : ''
output linuxVmName string = deployLinuxVm ? linuxVm.name : ''
output vmssId string = deployVmss ? vmss.id : ''
output availabilitySetId string = availabilitySet.id

