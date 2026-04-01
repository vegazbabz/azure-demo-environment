#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
<#
.SYNOPSIS
    Pester tests for scripts/seed-data.ps1

    All az CLI calls are mocked. No Azure subscription or deployed resources are required.
    Tests verify:
      - Get-AdeResource helper returns expected values
      - Each seeding block skips gracefully when no resource is found
      - Each seeding block invokes the correct az commands when a resource is present
      - -Force suppresses confirmation; -Modules filters which blocks run
#>

BeforeAll {
    # Silence console output
    Mock Write-Host {}

    # Stub az as a PS function so Pester can mock it even when the Azure CLI is not installed
    if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
        function script:az {}
    }

    # Stub logging functions loaded transitively via common.ps1
    function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
    function Write-AdeSection { param([string]$Title) }

    # Pre-define $script:AdeLogFile to avoid strict mode error when common.ps1 is not sourced
    $script:AdeLogFile = $null

    $seedScript = Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1'
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-AdeResource  (internal helper — dot-source seed-data to expose it)
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Get-AdeResource' -Tag 'unit' {

    BeforeAll {
        # Dot-source only the helper portion — mock az before anything else runs
        Mock az { $global:LASTEXITCODE = 0; 'my-storage-account' }

        # Expose the function without running the body of seed-data.ps1
        # Use the PowerShell AST to extract the typed function definition and define it via ScriptBlock
        $rawScript = Get-Content (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($rawScript, [ref]$null, [ref]$null)
        $funcDef = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-AdeResource'
        }, $true)
        if ($funcDef) {
            . ([scriptblock]::Create($funcDef.Extent.Text))
        }
    }

    It 'Returns the value from az resource list' {
        $result = Get-AdeResource -ResourceGroup 'ade-storage-rg' -ResourceType 'Microsoft.Storage/storageAccounts'
        $result | Should -Be 'my-storage-account'
    }

    It 'Returns null when az returns empty' {
        Mock az { $global:LASTEXITCODE = 0; '' }
        $result = Get-AdeResource -ResourceGroup 'ade-storage-rg' -ResourceType 'Microsoft.Storage/storageAccounts'
        $result | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Script-level behaviour — run seed-data.ps1 with parameters
# We call the script as a child process (using pwsh -File) to keep each test
# isolated. All az calls inside are mocked by prepending a mock az function
# via -Command.
# ─────────────────────────────────────────────────────────────────────────────

Describe 'seed-data.ps1 — skip when no resources found' -Tag 'unit' {

    BeforeAll {
        # Mock az so resource discovery always returns empty (no resources deployed)
        Mock az { $global:LASTEXITCODE = 0 }
    }

    It 'Does not throw when storage account is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules storage -Force
        } | Should -Not -Throw
    }

    It 'Does not throw when Cosmos DB account is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules cosmosdb -Force
        } | Should -Not -Throw
    }

    It 'Does not throw when Key Vault is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules keyvault -Force
        } | Should -Not -Throw
    }

    It 'Does not throw when Service Bus namespace is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules servicebus -Force
        } | Should -Not -Throw
    }

    It 'Does not throw when Event Hub namespace is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules eventhub -Force
        } | Should -Not -Throw
    }
}

Describe 'seed-data.ps1 — az commands invoked when resources exist' -Tag 'unit' {

    Context 'Storage seeding' {

        BeforeAll {
            # First az call (resource list) returns account name; subsequent calls succeed silently
            $script:azCallCount = 0
            Mock az {
                $script:azCallCount++
                $global:LASTEXITCODE = 0
                if ($script:azCallCount -eq 1) { 'demo-storage' }   # Get-AdeResource
                elseif ($script:azCallCount -eq 2) { 'storagekey123' } # keys list
                # everything else: silent success
            }
        }

        It 'Calls az storage blob upload for each sample file plus README' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules storage -Force
            # az should have been called: 1 (resource list) + 1 (keys list) + 4 (3 blobs + 1 README)
            Should -Invoke az -Times 6 -Exactly
        }
    }

    Context 'Cosmos seeding' {

        BeforeAll {
            $script:azCallCount = 0
            Mock az {
                $script:azCallCount++
                $global:LASTEXITCODE = 0
                if ($script:azCallCount -eq 1) { 'demo-cosmos' }     # Get-AdeResource
                # cosmosdb sql document create calls succeed silently
            }
        }

        It 'Calls az cosmosdb sql document create once per sample document' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules cosmosdb -Force
            # 1 (resource list) + 3 (document creates)
            Should -Invoke az -Times 4 -Exactly
        }
    }

    Context 'Key Vault seeding' {

        BeforeAll {
            $script:azCallCount = 0
            Mock az {
                $script:azCallCount++
                $global:LASTEXITCODE = 0
                if ($script:azCallCount -eq 1) { 'demo-kv' }   # Get-AdeResource
                elseif ($script:azCallCount -eq 2) { 'demo-tenant-id' }  # account show (tenantId)
                # keyvault secret set calls succeed silently
            }
        }

        It 'Calls az keyvault secret set for each secret' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules keyvault -Force
            # 1 (resource list) + 1 (account show) + 6 (secret sets)
            Should -Invoke az -Times 8 -Exactly
        }
    }
}

Describe 'seed-data.ps1 — module filter' -Tag 'unit' {

    BeforeAll {
        Mock az { $global:LASTEXITCODE = 0 }
    }

    It 'Only runs storage block when -Modules storage' {
        function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
        function Write-AdeSection { param([string]$Title) }
        . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules storage -Force
        # Only 1 az call (resource list for storage) — no cosmos/kv/sb/eh calls
        Should -Invoke az -Times 1 -Exactly
    }

    It 'Runs all blocks when -Modules all' {
        function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
        function Write-AdeSection { param([string]$Title) }
        . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules all -Force
        # 5 resource-list calls (one per block) — all return empty so no further calls
        Should -Invoke az -Times 5 -Exactly
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Source analysis — confirmation guard and subscription handling
# ─────────────────────────────────────────────────────────────────────────────

Describe 'seed-data.ps1 – source analysis' -Tag 'unit' {

    BeforeAll {
        $script:seedSource = Get-Content (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Raw
    }

    It 'Declares a -Force switch parameter' {
        $script:seedSource | Should -Match '\[switch\]\$Force'
    }

    It 'ValidatePattern uses (?-i) for case-sensitive Prefix enforcement' {
        $script:seedSource | Should -Match '\(\?-i\)' -Because 'must reject uppercase even on case-insensitive filesystems'
    }

    It 'Documents -Force as skipping confirmation in the help comment' {
        $script:seedSource | Should -Match '\.PARAMETER Force'
    }

    It 'Guards the confirmation prompt with if (-not $Force)' {
        $script:seedSource | Should -Match 'if\s*\(-not\s+\$Force\)'
        $script:seedSource | Should -Match 'Read-Host'
    }

    It 'Exits early (exit 0) when the user declines confirmation' {
        $script:seedSource | Should -Match 'notmatch'
        $script:seedSource | Should -Match 'exit 0'
    }

    It 'Runs az account set when SubscriptionId is provided' {
        $script:seedSource | Should -Match 'az account set'
        $script:seedSource | Should -Match 'if\s*\(\$SubscriptionId\)'
    }

    It 'Checks az account set exit code and throws on failure' {
        $script:seedSource | Should -Match 'LASTEXITCODE'
        $script:seedSource | Should -Match 'throw'
    }
}
