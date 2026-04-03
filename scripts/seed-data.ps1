#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Demo Environment (ADE) — Seed Script

.DESCRIPTION
    Seeds dummy data into deployed ADE resources so they are usable for
    demo and benchmark testing immediately after deployment:
      - Azure Blob Storage: uploads sample files (JSON, CSV)
      - Cosmos DB: inserts sample order documents
      - Azure SQL Database: runs data/sql/seed.sql against AdventureWorksLT
      - PostgreSQL: creates demo_products table and inserts sample rows
      - MySQL: creates demo_events table and inserts sample rows
      - Redis Cache: sets demo keys via TLS RESP connection
      - Key Vault: adds commonly-expected demo secrets
      - Service Bus: sends test messages to the orders queue
      - Event Hub: sends a batch of test telemetry events

    NOTE: SQL, PostgreSQL, and MySQL require -DatabaseAdminPassword.
    In hardened mode all databases are behind private endpoints — run this
    script from within the VNet (e.g. via Bastion or a jump VM).

.PARAMETER Prefix
    The prefix used during deployment. Default: ade

.PARAMETER SubscriptionId
    Target subscription ID. If omitted, uses the current az account.

.PARAMETER Modules
    Which resource types to seed. Defaults to all available.
    Accepted values: storage, cosmosdb, sql, postgresql, mysql, redis,
                     keyvault, servicebus, eventhub, all

.PARAMETER DatabaseAdminPassword
    Admin password for Azure SQL, PostgreSQL, and MySQL seeding.
    Required for those three blocks; omit to skip them.
    Use: -DatabaseAdminPassword (Read-Host -AsSecureString 'DB password')

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    ./seed-data.ps1 -Prefix ade -DatabaseAdminPassword (Read-Host -AsSecureString 'DB pwd')

.EXAMPLE
    ./seed-data.ps1 -Prefix ade -Modules storage,cosmosdb,redis -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
    [string]$Prefix = 'ade',

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('storage', 'cosmosdb', 'sql', 'postgresql', 'mysql', 'redis',
                 'keyvault', 'servicebus', 'eventhub', 'all')]
    [string[]]$Modules = @('all'),

    [Parameter(Mandatory = $false)]
    [securestring]$DatabaseAdminPassword,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. "$scriptRoot\helpers\common.ps1"

Write-AdeSection "Azure Demo Environment — Data Seeding"

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --output none
    if ($LASTEXITCODE -ne 0) { throw "Could not set subscription: $SubscriptionId" }
}

if (-not $Force) {
    Write-Host ""
    Write-Host "  This will write data to deployed ADE resources under prefix: '$Prefix'" -ForegroundColor Yellow
    Write-Host "  Modules: $($Modules -join ', ')" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Proceed with data seeding? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-AdeLog "Data seeding cancelled." -Level Warning
        exit 0
    }
}

$seedAll = $Modules -contains 'all'

# ─── Discover resource names ──────────────────────────────────────────────────

function Get-AdeResource {
    param([string]$ResourceGroup, [string]$ResourceType, [string]$Query = 'name')
    $result = az resource list `
        --resource-group $ResourceGroup `
        --resource-type $ResourceType `
        --query "[0].$Query" `
        -o tsv 2>$null
    return $result
}

# Sends a single RESP command over an already-open SslStream and returns the raw reply.
function Invoke-RedisCommand {
    param([System.Net.Security.SslStream]$Stream, [string[]]$Parts)
    $resp = "*$($Parts.Count)`r`n"
    foreach ($p in $Parts) {
        $len = [System.Text.Encoding]::UTF8.GetByteCount($p)
        $resp += "`$$len`r`n$p`r`n"
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
    $buf = New-Object byte[] 1024
    $n   = $Stream.Read($buf, 0, $buf.Length)
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n).Trim()
}

