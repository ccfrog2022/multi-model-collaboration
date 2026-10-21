# Collab.Tools.ps1 - tool registry, executable resolution, argv construction and
# the (coordinator-controlled) preference chain.
#
# Calls use explicit argv arrays. Collab.Process selects the Windows native
# runner or the macOS platform helper for the current operating system.

Set-StrictMode -Version 2.0

$script:CollabPromptMarkers = [ordered]@{
    no_delegation = '(?i)no[ -]?(re)?delegation|不得(自行)?转派|must not delegate'
    no_commit     = '(?i)no\s+git\s+commit|不得(自行)?\s*git\s*commit|do not commit'
}

function Get-CollabPromptMarkerSpec {
    [CmdletBinding()]
    param()
    return $script:CollabPromptMarkers
}

function Get-CollabToolRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolConfigFile)

    if (-not (Test-Path -LiteralPath $ToolConfigFile -PathType Leaf)) {
        return @{ Ok = $false; Code = 'tools_config_missing'; Reasons = @("Tool registry not found: $ToolConfigFile") }
    }
    $read = Read-CollabJson -Path $ToolConfigFile
    if (-not $read.Ok) { return $read }
    $registry = $read.Value
    if ($null -eq $registry -or $null -eq $registry.tools) {
        return @{ Ok = $false; Code = 'tools_config_invalid'; Reasons = @('Tool registry has no "tools" array') }
    }
    $ids=@()
    foreach ($entry in @($registry.tools)) {
        if ($entry.id -cnotmatch '^[a-z][a-z0-9_-]{0,63}$' -or $entry.id -in $ids) {
            return @{Ok=$false;Code='tools_config_invalid';Reasons=@('Tool IDs must be unique lowercase names')}
        }
        $ids+=$entry.id
        if ($entry.kind -notin @('json','claude','zcode','codex','grok')) {
            return @{Ok=$false;Code='tools_config_invalid';Reasons=@('Additional tools use the json adapter contract')}
        }
    }
    return @{ Ok = $true; Code = 'ok'; Registry = $registry; Path = $ToolConfigFile }
}

function Get-CollabToolEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$Tool
    )
    foreach ($entry in $Registry.tools) {
        if ($entry.id -eq $Tool) { return $entry }
    }
    return $null
}

function Get-CollabToolPreferenceChain {
    <#
      Ordered fallback chain for a role. This is informational: the runner never
      switches tools on its own. The coordinator reads this chain, and performs
      handoff explicitly (quota exhausted) or after an explicit bounded retry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registry,
        [string]$Role = 'executor'
    )
    $order = @()
    if ($null -ne $Registry.preferenceOrder) { $order = @($Registry.preferenceOrder) }
    $order += @($Registry.tools | Where-Object {$_.id -notin $order} | ForEach-Object {$_.id})
    $chain = foreach ($toolId in $order) {
        $entry = Get-CollabToolEntry -Registry $Registry -Tool $toolId
        $skip = $null
        if ($null -eq $entry) { $skip = 'not_registered' }
        elseif (-not $entry.enabled) { $skip = 'disabled' }
        elseif ($entry.allowedRoles -and ($Role -notin @($entry.allowedRoles))) { $skip = "role_not_allowed:$Role" }
        elseif ($entry.readiness -ne 'ready') { $skip = "readiness:$($entry.readiness)" }
        [ordered]@{
            tool       = $toolId
            label      = if ($null -ne $entry) { $entry.label } else { $toolId }
            readiness  = if ($null -ne $entry) { $entry.readiness } else { 'unknown' }
            selectable = ($null -eq $skip)
            skipReason = $skip
        }
    }
    return @($chain)
}

function Get-CollabToolProbeCache {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)
    $read = Read-CollabJson -Path (Join-Path $DataRoot 'tool-probes.json')
    if (-not $read.Ok -or $null -eq $read.Value) { return @{} }
    $map = @{}
    if ($null -ne $read.Value.probes) {
        foreach ($property in $read.Value.probes.PSObject.Properties) {
            $map[$property.Name] = $property.Value
        }
    }
    return $map
}

function Set-CollabToolProbeCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)]$Probe
    )
    $map = Get-CollabToolProbeCache -DataRoot $DataRoot
    $map[$Tool] = $Probe
    Write-CollabJsonAtomic -Path (Join-Path $DataRoot 'tool-probes.json') -Object ([ordered]@{
            schemaVersion = 1
            updatedAtUtc  = (Format-CollabTime -Time (Get-CollabUtcNow))
            probes        = $map
        })
    return $map[$Tool]
}

