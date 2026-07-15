<#
.SYNOPSIS
    Shared utility functions for the Azure Demo Environment (ADE) project.
    Sourced by deploy.ps1, destroy.ps1, and runbooks.
#>

Set-StrictMode -Version Latest

# ─── Logging ─────────────────────────────────────────────────────────────────
# Set this variable to an absolute path to mirror all log output to a file.
$script:AdeLogFile = $null

# Set to $true to enable Debug-level console output (wired to -Verbose in all entry scripts).
$script:AdeVerbose = $false

enum AdeLogLevel {
    Info
    Success
    Warning
    Error
    Step
    Debug
}

function Write-AdeLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [AdeLogLevel]$Level = [AdeLogLevel]::Info,
        [switch]$NoNewline
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'

    $color, $prefix = switch ($Level) {
        ([AdeLogLevel]::Info)    { 'Cyan',    'INFO ' }
        ([AdeLogLevel]::Success) { 'Green',   'OK   ' }
        ([AdeLogLevel]::Warning) { 'Yellow',  'WARN ' }
        ([AdeLogLevel]::Error)   { 'Red',     'ERR  ' }
        ([AdeLogLevel]::Step)    { 'Magenta', 'STEP ' }
        ([AdeLogLevel]::Debug)   { 'Gray',    'DBG  ' }
    }

    # Debug messages are suppressed from the console unless -Verbose was passed.
    # They are always written to the log file when one is configured.
    if ($Level -eq [AdeLogLevel]::Debug -and -not $script:AdeVerbose) {
        if ($script:AdeLogFile) {
            $plain = "[$timestamp] [$prefix] $Message"
            if ($NoNewline) { [System.IO.File]::AppendAllText($script:AdeLogFile, $plain) }
            else             { Add-Content -LiteralPath $script:AdeLogFile -Value $plain }
        }
        return
    }

    $plain = "[$timestamp] [$prefix] $Message"

    if ($NoNewline) {
        Write-Host -NoNewline "[$timestamp] "
        Write-Host -NoNewline "[$prefix] $Message" -ForegroundColor $color
    } else {
        Write-Host -NoNewline "[$timestamp] "
        Write-Host "[$prefix] $Message" -ForegroundColor $color
    }

    if ($script:AdeLogFile) {
        if ($NoNewline) {
            [System.IO.File]::AppendAllText($script:AdeLogFile, $plain)
        } else {
            Add-Content -LiteralPath $script:AdeLogFile -Value $plain
        }
    }
}

function Write-AdeSection {
    param([Parameter(Mandatory)][string]$Title)
    $line = '─' * 60
    Write-Host ""
    Write-Host $line -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkGray
    Write-Host ""

    if ($script:AdeLogFile) {
        Add-Content -LiteralPath $script:AdeLogFile -Value ''
        Add-Content -LiteralPath $script:AdeLogFile -Value $line
        Add-Content -LiteralPath $script:AdeLogFile -Value "  $Title"
        Add-Content -LiteralPath $script:AdeLogFile -Value $line
        Add-Content -LiteralPath $script:AdeLogFile -Value ''
    }
}

# ─── Azure CLI wrapper ────────────────────────────────────────────────────────

function Invoke-AzCmd {
    <#
    .SYNOPSIS
        Executes an az CLI command and returns parsed output.
        Throws a terminating error on non-zero exit code with the stderr message.
    .PARAMETER Arguments
        The az command arguments as a single string (everything after 'az').
        Split on whitespace with NO quote handling — a quoted value like
        --name "my rg" becomes three tokens, not two. Values containing
        quotes therefore throw: use ArgumentList for anything with spaces.
    .PARAMETER ArgumentList
        The az command arguments as a pre-split array. Eliminates whitespace-split
        bugs when template paths, resource group names, or parameter values contain spaces.
    .PARAMETER Silent
        Suppress the command echo.
    #>
    param(
        [string]$Arguments = '',
        [string[]]$ArgumentList,
        [switch]$Silent,
        [switch]$AllowFailure
    )

    # The string form splits on whitespace and cannot honor quoting. Failing loudly
    # here beats the silent alternative: a quoted value like --name "my rg" would
    # otherwise be split into broken tokens and produce an opaque az error.
    if (-not $ArgumentList -and $Arguments -match '["'']') {
        throw ("Invoke-AzCmd -Arguments splits on whitespace and does not honor quotes " +
               "(got: $Arguments). Use -ArgumentList to pass values containing spaces.")
    }

    $cmdArgs    = if ($ArgumentList) { $ArgumentList } else { $Arguments -split '\s+' | Where-Object { $_ } }
    $displayCmd = if ($ArgumentList) { $ArgumentList -join ' ' } else { $Arguments }

    if (-not $Silent) {
        Write-AdeLog "az $displayCmd" -Level Debug
    }

    $output = az $cmdArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $errMsg = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '
        if (-not $errMsg) { $errMsg = $output -join ' ' }
        throw "az command failed (exit $exitCode): az $displayCmd`n$errMsg"
    }

    # Return stdout lines only (filter out ErrorRecord objects)
    $stdout = $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }

    if ($stdout) {
        $joined = $stdout -join "`n"
        try { return $joined | ConvertFrom-Json -Depth 20 }
        catch { return $stdout }
    }
    return $null
}

