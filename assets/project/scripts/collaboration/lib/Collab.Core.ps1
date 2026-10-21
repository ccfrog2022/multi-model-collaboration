# Collab.Core.ps1 - roots, configuration, identifier/path safety, hashing,
# atomic JSON I/O, secret redaction and the audit trail.
#
# All functions are exported by the Collab module so that tests can call them
# directly. Nothing here launches processes or mutates project state.

# Validate configuration fields explicitly before accessing them under StrictMode.
Set-StrictMode -Version 2.0

# Set by Collab.psm1 before this file is dot-sourced; the fallback keeps the
# file usable when dot-sourced directly by a test harness.
if (-not (Test-Path variable:script:CollabModuleRoot) -or [string]::IsNullOrWhiteSpace($script:CollabModuleRoot)) {
    $script:CollabModuleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

$script:CollabRootFileNames = @(
    'AGENTS.md',
    'COLLABORATION.md',
    'COLLABORATION-SETUP.md'
)

$script:CollabRedactionRules = @(
    @{ Name = 'pem_private_key'; Pattern = '(?s)(-----BEGIN[^-]{0,40}PRIVATE KEY-----).*?(-----END[^-]{0,40}PRIVATE KEY-----)'; Replacement = '$1«REDACTED»$2' },
    @{ Name = 'sk_key'; Pattern = '(?i)\b(sk-[A-Za-z0-9_\-]{8,})'; Replacement = 'sk-«REDACTED»' },
    @{ Name = 'bearer'; Pattern = '(?i)(\bbearer\s+)([A-Za-z0-9._\-]{10,})'; Replacement = '$1«REDACTED»' },
    @{ Name = 'assignment'; Pattern = '(?i)((?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|refresh[_-]?token|password|passwd|client[_-]?secret|secret|token|authorization|x-api-key|anthropic_auth_token|openai_api_key|deepseek_api_key|zcode_[a-z_]*key)["'']?\s*[:=]\s*["'']?)([^\s"'',;}\]]{8,})'; Replacement = '$1«REDACTED»' }
)

function Get-CollabScriptRoot {
    <# Directory that holds the suite (scripts/collaboration). Captured when the
       module loads, so calling the module from any directory is safe. #>
    [CmdletBinding()]
    param()
    return $script:CollabModuleRoot
}

function Get-CollabRedactionRules {
    [CmdletBinding()]
    param()
    return $script:CollabRedactionRules
}

function Protect-CollabSecret {
    <#
      Best-effort redaction of key/token-shaped strings before anything is
      persisted. This is deliberately conservative, not a proof: unknown secret
      formats are not detected. Returns @{ Text = ...; Count = n; Rules = @() }.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return @{ Text = ''; Count = 0; Rules = @() }
    }
    $current = $Text
    $count = 0
    $hit = New-Object System.Collections.Generic.List[string]
    foreach ($rule in $script:CollabRedactionRules) {
        $regex = [regex]::new($rule.Pattern)
        $matches = $regex.Matches($current)
        if ($matches.Count -gt 0) {
            $count += $matches.Count
            $hit.Add($rule.Name)
            $current = $regex.Replace($current, $rule.Replacement)
        }
    }
    return @{ Text = $current; Count = $count; Rules = @($hit) }
}

function Write-CollabRedactedFile {
    <# Writes text to a file after redaction and reports how many rules fired. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$Text
    )
    $redacted = Protect-CollabSecret -Text $Text
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $redacted.Text -Encoding utf8NoBOM -NoNewline
    return $redacted
}

function Resolve-CollabRoot {
    <# Locates the project root. Defaults to the module location so that a
       console started in a subdirectory still finds the rules; a subdirectory
       cannot be the root because the configuration file must be present. #>
    [CmdletBinding()]
    param([string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $candidate = [System.IO.Path]::GetFullPath($Root)
        $marker = Join-Path $candidate '.agents/collaboration/config/collaboration.json'
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            return @{ Ok = $false; Code = 'invalid_root'; Reasons = @("Root '$candidate' has no .agents/collaboration/config/collaboration.json") }
        }
        return @{ Ok = $true; Code = 'ok'; Root = $candidate }
    }

    $scriptRoot = Get-CollabScriptRoot
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '../..'))
    $marker = Join-Path $candidate '.agents/collaboration/config/collaboration.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        return @{ Ok = $false; Code = 'invalid_root'; Reasons = @("Configuration not found from script location '$scriptRoot'") }
    }
    return @{ Ok = $true; Code = 'ok'; Root = $candidate }
}

