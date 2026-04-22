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

    It 'Does not throw when Event Grid topic is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules eventgrid -Force
        } | Should -Not -Throw
    }

    It 'Does not throw when SQL Server is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules sql -Force
        } | Should -Not -Throw
    }

    It 'Does not throw when PostgreSQL server is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules postgresql -Force
        } | Should -Not -Throw
    }

    It 'Does not throw when MySQL server is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules mysql -Force
        } | Should -Not -Throw
    }

    It 'Does not throw when Redis Cache is missing' {
        {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules redis -Force
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

        It 'Calls az storage blob upload for each sample file plus additional storage seeding' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules storage -Force
            # 1  (resource list) + 1 (keys list)
            # + 3 (blob uploads: customers, products, telemetry)
            # + 1 (container exists check for public — returns '' so README skipped)
            # + 1 (logs blob upload)
            # + 1 (queue create) + 3 (queue messages)
            # + 1 (table create) + 3 (entity inserts)
            # + 1 (file share upload)
            # = 16
            Should -Invoke az -Times 16 -Exactly
        }
    }

    Context 'Cosmos seeding' {

        BeforeAll {
            $script:azCallCount = 0
            Mock az {
                $script:azCallCount++
                $global:LASTEXITCODE = 0
                if    ($script:azCallCount -eq 1) { 'demo-cosmos'    }  # Get-AdeResource
                elseif ($script:azCallCount -eq 3) { 'dGVzdGtleQ==' }  # keys list → primaryMasterKey (base64)
                # call 2: cosmosdb show disableLocalAuth → nothing (= not disabled)
            }
            Mock Invoke-RestMethod { @{} }
        }

        It 'Calls Invoke-RestMethod once per sample document' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules cosmosdb -Force
            # 1 (resource list) + 1 (cosmosdb show for disableLocalAuth check) + 1 (keys list)
            Should -Invoke az -Times 3 -Exactly
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly
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

        It 'Calls az keyvault secret set for each secret plus key and certificate creation' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules keyvault -Force
            # 1 (resource list) + 1 (account show) + 1 (sql server list)
            # + 7 (secret sets) + 1 (key create) + 1 (cert create)
            # = 12
            Should -Invoke az -Times 12 -Exactly
        }
    }

    Context 'SQL seeding' {

        BeforeAll {
            $script:azCallCount = 0
            Mock az {
                $script:azCallCount++
                $global:LASTEXITCODE = 0
                if ($script:azCallCount -eq 1) { 'ade-sqlserver' }   # Get-AdeResource
                # SQL seeding now uses System.Data.SqlClient — no second az call
            }
        }

        It 'Attempts SQL seeding when SQL Server is found and password is provided' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules sql -Force -DatabaseAdminPassword 'TestPass1!'
            # 1 (resource list only) — SQL now uses System.Data.SqlClient, not az
            Should -Invoke az -Times 1 -Exactly
        }
    }

    Context 'PostgreSQL seeding' {

        BeforeAll {
            $script:azCallCount = 0
            Mock az {
                $script:azCallCount++
                $global:LASTEXITCODE = 0
                if ($script:azCallCount -eq 1) { 'ade-postgres' }   # Get-AdeResource
            }
            # Ensure psql is not found so the script skips gracefully without a real connection
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'psql' }
        }

        It 'Skips PostgreSQL seeding gracefully when psql client is not installed' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            { . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules postgresql -Force -DatabaseAdminPassword 'TestPass1!' } | Should -Not -Throw
            # 1 az call (resource list only) — seeding skipped because psql not found
            Should -Invoke az -Times 1 -Exactly
        }
    }

    Context 'MySQL seeding' {

        BeforeAll {
            $script:azCallCount = 0
            Mock az {
                $script:azCallCount++
                $global:LASTEXITCODE = 0
                if ($script:azCallCount -eq 1) { 'ade-mysql' }   # Get-AdeResource
            }
            # Ensure mysql is not found so the script skips gracefully without a real connection
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'mysql' }
        }

        It 'Skips MySQL seeding gracefully when mysql client is not installed' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            { . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules mysql -Force -DatabaseAdminPassword 'TestPass1!' } | Should -Not -Throw
            # 1 az call (resource list only) — seeding skipped because mysql not found
            Should -Invoke az -Times 1 -Exactly
        }
    }

    Context 'Redis seeding' {

        BeforeAll {
            # Stub must exist before Mock can intercept it (defined in seed-data.ps1 at dot-source time)
            function Get-RedisTcpClient { param([string]$Host, [int]$Port) }
            Mock Get-RedisTcpClient { throw 'Redis TCP mocked — no real connection' }
            $script:azCallCount = 0
            Mock az {
                $script:azCallCount++
                $global:LASTEXITCODE = 0
                if ($script:azCallCount -eq 1) { 'demo-redis' }   # Get-AdeResource
                elseif ($script:azCallCount -eq 2) {
                    '{"primaryKey":"test-primary-key","secondaryKey":"test-secondary-key"}'
                }
            }
        }

        It 'Calls az redis list-keys when cache is found' {
            function Write-AdeLog    { param([string]$Message, $Level, [switch]$NoNewline) }
            function Write-AdeSection { param([string]$Title) }
            . (Join-Path $PSScriptRoot '..\..\scripts\seed-data.ps1') -Prefix 'ade' -Modules redis -Force
            # 1 (resource list) + 1 (az redis list-keys); TCP mock throws — caught by the try/catch in seed-data.ps1
            Should -Invoke az -Times 2 -Exactly
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
        # 10 resource-list calls (one per block: storage, cosmosdb, sql, postgresql, mysql,
        # redis, keyvault, servicebus, eventhub, eventgrid) — all return '' so all skip
        Should -Invoke az -Times 10 -Exactly
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

    It 'Discovers GP v2 storage account using isHnsEnabled!=true (null is not false in JMESPath)' {
        # isHnsEnabled is NULL (not false) on GP v2 accounts — ==`false` never matches.
        # Must use !=`true` to also match accounts where the property is absent/null.
        $script:seedSource | Should -Match 'storage account list'
        $script:seedSource | Should -Match 'isHnsEnabled!=.true.'
    }

    It 'Checks LASTEXITCODE after blob upload to detect silent container-not-found failures' {
        # Without the check, uploads to the wrong account report [OK] even when the container
        # does not exist and the az CLI returns a non-zero exit code.
        $script:seedSource | Should -Match 'blob upload[\s\S]{1,400}\$LASTEXITCODE'
    }

    It 'Uses --query endpoint (not properties.endpoint) for az eventgrid topic show' {
        # az eventgrid topic show auto-flattens the ARM response so the endpoint is a
        # top-level field; querying properties.endpoint always returns null.
        $script:seedSource | Should -Match "query 'endpoint'"
        $script:seedSource | Should -Not -Match "query 'properties\.endpoint'"
    }

    It 'Captures cert creation stderr so the real error is shown in the warning' {
        # Previously 2>$null swallowed the actual error message making diagnosis impossible.
        # Fix: redirect 2>&1 and include output in the warning log.
        $script:seedSource | Should -Match 'certificate create'
        $script:seedSource | Should -Match 'certErrMsg'
    }

    It 'Passes KV certificate policy via temp file (@path) not inline to avoid PowerShell quote stripping' {
        # Passing JSON inline via --policy on Windows PowerShell strips double quotes before
        # az CLI receives the string, causing "Failed to parse string as JSON".
        # Fix: write policy to a temp file and use --policy "@filepath".
        $script:seedSource | Should -Match 'certPolicyFile'
        $script:seedSource | Should -Match '@\$certPolicyFile'
        $script:seedSource | Should -Not -Match "--policy '\{" -Because 'inline JSON string must not be used'
    }
}