# ─── Profile loading ──────────────────────────────────────────────────────────

function Get-AdeProfile {
    <#
    .SYNOPSIS
        Loads and returns a deployment profile. Accepts a profile name (e.g. 'full')
        or an absolute/relative path to a custom JSON file.
    #>
    param([Parameter(Mandatory)][string]$ProfileNameOrPath)

    $builtIn = Join-Path -Path $PSScriptRoot -ChildPath '..\..\config\profiles' -AdditionalChildPath "$ProfileNameOrPath.json"

    $profilePath = if (Test-Path $ProfileNameOrPath -PathType Leaf) {
        $ProfileNameOrPath
    } elseif (Test-Path $builtIn -PathType Leaf) {
        $builtIn
    } else {
        throw "Profile '$ProfileNameOrPath' not found. Built-in profiles: full, minimal, compute-only, databases-only, networking-only, security-focus"
    }

    Write-AdeLog "Loading profile: $(Resolve-Path $profilePath)" -Level Info
    $adeProfile = Get-Content $profilePath -Raw | ConvertFrom-Json -Depth 20

    # Inject globalSettings.tags from defaults.json so Build-AdeTags always has data
    $tagsProp = $adeProfile.PSObject.Properties['tags']
    if (-not $tagsProp -or $null -eq $tagsProp.Value) {
        $defaultsPath = Join-Path $PSScriptRoot '..\..\config\defaults.json'
        if (Test-Path $defaultsPath) {
            $defaults = Get-Content $defaultsPath -Raw | ConvertFrom-Json -Depth 20
            $adeProfile | Add-Member -NotePropertyName 'tags' -NotePropertyValue $defaults.globalSettings.tags -Force
        }
    }

    return $adeProfile
}

# ─── Module dependency order ──────────────────────────────────────────────────

function Get-AdeDeploymentOrder {
    <#
    .SYNOPSIS
        Returns the ordered list of modules that are enabled in the given profile.
        Order is fixed to satisfy dependencies:
          monitoring -> networking -> security -> compute -> storage ->
          databases -> appservices -> containers -> governance
    #>
    param([Parameter(Mandatory)][psobject]$Profile)

    $order = @('monitoring', 'networking', 'security', 'compute', 'storage',
               'databases', 'appservices', 'containers', 'integration', 'ai', 'data', 'governance')

    $enabled = [System.Collections.Generic.List[string]]::new()
    foreach ($module in $order) {
        if (-not $Profile.modules.PSObject.Properties[$module]) { continue }
        $moduleConfig = $Profile.modules.$module
        if ($moduleConfig -and $moduleConfig.enabled -eq $true) {
            $enabled.Add($module)
        }
    }
    return $enabled
}

# ─── Resource group helpers ───────────────────────────────────────────────────

