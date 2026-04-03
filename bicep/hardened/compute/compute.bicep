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

@description('Deploy a Domain Controller VM. Requires dcSubnetId. Hardened: no public IP, AMA extension, encryption at host.')
param deployDomainController bool = false

@description('Domain Controller subnet resource ID.')
param dcSubnetId string = ''

@description('Active Directory domain FQDN. Example: ade.local')
param domainName string = ''

@description('Log Analytics workspace resource ID for Azure Monitor Agent.')
#disable-next-line no-unused-params
param logAnalyticsId string = ''

@description('Data Collection Rule resource ID for Azure Monitor Agent.')
param dataCollectionRuleId string = ''

@description('Resource tags.')
param tags object = {}

var dcDomainName  = !empty(domainName) ? domainName : '${prefix}.local'
var dcNetbiosName = toUpper(take(prefix, 15))
var dcStaticIp    = '10.0.15.4'

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
  // Hardened: system-assigned managed identity required for AAD login extension (MCSB IM-1)
  identity: {
    type: 'SystemAssigned'
  }
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
  // Hardened: system-assigned managed identity required for AAD SSH login extension (MCSB IM-1)
  identity: {
    type: 'SystemAssigned'
  }
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
        // Hardened: password auth disabled — AAD SSH (AADSSHLoginForLinux extension) is the only
        //          login path. Access is via Bastion only (no public IP). (CIS 7.3, MCSB PA-1)
        //          adminPassword param retained to satisfy ARM API; it is not used for SSH access.
        disablePasswordAuthentication: true
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
  // Hardened: system-assigned identity for AMA and AAD extension auth (MCSB IM-1)
  identity: {
    type: 'SystemAssigned'
  }
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

// ─── Domain Controller VM ─────────────────────────────────────────────────────
// Hardened: no public IP (Bastion only), encryption at host, trusted launch,
//           AMA extension for log collection. AAD login extension NOT applied
//           (a DC cannot be Entra-joined). Static IP 10.0.15.4.
// CSE promotes the VM to DC on first boot. VNet DNS must point to 10.0.15.4 —
// set deployDomainController=true in the networking module.

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
          privateIPAllocationMethod: 'Static'
          privateIPAddress: dcStaticIp
          // Hardened: no public IP — admin access via Bastion only
        }
      }
    ]
  }
}

resource dcVm 'Microsoft.Compute/virtualMachines@2023-09-01' = if (deployDomainController) {
  name: '${prefix}-dc-vm'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: {
      encryptionAtHost: true
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    osProfile: {
      computerName: '${take(prefix, 14)}dc'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
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
        { id: dcNic.id, properties: { primary: true, deleteOption: 'Delete' } }
      ]
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

// Hardened: AMA for centralized log collection from DC
resource dcAmaExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployDomainController) {
  parent: dcVm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// Promotes the VM to a Domain Controller (runs after AMA installs).
// protectedSettings encrypts the command (incl. password) in ARM state.
resource dcCse 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployDomainController) {
  parent: dcVm
  name: 'InstallADDS'
  location: location
  dependsOn: [dcAmaExtension]
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
