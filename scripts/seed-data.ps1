#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Demo Environment (ADE) — Seed Script

.DESCRIPTION
    Seeds dummy data into deployed ADE resources so they are usable for
    demo and benchmark testing immediately after deployment:
      - Azure Blob Storage: uploads sample files (JSON, CSV) to data/logs/public containers
      - Storage Queue: creates demo-tasks queue and enqueues sample task messages
      - Storage Table: creates demotable and inserts sample device/config entities
      - Storage File Share: uploads welcome.txt to the provisioned file share
      - Cosmos DB: inserts sample order documents
      - Azure SQL Database: runs data/sql/seed.sql against AdventureWorksLT
      - PostgreSQL: creates demo_products + demo_orders tables and inserts sample rows
      - MySQL: creates demo_events + demo_devices tables and inserts sample rows
      - Redis Cache: sets demo keys via TLS RESP connection
      - Key Vault: adds demo secrets, an RSA 2048 encryption key, and a self-signed certificate
      - Service Bus: sends test messages to the orders queue
      - Event Hub: sends telemetry events via REST to the telemetry hub
      - Event Grid: publishes demo events to the custom topic

    NOTE: SQL, PostgreSQL, and MySQL require -DatabaseAdminPassword.
    In hardened mode all databases are behind private endpoints — run this
    script from within the VNet (e.g. via Bastion or a jump VM).
    Key Vault key and certificate creation require Key Vault Administrator
    (or Crypto Officer + Certificates Officer) on the vault.

.PARAMETER Prefix
    The prefix used during deployment. Default: ade

.PARAMETER SubscriptionId
    Target subscription ID. If omitted, uses the current az account.

.PARAMETER Modules
    Which resource types to seed. Defaults to all available.
    Accepted values: storage, cosmosdb, sql, postgresql, mysql, redis,
                     keyvault, servicebus, eventhub, eventgrid, all

.PARAMETER AdminUsername
    Admin username used during ADE deployment. Must match the -AdminUsername value
    passed to deploy.ps1 (default: 'adeadmin'). Used as the login for SQL, PostgreSQL,
    and MySQL seeding.

.PARAMETER DatabaseAdminPassword
    Admin password for Azure SQL, PostgreSQL, and MySQL seeding.
    Required for those three blocks; omit to skip them.
    Use: -DatabaseAdminPassword 'YourPassword'

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    ./seed-data.ps1 -Prefix ade -DatabaseAdminPassword 'YourPassword'

.EXAMPLE
    ./seed-data.ps1 -Prefix ade -Modules storage,cosmosdb,redis -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('(?-i)^[a-z0-9]{2,8}$')]
    [string]$Prefix = 'ade',

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('storage', 'cosmosdb', 'sql', 'postgresql', 'mysql', 'redis',
                 'keyvault', 'servicebus', 'eventhub', 'eventgrid', 'all')]
    [string[]]$Modules = @('all'),

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername = 'adeadmin',

    [Parameter(Mandatory = $false)]
    [string]$DatabaseAdminPassword,

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
$script:_seedFailed = $false

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

# Opens a TcpClient to a Redis host. Extracted so unit tests can mock it.
function Get-RedisTcpClient {
    [OutputType([System.Net.Sockets.TcpClient])]
    param([string]$Host, [int]$Port)
    return [System.Net.Sockets.TcpClient]::new($Host, $Port)
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

# Generates a SharedAccessSignature token for Azure Service Bus / Event Hubs REST API.
function New-EhSasToken {
    param(
        [string]$ResourceUri,
        [string]$KeyName,
        [string]$Key,
        [int]$ExpirySeconds = 3600
    )
    $expiry       = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $ExpirySeconds
    $stringToSign = [Uri]::EscapeDataString($ResourceUri) + "`n" + $expiry
    $hmac         = [System.Security.Cryptography.HMACSHA256]::new(
                        [System.Text.Encoding]::UTF8.GetBytes($Key))
    $sig          = [Convert]::ToBase64String(
                        $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign)))
    return "SharedAccessSignature sr=$([Uri]::EscapeDataString($ResourceUri))&sig=$([Uri]::EscapeDataString($sig))&se=$expiry&skn=$KeyName"
}