function Test-CollabConfig {
    [CmdletBinding()]
    param([AllowNull()]$Config, [string]$Path = 'collaboration.json')
    $reasons = [Collections.Generic.List[string]]::new()
    # Validate parent objects first so a missing parent produces one actionable error.
    $fields = [ordered]@{
        '$'='object'; 'schemaVersion'='version'; 'paths'='object'
        'paths.dataRoot'='string'; 'paths.workerInbox'='string'
        'protocol'='object'; 'protocol.serial'='bool'; 'protocol.inventory'='object'
        'protocol.inventory.maxFiles'='int32'; 'protocol.inventory.maxHashBytes'='int64'
        'protocol.inventory.exclude'='strings'; 'protected'='object'
        'protected.workerDenyPaths'='strings'; 'protected.immutablePaths'='strings'
        'protected.maintenancePaths'='strings'; 'protected.neverAllowWithinMaintenance'='strings'
    }
    $invalid = [Collections.Generic.List[string]]::new()
    foreach ($key in $fields.Keys) {
        if (@($invalid | Where-Object { $_ -eq '$' -or $key.StartsWith($_ + '.') }).Count) { continue }
        $value = $Config; $exists = $true
        if ($key -ne '$') {
            foreach ($part in $key.Split('.')) {
                if ($value -is [Collections.IDictionary]) {
                    if (-not $value.Contains($part)) { $exists=$false; break }
                    $value=$value[$part]
                } else {
                    $property=$value.PSObject.Properties[$part]
                    if ($null -eq $property) { $exists=$false; break }
                    $value=$property.Value
                }
            }
        }
        $kind=$fields[$key]
        $integer=($value -is [int] -or $value -is [long] -or $value -is [System.Numerics.BigInteger])
        $valid = $exists -and $(switch ($kind) {
            'object' { $value -is [Collections.IDictionary] -or $value -is [pscustomobject] }
            'version' { $integer -and $value -eq 1 }
            'string' { $value -is [string] -and -not [string]::IsNullOrWhiteSpace($value) }
            'bool' { $value -is [bool] }
            'int32' { $integer -and $value -gt 0 -and $value -le [int]::MaxValue }
            'int64' { $integer -and $value -gt 0 -and $value -le [long]::MaxValue }
            'strings' { $value -is [array] -and @($value | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -eq 0 }
        })
        if (-not $valid) {
            $invalid.Add($key)
            $detail=if (-not $exists) { 'required field is missing' } else { "expected $kind" }
            $reasons.Add("Configuration '$Path', field '$key': $detail")
        }
    }
    if ($reasons.Count) { return @{ Ok=$false; Code='config_invalid'; Reasons=@($reasons) } }
    return @{ Ok=$true; Code='ok'; Reasons=@() }
}

function Get-CollabConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $path = Join-Path $Root '.agents/collaboration/config/collaboration.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ Ok = $false; Code = 'config_missing'; Reasons = @("Missing configuration: $path") }
    }
    try {
        $config = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 32 -NoEnumerate
    }
    catch {
        return @{ Ok = $false; Code = 'config_invalid'; Reasons = @("Cannot read configuration '$path' as JSON: $($_.Exception.Message)") }
    }
    $validation = Test-CollabConfig -Config $config -Path $path
    if (-not $validation.Ok) { return $validation }
    return @{ Ok = $true; Code = 'ok'; Config = $config; Path = $path }
}

function Get-CollabToolConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ToolConfigFile
    )
    if (-not [string]::IsNullOrWhiteSpace($ToolConfigFile)) {
        $resolved = Resolve-CollabPath -Root $Root -RelativePath $ToolConfigFile
        if (-not $resolved.Ok) { return $resolved }
        return @{ Ok = $true; Code = 'ok'; Path = $resolved.FullPath }
    }
    return @{ Ok = $true; Code = 'ok'; Path = (Join-Path $Root '.agents/collaboration/config/tools.json') }
}