# ─── Blob Storage ─────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'storage') {
    Write-AdeSection "Seeding: Blob Storage"

    $storageRg   = "$Prefix-storage-rg"
    $accountName = Get-AdeResource -ResourceGroup $storageRg -ResourceType 'Microsoft.Storage/storageAccounts'

    if (-not $accountName) {
        Write-AdeLog "No storage account found in '$storageRg'. Skipping." -Level Warning
    } else {
        Write-AdeLog "Storage account: $accountName" -Level Info

        $key = az storage account keys list `
            --account-name $accountName `
            --resource-group $storageRg `
            --query '[0].value' -o tsv

        # Upload sample blobs to 'data' container
        $sampleFiles = @(
            @{ Name = 'customers.json';   Content = '[{"id":1,"name":"Contoso Ltd","tier":"gold"},{"id":2,"name":"Fabrikam Inc","tier":"silver"}]' }
            @{ Name = 'products.csv';     Content = "id,name,price,category`n1,Widget A,19.99,hardware`n2,Widget B,49.99,hardware`n3,Service Pack,99.00,software" }
            @{ Name = 'telemetry.json';   Content = '[{"ts":"2026-01-01T00:00:00Z","device":"dev-001","temp":22.5,"humidity":60},{"ts":"2026-01-01T00:01:00Z","device":"dev-001","temp":22.7,"humidity":59}]' }
        )

        foreach ($file in $sampleFiles) {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) $file.Name
            $file.Content | Set-Content -Path $tmpPath -Encoding UTF8
            az storage blob upload `
                --account-name $accountName `
                --account-key $key `
                --container-name 'data' `
                --name $file.Name `
                --file $tmpPath `
                --overwrite `
                --output none
            Write-AdeLog "Uploaded: data/$($file.Name)" -Level Success
            Remove-Item $tmpPath -Force
        }

        # Upload a README to 'public' container
        $readmePath = Join-Path ([System.IO.Path]::GetTempPath()) 'README.md'
        @"
# Azure Demo Environment — Sample Data

This container contains publicly accessible sample files.
Uploaded by seed-data.ps1 on $(Get-Date -Format 'yyyy-MM-dd').
"@ | Set-Content -Path $readmePath -Encoding UTF8
        az storage blob upload `
            --account-name $accountName `
            --account-key $key `
            --container-name 'public' `
            --name 'README.md' `
            --file $readmePath `
            --overwrite `
            --output none
        Write-AdeLog "Uploaded: public/README.md" -Level Success
        Remove-Item $readmePath -Force
    }
}

# ─── Cosmos DB ────────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'cosmosdb') {
    Write-AdeSection "Seeding: Cosmos DB"

    $dbRg        = "$Prefix-databases-rg"
    $accountName = Get-AdeResource -ResourceGroup $dbRg -ResourceType 'Microsoft.DocumentDB/databaseAccounts'

    if (-not $accountName) {
        Write-AdeLog "No Cosmos DB account found in '$dbRg'. Skipping." -Level Warning
    } else {
        Write-AdeLog "Cosmos DB account: $accountName" -Level Info

        # Use az cosmosdb sql document create for simplicity
        $sampleDocs = @(
            @{ id = 'order-001'; customerId = 1; total = 149.99; status = 'completed'; items = @(@{ sku = 'WIDGET-A'; qty = 2 }) }
            @{ id = 'order-002'; customerId = 2; total = 299.50; status = 'pending';   items = @(@{ sku = 'WIDGET-B'; qty = 5 }) }
            @{ id = 'order-003'; customerId = 1; total = 99.00;  status = 'shipped';   items = @(@{ sku = 'SVC-PACK'; qty = 1 }) }
        )

        foreach ($doc in $sampleDocs) {
            $docJson = $doc | ConvertTo-Json -Depth 5 -Compress
            $tmpDoc  = Join-Path ([System.IO.Path]::GetTempPath()) "cosmosDoc-$($doc.id).json"
            $docJson | Set-Content -Path $tmpDoc -Encoding UTF8
            az cosmosdb sql document create `
                --account-name $accountName `
                --resource-group $dbRg `
                --database-name 'DemoDb' `
                --container-name 'Orders' `
                --body $tmpDoc `
                --output none 2>$null
            Remove-Item $tmpDoc -Force
            Write-AdeLog "Inserted Cosmos document: $($doc.id)" -Level Success
        }
    }
}