function Compare-CollabVersionString {
    <# Zero-padded numeric sort key for directory names such as 0.158.0-alpha.2.1,
       so that a plain string comparison orders versions correctly. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    $numeric = ($Value -split '-')[0]
    $parts = @($numeric -split '\.' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
    while ($parts.Count -lt 4) { $parts += 0 }
    return (($parts[0..3] | ForEach-Object { ([int]$_).ToString('0000') }) -join '.')
}

function Resolve-CollabToolExecutable {
    <#
      Resolves the executable for a tool entry. "fixed" paths are checked for
      existence; "discover-version-dir" requires a fresh compatibility probe of the
      actual binary; installation directory names are opaque identifiers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$DataRoot
    )
    $mode = 'fixed'
    if ($null -ne $Entry.resolve -and $null -ne $Entry.resolve.mode) { $mode = $Entry.resolve.mode }

    if ($mode -eq 'fixed') {
        $exe = $Entry.executable
        if ([string]::IsNullOrWhiteSpace($exe)) {
            return @{ Ok = $false; Code = 'tool_exe_unset'; Reasons = @("Tool '$($Entry.id)' has no executable configured") }
        }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            $command = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command -and $command.Source) {
                return @{ Ok = $true; Code = 'ok'; ExePath = $command.Source; Discovered = $false; Version = $null }
            }
            return @{ Ok = $false; Code = 'tool_exe_missing'; Reasons = @("Executable not found for tool '$($Entry.id)': $exe") }
        }
        return @{ Ok = $true; Code = 'ok'; ExePath = $exe; Discovered = $false; Version = $null }
    }

    if ($mode -eq 'discover-version-dir') {
        $root = $Entry.resolve.root
        $pattern = $Entry.resolve.pattern
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            return @{ Ok = $false; Code = 'tool_root_missing'; Reasons = @("Version root not found for tool '$($Entry.id)': $root") }
        }
        if ([string]::IsNullOrWhiteSpace($pattern)) { $pattern = if ($IsWindows) {'*/codex.exe'} else {'*/codex'} }
        # Installation directory names are opaque hashes, not versions. Select
        # only an installed binary bound to a fresh version + exec-help probe.
        $cache = Get-CollabToolProbeCache -DataRoot $DataRoot
        if (-not $cache.ContainsKey($Entry.id)) {
            return @{ Ok = $false; Code = 'tool_version_unverified'; Reasons = @('Run Update-CollabToolCompatibilityProbe for installed candidates before dispatch') }
        }
        $probe = $cache[$Entry.id]
        try {
            $age = ((Get-CollabUtcNow) - ([datetime]::Parse($probe.atUtc).ToUniversalTime())).TotalDays
            $maxDays = 7
            if ($null -ne $Entry.resolve.PSObject.Properties['probeMaxAgeDays']) { $maxDays = [double]$Entry.resolve.probeMaxAgeDays }
            if ($age -lt 0 -or $age -gt $maxDays) { throw 'compatibility probe expired or future-dated' }
            $installed = @(Get-ChildItem -LiteralPath $root -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter (Split-Path -Leaf $pattern) -File })
            if ($probe.exePath -notin @($installed.FullName)) { throw 'cached executable is no longer installed under the configured root' }
            if (-not $probe.versionOk -or -not $probe.helpOk) { throw 'version or required exec help was not verified' }
            if ($null -ne $probe.PSObject.Properties['compatible'] -and -not $probe.compatible) { throw 'candidate was marked incompatible' }
            $probeHash = if ($null -ne $probe.PSObject.Properties['sha256']) { $probe.sha256 } else { $probe.exeSha256 }
            if ($probeHash -ne (Get-CollabSha256 $probe.exePath)) { throw 'cached executable hash changed' }
            $required = [string]$Entry.resolve.requireVersionContains
            if ($required -and $probe.version -notlike "*$required*") { throw 'actual version does not match the configured requirement' }
            return @{ Ok = $true; Code = 'ok'; ExePath = $probe.exePath; Discovered = $true; Version = $probe.version; Probe = $probe }
        } catch {
            return @{ Ok = $false; Code = 'tool_version_unverified'; Reasons = @("Fresh compatibility probe required: $($_.Exception.Message)") }
        }
    }

    return @{ Ok = $false; Code = 'tool_resolve_mode'; Reasons = @("Unknown resolve mode '$mode' for tool '$($Entry.id)'") }
}