function Resolve-CollabPath {
    <#
      Resolves a caller-supplied relative path against the project root and
      rejects anything that can escape the root: absolute paths, wildcards,
      alternate data streams, traversal, trailing dots/spaces and any existing
      reparse point (junction/symlink) on the way down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return @{ Ok = $false; Code = 'path_empty'; Reasons = @('Path is empty') }
    }
    if ($RelativePath.IndexOfAny([char[]]"*?") -ge 0) {
        return @{ Ok = $false; Code = 'path_wildcard'; Reasons = @("Wildcards are not allowed: $RelativePath") }
    }
    if ($RelativePath -match '[\x00-\x1f]') {
        return @{ Ok = $false; Code = 'path_control_char'; Reasons = @('Path contains control characters') }
    }
    if ($RelativePath.Contains(':')) {
        return @{ Ok = $false; Code = 'path_stream'; Reasons = @("Drive-qualified or alternate-data-stream paths are not allowed: $RelativePath") }
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        return @{ Ok = $false; Code = 'path_absolute'; Reasons = @("Absolute paths are not allowed: $RelativePath") }
    }

    $normalized = $RelativePath.Replace('\', '/')
    $segments = $normalized -split '/'
    foreach ($segment in $segments) {
        if ($segment -eq '' -and $segments.Count -gt 1) {
            continue
        }
        if ($segment -eq '..') {
            return @{ Ok = $false; Code = 'path_traversal'; Reasons = @("Traversal segment '..' is not allowed: $RelativePath") }
        }
        if ($segment -eq '.' -or $segment -eq '') {
            return @{ Ok = $false; Code = 'path_invalid'; Reasons = @("Empty or '.' segment is not allowed: $RelativePath") }
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            return @{ Ok = $false; Code = 'path_invalid'; Reasons = @("Segment '$segment' ends with a dot or space") }
        }
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $normalized))
    $rootPrefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootPrefix, (Get-CollabPathComparison))) {
        return @{ Ok = $false; Code = 'path_escape'; Reasons = @("Path escapes the project root: $RelativePath") }
    }

    $current = $rootFull
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                return @{ Ok = $false; Code = 'path_reparse'; Reasons = @("Reparse point (junction/symlink) in path is not allowed: $RelativePath") }
            }
        }
    }

    $relative = $candidate.Substring($rootPrefix.Length).Replace('\', '/')
    return @{ Ok = $true; Code = 'ok'; FullPath = $candidate; RelativePath = $relative }
}

function Test-CollabGlobMatch {
    <# Glob matching with '**' (any depth), '*' (single segment) and '?'. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern
    )
    $p = $Path.Replace('\', '/').TrimStart('./')
    $g = $Pattern.Replace('\', '/').TrimStart('./')
    $regex = [regex]::Escape($g)
    $regex = $regex.Replace('\*\*/', '(?:.*/)?')
    $regex = $regex.Replace('\*\*', '.*')
    $regex = $regex.Replace('\*', '[^/]*')
    $regex = $regex.Replace('\?', '[^/]')
    return [regex]::IsMatch($p, '^' + $regex + '$', $(if ($IsWindows) {[Text.RegularExpressions.RegexOptions]::IgnoreCase} else {[Text.RegularExpressions.RegexOptions]::None}))
}

function Test-CollabPathMatchesAny {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$Patterns = @()
    )
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if (Test-CollabGlobMatch -Path $Path -Pattern $pattern) { return $true }
    }
    return $false
}

function Assert-CollabIdentifier {
    <# Task, invocation and review ids: short, filesystem-safe, no separators. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [string]$What = 'identifier'
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ Ok = $false; Code = 'id_empty'; Reasons = @("$What must not be empty") }
    }
    if ($Value.Length -gt 64) {
        return @{ Ok = $false; Code = 'id_too_long'; Reasons = @("$What must be at most 64 characters") }
    }
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        return @{ Ok = $false; Code = 'id_invalid'; Reasons = @("$What must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ (got '$Value')") }
    }
    if ($Value -match '^\.+$') {
        return @{ Ok = $false; Code = 'id_invalid'; Reasons = @("$What must not be a dot-only name") }
    }
    return @{ Ok = $true; Code = 'ok'; Value = $Value }
}

