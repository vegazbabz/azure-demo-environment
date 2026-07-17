@{
    RootModule        = 'AzureDemoEnvironment.psm1'
    ModuleVersion     = '2.2.0'
    GUID              = 'd43309aa-658b-4477-962f-e530096d3799'
    Author            = 'vegazbabz'
    Copyright         = '(c) vegazbabz. MIT License.'
    Description       = 'Deploys a fully automated, modular Azure demo environment for security benchmark testing: 12 independently toggleable Bicep modules (monitoring, networking, security, compute, storage, databases, app services, containers, integration, AI, data, governance) in either out-of-the-box default mode or CIS/MCSB-hardened mode, plus teardown, dummy-data seeding, and a terminal cost dashboard. Uses the Azure CLI and Bicep CLI (no Az PowerShell modules). WARNING: deploying creates real, billable Azure resources — some (Azure Firewall, DDoS Protection, VPN Gateway) are expensive even when idle. The author accepts no responsibility for any Azure costs incurred; always tear down with Remove-AdeEnvironment and set subscription budgets.'
    PowerShellVersion = '7.0'
    # Gives the package the Core-edition compatibility badge on the Gallery.
    CompatiblePSEditions = @('Core')

    # No RequiredModules: all Azure calls go through the Azure CLI (az), which
    # must be installed and logged in, with the Bicep CLI (az bicep install).
    FunctionsToExport = @(
        'Deploy-AdeEnvironment',
        'Remove-AdeEnvironment',
        'Initialize-AdeSeedData',
        'Get-AdeCostDashboard'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            # Single-word tags only (Gallery requirement). The Windows/Linux/MacOS
            # and PSEdition_Core tags drive the compatibility badges on the
            # package page; the rest are search terms.
            Tags         = @(
                'Azure', 'MicrosoftAzure', 'Demo', 'Sandbox', 'Lab',
                'Bicep', 'IaC', 'Infrastructure', 'Deployment', 'Provisioning',
                'CIS', 'MCSB', 'Benchmark', 'Security', 'Hardening',
                'AzureCLI', 'DevOps', 'Governance',
                'PSEdition_Core', 'Windows', 'Linux', 'MacOS'
            )
            # The repository's GitHub social preview image (user-maintained via
            # repo Settings → Social preview).
            IconUri      = 'https://repository-images.githubusercontent.com/1198901868/d1e820c8-ea85-46a8-9a0a-0d8477320b93'
            LicenseUri   = 'https://github.com/vegazbabz/azure-demo-environment/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/vegazbabz/azure-demo-environment'
            ReleaseNotes = 'https://github.com/vegazbabz/azure-demo-environment/releases'
        }
    }
}