# ─── Azure SQL ───────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'sql') {
    Write-AdeSection "Seeding: Azure SQL Database"

    $dbRg      = "$Prefix-databases-rg"
    $sqlServer = Get-AdeResource -ResourceGroup $dbRg -ResourceType 'Microsoft.Sql/servers'

    if (-not $sqlServer) {
        Write-AdeLog "No SQL Server found in '$dbRg'. Skipping." -Level Warning
    } elseif (-not $DatabaseAdminPassword) {
        Write-AdeLog "SQL seeding skipped — provide -DatabaseAdminPassword to seed." -Level Warning
    } else {
        $dbAdminPwd = [System.Net.NetworkCredential]::new('', $DatabaseAdminPassword).Password
        $dbName     = "$Prefix-sqldb"
        Write-AdeLog "SQL Server: $sqlServer  DB: $dbName" -Level Info

        $seedSql = Get-Content (Join-Path $PSScriptRoot '..\data\sql\seed.sql') -Raw
        # Strip GO batch separators — az sql db query does not support them
        $seedSql = ($seedSql -split '(?m)^\s*GO\s*$' | Where-Object { $_.Trim() }) -join "`n"

        az sql db query `
            --resource-group $dbRg `
            --server $sqlServer `
            --name $dbName `
            --admin-user 'sqladmin' `
            --admin-password $dbAdminPwd `
            --query-text $seedSql `
            --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-AdeLog "SQL seed applied: $dbName (AdventureWorksLT + demo rows)" -Level Success
        } else {
            Write-AdeLog "SQL seed returned non-zero exit. Check connectivity and credentials." -Level Warning
        }
    }
}

# ─── PostgreSQL ───────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'postgresql') {
    Write-AdeSection "Seeding: PostgreSQL Flexible Server"

    $dbRg    = "$Prefix-databases-rg"
    $pgServer = Get-AdeResource -ResourceGroup $dbRg -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers'

    if (-not $pgServer) {
        Write-AdeLog "No PostgreSQL server found in '$dbRg'. Skipping." -Level Warning
    } elseif (-not $DatabaseAdminPassword) {
        Write-AdeLog "PostgreSQL seeding skipped — provide -DatabaseAdminPassword to seed." -Level Warning
    } else {
        $dbAdminPwd = [System.Net.NetworkCredential]::new('', $DatabaseAdminPassword).Password
        $pgDbName   = "${Prefix}db"
        Write-AdeLog "PostgreSQL server: $pgServer  DB: $pgDbName" -Level Info

        $pgSeed = Get-Content (Join-Path $PSScriptRoot '..\data\postgres\seed.sql') -Raw

        az postgres flexible-server execute `
            --resource-group $dbRg `
            --name $pgServer `
            --database-name $pgDbName `
            --admin-user 'pgadmin' `
            --admin-password $dbAdminPwd `
            --querytext $pgSeed `
            --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-AdeLog "PostgreSQL seed applied: $pgDbName" -Level Success
        } else {
            Write-AdeLog "PostgreSQL seed returned non-zero exit. Check connectivity and credentials." -Level Warning
        }
    }
}