function New-AdeResourceGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][hashtable]$Tags
    )

    # Build tag list, filtering out null/empty values
    $tagArgs = @($Tags.GetEnumerator() |
        Where-Object { $null -ne $_.Value -and $_.Value -ne '' } |
        ForEach-Object { "$($_.Key)=$($_.Value)" })

    Write-AdeLog "Ensuring resource group: $Name" -Level Info

    # In WhatIf mode do not create or modify any real infrastructure.
    if ([bool]$WhatIfPreference) {
        Write-AdeLog "What if: would ensure resource group '$Name' in '$Location'" -Level Info
        return
    }

    # Check whether the RG already exists so we can detect a location conflict
    # before `az group create` emits an opaque API error.
    $existing = az group show --name $Name --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing) {
        $existingLocation = ($existing | ConvertFrom-Json).location
        if ($existingLocation -ne $Location) {
            # deploy.ps1 auto-detects and corrects $Location before reaching here.
            # This warning fires only if New-AdeResourceGroup is called directly
            # with a mismatched location (e.g. from a custom script).
            Write-AdeLog "Resource group '$Name' exists in '$existingLocation'; ignoring requested location '$Location' and reusing '$existingLocation'." -Level Warning
            $Location = $existingLocation
        }
        Write-AdeLog "Resource group already exists: $Name ($existingLocation)" -Level Info
        # Update tags on the existing RG without touching its location.
        az group update --name $Name --tags @tagArgs --output none
        if ($LASTEXITCODE -ne 0) {
            Write-AdeLog "Could not update tags on $Name (non-fatal)." -Level Warning
        }
        return
    }

    az group create `
        --name $Name `
        --location $Location `
        --tags @tagArgs `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group: $Name"
    }
    Write-AdeLog "Resource group ready: $Name" -Level Success
}

