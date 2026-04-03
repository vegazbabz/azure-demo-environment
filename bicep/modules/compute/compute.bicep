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

@description('Deploy Ubuntu 22.04 LTS VM. Off by default - opt-in only.')
param deployLinuxVm bool = false

@description('Deploy VM Scale Set (Windows).')
param deployVmss bool = false

@description('Enable auto-shutdown at 19:00 UTC daily.')
param enableAutoShutdown bool = false

@description('VM size. Standard_B2s is cost-optimised for demo.')
param vmSize string = 'Standard_B2s'

@description('Deploy a Domain Controller VM. Requires dcSubnetId.')
param deployDomainController bool = false

@description('Domain Controller subnet resource ID.')
param dcSubnetId string = ''

@description('Active Directory domain FQDN. Example: ade.local')
param domainName string = ''

@description('Resource tags.')
param tags object = {}

var dcDomainName   = !empty(domainName) ? domainName : '${prefix}.local'
var dcNetbiosName  = toUpper(take(prefix, 15))
var dcStaticIp     = '10.0.15.4'

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
        computerNamePrefix: take('${prefix}vmss', 9)
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

// ─── Domain Controller VM ─────────────────────────────────────────────────────
// Promotes a Windows Server 2022 VM to an AD DS Domain Controller.
// Static private IP: 10.0.15.4. Public IP enabled (default mode).
// CSE installs AD DS feature and runs Install-ADDSForest automatically.
// VNet DNS must point to 10.0.15.4 — set deployDomainController=true in networking.
//
// SAFE MODE PASSWORD: Uses the same adminPassword as the VM for simplicity in
// a demo environment. In production, use a separate secure secret.

resource dcPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (deployDomainController) {
  name: '${prefix}-dc-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource dcNic 'Microsoft.Network/networkInterfaces@2023-09-01' = if (deployDomainController) {
  name: '${prefix}-dc-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: dcSubnetId }
          // Static IP so it matches the VNet DNS server address (10.0.15.4)
          privateIPAllocationMethod: 'Static'
          privateIPAddress: dcStaticIp
          publicIPAddress: { id: dcPublicIp.id }
        }
      }
    ]
  }
}

resource dcVm 'Microsoft.Compute/virtualMachines@2023-09-01' = if (deployDomainController) {
  name: '${prefix}-dc-vm'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: '${take(prefix, 14)}dc'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: { patchMode: 'AutomaticByOS' }
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
        { id: dcNic.id, properties: { primary: true, deleteOption: 'Delete' } }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

// Installs AD DS feature and promotes the VM to a Domain Controller.
// The command runs inside protectedSettings so adminPassword is encrypted at rest.
resource dcCse 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployDomainController) {
  parent: dcVm
  name: 'InstallADDS'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: 'powershell.exe -NonInteractive -Command "Install-WindowsFeature AD-Domain-Services -IncludeManagementTools; Import-Module ADDSDeployment; $pwd = ConvertTo-SecureString \'${adminPassword}\' -AsPlainText -Force; Install-ADDSForest -DomainName \'${dcDomainName}\' -DomainNetbiosName \'${dcNetbiosName}\' -SafeModeAdministratorPassword $pwd -InstallDns:$true -Force:$true -NoRebootOnCompletion:$false"'
    }
  }
}

resource dcAutoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployDomainController && enableAutoShutdown) {
  name: 'shutdown-computevm-${prefix}-dc-vm'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: '1900' }
    timeZoneId: 'UTC'
    targetResourceId: dcVm.id
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output windowsVmId string = deployWindowsVm ? windowsVm.id : ''
output windowsVmName string = deployWindowsVm ? windowsVm.name : ''
output linuxVmId string = deployLinuxVm ? linuxVm.id : ''
output linuxVmName string = deployLinuxVm ? linuxVm.name : ''
output vmssId string = deployVmss ? vmss.id : ''
output availabilitySetId string = availabilitySet.id
output dcVmName string = deployDomainController ? dcVm.name : ''
output dcPrivateIp string = deployDomainController ? dcStaticIp : ''
output domainName string = deployDomainController ? dcDomainName : ''