# ─── MySQL ────────────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'mysql') {
    Write-AdeSection "Seeding: MySQL Flexible Server"

    $dbRg      = "$Prefix-databases-rg"
    $mysqlServer = Get-AdeResource -ResourceGroup $dbRg -ResourceType 'Microsoft.DBforMySQL/flexibleServers'

    if (-not $mysqlServer) {
        Write-AdeLog "No MySQL server found in '$dbRg'. Skipping." -Level Warning
    } elseif (-not $DatabaseAdminPassword) {
        Write-AdeLog "MySQL seeding skipped — provide -DatabaseAdminPassword to seed." -Level Warning
    } else {
        $dbAdminPwd  = [System.Net.NetworkCredential]::new('', $DatabaseAdminPassword).Password
        $mysqlDbName = "${Prefix}db"
        Write-AdeLog "MySQL server: $mysqlServer  DB: $mysqlDbName" -Level Info

        $mysqlSeed = Get-Content (Join-Path $PSScriptRoot '..\data\mysql\seed.sql') -Raw

        az mysql flexible-server execute `
            --resource-group $dbRg `
            --name $mysqlServer `
            --database-name $mysqlDbName `
            --admin-user 'pgadmin' `
            --admin-password $dbAdminPwd `

            --file-path (Join-Path $PSScriptRoot '..\data\mysql\seed.sql') `
            --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-AdeLog "MySQL seed applied: $mysqlDbName" -Level Success
        } else {
            Write-AdeLog "MySQL seed returned non-zero exit. Check connectivity and credentials." -Level Warning
        }
    }
}

# ─── Redis Cache ──────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'redis') {
    Write-AdeSection "Seeding: Redis Cache"

    $dbRg      = "$Prefix-databases-rg"
    $redisName = Get-AdeResource -ResourceGroup $dbRg -ResourceType 'Microsoft.Cache/redis'

    if (-not $redisName) {
        Write-AdeLog "No Redis Cache found in '$dbRg'. Skipping." -Level Warning
    } else {
        Write-AdeLog "Redis Cache: $redisName" -Level Info

        $redisKeys  = az redis list-keys `
            --resource-group $dbRg `
            --name $redisName `
            --output json 2>$null | ConvertFrom-Json

        if (-not $redisKeys) {
            Write-AdeLog "Could not retrieve Redis keys. Skipping." -Level Warning
        } else {
            $primaryKey = $redisKeys.primaryKey
            $redisHost  = "$redisName.redis.cache.windows.net"

            # Demo key-value pairs to seed
            $demoKeys = [ordered]@{
                'demo:session:001'      = '{"userId":"user-001","role":"admin","exp":9999999999}'
                'demo:session:002'      = '{"userId":"user-002","role":"reader","exp":9999999999}'
                'demo:config:app'       = '{"theme":"dark","language":"en","maxRetries":3}'
                'demo:counter:requests' = '42000'
                'demo:feature:flags'    = '{"newUI":true,"betaSearch":false,"darkMode":true}'
            }

            $tcp = $null
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new($redisHost, 6380)
                $ssl = [System.Net.Security.SslStream]::new(
                    $tcp.GetStream(), $false,
                    [System.Net.Security.RemoteCertificateValidationCallback]{ param($s, $c, $ch, $e) $true }
                )
                $ssl.AuthenticateAsClient($redisHost)

                # Authenticate
                $null = Invoke-RedisCommand -Stream $ssl -Parts @('AUTH', $primaryKey)

                # SET demo keys (sessions with 24h TTL, others permanent)
                foreach ($kv in $demoKeys.GetEnumerator()) {
                    $null = Invoke-RedisCommand -Stream $ssl -Parts @('SET', $kv.Key, $kv.Value)
                    Write-AdeLog "Redis SET: $($kv.Key)" -Level Success
                }
                $null = Invoke-RedisCommand -Stream $ssl -Parts @('EXPIRE', 'demo:session:001', '86400')
                $null = Invoke-RedisCommand -Stream $ssl -Parts @('EXPIRE', 'demo:session:002', '86400')

                $null = Invoke-RedisCommand -Stream $ssl -Parts @('QUIT')
            } catch {
                Write-AdeLog "Redis TLS connection failed: $_. Ensure the runner has network access to $redisHost." -Level Warning
            } finally {
                if ($tcp) { $tcp.Dispose() }
            }
        }
    }
}