function Remove-AdeResourceGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$NoWait
    )

    # Remove any resource locks first so deletion doesn't fail
    $locks = az lock list --resource-group $Name --query "[].id" -o tsv 2>$null
    foreach ($lockId in $locks) {
        if ($lockId -and $PSCmdlet.ShouldProcess($lockId, 'Remove resource lock')) {
            Write-AdeLog "Removing lock: $lockId" -Level Warning
            az lock delete --ids $lockId --output none
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Delete resource group')) { return }
    Write-AdeLog "Deleting resource group: $Name" -Level Warning
    if ($NoWait) { az group delete --name $Name --yes --no-wait --output none }
    else         { az group delete --name $Name --yes --output none }

    if ($LASTEXITCODE -ne 0) {
        throw "az group delete failed for '$Name' (exit $LASTEXITCODE). The resource group may still exist."
    }
}

# ─── Bicep deployment helpers ─────────────────────────────────────────────────

function Invoke-AdeBicepDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    <#
    .SYNOPSIS
        Deploys a Bicep module to a specific resource group. Returns the outputs object.
        Streams per-resource progress to the console while the deployment runs.
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$DeploymentName,
        [hashtable]$Parameters = @{},
        [int]$PollIntervalSeconds = 5
    )

    if (-not (Test-Path $TemplatePath)) {
        throw "Bicep template not found: $TemplatePath"
    }

    # Build parameter arguments.
    # Scalars stay inline as 'key=value'. Complex values (hashtables, arrays, psobjects)
    # are written to a temp ARM-format parameters file and referenced as '@file' to avoid
    # Windows command-line double-quote stripping when JSON is embedded in an argument string.
    $paramArgs = @()
    $tempParamsFile = $null
    $fileParams = @{}

    foreach ($key in $Parameters.Keys) {
        $val = $Parameters[$key]
        if ($val -is [hashtable] -or $val -is [System.Collections.Hashtable] -or
            $val -is [pscustomobject] -or
            $val -is [array] -or $val -is [System.Collections.ArrayList]) {
            $fileParams[$key] = @{ value = $val }
        } elseif ($val -is [string] -and (
                $key -match '(?i)password|secret|apikey|accesskey' -or
                $val -match '[&|<>^"''`$!#%]')) {
            # Route credential parameters (key-name match) and strings containing
            # shell-unsafe characters through the JSON file.  This prevents plaintext
            # secrets from appearing in the debug log or being misinterpreted by the
            # shell (e.g. & splits commands, $ expands variables).
            $fileParams[$key] = @{ value = $val }
        } else {
            $paramArgs += "$key=$val"
        }
    }

    if ($fileParams.Count -gt 0) {
        $tempParamsFile = New-AdeTempJsonPath -Prefix 'ade' -Purpose 'parameters'
        $json = $fileParams | ConvertTo-Json -Depth 20
        # Use .NET WriteAllText rather than Set-Content so the write is not skipped
        # when $WhatIfPreference is active (Set-Content honours ShouldProcess).
        [System.IO.File]::WriteAllText($tempParamsFile, $json, [System.Text.UTF8Encoding]::new($false))
        $paramArgs = @("@$tempParamsFile") + $paramArgs
    }

    try {

    # What-if: run synchronously and return immediately
    if ([bool]$WhatIfPreference) {
        # az deployment group what-if requires the RG to exist. In WhatIf mode
        # New-AdeResourceGroup skips creation, so the RG may not be present.
        # Fall back to a descriptive log message in that case.
        $null = Invoke-AzCmd -ArgumentList @('group', 'show', '--name', $ResourceGroup, '--output', 'none') -AllowFailure -Silent
        if ($LASTEXITCODE -ne 0) {
            Write-AdeLog "What if: would deploy '$([System.IO.Path]::GetFileName($TemplatePath))' to '$ResourceGroup' (resource group does not exist yet — would be created first)" -Level Info
            return $null
        }
        $argList = @(
            'deployment', 'group', 'what-if',
            '--resource-group', $ResourceGroup,
            '--name',           $DeploymentName,
            '--template-file',  $TemplatePath,
            '--output',         'table'
        )
        if ($paramArgs.Count -gt 0) { $argList += '--parameters'; $argList += $paramArgs }
        Invoke-AzCmd -ArgumentList $argList
        return $null
    }

    # Snapshot resources already in the RG before deployment so we can distinguish
    # newly created resources from those that were already present (updated/no-op).
    $preDeployNames = @{}
    $preList = Invoke-AzCmd -ArgumentList @(
        'resource', 'list',
        '--resource-group', $ResourceGroup,
        '--query', '[].{name:name,type:type}',
        '--output', 'json'
    ) -Silent -AllowFailure
    if ($preList) {
        foreach ($r in @($preList)) { $preDeployNames["$($r.type)/$($r.name)"] = $true }
    }

    # Submit deployment asynchronously so we can stream per-resource progress
    $argList = @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroup,
        '--name',           $DeploymentName,
        '--template-file',  $TemplatePath,
        '--output',         'none',
        '--no-wait'
    )
    if ($paramArgs.Count -gt 0) { $argList += '--parameters'; $argList += $paramArgs }
    $null = Invoke-AzCmd -ArgumentList $argList

    # Stream per-resource progress by polling deployment operations via Invoke-AzCmd
    # so unit tests can mock all az calls through a single seam.
    $seenOps        = @{}
    $loggedViaOps   = @{}   # type/name keys logged during polling; post-deploy skips duplicates
    $hasNewViaOps   = $false
    $showableOps    = @('Create', 'Delete', 'Deploy')
    $terminalStates = @('Succeeded', 'Failed', 'Canceled')
    $depState       = 'Running'
    $showResult     = $null
    $pollStart      = [DateTime]::UtcNow
    $maxPollSeconds = 5400  # 90 min — the deploy job timeout-minutes: 120 is the hard cap

    do {
        # Back off as the deployment ages: 1x interval for the first 2 minutes,
        # 3x until 10 minutes, then 6x (default 5s -> 15s -> 30s). Long-running
        # modules (AKS, APIM, gateways) otherwise generate thousands of ARM
        # reads over a full deploy and risk 429 throttling. An explicit 0
        # (unit tests) always stays 0.
        $pollElapsed = ([DateTime]::UtcNow - $pollStart).TotalSeconds
        $pollBackoff = if ($pollElapsed -gt 600) { 6 } elseif ($pollElapsed -gt 120) { 3 } else { 1 }
        Start-Sleep -Seconds ($PollIntervalSeconds * $pollBackoff)
        if (([DateTime]::UtcNow - $pollStart).TotalSeconds -gt $maxPollSeconds) {
            throw "Deployment '$DeploymentName' timed out after $([int]($maxPollSeconds / 60)) minutes of polling. The deployment may still be running in Azure — check the portal."
        }

        $ops = Invoke-AzCmd -ArgumentList @(
            'deployment', 'group', 'operation', 'list',
            '--resource-group', $ResourceGroup,
            '--name',           $DeploymentName,
            '--output',         'json'
        ) -Silent -AllowFailure

        if ($ops) {
            foreach ($op in $ops) {
                $opId    = $op.operationId
                $state   = $op.properties.provisioningState
                $opType  = $op.properties.provisioningOperation
                $resName = $op.properties.targetResource.resourceName
                $resType = ($op.properties.targetResource.resourceType -split '/')[-1]

                # Only show meaningful resource operations, skip ARM internals
                if ($opType -notin $showableOps -or -not $resName) { continue }

                if (-not $seenOps.ContainsKey($opId)) {
                    $seenOps[$opId] = $state
                } elseif ($seenOps[$opId] -ne $state) {
                    $seenOps[$opId] = $state
                } else {
                    continue  # state unchanged — nothing to do
                }

                # Log on terminal state transition (real-time, with correct timestamp)
                $resKey = "$($op.properties.targetResource.resourceType)/$resName"
                if ($state -eq 'Succeeded') {
                    $isNew    = -not $preDeployNames.ContainsKey($resKey)
                    $label    = if ($isNew) { '[new]' } else { '[existing]' }
                    $logLevel = if ($isNew) { 'Success' } else { 'Info' }
                    Write-AdeLog "  $resType '$resName' $label" -Level $logLevel
                    $loggedViaOps[$resKey] = $true
                    if ($isNew) { $hasNewViaOps = $true }
                } elseif ($state -in @('Failed', 'Canceled')) {
                    Write-AdeLog "  $resType '$resName' — $state" -Level Error
                }
            }
        }

        $showResult = Invoke-AzCmd -ArgumentList @(
            'deployment', 'group', 'show',
            '--resource-group', $ResourceGroup,
            '--name',           $DeploymentName,
            '--output',         'json'
        ) -Silent -AllowFailure

        if ($showResult -and $showResult.properties) {
            $depState = $showResult.properties.provisioningState
        }

    } while ($depState -notin $terminalStates)

    if ($depState -ne 'Succeeded') {
        $errMsg = if ($showResult -and $showResult.properties.error) {
            $err = $showResult.properties.error
            # Prefer the inner details messages — they contain the actual failure reason
            # (e.g. VaultAlreadyExists). Fall back to the outer message if no details exist.
            $detailMsgs = @($err.details | Where-Object { $_.message } | ForEach-Object { "$($_.code): $($_.message)" })

            # If all detail messages are the generic ResourceDeploymentFailure wrapper,
            # the real reason is one level deeper in the deployment operations.
            $nonGenericDetails = @($detailMsgs | Where-Object { $_ -notmatch '^ResourceDeploymentFailure' })
            $allGeneric = $detailMsgs.Count -gt 0 -and $nonGenericDetails.Count -eq 0
            if ($allGeneric -or $detailMsgs.Count -eq 0) {
                $ops = Invoke-AzCmd -ArgumentList @(
                    'deployment', 'operation', 'group', 'list',
                    '--resource-group', $ResourceGroup,
                    '--name',           $DeploymentName,
                    '--output',         'json'
                ) -Silent -AllowFailure
                $opMsgs = @()
                if ($ops) {
                    $opMsgs = @($ops | Where-Object {
                        $_.properties.provisioningState -eq 'Failed' -and
                        $_.properties.statusMessage.error.message
                    } | ForEach-Object {
                        $opErr = $_.properties.statusMessage.error
                        "$($opErr.code): $($opErr.message)"
                    })
                }
                if ($opMsgs.Count -gt 0) { $opMsgs -join ' | ' }
                elseif ($detailMsgs.Count -gt 0) { $detailMsgs -join ' | ' }
                else { $err.message }
            } else {
                $detailMsgs -join ' | '
            }
        } else { $depState }
        throw "Deployment '$DeploymentName' $depState`: $errMsg"
    }

    # Post-deployment resource summary — diff against pre-deploy snapshot.
    $newResources      = @()
    $existingResources = @()
    $deployedList = Invoke-AzCmd -ArgumentList @(
        'resource', 'list',
        '--resource-group', $ResourceGroup,
        '--query', '[].{name:name,type:type}',
        '--output', 'json'
    ) -Silent -AllowFailure
    if ($deployedList) {
        foreach ($r in @($deployedList)) {
            $shortType = ($r.type -split '/')[-1]
            $key = "$($r.type)/$($r.name)"
            if ($loggedViaOps.ContainsKey($key)) { continue }  # already logged during polling
            if ($preDeployNames.ContainsKey($key)) {
                $existingResources += "  $shortType '$($r.name)'"
            } else {
                $newResources += "  $shortType '$($r.name)'"
            }
        }
        foreach ($line in $newResources)      { Write-AdeLog "$line [new]"      -Level Success }
        foreach ($line in $existingResources) { Write-AdeLog "$line [existing]" -Level Info }
    }

    if ($showResult -and $showResult.properties) {
        return [pscustomobject]@{
            Outputs         = $showResult.properties.outputs
            HasNewResources = ($newResources.Count -gt 0 -or $hasNewViaOps)
        }
    }
    return $null

    } finally {
        if ($tempParamsFile -and (Test-Path $tempParamsFile)) {
            Remove-Item -LiteralPath $tempParamsFile -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
}

# ─── Tag builder ──────────────────────────────────────────────────────────────

function Build-AdeTags {
    param(
        [Parameter(Mandatory)][psobject]$Profile,
        [string]$Module = ''
    )

    $tags = @{
        project     = $Profile.tags.project
        purpose     = $Profile.tags.purpose
        environment = $Profile.tags.environment
        managedBy   = $Profile.tags.managedBy
        deployedAt  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        profile     = $Profile.profileName
    }
    if ($Module) { $tags['module'] = $Module }
    return $tags
}

# ─── Output helpers ───────────────────────────────────────────────────────────

function Get-AdeDeploymentOutput {
    <#
    .SYNOPSIS
        Safely retrieves a named output value from a deployment outputs object.
    #>
    param(
        [psobject]$Outputs,
        [Parameter(Mandatory)][string]$Key
    )

    if ($null -eq $Outputs) { return '' }
    $prop = $Outputs.PSObject.Properties[$Key]
    if ($null -eq $prop) { return '' }
    $val = $prop.Value
    if ($null -eq $val) { return '' }
    return $val.value
}

# ─── Temporary files ──────────────────────────────────────────────────────────

function New-AdeTempJsonPath {
    <#
    .SYNOPSIS
        Returns a unique JSON temp-file path without creating the file.

    .DESCRIPTION
        [System.IO.Path]::GetTempFileName() creates a file immediately. Appending
        ".json" to that path leaves the original temp file orphaned. This helper
        only builds a path, so callers create and clean up exactly one file.
    #>
    param(
        [string]$Prefix = 'ade',
        [string]$Purpose = 'tmp'
    )

    $safePrefix  = if ($Prefix)  { $Prefix  -replace '[^A-Za-z0-9._-]', '-' } else { 'ade' }
    $safePurpose = if ($Purpose) { $Purpose -replace '[^A-Za-z0-9._-]', '-' } else { 'tmp' }
    $fileName = '{0}-{1}.{2}.json' -f $safePrefix, ([System.Guid]::NewGuid().ToString('N')), $safePurpose
    return [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), $fileName)
}

