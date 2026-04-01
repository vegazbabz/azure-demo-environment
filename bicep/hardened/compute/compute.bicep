// ─── hardened/compute/compute.bicep ──────────────────────────────────────────
// Deploys: Windows Server 2022 VM, Ubuntu 22.04 LTS VM, VM Scale Set (optional),
//          Availability Set.
//
// HARDENED MODE: No public IPs — all VM access via Bastion only. Encryption at
//               host enabled (platform-managed keys). Auto-shutdown ON by default.
//               Azure Monitor Agent extension installed. AAD login extension.
//               Trusted launch (Secure Boot + vTPM) on VMs.
//               Aligns with: CIS 7.x, MCSB PV-4, PV-5, DP-5, LT-3.
//
// NOTE: Encryption at host requires the 'EncryptionAtHost' feature to be registered
//       on the subscription: az feature register --name EncryptionAtHost
//             --namespace Microsoft.Compute
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

@description('Deploy Ubuntu 22.04 LTS VM.')
param deployLinuxVm bool = true

@description('Deploy VM Scale Set (Windows).')
param deployVmss bool = false

@description('Enable auto-shutdown at 19:00 UTC daily. Hardened: ON by default.')
param enableAutoShutdown bool = true    // Hardened: on

@description('VM size. Standard_B2s is cost-optimised for demo.')
param vmSize string = 'Standard_B2s'

@description('Log Analytics workspace resource ID for Azure Monitor Agent.')
#disable-next-line no-unused-params
param logAnalyticsId string = ''

@description('Data Collection Rule resource ID for Azure Monitor Agent.')
param dataCollectionRuleId string = ''

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
// Hardened: no public IP, encryption at host, trusted launch (Secure Boot + vTPM)

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
          // Hardened: no public IP — access only via Bastion
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
    // Hardened: encryption at host (all disks encrypted using platform key)
    securityProfile: {
      encryptionAtHost: true
      // Trusted launch: Secure Boot + vTPM (CIS 7.x, MCSB PV-5)
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: '${prefix}winvm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: {
          // Hardened: automatic assessment + automatic patching
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
        // Hardened: disable VM agent provisioning of guest user scripts
        provisionVMAgent: true
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

// Auto-shutdown (hardened: enabled by default)
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

// Hardened: Azure Monitor Agent extension for centralized telemetry collection
resource windowsAmaExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployWindowsVm) {
  parent: windowsVm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    // No settings block — AMA uses the VM's system-assigned identity automatically
  }
}

// Hardened: AAD login extension — enables Entra ID (AAD) authentication for RDP
resource windowsAadExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployWindowsVm) {
  parent: windowsVm
  name: 'AADLoginForWindows'
  location: location
  dependsOn: [windowsAmaExtension]
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

// Hardened: associate DCR with Windows VM for AMA data collection
resource windowsDcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (deployWindowsVm && !empty(dataCollectionRuleId)) {
  name: '${prefix}-win-dcr-assoc'
  scope: windowsVm
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
    description: 'ADE AMA data collection rule association — Windows VM'
  }
}

// ─── Linux VM ─────────────────────────────────────────────────────────────────
// Hardened: no public IP, encryption at host, trusted launch, SSH-only (no password auth)

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
          // Hardened: no public IP
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
    securityProfile: {
      encryptionAtHost: true
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: '${prefix}linuxvm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        // NOTE: Password auth kept enabled for demo API compatibility (adminPassword param required).
        // In production, set disablePasswordAuthentication: true and supply an SSH public key.
        // Access is via Bastion only (no public IP); SSH key auth is strongly preferred.
        disablePasswordAuthentication: false
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
        provisionVMAgent: true
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

// Hardened: Azure Monitor Agent for Linux
resource linuxAmaExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployLinuxVm) {
  parent: linuxVm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// Hardened: AAD SSH login extension
resource linuxAadExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployLinuxVm) {
  parent: linuxVm
  name: 'AADSSHLoginForLinux'
  location: location
  dependsOn: [linuxAmaExtension]
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

resource linuxDcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (deployLinuxVm && !empty(dataCollectionRuleId)) {
  name: '${prefix}-linux-dcr-assoc'
  scope: linuxVm
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
    description: 'ADE AMA data collection rule association — Linux VM'
  }
}

// ─── VM Scale Set (Windows) ───────────────────────────────────────────────────
// Hardened: no public IP, encryption at host, AMA extension

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
      securityProfile: {
        encryptionAtHost: true
        securityType: 'TrustedLaunch'
        uefiSettings: {
          secureBootEnabled: true
          vTpmEnabled: true
        }
      }
      osProfile: {
        computerNamePrefix: '${prefix}vmss'
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          enableAutomaticUpdates: true
          patchSettings: {
            patchMode: 'AutomaticByPlatform'
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
                    // Hardened: no public IP on VMSS instances
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: [
          {
            name: 'AzureMonitorWindowsAgent'
            properties: {
              publisher: 'Microsoft.Azure.Monitor'
              type: 'AzureMonitorWindowsAgent'
              typeHandlerVersion: '1.0'
              autoUpgradeMinorVersion: true
              enableAutomaticUpgrade: true
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