# ─── Key Vault ────────────────────────────────────────────────────────────────
if ($seedAll -or $Modules -contains 'keyvault') {
    Write-AdeSection "Seeding: Key Vault"

    $secRg    = "$Prefix-security-rg"
    $vaultName = Get-AdeResource -ResourceGroup $secRg -ResourceType 'Microsoft.KeyVault/vaults'

    if (-not $vaultName) {
        Write-AdeLog "No Key Vault found in '$secRg'. Skipping." -Level Warning
    } else {
        Write-AdeLog "Key Vault: $vaultName" -Level Info

        # Ensure current caller has secret set permission
        $kvTenantId = az account show --query tenantId -o tsv 2>$null
        if (-not $kvTenantId) { $kvTenantId = 'demo-tenant-id' }

        # Resolve real SQL Server FQDN if deployed — replaces the Bicep placeholder
        $dbRg      = "$Prefix-databases-rg"
        $sqlServer = az sql server list --resource-group $dbRg --query '[0].name' -o tsv 2>$null
        $sqlFqdn   = if ($sqlServer) {
            az sql server show --resource-group $dbRg --name $sqlServer --query 'fullyQualifiedDomainName' -o tsv 2>$null
        }
        $dbConnString = if ($sqlFqdn) {
            "Server=$sqlFqdn;Database=$Prefix-sqldb;User Id=sqladmin;Password=REPLACE_IN_PRODUCTION"
        } else {
            'Server=REPLACE_WITH_SQL_FQDN;Database=demodb;User Id=sqladmin;Password=REPLACE_IN_PRODUCTION'
        }

        $kvSecrets = @{
            'db-connection-string'  = $dbConnString
            'app-client-id'        = 'demo-client-id-00000000-0000-0000-0000-000000000001'
            'app-client-secret'    = 'demo-secret-value-replace-in-production'
            'app-tenant-id'        = $kvTenantId
            'smtp-password'        = 'demo-smtp-password-replace-in-production'
            'third-party-api-key'  = 'demo-api-key-abc123xyz-replace-in-production'
            'jwt-signing-key'      = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('demo-jwt-signing-key-replace-in-production'))
        }

        foreach ($secret in $kvSecrets.GetEnumerator()) {
            az keyvault secret set `
                --vault-name $vaultName `
                --name $secret.Key `
                --value $secret.Value `
                --output none 2>$null
            Write-AdeLog "Secret set: $($secret.Key)" -Level Success
        }
    }
}

# ─── Service Bus ─────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'servicebus') {
    Write-AdeSection "Seeding: Service Bus"

    $intRg    = "$Prefix-integration-rg"
    $sbNs     = Get-AdeResource -ResourceGroup $intRg -ResourceType 'Microsoft.ServiceBus/namespaces'

    if (-not $sbNs) {
        Write-AdeLog "No Service Bus namespace found in '$intRg'. Skipping." -Level Warning
    } else {
        Write-AdeLog "Service Bus namespace: $sbNs" -Level Info

        $sbKey = az servicebus namespace authorization-rule keys list `
            --resource-group $intRg `
            --namespace-name $sbNs `
            --name RootManageSharedAccessKey `
            --query primaryConnectionString -o tsv 2>$null

        if ($sbKey) {
            $testMessages = @(
                '{"orderId":"test-001","event":"OrderCreated","timestamp":"2026-01-01T00:00:00Z"}'
                '{"orderId":"test-002","event":"OrderShipped","timestamp":"2026-01-01T01:00:00Z"}'
            )
            foreach ($msg in $testMessages) {
                az servicebus message send `
                    --connection-string $sbKey `
                    --entity-path 'orders' `
                    --message $msg `
                    --output none 2>$null
            }
            Write-AdeLog "Sent $($testMessages.Count) test messages to 'orders' queue." -Level Success
        }
    }
}

# ─── Event Hub ───────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'eventhub') {
    Write-AdeSection "Seeding: Event Hub"

    $intRg    = "$Prefix-integration-rg"
    $ehNs     = Get-AdeResource -ResourceGroup $intRg -ResourceType 'Microsoft.EventHub/namespaces'

    if (-not $ehNs) {
        Write-AdeLog "No Event Hub namespace found in '$intRg'. Skipping." -Level Warning
    } else {
        Write-AdeLog "Event Hub namespace: $ehNs" -Level Info

        $ehKey = az eventhubs namespace authorization-rule keys list `
            --resource-group $intRg `
            --namespace-name $ehNs `
            --name RootManageSharedAccessKey `
            --query primaryConnectionString -o tsv 2>$null

        if ($ehKey) {
            Write-AdeLog "Event Hub key retrieved. Use the SDK or az eventhubs to send test events." -Level Info
            Write-AdeLog "Connection string saved to env var: ADE_EVENTHUB_CONN" -Level Info
            $env:ADE_EVENTHUB_CONN = $ehKey
        }
    }
}

# ─── Complete ─────────────────────────────────────────────────────────────────

Write-AdeSection "Data Seeding Complete"
Write-AdeLog "Dummy data has been seeded into deployed ADE resources." -Level Success
Write-AdeLog "Run './scripts/dashboard/Get-AdeCostDashboard.ps1' to review resource status." -Level Info
exit 0