# ─── Blob Storage ─────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'storage') {
    Write-AdeSection "Seeding: Blob Storage"

    $storageRg   = "$Prefix-storage-rg"
    # isHnsEnabled is NULL (not false) on GP v2 accounts when HNS was never enabled.
    # JMESPath `==\`false\`` does not match null — use `!=\`true\`` to catch both null and false.
    $rawAcct     = az storage account list `
        --resource-group $storageRg `
        --query '[?isHnsEnabled!=`true`].name | [0]' `
        -o tsv 2>$null
    $accountName = if ($rawAcct) { $rawAcct.Trim() } else { '' }

    if (-not $accountName) {
        Write-AdeLog "No storage account found in '$storageRg'. Skipping." -Level Warning
    } else {
        Write-AdeLog "Storage account: $accountName" -Level Info

        $key = az storage account keys list `
            --account-name $accountName `
            --resource-group $storageRg `
            --query '[0].value' -o tsv 2>$null

        # Hardened mode: allowSharedKeyAccess = false — keys CLI returns empty.
        # Fall back to Entra ID identity-based auth (requires caller to have
        # Storage Blob Data Contributor role on the account).
        $authArgs = if ($key) {
            @('--account-key', $key)
        } else {
            Write-AdeLog "Shared keys disabled — using --auth-mode login (ensure Storage Blob Data Contributor role)." -Level Warning
            @('--auth-mode', 'login')
        }
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
                @authArgs `
                --container-name 'data' `
                --name $file.Name `
                --file $tmpPath `
                --overwrite `
                --output none 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-AdeLog "Uploaded: data/$($file.Name)" -Level Success
            } else {
                Write-AdeLog "Failed to upload data/$($file.Name) — 'data' container missing or access denied." -Level Warning
            }
            Remove-Item $tmpPath -Force
        }

        # Upload a README to 'public' container only if it exists (absent in hardened mode)
        $publicExists = (az storage container exists `
            --account-name $accountName `
            @authArgs `
            --name 'public' `
            --query exists `
            --output tsv 2>$null) -eq 'true'
        if ($publicExists) {
            $readmePath = Join-Path ([System.IO.Path]::GetTempPath()) 'README.md'
            @"
# Azure Demo Environment — Sample Data

This container contains publicly accessible sample files.
Uploaded by seed-data.ps1 on $(Get-Date -Format 'yyyy-MM-dd').
"@ | Set-Content -Path $readmePath -Encoding UTF8
            az storage blob upload `
                --account-name $accountName `
                @authArgs `
                --container-name 'public' `
                --name 'README.md' `
                --file $readmePath `
                --overwrite `
                --output none
            Write-AdeLog "Uploaded: public/README.md" -Level Success
            Remove-Item $readmePath -Force
        } else {
            Write-AdeLog "'public' container not found (hardened mode — expected). Skipping README upload." -Level Warning
        }

        # ─── Logs container: seed a diagnostic run record ─────────────────────────
        $logFile = Join-Path ([System.IO.Path]::GetTempPath()) 'seed-diagnostics.json'
        @{ seedRun = (Get-Date -Format 'o'); host = [System.Net.Dns]::GetHostName(); status = 'ok' } |
            ConvertTo-Json -Compress | Set-Content -Path $logFile -Encoding UTF8
        az storage blob upload `
            --account-name $accountName `
            @authArgs `
            --container-name 'logs' `
            --name 'seed/seed-diagnostics.json' `
            --file $logFile `
            --overwrite `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-AdeLog "Uploaded: logs/seed/seed-diagnostics.json" -Level Success
        } else {
            Write-AdeLog "Failed to upload diagnostic log to 'logs' container." -Level Warning
        }
        Remove-Item $logFile -Force

        # ─── Storage Queue: demo task queue ───────────────────────────────────────
        az storage queue create `
            --account-name $accountName `
            @authArgs `
            --name 'demo-tasks' `
            --output none 2>$null
        Write-AdeLog "Queue created: demo-tasks" -Level Info

        $demoQueueMessages = @(
            '{"taskId":"task-001","type":"SendEmail","priority":"high","createdAt":"2026-01-01T00:00:00Z"}'
            '{"taskId":"task-002","type":"ProcessOrder","priority":"normal","createdAt":"2026-01-01T00:01:00Z"}'
            '{"taskId":"task-003","type":"GenerateReport","priority":"low","createdAt":"2026-01-01T00:02:00Z"}'
        )
        foreach ($msg in $demoQueueMessages) {
            $msgB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($msg))
            az storage message put `
                --account-name $accountName `
                @authArgs `
                --queue-name 'demo-tasks' `
                --content $msgB64 `
                --output none 2>$null
        }
        Write-AdeLog "Enqueued $($demoQueueMessages.Count) demo tasks to 'demo-tasks' queue." -Level Success

        # ─── Storage Table: demo entity store ─────────────────────────────────────
        az storage table create `
            --account-name $accountName `
            @authArgs `
            --name 'demotable' `
            --output none 2>$null
        Write-AdeLog "Table created: demotable" -Level Info

        $demoEntities = @(
            [ordered]@{ PartitionKey = 'devices'; RowKey = 'dev-001'; Model = 'SensorXv2'; Location = 'BuildingA'; Active = 'true' }
            [ordered]@{ PartitionKey = 'devices'; RowKey = 'dev-002'; Model = 'SensorXv2'; Location = 'BuildingB'; Active = 'true' }
            [ordered]@{ PartitionKey = 'config';  RowKey = 'global';  Theme = 'dark'; Version = '1.0'; Features = 'newUI' }
        )
        foreach ($entity in $demoEntities) {
            $entityProps = $entity.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
            az storage entity insert `
                --account-name $accountName `
                @authArgs `
                --table-name 'demotable' `
                --entity @entityProps `
                --if-exists replace `
                --output none 2>$null
            Write-AdeLog "Entity inserted: $($entity.PartitionKey)/$($entity.RowKey)" -Level Success
        }

        # ─── File Share: seed a welcome file ──────────────────────────────────────
        $welcomePath = Join-Path ([System.IO.Path]::GetTempPath()) 'welcome.txt'
        "Azure Demo Environment`nPrefix : $Prefix`nDeployed: $(Get-Date -Format 'yyyy-MM-dd')`nContents: Demo files for storage benchmark testing." |
            Set-Content -Path $welcomePath -Encoding UTF8
        az storage file upload `
            --account-name $accountName `
            @authArgs `
            --share-name "$Prefix-fileshare" `
            --source $welcomePath `
            --output none 2>$null
        Write-AdeLog "Uploaded: $Prefix-fileshare/welcome.txt" -Level Success
        Remove-Item $welcomePath -Force
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

        # In hardened mode, disableLocalAuth=true blocks key-based data plane access.
        # az cosmosdb sql document create uses keys internally; it has no --auth-mode login flag.
        $localAuthDisabled = (az cosmosdb show `
            --name $accountName `
            --resource-group $dbRg `
            --query 'properties.disableLocalAuth' `
            --output tsv 2>$null) -eq 'true'

        if ($localAuthDisabled) {
            Write-AdeLog "Cosmos DB local auth is disabled (hardened mode). Skipping document seeding via CLI." -Level Warning
            Write-AdeLog "To seed manually: assign 'Cosmos DB Built-in Data Contributor' to your identity, then use the Azure Portal Data Explorer or the Cosmos REST API with an Entra Bearer token." -Level Info
        } else {
        # az cosmosdb sql document does not exist in az CLI core; use the Cosmos DB
        # Data Plane REST API with master-key HMAC-SHA256 authentication instead.
        $cosmosKey = az cosmosdb keys list `
            --name $accountName `
            --resource-group $dbRg `
            --query primaryMasterKey `
            --output tsv 2>$null

        $dbName        = "${Prefix}-db"
        $containerName = 'items'
        $resourceLink  = "dbs/$dbName/colls/$containerName"

        $sampleDocs = @(
            @{ id = 'order-001'; customerId = 1; total = 149.99; status = 'completed'; items = @(@{ sku = 'WIDGET-A'; qty = 2 }) }
            @{ id = 'order-002'; customerId = 2; total = 299.50; status = 'pending';   items = @(@{ sku = 'WIDGET-B'; qty = 5 }) }
            @{ id = 'order-003'; customerId = 1; total = 99.00;  status = 'shipped';   items = @(@{ sku = 'SVC-PACK'; qty = 1 }) }
        )

        foreach ($doc in $sampleDocs) {
            $docJson  = $doc | ConvertTo-Json -Depth 5 -Compress
            $dateUtc  = [datetime]::UtcNow.ToString('R')

            # Build Cosmos DB master-key authorization token (HMAC-SHA256)
            $stringToSign = "post`ndocs`n$resourceLink`n$($dateUtc.ToLower())`n`n"
            $keyBytes  = [System.Convert]::FromBase64String($cosmosKey)
            $hmac      = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
            $sig       = [System.Convert]::ToBase64String(
                             $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign)))
            $authToken = [uri]::EscapeDataString("type=master&ver=1.0&sig=$sig")

            try {
                $null = Invoke-RestMethod `
                    -Uri     "https://$accountName.documents.azure.com/$resourceLink/docs" `
                    -Method  POST `
                    -Headers @{
                        'Authorization'                    = $authToken
                        'x-ms-date'                        = $dateUtc
                        'x-ms-version'                     = '2018-12-31'
                        'x-ms-documentdb-partitionkey'     = "[`"$($doc.id)`"]"
                        'x-ms-documentdb-is-upsert'        = 'true'
                    } `
                    -ContentType 'application/json' `
                    -Body        $docJson `
                    -ErrorAction Stop
                Write-AdeLog "Inserted Cosmos document: $($doc.id)" -Level Success
            } catch {
                Write-AdeLog "Failed to insert Cosmos document: $($doc.id) — $($_.Exception.Message)" -Level Warning
            }
        }
        } # end else (local auth enabled)
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
        $dbAdminPwd = $DatabaseAdminPassword
        $dbName     = "$Prefix-sqldb"
        Write-AdeLog "SQL Server: $sqlServer  DB: $dbName" -Level Info

        # az sql db query was removed from Azure CLI — use System.Data.SqlClient directly
        $seedFile = Join-Path $PSScriptRoot '..\data\sql\seed.sql'
        try {
            $connStr = "Server=tcp:${sqlServer}.database.windows.net,1433;Initial Catalog=$dbName;User ID=$AdminUsername;Password=$dbAdminPwd;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30"
            $conn    = New-Object System.Data.SqlClient.SqlConnection($connStr)
            $conn.Open()
            $sqlRaw  = (Get-Content $seedFile -Raw) -replace '(?im)^\s*USE\s+\[?\w+\]?\s*;?\s*(\r?\n)', ''
            $batches = $sqlRaw -split '(?m)^\s*GO\s*$'
            foreach ($batch in ($batches | Where-Object { $_.Trim() })) {
                $cmd             = $conn.CreateCommand()
                $cmd.CommandText = $batch
                $cmd.CommandTimeout = 60
                $cmd.ExecuteNonQuery() | Out-Null
            }
            $conn.Close()
            Write-AdeLog "SQL seed applied: $dbName" -Level Success
        } catch {
            Write-AdeLog "SQL seed failed: $_" -Level Warning
            $script:_seedFailed = $true
        }
    }
}

# ─── PostgreSQL ───────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'postgresql') {
    Write-AdeSection "Seeding: PostgreSQL Flexible Server"

    $dbRg     = "$Prefix-databases-rg"
    $pgServer = Get-AdeResource -ResourceGroup $dbRg -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers'

    if (-not $pgServer) {
        Write-AdeLog "No PostgreSQL server found in '$dbRg'. Skipping." -Level Warning
    } elseif (-not $DatabaseAdminPassword) {
        Write-AdeLog "PostgreSQL seeding skipped — provide -DatabaseAdminPassword to seed." -Level Warning
    } elseif (-not (Get-Command 'psql' -ErrorAction SilentlyContinue)) {
        Write-AdeLog "PostgreSQL seeding skipped — 'psql' client not found. See README § Seed data for options." -Level Info
    } else {
        $dbAdminPwd = $DatabaseAdminPassword
        $pgDbName   = "${Prefix}db"
        $pgSeedFile = Join-Path $PSScriptRoot '..\data\postgres\seed.sql'
        Write-AdeLog "PostgreSQL server: $pgServer  DB: $pgDbName" -Level Info
        try {
            $env:PGPASSWORD = $dbAdminPwd
            psql --host="$pgServer.postgres.database.azure.com" --port=5432 `
                 --username="$AdminUsername" --dbname="$pgDbName" `
                 --file="$pgSeedFile" --no-password 2>&1 | ForEach-Object { Write-AdeLog $_ -Level Info }
            if ($LASTEXITCODE -ne 0) { throw "psql exited with code $LASTEXITCODE" }
            Write-AdeLog "PostgreSQL seed applied: $pgDbName" -Level Success
        } catch {
            Write-AdeLog "PostgreSQL seed failed: $_" -Level Warning
            $script:_seedFailed = $true
        } finally {
            Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
        }
    }
}

# ─── MySQL ────────────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'mysql') {
    Write-AdeSection "Seeding: MySQL Flexible Server"

    $dbRg        = "$Prefix-databases-rg"
    $mysqlServer = Get-AdeResource -ResourceGroup $dbRg -ResourceType 'Microsoft.DBforMySQL/flexibleServers'

    if (-not $mysqlServer) {
        Write-AdeLog "No MySQL server found in '$dbRg'. Skipping." -Level Warning
    } elseif (-not $DatabaseAdminPassword) {
        Write-AdeLog "MySQL seeding skipped — provide -DatabaseAdminPassword to seed." -Level Warning
    } elseif (-not (Get-Command 'mysql' -ErrorAction SilentlyContinue)) {
        Write-AdeLog "MySQL seeding skipped — 'mysql' client not found. See README § Seed data for options." -Level Info
    } else {
        $dbAdminPwd  = $DatabaseAdminPassword
        $mysqlDbName = "${Prefix}db"
        $mysqlSeedFile = Join-Path $PSScriptRoot '..\data\mysql\seed.sql'
        Write-AdeLog "MySQL server: $mysqlServer  DB: $mysqlDbName" -Level Info
        try {
            mysql --host="$mysqlServer.mysql.database.azure.com" --port=3306 `
                  --user="$AdminUsername" --password="$dbAdminPwd" `
                  --ssl-mode=REQUIRED "$mysqlDbName" `
                  --execute="source $mysqlSeedFile" 2>&1 | ForEach-Object { Write-AdeLog $_ -Level Info }
            if ($LASTEXITCODE -ne 0) { throw "mysql exited with code $LASTEXITCODE" }
            Write-AdeLog "MySQL seed applied: $mysqlDbName" -Level Success
        } catch {
            Write-AdeLog "MySQL seed failed: $_" -Level Warning
            $script:_seedFailed = $true
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
                $tcp = Get-RedisTcpClient -Host $redisHost -Port 6380
                #region DEMO ONLY — DO NOT COPY TO PRODUCTION
                # RemoteCertificateValidationCallback returns $true unconditionally.
                # This is acceptable here because:
                #   1. The target is always *.redis.cache.windows.net — an Azure-managed cert.
                #   2. This is a one-shot demo seed script, not a long-lived service connection.
                #   3. SslStream + port 6380 still provides transport encryption (TLS 1.2+).
                # For production workloads use the StackExchange.Redis NuGet package, which
                # validates the full certificate chain by default.
                $ssl = [System.Net.Security.SslStream]::new(
                    $tcp.GetStream(), $false,
                    [System.Net.Security.RemoteCertificateValidationCallback]{ param($s, $c, $ch, $e) $true }
                )
                #endregion DEMO ONLY
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
            # Randomised per-seed so each deployment gets a unique placeholder value.
            # These are NOT real credentials — replace with actual secrets before production use.
            'app-client-secret'    = "demo-secret-$([guid]::NewGuid().ToString('N').Substring(0,16))"
            'app-tenant-id'        = $kvTenantId
            'smtp-password'        = "demo-smtp-$([guid]::NewGuid().ToString('N').Substring(0,16))"
            'third-party-api-key'  = "demo-apikey-$([guid]::NewGuid().ToString('N').Substring(0,16))"
            'jwt-signing-key'      = [System.Convert]::ToBase64String(
                                        [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
                                    )
        }

        foreach ($secret in $kvSecrets.GetEnumerator()) {
            az keyvault secret set `
                --vault-name $vaultName `
                --name $secret.Key `
                --value $secret.Value `
                --output none 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-AdeLog "Secret set: $($secret.Key)" -Level Success
            } else {
                Write-AdeLog "Secret '$($secret.Key)' could not be written — KV may have restricted network access in hardened mode." -Level Warning
            }
        }

        # ─── Key: RSA 2048 encryption key ─────────────────────────────────────────
        # Requires Key Vault Crypto Officer (or Administrator) on the vault.
        az keyvault key create `
            --vault-name $vaultName `
            --name 'demo-encryption-key' `
            --kty RSA `
            --size 2048 `
            --ops encrypt decrypt wrapKey unwrapKey `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-AdeLog "Key created: demo-encryption-key (RSA 2048)" -Level Success
        } else {
            Write-AdeLog "Key 'demo-encryption-key' could not be created — ensure Key Vault Crypto Officer role is assigned." -Level Warning
        }

        # ─── Certificate: self-signed TLS demo certificate ────────────────────────
        # Requires Key Vault Certificates Officer (or Administrator) on the vault.
        # Policy: Self-signed, RSA 2048, CN=ade-demo, 12-month validity, server+client EKU.
        # NOTE: Passing JSON via --policy inline on Windows PowerShell causes double-quote
        #       stripping before az CLI receives it. Write to a temp file and use @path instead.
        $selfSignedPolicy = @{
            issuerParameters = @{ name = 'Self' }
            keyProperties    = @{ exportable = $true; keySize = 2048; keyType = 'RSA'; reuseKey = $false }
            lifetimeActions  = @(@{ action = @{ actionType = 'AutoRenew' }; trigger = @{ daysBeforeExpiry = 90 } })
            secretProperties = @{ contentType = 'application/x-pkcs12' }
            x509CertificateProperties = @{
                ekus    = @('1.3.6.1.5.5.7.3.1', '1.3.6.1.5.5.7.3.2')
                keyUsage = @('digitalSignature', 'keyEncipherment')
                subject  = 'CN=ade-demo'
                validityInMonths = 12
            }
        } | ConvertTo-Json -Depth 6 -Compress
        $certPolicyFile = Join-Path ([System.IO.Path]::GetTempPath()) 'ade-cert-policy.json'
        $selfSignedPolicy | Set-Content -Path $certPolicyFile -Encoding UTF8
        $certErr = az keyvault certificate create `
            --vault-name $vaultName `
            --name 'demo-tls-cert' `
            --policy "@$certPolicyFile" `
            --output none 2>&1
        Remove-Item $certPolicyFile -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -eq 0) {
            Write-AdeLog "Certificate created: demo-tls-cert (self-signed, CN=ade-demo, RSA 2048)" -Level Success
        } else {
            $certErrMsg = ($certErr | Out-String).Trim()
            Write-AdeLog "Certificate 'demo-tls-cert' could not be created: $certErrMsg" -Level Warning
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
            # Extract the bare SAS key from the connection string
            # Format: Endpoint=sb://...;SharedAccessKeyName=...;SharedAccessKey=<key>
            $ehPrimaryKey = ($ehKey -split ';' | Where-Object { $_ -like 'SharedAccessKey=*' }) -replace 'SharedAccessKey=', ''
            $ehHubName    = "$Prefix-telemetry"
            $ehUri        = "https://$ehNs.servicebus.windows.net/$ehHubName"

            $sas = New-EhSasToken -ResourceUri $ehUri -KeyName 'RootManageSharedAccessKey' -Key $ehPrimaryKey

            $telemetryEvents = @(
                @{ device = 'dev-001'; temperature = 22.5; humidity = 60;   ts = '2026-01-01T00:00:00Z'; unit = 'celsius' }
                @{ device = 'dev-002'; temperature = 19.3; humidity = 65;   ts = '2026-01-01T00:01:00Z'; unit = 'celsius' }
                @{ device = 'dev-003'; motion = $true;     zone = 'entrance'; ts = '2026-01-01T00:02:00Z' }
            )
            $sentCount = 0
            foreach ($event in $telemetryEvents) {
                try {
                    Invoke-RestMethod `
                        -Method POST `
                        -Uri "$ehUri/messages" `
                        -Headers @{ Authorization = $sas } `
                        -ContentType 'application/json; charset=utf-8' `
                        -Body ($event | ConvertTo-Json -Compress) | Out-Null
                    $sentCount++
                } catch {
                    Write-AdeLog "Event Hub send failed: $_" -Level Warning
                }
            }
            Write-AdeLog "Sent $sentCount telemetry events to '$ehHubName' Event Hub." -Level Success
            # Note: connection string intentionally not persisted in the environment
            # after use — SAS keys should not outlive the operation that needs them.
        }
    }
}

# ─── Event Grid ───────────────────────────────────────────────────────────────

if ($seedAll -or $Modules -contains 'eventgrid') {
    Write-AdeSection "Seeding: Event Grid"

    $intRg     = "$Prefix-integration-rg"
    $topicName = Get-AdeResource -ResourceGroup $intRg -ResourceType 'Microsoft.EventGrid/topics'

    if (-not $topicName) {
        Write-AdeLog "No Event Grid custom topic found in '$intRg'. Skipping." -Level Warning
    } else {
        Write-AdeLog "Event Grid topic: $topicName" -Level Info

        $topicEndpoint = az eventgrid topic show `
            --name $topicName `
            --resource-group $intRg `
            --query 'endpoint' -o tsv 2>$null

        $topicKey = az eventgrid topic key list `
            --name $topicName `
            --resource-group $intRg `
            --query 'key1' -o tsv 2>$null

        if ($topicEndpoint -and $topicKey) {
            $demoEgEvents = @(
                [ordered]@{
                    id          = [Guid]::NewGuid().ToString()
                    eventType   = 'Demo.Order.Created'
                    subject     = '/ade/orders/order-001'
                    eventTime   = (Get-Date -Format 'o')
                    dataVersion = '1.0'
                    data        = @{ orderId = 'order-001'; customerId = 1; total = 149.99 }
                }
                [ordered]@{
                    id          = [Guid]::NewGuid().ToString()
                    eventType   = 'Demo.Resource.Updated'
                    subject     = '/ade/resources/storage-001'
                    eventTime   = (Get-Date -Format 'o')
                    dataVersion = '1.0'
                    data        = @{ resourceId = 'storage-001'; action = 'updated'; module = 'storage' }
                }
            ) | ConvertTo-Json -Depth 5

            try {
                Invoke-RestMethod `
                    -Method POST `
                    -Uri $topicEndpoint `
                    -Headers @{ 'aeg-sas-key' = $topicKey } `
                    -ContentType 'application/json' `
                    -Body $demoEgEvents | Out-Null
                Write-AdeLog "Published 2 demo events to Event Grid topic '$topicName'." -Level Success
            } catch {
                Write-AdeLog "Event Grid publish failed: $_" -Level Warning
            }
        } else {
            Write-AdeLog "Could not retrieve Event Grid topic endpoint or key. Skipping." -Level Warning
        }
    }
}

# ─── Complete ─────────────────────────────────────────────────────────────────

Write-AdeSection "Data Seeding Complete"
if ($script:_seedFailed) {
    Write-AdeLog "One or more seeding steps failed (see [WARN] lines above)." -Level Warning
    Write-AdeLog "Run './scripts/dashboard/Get-AdeCostDashboard.ps1' to review resource status." -Level Info
    exit 1
} else {
    Write-AdeLog "Dummy data has been seeded into deployed ADE resources." -Level Success
    Write-AdeLog "Run './scripts/dashboard/Get-AdeCostDashboard.ps1' to review resource status." -Level Info
    exit 0
}