# ─── Destructive action confirmation ─────────────────────────────────────────

function Confirm-AdeDestructiveAction {
    <#
    .SYNOPSIS
        Asks the user to confirm an irreversible action (delete / purge) that a
        deployment needs to perform as a pre-flight workaround.

    .DESCRIPTION
        Deployments should never delete resources silently. This gate prompts
        interactively and defaults to No. Under -Force or CI (no interactive
        console) it auto-approves — matching the existing non-interactive
        behavior — but still logs a warning so the action is visible in the log.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [switch]$Force
    )

    if ($Force -or [bool]$env:CI -or [bool]$env:GITHUB_ACTIONS) {
        Write-AdeLog "$Action — auto-approved (-Force / CI)." -Level Warning
        return $true
    }

    Write-Host ""
    $answer = Read-Host "  $Action. Proceed? [y/N]"
    return $answer -match '^[Yy]$'
}

# ─── Deployer public IP ───────────────────────────────────────────────────────

function Get-AdeDeployerPublicIp {
    <#
    .SYNOPSIS
        Best-effort detection of the deployer's public IPv4 address.

    .DESCRIPTION
        Used to scope the SQL Server firewall rule to the machine running the
        deployment (workstation or CI runner) instead of opening 0.0.0.0/0.
        Tries several well-known echo services; returns $null when none respond
        or the response is not a valid IPv4 address. Callers must treat $null
        as "no deployer rule" and warn accordingly.
    #>
    param()

    $services = @(
        'https://api.ipify.org',
        'https://ifconfig.me/ip',
        'https://icanhazip.com'
    )
    foreach ($svc in $services) {
        try {
            Write-AdeLog "Detecting deployer public IP via $svc" -Level Debug
            $ip = (Invoke-RestMethod -Uri $svc -TimeoutSec 10).ToString().Trim()
            # Accept IPv4 only — SQL firewall rules do not support IPv6.
            if ($ip -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$' -and
                -not (($ip -split '\.') | Where-Object { [int]$_ -gt 255 })) {
                return $ip
            }
            Write-AdeLog "  ✗ $svc returned '$ip' (not a valid IPv4 address)" -Level Debug
        } catch {
            Write-AdeLog "  ✗ $svc unreachable: $($_.Exception.Message)" -Level Debug
        }
    }
    return $null
}