function New-CollabNonce {
    [CmdletBinding()]
    param([int]$Bytes = 16)
    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    return [System.BitConverter]::ToString($buffer).Replace('-', '').ToLowerInvariant()
}

function Get-CollabSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-CollabTextSha256 {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Read-CollabJson {
    <# Reads JSON. Missing file yields $null; malformed JSON returns Ok=$false. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ Ok = $true; Code = 'missing'; Value = $null }
    }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($text)) {
            return @{ Ok = $false; Code = 'json_empty'; Reasons = @("File is empty: $Path") }
        }
        return @{ Ok = $true; Code = 'ok'; Value = ($text | ConvertFrom-Json -Depth 64) }
    }
    catch {
        return @{ Ok = $false; Code = 'json_invalid'; Reasons = @("Invalid JSON in '$Path': $($_.Exception.Message)") }
    }
}

function Write-CollabJsonAtomic {
    <# Temp file in the same directory + atomic replace, so a reader never sees
       a half-written record. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$Object,
        [int]$Depth = 32
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $json = if ($null -eq $Object) { 'null' } else { $Object | ConvertTo-Json -Depth $Depth }
    $temp = "$Path.tmp-$(New-CollabNonce -Bytes 6)"
    Set-Content -LiteralPath $temp -Value $json -Encoding utf8NoBOM
    try {
        [System.IO.File]::Move($temp, $Path, $true)
    }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
    return $Path
}

function Write-CollabJsonLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [int]$Depth = 24
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $json = ($Object | ConvertTo-Json -Depth $Depth -Compress)
    $line = $json + [System.Environment]::NewLine
    [System.IO.File]::AppendAllText($Path, $line, [System.Text.UTF8Encoding]::new($false))
}

function Add-CollabAudit {
    <# Append-only audit trail. Secrets are redacted before writing. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$Action,
        [string]$Actor = 'coordinator',
        [string]$TaskId = '',
        [hashtable]$Detail = @{}
    )
    $entry = [ordered]@{
        atUtc   = (Get-Date).ToUniversalTime().ToString('o')
        action  = $Action
        actor   = $Actor
        taskId  = $TaskId
        pid     = $PID
        detail  = $Detail
    }
    $redacted = Protect-CollabSecret -Text ($entry | ConvertTo-Json -Depth 16 -Compress)
    Write-CollabJsonLine -Path (Join-Path $DataRoot 'audit.jsonl') -Object (@{ raw = $redacted.Text })
    return $entry
}

function Get-CollabUtcNow {
    [CmdletBinding()]
    param()
    return (Get-Date).ToUniversalTime()
}

function Format-CollabTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$Time)
    return $Time.ToUniversalTime().ToString('o')
}

function New-CollabOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Code = 'ok',
        [AllowEmptyCollection()][string[]]$Reasons = @(),
        [hashtable]$Data = @{}
    )
    return [pscustomobject]@{
        Ok      = $Ok
        Code    = $Code
        Reasons = @($Reasons)
        Data    = $Data
    }
}

function Get-CollabFileRecord {
    <# Metadata record used by the backup manifest (path, hash, times, ACL). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ Existed = $false }
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($IsMacOS) {
        $meta = Get-CollabMacMetadata -Path $Path
        return @{Existed=$true;Sha256=(Get-CollabSha256 $Path);Size=$item.Length;CreationTimeUtc=$item.CreationTimeUtc.ToString('o');LastWriteTimeUtc=$item.LastWriteTimeUtc.ToString('o');LastAccessTimeUtc=$item.LastAccessTimeUtc.ToString('o');Attributes=$item.Attributes.ToString();Sddl='';PlatformMetadata=$meta}
    }
    $sddl = ''
    try {
        $acl = Get-Acl -LiteralPath $Path
        $sddl = $acl.Sddl
    }
    catch {
        $sddl = 'unavailable'
    }
    return @{
        Existed           = $true
        Sha256            = Get-CollabSha256 -Path $Path
        Size              = $item.Length
        CreationTimeUtc   = $item.CreationTimeUtc.ToString('o')
        LastWriteTimeUtc  = $item.LastWriteTimeUtc.ToString('o')
        LastAccessTimeUtc = $item.LastAccessTimeUtc.ToString('o')
        Attributes        = $item.Attributes.ToString()
        Sddl              = $sddl
        PlatformMetadata  = $null
    }
}