function Get-CollabQuotedArgument {
    <# Mirrors the Windows quoting algorithm; used for the command-line length guard. #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
        [void]$sb.Append($character)
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-CollabCommandLineLength {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )
    $length = (Get-CollabQuotedArgument -Value $ExePath).Length
    foreach ($argument in $Arguments) {
        $length += 1 + (Get-CollabQuotedArgument -Value $argument).Length
    }
    return $length
}

function Get-CollabRoleArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Role
    )
    if ($null -ne $Entry.roleArgs -and $null -ne $Entry.roleArgs.$Role) {
        return @($Entry.roleArgs.$Role)
    }
    return @()
}

function Test-CollabPromptMarkers {
    <#
      Structural check that a dispatch prompt pins the worker role and forbids
      redelegation and commits. This is a textual gate, not a semantic proof
      that the model obeys the prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Role
    )
    $missing = @()
    $rolePattern = 'Role:\s*' + [regex]::Escape($Role) + '\s*$'
    if (-not [regex]::IsMatch($Text, $rolePattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
        $missing += "role_line:Role: $Role"
    }
    if (-not [regex]::IsMatch($Text, $script:CollabPromptMarkers.no_delegation)) {
        $missing += 'no_delegation'
    }
    if (-not [regex]::IsMatch($Text, $script:CollabPromptMarkers.no_commit)) {
        $missing += 'no_commit'
    }
    return @{ Ok = ($missing.Count -eq 0); Missing = $missing }
}