# ─── Password generation ─────────────────────────────────────────────────────

function New-AdePassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random password as a SecureString.

    .DESCRIPTION
        Guarantees at least two characters from each class (upper, lower, digit,
        symbol) using ambiguity-free character sets, fills the remainder from the
        union of all classes, and shuffles with Fisher-Yates — all driven by a
        crypto RNG. Meets Azure VM / SQL / PostgreSQL / MySQL complexity rules.
        The plaintext is discarded immediately after SecureString conversion.
    #>
    [OutputType([securestring])]
    param(
        [ValidateRange(12, 128)]
        [int]$Length = 16
    )

    # Ambiguity-free sets: no I/l/1/O/0 look-alikes (passwords may be hand-typed)
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghjkmnpqrstuvwxyz'
    $digits  = '23456789'
    $symbols = '!@#$%^&*'
    $all     = $upper + $lower + $digits + $symbols

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # First $Length bytes pick characters, second $Length bytes drive the shuffle.
        $bytes = [byte[]]::new($Length * 2)
        $rng.GetBytes($bytes)

        $pwChars = [System.Collections.Generic.List[char]]::new()
        # Two guaranteed characters per class (Azure complexity with headroom)
        $pwChars.Add($upper[$bytes[0]   % $upper.Length])
        $pwChars.Add($upper[$bytes[1]   % $upper.Length])
        $pwChars.Add($lower[$bytes[2]   % $lower.Length])
        $pwChars.Add($lower[$bytes[3]   % $lower.Length])
        $pwChars.Add($digits[$bytes[4]  % $digits.Length])
        $pwChars.Add($digits[$bytes[5]  % $digits.Length])
        $pwChars.Add($symbols[$bytes[6] % $symbols.Length])
        $pwChars.Add($symbols[$bytes[7] % $symbols.Length])
        for ($i = 8; $i -lt $Length; $i++) {
            $pwChars.Add($all[$bytes[$i] % $all.Length])
        }

        # Fisher-Yates shuffle using the second half of the crypto bytes
        for ($i = $pwChars.Count - 1; $i -gt 0; $i--) {
            $j = $bytes[$Length + ($i % $Length)] % ($i + 1)
            $tmp = $pwChars[$i]; $pwChars[$i] = $pwChars[$j]; $pwChars[$j] = $tmp
        }

        $plain  = -join $pwChars
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
        $plain  = $null   # discard plaintext from memory
        return $secure
    } finally {
        $rng.Dispose()
    }
}