function Get-CollabRootFileStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $result = foreach ($name in $script:CollabRootFileNames) {
        $path = Join-Path $Root $name
        [ordered]@{
            path   = $name
            exists = (Test-Path -LiteralPath $path -PathType Leaf)
            sha256 = (Get-CollabSha256 -Path $path)
        }
    }
    return @($result)
}

function Get-CollabControlFileList {
    <# Control-plane files whose hashes are snapshotted around every invocation.
       Frozen tests and ordinary project files are handled by the inventory. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRootRelative
    )
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Control snapshot root must be a physical directory: $Root"
    }
    $roots = @('.agents/collaboration', 'scripts/collaboration', $DataRootRelative)
    foreach ($name in $script:CollabRootFileNames) {
        $candidate = Assert-CollabOk (Resolve-CollabPath -Root $Root -RelativePath $name)
        if (Test-Path -LiteralPath $candidate.FullPath -PathType Leaf) { $candidate.FullPath }
    }
    foreach ($relative in $roots) {
        $base = Assert-CollabOk (Resolve-CollabPath -Root $Root -RelativePath $relative)
        if (-not (Test-Path -LiteralPath $base.FullPath)) { continue }
        $stack = [Collections.Generic.Stack[string]]::new()
        $stack.Push($base.FullPath)
        while ($stack.Count) {
            $current = Get-Item -LiteralPath $stack.Pop() -Force -ErrorAction Stop
            if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse point in control snapshot: $($current.FullName)"
            }
            if (-not $current.PSIsContainer) { throw "Control tree must be a directory: $($current.FullName)" }
            foreach ($item in Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Reparse point in control snapshot: $($item.FullName)"
                }
                if ($item.PSIsContainer) { $stack.Push($item.FullName) } else { $item.FullName }
            }
        }
    }
}

function Get-CollabControlSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRootRelative,
        [string[]]$ExcludePath=@()
    )
    $map = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($file in (Get-CollabControlFileList -Root $Root -DataRootRelative $DataRootRelative)) {
        $relative = $file.Substring($Root.Length).TrimStart([char[]]'\/').Replace('\', '/')
        if ($relative -cin $ExcludePath) { continue }
        $safe=Assert-CollabOk (Resolve-CollabPath -Root $Root -RelativePath $relative)
        $map[$relative] = Get-CollabSha256 -Path $safe.FullPath
    }
    return $map
}

function Compare-CollabControlSnapshot {
    <# Returns added/removed/modified control files between two snapshots. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After
    )
    $beforeMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if ($Before -is [System.Collections.IDictionary]) {
        foreach ($key in $Before.Keys) { $beforeMap[$key] = $Before[$key] }
    } else {
        foreach ($property in $Before.PSObject.Properties) { $beforeMap[$property.Name] = $property.Value }
    }
    $afterMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if ($After -is [System.Collections.IDictionary]) {
        foreach ($key in $After.Keys) { $afterMap[$key] = $After[$key] }
    } else {
        foreach ($property in $After.PSObject.Properties) { $afterMap[$property.Name] = $property.Value }
    }

    $added = @($afterMap.Keys | Where-Object { -not $beforeMap.ContainsKey($_) } | Sort-Object)
    $removed = @($beforeMap.Keys | Where-Object { -not $afterMap.ContainsKey($_) } | Sort-Object)
    $modified = @($afterMap.Keys | Where-Object { $beforeMap.ContainsKey($_) -and $beforeMap[$_] -ne $afterMap[$_] } | Sort-Object)
    return [ordered]@{
        added    = $added
        removed  = $removed
        modified = $modified
        clean    = (($added.Count + $removed.Count + $modified.Count) -eq 0)
    }
}