function Get-CollabToolInvocation {
    <#
      Builds argv from protocol fields, commonArgs and configured roleArgs.
      Role permissions are configured for the selected CLI. The managed facade
      additionally validates the required Codex role switches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$ResultFile,
        [switch]$GitRepository,
        [int]$MaxCommandLineLength = 30000
    )

    if ($Entry.allowedRoles -and ($Role -notin @($Entry.allowedRoles))) {
        return @{ Ok = $false; Code = 'role_not_allowed'; Reasons = @("Tool '$($Entry.id)' does not allow role '$Role'") }
    }

    $kind = $Entry.kind
    $arguments = New-Object System.Collections.Generic.List[string]
    $requestedModel = $Entry.requestedModel
    $readOnly = ($Role -in @('reviewer', 'probe'))

    switch ($kind) {
        'json' {
            $values=@{
                '{prompt}'=$PromptText; '{model}'=[string]$Entry.requestedModel
                '{cwd}'=$WorkingDirectory; '{resultFile}'=$ResultFile; '{role}'=$Role
                '{promptFile}'=(Join-Path (Split-Path -Parent $ResultFile) 'prompt.txt')
            }
            foreach ($argument in @($Entry.commonArgs) + @(Get-CollabRoleArguments -Entry $Entry -Role $Role)) {
                # Whole-token substitution keeps prompt text out of shell syntax.
                if ($values.ContainsKey([string]$argument)) { $arguments.Add($values[[string]$argument]) }
                else { $arguments.Add([string]$argument) }
            }
        }
        'claude' {
            foreach ($argument in @($Entry.commonArgs)) { $arguments.Add([string]$argument) }
            if (-not [string]::IsNullOrWhiteSpace($Entry.requestedModel)) {
                $arguments.Add('--model'); $arguments.Add($Entry.requestedModel)
            }
            foreach ($argument in (Get-CollabRoleArguments -Entry $Entry -Role $Role)) { $arguments.Add([string]$argument) }
            $arguments.Add('-p')
            $arguments.Add($PromptText)
        }
        'zcode' {
            $entryPath = $Entry.entryScript
            if ([string]::IsNullOrWhiteSpace($entryPath) -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
                return @{ Ok = $false; Code = 'tool_entry_missing'; Reasons = @("ZCode entry script not found: $entryPath") }
            }
            $arguments.Add($entryPath)
            $arguments.Add('-p'); $arguments.Add($PromptText)
            $arguments.Add('--cwd'); $arguments.Add($WorkingDirectory)
            foreach ($argument in (Get-CollabRoleArguments -Entry $Entry -Role $Role)) { $arguments.Add([string]$argument) }
            foreach ($argument in @($Entry.commonArgs)) { $arguments.Add([string]$argument) }
        }
        'codex' {
            $arguments.Add('exec')
            foreach ($argument in @($Entry.commonArgs)) { $arguments.Add([string]$argument) }
            foreach ($argument in (Get-CollabRoleArguments -Entry $Entry -Role $Role)) { $arguments.Add([string]$argument) }
            if (-not [string]::IsNullOrWhiteSpace($Entry.requestedModel)) {
                $arguments.Add('-m'); $arguments.Add($Entry.requestedModel)
            }
            if (-not [string]::IsNullOrWhiteSpace($Entry.reasoningEffort)) {
                $arguments.Add('-c'); $arguments.Add("model_reasoning_effort=$($Entry.reasoningEffort)")
            }
            $arguments.Add('-C'); $arguments.Add($WorkingDirectory)
            if (-not $GitRepository) {
                if (@($Entry.nonGitArgs).Count -gt 0) {
                    foreach ($argument in @($Entry.nonGitArgs)) { $arguments.Add([string]$argument) }
                }
            }
            $arguments.Add('-o'); $arguments.Add($ResultFile)
            $arguments.Add($PromptText)
        }
        'grok' {
            $arguments.Add('-p'); $arguments.Add($PromptText)
            $arguments.Add('--cwd'); $arguments.Add($WorkingDirectory)
            foreach ($argument in @($Entry.commonArgs)) { $arguments.Add([string]$argument) }
            foreach ($argument in (Get-CollabRoleArguments -Entry $Entry -Role $Role)) { $arguments.Add([string]$argument) }
        }
        default {
            return @{ Ok = $false; Code = 'tool_kind_unknown'; Reasons = @("Unknown tool kind '$kind' for tool '$($Entry.id)'") }
        }
    }

    $argumentArray = @($arguments.ToArray())
    $length = Get-CollabCommandLineLength -ExePath $ExePath -Arguments $argumentArray
    if ($length -gt $MaxCommandLineLength) {
        return @{
            Ok = $false; Code = 'command_line_too_long'
            Reasons = @("Command line for '$($Entry.id)' would be $length characters (limit $MaxCommandLineLength). Shorten the prompt or split the task.")
        }
    }

    $environment = @{}
    if ($null -ne $Entry.env) {
        if ($Entry.env -is [System.Collections.IDictionary]) {
            foreach ($key in $Entry.env.Keys) { $environment[$key] = [string]$Entry.env[$key] }
        } else {
            foreach ($property in $Entry.env.PSObject.Properties) {
                $environment[$property.Name] = [string]$property.Value
            }
        }
    }

    return @{
        Ok             = $true
        Code           = 'ok'
        Tool           = $Entry.id
        Kind           = $kind
        ExePath        = $ExePath
        Arguments      = $argumentArray
        Environment    = $environment
        RequestedModel = $requestedModel
        ReadOnly       = $readOnly
        CommandLength  = $length
        Rationale      = @($Entry.notes)
    }
}
function Get-CollabToolFingerprint {
    param([Parameter(Mandatory)]$Entry,[Parameter(Mandatory)][string]$ExePath,[Parameter(Mandatory)][string]$WorkingDirectory)
    $files=[Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $files[$ExePath]=Get-CollabSha256 $ExePath
    foreach ($argument in @($Entry.commonArgs) + @($Entry.roleArgs.PSObject.Properties | ForEach-Object {$_.Value})) {
        if ($argument -isnot [string] -or -not $argument -or $argument.StartsWith('-') -or $argument.StartsWith('{')) { continue }
        try { $path=[IO.Path]::GetFullPath($argument,$WorkingDirectory) } catch { continue }
        if (Test-Path -LiteralPath $path -PathType Leaf) { $files[$path]=Get-CollabSha256 $path }
    }
    $binding=[ordered]@{kind=$Entry.kind;files=$files;commonArgs=$Entry.commonArgs;roleArgs=$Entry.roleArgs;allowedRoles=$Entry.allowedRoles;env=$Entry.env}
    return Get-CollabTextSha256 ($binding|ConvertTo-Json -Depth 32 -Compress)
}

function Update-CollabToolCompatibilityProbe {
    <# Runs configured local probeArgs for fixed entries, or --version and
       exec --help for Codex directory discovery, through the managed runner.
       Fixed probes bind adapter files/config; discovery binds binary identity. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$DataRoot
    )
    if (@(Get-CollabOpenViolations -DataRoot $DataRoot).Count -gt 0 -or $null -ne (Get-CollabCleanupFlag -DataRoot $DataRoot)) {
        return @{ Ok = $false; Code = 'probe_launch_blocked'; Reasons = @('Unresolved project violation or cleanup uncertainty blocks launch') }
    }
    if ($Entry.resolve.mode -eq 'fixed') {
        $resolved=Resolve-CollabToolExecutable -Entry $Entry -DataRoot $DataRoot
        if (-not $resolved.Ok) { return $resolved }
        $probeArgs=Get-CollabPropertyValue -Object $Entry -Name 'probeArgs'
        if (-not @($probeArgs).Count -or $null -eq $probeArgs) {
            return @{Ok=$false;Code='probe_args_required';Reasons=@('Configure a local capability/version probeArgs array')}
        }
        $id='compat-'+[guid]::NewGuid().ToString('N')
        $directory=Join-Path $DataRoot "probes/$id"
        $hash=Get-CollabSha256 $resolved.ExePath
        $fingerprint=Get-CollabToolFingerprint -Entry $Entry -ExePath $resolved.ExePath -WorkingDirectory (Split-Path -Parent $DataRoot)
        $run=Invoke-CollabProcess -ExePath $resolved.ExePath -Arguments @($probeArgs) -WorkingDirectory (Split-Path -Parent $DataRoot) -LogDirectory $directory -InvocationId $id -TotalTimeoutSeconds 15 -IdleTimeoutSeconds 10 -GracefulSeconds 0 -ForceSeconds 3
        $null=Write-CollabJsonAtomic -Path (Join-Path $directory 'process-result.json') -Object $run
        if ($run.Cleanup -ne 'verified') {
            $null=Set-CollabCleanupFlag -DataRoot $DataRoot -TaskId $id -InvocationId $id -Cleanup $run.Cleanup -Detail $run.CleanupDetail
            return @{Ok=$false;Code='probe_cleanup_uncertain';Process=$run}
        }
        $output=''
        if ($run.StdoutPath -and (Test-Path -LiteralPath $run.StdoutPath)) { $output=[IO.File]::ReadAllText($run.StdoutPath) }
        $missing=@(Get-CollabPropertyValue -Object $Entry -Name 'probeContains' | Where-Object {$_ -and -not $output.Contains($_)})
        $ok=$run.Ok -and $run.ExitCode -eq 0 -and $missing.Count -eq 0 -and $hash -eq (Get-CollabSha256 $resolved.ExePath) -and $fingerprint -eq (Get-CollabToolFingerprint -Entry $Entry -ExePath $resolved.ExePath -WorkingDirectory (Split-Path -Parent $DataRoot))
        $probe=@{atUtc=(Format-CollabTime (Get-CollabUtcNow));exePath=$resolved.ExePath;sha256=$hash;fingerprint=$fingerprint;compatible=$ok;evidence=$directory;missing=$missing}
        if ($ok) { $null=Set-CollabToolProbeCache -DataRoot $DataRoot -Tool $Entry.id -Probe $probe }
        return @{Ok=$ok;Code=$(if ($ok) {'ok'} else {'probe_failed'});Probe=$probe;Process=$run}
    }
    $root = $Entry.resolve.root
    $pattern = [string]$Entry.resolve.pattern
    if (-not $pattern) { $pattern = if ($IsWindows) {'*/codex.exe'} else {'*/codex'} }
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter (Split-Path -Leaf $pattern) -File })
    $probes = @()
    foreach ($candidate in $candidates) {
        $hash = Get-CollabSha256 $candidate.FullName
        $id = 'compat-' + [guid]::NewGuid().ToString('N')
        $directory = Join-Path $DataRoot "probes/$id"
        $runs = @{}
        foreach ($phase in @('version', 'help')) {
            if (@(Get-CollabOpenViolations -DataRoot $DataRoot).Count -gt 0 -or $null -ne (Get-CollabCleanupFlag -DataRoot $DataRoot)) {
                return @{ Ok = $false; Code = 'probe_launch_blocked'; Reasons = @('Unresolved project violation or cleanup uncertainty blocks launch'); Probes = $probes; Evidence = $directory }
            }
            $phaseId = "$id-$phase"
            $phaseDirectory = Join-Path $directory $phase
            $processPath = Join-Path $phaseDirectory 'process-result.json'
            $phaseArguments = if ($phase -eq 'version') { @('--version') } else { @('exec','--help') }
            try {
                $run = Invoke-CollabProcess -ExePath $candidate.FullName -Arguments $phaseArguments -WorkingDirectory $root -LogDirectory $phaseDirectory -InvocationId $phaseId -TotalTimeoutSeconds 15 -IdleTimeoutSeconds 10 -GracefulSeconds 0 -ForceSeconds 3
            } catch {
                $run = @{ Ok = $false; InvocationId = $phaseId; ExePath = $candidate.FullName; Arguments = $phaseArguments; Cleanup = 'uncertain'; CleanupDetail = (Protect-CollabSecret -Text $_.Exception.Message).Text; RunnerException = $true }
            }
            $cleanup = [string](Get-CollabPropertyValue -Object $run -Name 'Cleanup')
            if ([string]::IsNullOrWhiteSpace($cleanup)) { $cleanup = 'uncertain' }
            try {
                $null = Write-CollabJsonAtomic -Path $processPath -Object $run
            } catch {
                $detail = "Probe evidence could not be persisted at ${processPath}; no further launches: " + (Protect-CollabSecret -Text $_.Exception.Message).Text
                $null = Set-CollabCleanupFlag -DataRoot $DataRoot -TaskId $id -InvocationId $phaseId -Cleanup 'uncertain' -Detail $detail
                throw
            }
            if ($cleanup -ne 'verified') {
                $detail = "Probe cleanup is ${cleanup}; evidence: ${processPath}; no further launches or success cache. " + [string](Get-CollabPropertyValue -Object $run -Name 'CleanupDetail')
                $null = Set-CollabCleanupFlag -DataRoot $DataRoot -TaskId $id -InvocationId $phaseId -Cleanup $cleanup -Detail $detail
                return @{ Ok = $false; Code = 'probe_cleanup_uncertain'; Reasons = @($detail); Probes = $probes; Process = $run; Evidence = $processPath }
            }
            $runs[$phase] = $run
        }
        $versionRun = $runs['version']
        $helpRun = $runs['help']
        $version = if ($versionRun.StdoutPath -and (Test-Path -LiteralPath $versionRun.StdoutPath)) { [string](Get-Content -LiteralPath $versionRun.StdoutPath -Raw) } else { '' }
        $help = if ($helpRun.StdoutPath -and (Test-Path -LiteralPath $helpRun.StdoutPath)) { [string](Get-Content -LiteralPath $helpRun.StdoutPath -Raw) } else { '' }
        $versionOk = $versionRun.Ok -and $null -ne $versionRun.ExitCode -and $versionRun.ExitCode -eq 0 -and $version -match '(\d+\.\d+\.\d+)'
        $versionKey = if ($versionOk) { [version]$Matches[1] } else { [version]'0.0.0' }
        $missing = @('--ephemeral','--sandbox','--json','--output-last-message','--cd','--skip-git-repo-check','--dangerously-bypass-approvals-and-sandbox','--model','--config') | Where-Object { -not $help.Contains($_) }
        $helpOk = $helpRun.Ok -and $null -ne $helpRun.ExitCode -and $helpRun.ExitCode -eq 0 -and @($missing).Count -eq 0
        $required = [string]$Entry.resolve.requireVersionContains
        $compatible = $versionOk -and $helpOk -and (-not $required -or $version -like "*$required*") -and $hash -eq (Get-CollabSha256 $candidate.FullName)
        $probes += [pscustomobject]@{ atUtc = Format-CollabTime (Get-CollabUtcNow); exePath = $candidate.FullName; sha256 = $hash; version = $version.Trim(); versionKey = $versionKey; versionOk = [bool]$versionOk; helpOk = [bool]$helpOk; compatible = [bool]$compatible; missingHelp = @($missing); evidence = $directory; versionRun = $versionRun; helpRun = $helpRun }
    }
    $best = $probes | Where-Object compatible | Sort-Object versionKey -Descending | Select-Object -First 1
    if ($null -eq $best) { return @{ Ok = $false; Code = 'no_compatible_candidate'; Probes = $probes } }
    [void](Set-CollabToolProbeCache -DataRoot $DataRoot -Tool $Entry.id -Probe $best)
    return @{ Ok = $true; Code = 'ok'; Probe = $best; Probes = $probes }
}