# ─── Key Vault secrets ────────────────────────────────────────────────────────

function Get-AdeKeyVaultSecret {
    <#
    .SYNOPSIS
        Reads a Key Vault secret value (data plane) as a SecureString.

    .DESCRIPTION
        Return contract — callers depend on the distinction:
          SecureString  the secret exists and was read
          $null         the secret cleanly does NOT exist (SecretNotFound)
          throws        any other failure (Forbidden, firewall, network) after
                        MaxAttempts — so "unreadable" is never mistaken for
                        "absent", which would silently rotate a password that
                        is still in use on deployed resources.
        Retries cover RBAC role-assignment propagation delay after a deploy.
    #>
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$SecretName,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    $retryDelays = @(0, 5, 15)   # seconds to wait before attempt 1, 2, 3+
    $lastError   = ''

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $delay = $retryDelays[[Math]::Min($attempt - 1, $retryDelays.Count - 1)]
        if ($delay -gt 0) {
            Write-AdeLog "  retrying secret read in ${delay}s (RBAC propagation)..." -Level Debug
            Start-Sleep -Seconds $delay
        }

        Write-AdeLog "az keyvault secret show --vault-name $VaultName --name $SecretName (attempt $attempt/$MaxAttempts)" -Level Debug
        $output = az keyvault secret show --vault-name $VaultName --name $SecretName --query value -o tsv 2>&1

        if ($LASTEXITCODE -eq 0) {
            $value = (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join '').Trim()
            if ($value) { return (ConvertTo-SecureString $value -AsPlainText -Force) }
            Write-AdeLog "Secret '$SecretName' in vault '$VaultName' has an empty value — treating as absent." -Level Debug
            return $null
        }

        $errText = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' ')
        if (-not $errText) { $errText = @($output) -join ' ' }
        if ($errText -match 'SecretNotFound') {
            Write-AdeLog "Secret '$SecretName' not found in vault '$VaultName'." -Level Debug
            return $null
        }
        $lastError = $errText
        Write-AdeLog "  ✗ secret read attempt $attempt failed: $errText" -Level Debug
    }

    throw ("Could not read secret '$SecretName' from Key Vault '$VaultName' after $MaxAttempts attempts: $lastError. " +
           "The secret exists (or its existence could not be ruled out) but its value is unreadable — refusing to " +
           "generate a replacement so passwords already in use are not silently rotated.")
}

