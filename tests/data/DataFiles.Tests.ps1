#Requires -Version 7.0
<#
.SYNOPSIS
    Schema and content validation tests for files in data/

    Verifies that seed data files are well-formed, have expected fields,
    and contain plausible values — so a corrupt/edited file fails CI before
    it reaches a real Azure environment.
#>

BeforeAll {
    $script:repoRoot     = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:blobDir      = Join-Path $script:repoRoot 'data\blob'
    $script:cosmosDir    = Join-Path $script:repoRoot 'data\cosmos'
    $script:sqlDir       = Join-Path $script:repoRoot 'data\sql'

    $script:customersFile = Join-Path $script:blobDir   'customers.json'
    $script:productsFile  = Join-Path $script:blobDir   'products.csv'
    $script:telemetryFile = Join-Path $script:blobDir   'telemetry.json'
    $script:ordersFile    = Join-Path $script:cosmosDir 'orders.json'
    $script:seedSqlFile   = Join-Path $script:sqlDir    'seed.sql'
}

# ─────────────────────────────────────────────────────────────────────────────
# customers.json
# ─────────────────────────────────────────────────────────────────────────────

Describe 'data/blob/customers.json' -Tag 'unit' {

    BeforeAll {
        $script:customers = Get-Content $script:customersFile | ConvertFrom-Json
    }

    It 'File exists' {
        Test-Path $script:customersFile | Should -BeTrue
    }

    It 'Parses as valid JSON' {
        { Get-Content $script:customersFile | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'Contains at least one customer record' {
        @($script:customers).Count | Should -BeGreaterOrEqual 1
    }

    It 'Every record has required fields: id, name, email, tier' {
        foreach ($c in $script:customers) {
            $c.PSObject.Properties.Name | Should -Contain 'id'
            $c.PSObject.Properties.Name | Should -Contain 'name'
            $c.PSObject.Properties.Name | Should -Contain 'email'
            $c.PSObject.Properties.Name | Should -Contain 'tier'
        }
    }

    It 'Every id is a positive integer' {
        foreach ($c in $script:customers) {
            $c.id | Should -BeGreaterThan 0
        }
    }

    It 'Every email contains @ and a dot' {
        foreach ($c in $script:customers) {
            $c.email | Should -Match '@.+\.'
        }
    }

    It 'Every tier is one of: gold, silver, bronze' {
        $validTiers = @('gold', 'silver', 'bronze')
        foreach ($c in $script:customers) {
            $c.tier | Should -BeIn $validTiers
        }
    }

    It 'No duplicate customer ids' {
        $ids = @($script:customers | ForEach-Object { $_.id })
        $ids.Count | Should -Be ($ids | Select-Object -Unique).Count
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# products.csv
# ─────────────────────────────────────────────────────────────────────────────

Describe 'data/blob/products.csv' -Tag 'unit' {

    BeforeAll {
        $script:products = Get-Content $script:productsFile | ConvertFrom-Csv
    }

    It 'File exists' {
        Test-Path $script:productsFile | Should -BeTrue
    }

    It 'Parses as valid CSV' {
        { Get-Content $script:productsFile | ConvertFrom-Csv } | Should -Not -Throw
    }

    It 'Contains at least one product record' {
        @($script:products).Count | Should -BeGreaterOrEqual 1
    }

    It 'Has required columns: id, name, category, price, stock, sku' {
        $cols = $script:products[0].PSObject.Properties.Name
        foreach ($col in @('id','name','category','price','stock','sku')) {
            $cols | Should -Contain $col
        }
    }

    It 'Every price is a non-negative number' {
        foreach ($p in $script:products) {
            [double]$p.price | Should -BeGreaterOrEqual 0
        }
    }

    It 'Every stock value is a non-negative integer' {
        foreach ($p in $script:products) {
            [int]$p.stock | Should -BeGreaterOrEqual 0
        }
    }

    It 'No duplicate SKUs' {
        $skus = @($script:products | ForEach-Object { $_.sku })
        $skus.Count | Should -Be ($skus | Select-Object -Unique).Count
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# telemetry.json
# ─────────────────────────────────────────────────────────────────────────────

Describe 'data/blob/telemetry.json' -Tag 'unit' {

    BeforeAll {
        $script:telemetry = Get-Content $script:telemetryFile | ConvertFrom-Json
    }

    It 'File exists' {
        Test-Path $script:telemetryFile | Should -BeTrue
    }

    It 'Parses as valid JSON' {
        { Get-Content $script:telemetryFile | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'Contains at least one telemetry record' {
        @($script:telemetry).Count | Should -BeGreaterOrEqual 1
    }

    It 'Every record has required fields: deviceId, ts, temperature' {
        foreach ($t in $script:telemetry) {
            $t.PSObject.Properties.Name | Should -Contain 'deviceId'
            $t.PSObject.Properties.Name | Should -Contain 'ts'
            $t.PSObject.Properties.Name | Should -Contain 'temperature'
        }
    }

    It 'Every deviceId is a non-empty string' {
        foreach ($t in $script:telemetry) {
            $t.deviceId | Should -Not -BeNullOrEmpty
        }
    }

    It 'Every timestamp (ts) is a valid date/time' {
        foreach ($t in $script:telemetry) {
            # ConvertFrom-Json may auto-parse ISO 8601 to DateTime; accept either case
            $ok = ($t.ts -is [datetime]) -or ($null -ne ($t.ts -as [datetime]))
            $ok | Should -BeTrue -Because "ts '$($t.ts)' should be a valid date/time"
        }
    }

    It 'Temperature values are plausible (between -50 and 100 Celsius)' {
        foreach ($t in $script:telemetry) {
            $t.temperature | Should -BeGreaterThan -50
            $t.temperature | Should -BeLessThan 100
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# orders.json (Cosmos DB)
# ─────────────────────────────────────────────────────────────────────────────

Describe 'data/cosmos/orders.json' -Tag 'unit' {

    BeforeAll {
        $script:orders = Get-Content $script:ordersFile | ConvertFrom-Json
    }

    It 'File exists' {
        Test-Path $script:ordersFile | Should -BeTrue
    }

    It 'Parses as valid JSON' {
        { Get-Content $script:ordersFile | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'Contains at least one order record' {
        @($script:orders).Count | Should -BeGreaterOrEqual 1
    }

    It 'Every record has required fields: id, customerId, status, total' {
        foreach ($o in $script:orders) {
            $o.PSObject.Properties.Name | Should -Contain 'id'
            $o.PSObject.Properties.Name | Should -Contain 'customerId'
            $o.PSObject.Properties.Name | Should -Contain 'status'
            $o.PSObject.Properties.Name | Should -Contain 'total'
        }
    }

    It 'Every status is one of: pending, shipped, completed, cancelled' {
        $validStatuses = @('pending', 'shipped', 'completed', 'cancelled')
        foreach ($o in $script:orders) {
            $o.status | Should -BeIn $validStatuses
        }
    }

    It 'Every total is a positive number' {
        foreach ($o in $script:orders) {
            $o.total | Should -BeGreaterThan 0
        }
    }

    It 'No duplicate order ids' {
        $ids = @($script:orders | ForEach-Object { $_.id })
        $ids.Count | Should -Be ($ids | Select-Object -Unique).Count
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# sql/seed.sql
# ─────────────────────────────────────────────────────────────────────────────

Describe 'data/sql/seed.sql' -Tag 'unit' {

    BeforeAll {
        $script:sql = Get-Content $script:seedSqlFile -Raw
    }

    It 'File exists' {
        Test-Path $script:seedSqlFile | Should -BeTrue
    }

    It 'File is not empty' {
        $script:sql.Trim() | Should -Not -BeNullOrEmpty
    }

    It 'Contains at least one INSERT statement' {
        $script:sql | Should -Match '(?i)INSERT\s+INTO'
    }

    It 'Does not contain DROP TABLE without IF EXISTS guard' {
        # Bare DROP TABLE (without IF EXISTS) is dangerous in seed scripts
        if ($script:sql -match '(?i)DROP\s+TABLE\b') {
            $script:sql | Should -Match '(?i)DROP\s+TABLE\s+(IF\s+EXISTS\b)'
        }
    }

    It 'Does not contain TRUNCATE without a comment explaining intent' {
        if ($script:sql -match '(?i)TRUNCATE\b') {
            # There should be a comment on or near the TRUNCATE line
            $lines  = $script:sql -split "`n"
            $truncLines = $lines | Where-Object { $_ -match '(?i)TRUNCATE' }
            foreach ($line in $truncLines) {
                $line | Should -Match '--' -Because 'TRUNCATE should be commented'
            }
        }
    }
}
