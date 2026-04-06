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

    # Write the timestamp in default terminal color so it is always visible
    # regardless of the user's color scheme (cyan on cyan, etc.).
    # The level bracket + message get the semantic color.
    if ($NoNewline) {
        Write-Host -NoNewline "[$timestamp] "
        Write-Host -NoNewline "[$prefix] $Message" -ForegroundColor $color
    } else {
        Write-Host -NoNewline "[$timestamp] "
        Write-Host "[$prefix] $Message" -ForegroundColor $color
    }

    if ($script:AdeLogFile) {
        $plain = "[$timestamp] [$prefix] $Message"
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
        Prefer ArgumentList when paths or values may contain spaces.
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
        if ($lockId) {
            Write-AdeLog "Removing lock: $lockId" -Level Warning
            az lock delete --ids $lockId --output none
        }
    }

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

    # Build the parameter arguments
    $paramArgs = @()
    foreach ($key in $Parameters.Keys) {
        $val = $Parameters[$key]
        if ($val -is [hashtable] -or $val -is [System.Collections.Hashtable] -or $val -is [pscustomobject]) {
            $jsonVal = $val | ConvertTo-Json -Compress -Depth 10
            $paramArgs += "$key=$jsonVal"
        } elseif ($val -is [array] -or $val -is [System.Collections.ArrayList]) {
            $jsonVal = $val | ConvertTo-Json -Compress -Depth 10
            $paramArgs += "$key=$jsonVal"
        } else {
            $paramArgs += "$key=$val"
        }
    }

    # What-if: run synchronously and return immediately
    if ([bool]$WhatIfPreference) {
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
    $showableOps    = @('Create', 'Delete', 'Deploy')
    $terminalStates = @('Succeeded', 'Failed', 'Canceled')
    $depState       = 'Running'
    $showResult     = $null
    $pollStart      = [DateTime]::UtcNow
    $maxPollSeconds = 5400  # 90 min — the deploy job timeout-minutes: 120 is the hard cap

    do {
        Start-Sleep -Seconds $PollIntervalSeconds
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
                    if ($state -ne 'Waiting') {
                        Write-AdeLog "  $resType '$resName'" -Level Info
                    }
                } elseif ($seenOps[$opId] -ne $state) {
                    $seenOps[$opId] = $state
                    if ($state -in @('Failed', 'Canceled')) {
                        Write-AdeLog "  $resType '$resName' — $state" -Level Error
                    }
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
            if ($detailMsgs.Count -gt 0) { $detailMsgs -join ' | ' } else { $err.message }
        } else { $depState }
        throw "Deployment '$DeploymentName' $depState`: $errMsg"
    }

    # Post-deployment resource summary — diff against pre-deploy snapshot.
    $deployedList = Invoke-AzCmd -ArgumentList @(
        'resource', 'list',
        '--resource-group', $ResourceGroup,
        '--query', '[].{name:name,type:type}',
        '--output', 'json'
    ) -Silent -AllowFailure
    if ($deployedList) {
        $newResources      = @()
        $existingResources = @()
        foreach ($r in @($deployedList)) {
            $shortType = ($r.type -split '/')[-1]
            $key = "$($r.type)/$($r.name)"
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
        return $showResult.properties.outputs
    }
    return $null
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

# ─── Feature flag accessor ───────────────────────────────────────────────────

function Get-FeatureFlag {
    <#
    .SYNOPSIS
        Safe feature flag accessor — works under Set-StrictMode -Version Latest.
        Returns $Default when the property doesn't exist on the object (avoids PropertyNotFoundException).
    #>
    param(
        [object]$Features,
        [string]$Name,
        $Default = $false
    )
    if ($null -eq $Features) { return $Default }
    $prop = $Features.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

Write-AdeLog "common.ps1 loaded" -Level Debug