function Get-AdeKeyVaultSecretNames {
    <#
    .SYNOPSIS
        Lists secret names in a Key Vault via the ARM control plane.

    .DESCRIPTION
        Uses the management endpoint (az rest) instead of the data plane, so it
        works even when the vault firewall blocks the caller (hardened mode with
        publicNetworkAccess Disabled) and requires no data-plane RBAC — Reader
        on the resource group suffices. Follows nextLink pagination.
        Returns @() when the list cannot be retrieved; callers must treat that
        as "existence unknown", not "no secrets".
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$VaultName
    )

    $names = [System.Collections.Generic.List[string]]::new()
    $url   = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
             "/providers/Microsoft.KeyVault/vaults/$VaultName/secrets?api-version=2023-07-01"

    while ($url) {
        Write-AdeLog "az rest --method GET --url $url" -Level Debug
        $raw = az rest --method GET --url $url 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
        try {
            $parsed = (@($raw) -join "`n") | ConvertFrom-Json -ErrorAction Stop
            foreach ($item in @($parsed.value)) {
                if ($item -and $item.name) { $names.Add($item.name) }
            }
            $nextProp = $parsed.PSObject.Properties['nextLink']
            $url = if ($nextProp -and $nextProp.Value) { $nextProp.Value } else { $null }
        } catch {
            return @()
        }
    }
    return $names.ToArray()
}

# ─── Feature flag accessor ───────────────────────────────────────────────────

function Get-AdeObjectPropertyValue {
    <#
    .SYNOPSIS
        Safely reads a named property from either a PSCustomObject or hashtable.
    #>
    param(
        [object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }

    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-AdeModuleFeatures {
    <#
    .SYNOPSIS
        Safely retrieves the features object for a module from a deployment profile.

    .DESCRIPTION
        Centralizes the repeated StrictMode-safe profile traversal used by deploy
        and validation code. Returns an empty object when the module or features
        block is absent so callers can use Get-FeatureFlag directly.
    #>
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string]$ModuleName
    )

    $empty = [pscustomobject]@{}
    $modules = Get-AdeObjectPropertyValue -InputObject $Profile -Name 'modules'
    if ($null -eq $modules) { return $empty }

    $moduleConfig = Get-AdeObjectPropertyValue -InputObject $modules -Name $ModuleName
    if ($null -eq $moduleConfig) { return $empty }

    $features = Get-AdeObjectPropertyValue -InputObject $moduleConfig -Name 'features'
    if ($null -eq $features) { return $empty }

    return $features
}

function Get-FeatureFlag {
    <#
    .SYNOPSIS
        Safe feature flag accessor — works under Set-StrictMode -Version Latest.
        Returns $Default when the property doesn't exist on the object (avoids PropertyNotFoundException).
        Supports PSCustomObject and hashtable-backed feature objects.
    #>
    param(
        [object]$Features,
        [string]$Name,
        $Default = $false
    )

    $value = Get-AdeObjectPropertyValue -InputObject $Features -Name $Name
    if ($null -eq $value) { return $Default }
    return $value
}

Write-AdeLog "common.ps1 loaded" -Level Debug
