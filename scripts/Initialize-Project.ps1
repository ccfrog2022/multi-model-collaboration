#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Mode = 'Plan',
    [string]$PlanFile,
    [string]$BackupDirectory,
    [string]$ToolsFile,
    [switch]$Confirm
)
# Project bootstrap for Windows and macOS; Plan, Apply and Rollback share one contract.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:AssetRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/project'))
$script:Lock = $null
$script:Journal = $null
$script:JournalPath = $null
$script:JournalTemp = $null
$script:Begin = '<!-- MULTI-MODEL-COLLABORATION:BEGIN -->'
$script:End = '<!-- MULTI-MODEL-COLLABORATION:END -->'
# Check the shipped file set before loading any package dependency or touching the project.
$requiredAssets = @(
    '.agents/collaboration/README.md'
    '.agents/collaboration/config/collaboration.json'
    '.agents/collaboration/config/tools.json'
    '.agents/collaboration/templates/acceptance.json'
    '.agents/collaboration/templates/context.json'
    '.agents/collaboration/templates/invoke.json'
    '.agents/collaboration/templates/new-task.json'
    '.agents/collaboration/templates/plan.md'
    '.agents/collaboration/templates/recover-task.json'
    '.agents/collaboration/templates/review.json'
    '.agents/collaboration/templates/rework.json'
    '.agents/collaboration/templates/worker.md'
    'AGENTS.md'
    'COLLABORATION-SETUP.md'
    'COLLABORATION.md'
    'scripts/collaboration/Collab.ps1'
    'scripts/collaboration/Collab.psm1'
    'scripts/collaboration/lib/Collab.Coordination.ps1'
    'scripts/collaboration/lib/Collab.Core.ps1'
    'scripts/collaboration/lib/Collab.Evidence.ps1'
    'scripts/collaboration/lib/Collab.Lock.ps1'
    'scripts/collaboration/lib/Collab.Parser.ps1'
    'scripts/collaboration/lib/Collab.Platform.ps1'
    'scripts/collaboration/lib/Collab.Process.ps1'
    'scripts/collaboration/lib/Collab.Recovery.ps1'
    'scripts/collaboration/lib/Collab.State.ps1'
    'scripts/collaboration/lib/Collab.Tools.ps1'
    'scripts/collaboration/native/Collab.Native.cs'
    'scripts/collaboration/native/platform_macos.py'
)
$missingAssets = @($requiredAssets | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:AssetRoot $_) -PathType Leaf) })
if ($missingAssets.Count) {
    [ordered]@{ Ok=$false; Code='package_incomplete'; MissingPaths=$missingAssets; Reasons=@("Package assets missing under '$script:AssetRoot': " + ($missingAssets -join ', ') + '. Download the complete package including assets/project/.agents.'); Journal=$null } | ConvertTo-Json -Depth 8
    exit 1
}
. (Join-Path $script:AssetRoot 'scripts/collaboration/lib/Collab.Platform.ps1')

function Hash-Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Json($Object) { return ConvertTo-Json -InputObject $Object -Depth 100 -Compress }
function Hash-Object($Object) { return Hash-Bytes ($script:Utf8.GetBytes((Json $Object))) }
function Read-Bytes([string]$Path) {
    if ($IsWindows) { return ,([CollabInitializer.ReadOnlyBytes]::Read($Path)) }
    return ,([IO.File]::ReadAllBytes($Path))
}
function Hash-File([string]$Path) { return Hash-Bytes (Read-Bytes $Path) }

function Safe-Path([string]$Path, [string]$Kind = 'Any') {
    if ($IsMacOS) { $Path=(Invoke-CollabMacHelper @{operation='canonical';path=$Path}).path }
    # Reject aliases, devices, streams and ambiguous normalization before resolving.
    if ($IsMacOS) {
        if (-not $Path.StartsWith('/') -or $Path -match '[\\*?\x00-\x1f]' -or @($Path.Split('/') | Where-Object {$_ -in @('.', '..')}).Count) { throw 'Use a literal absolute macOS path' }
        $p = $Path
    } else {
    $p = $Path.Replace('/', '\')
    if ($p -notmatch '^[A-Za-z]:\\' -or $p.Substring(3) -match '[:*?"<>|\x00-\x1f]') { throw 'Only literal local drive absolute paths are supported' }
    foreach ($segment in ($p.Substring(3).TrimEnd('\') -split '\\')) {
        if ($segment -eq '' -and $p.Length -eq 3) { continue }
        if ($segment -in @('', '.', '..') -or $segment -match '[ .]$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Ambiguous or reserved path segment' }
    }
    }
    $full = [IO.Path]::GetFullPath($p).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $full) { $full = '/' }
    if ($IsWindows -and $full.Length -eq 2) { $full += '\' }
    $probe = $full
    while ($probe) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse path refused: $probe" }
            if ($item.LinkType -eq 'HardLink') { throw 'Hard-linked paths are unsupported for exact rollback' }
            if ($probe -ne $full -and -not $item.PSIsContainer) { throw 'Non-directory ancestor' }
        }
        $parent = [IO.Path]::GetDirectoryName($probe)
        if ($parent -eq $probe) { break }; $probe = $parent
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if ($Kind -eq 'File' -and $item.PSIsContainer) { throw 'Expected a file' }
        if ($Kind -eq 'Directory' -and -not $item.PSIsContainer) { throw 'Expected a directory' }
    }
    return $full
}
function Under([string]$Path, [string]$Parent) {
    return $Path.Equals($Parent, (Get-CollabPathComparison)) -or $Path.StartsWith($Parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, (Get-CollabPathComparison))
}
function Target([string]$Relative) {
    if ($Relative -match '[:\\*?]' -or $Relative.StartsWith('/') -or @($Relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count) { throw 'Invalid relative target' }
    $p = Safe-Path (Join-Path $script:Root $Relative) 'File'
    if (-not (Under $p $script:Root) -or $p -eq $script:Root) { throw 'Target escapes root' }
    return $p
}
function Tree([string]$Directory) {
    $null = Safe-Path $Directory 'Directory'
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    $names = if ($IsWindows) { [CollabInitializer.ReadOnlyBytes]::List($Directory) } else { [IO.Directory]::EnumerateFileSystemEntries($Directory) | ForEach-Object { [IO.Path]::GetFileName($_) } }
    foreach ($name in @($names | Sort-Object -CaseSensitive)) {
        $item = Get-Item -LiteralPath (Join-Path $Directory $name) -Force
        $null = Safe-Path $item.FullName
        if ($item.PSIsContainer) { Tree $item.FullName } else { $item.FullName }
    }
}
function Check-JsonKeys($Element) {
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { throw 'Duplicate JSON key' }
            Check-JsonKeys $property.Value
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($value in $Element.EnumerateArray()) { Check-JsonKeys $value }
    }
}
function Json-Value($Element) {
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $value = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) { $value[$property.Name] = Json-Value $property.Value }
            return $value
        }
        'Array' {
            $value = @()
            foreach ($item in $Element.EnumerateArray()) { $value += ,(Json-Value $item) }
            return ,$value
        }
        'String' { return $Element.GetString() }
        'Number' { $integer=0L; if ($Element.TryGetInt64([ref]$integer)) { return $integer }; return $Element.GetDouble() }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw 'Unsupported JSON value' }
    }
}
function Read-Json([string]$Path) {
    $null = Safe-Path $Path 'File'
    $bytes = Read-Bytes $Path
    $text = $script:Utf8.GetString($bytes).TrimStart([char]0xfeff)
    $doc = [Text.Json.JsonDocument]::Parse($text)
    # Preserve input property order and string values in the bound plan.
    try { Check-JsonKeys $doc.RootElement; return Json-Value $doc.RootElement } finally { $doc.Dispose() }
}
function Keys($Object, [string[]]$Allowed, [string[]]$Required = @()) {
    if ($Object -isnot [Collections.IDictionary]) { throw 'Expected JSON object' }
    foreach ($key in $Object.Keys) { if ($key -cnotin $Allowed) { throw 'Unknown JSON field refused' } }
    foreach ($key in $Required) { if (-not $Object.Contains($key)) { throw "Missing field: $key" } }
}
function String-Value($Value) { if ($Value -isnot [string]) { throw 'Expected string' } }
function String-Array($Value) {
    if ($Value -isnot [array]) { throw 'Expected string array' }
    foreach ($v in $Value) { String-Value $v }
}
function Secret-Check($Object) {
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { Secret-Check $Object[$key] }
    } elseif ($Object -is [array]) {
        foreach ($v in $Object) { Secret-Check $v }
    } elseif ($Object -is [string]) {
        if ($Object -match '(?i)(sk-[a-z0-9_-]{8,}|bearer\s+|-----BEGIN|(?:api[_-]?key|token|password|passwd|secret|authorization|auth)\s*[:=]|https?://[^/\s]*@|\$\(|`|\$\{|\{\{|<[^>]+>|\x00|[\r\n])') { throw 'Secret or interpolation-shaped tools value refused' }
    }
}
function Validate-Tools($Registry) {
    Keys $Registry @('schemaVersion','preferenceOrder','tools') @('schemaVersion','preferenceOrder','tools')
    if ($Registry.schemaVersion -ne 1 -or $Registry.tools -isnot [array]) { throw 'Invalid tool registry' }
    Secret-Check $Registry
    String-Array $Registry.preferenceOrder
    $ids=@()
    foreach ($t in $Registry.tools) {
        Keys $t @('id','label','kind','enabled','readiness','executable','entryScript','requestedModel','observedModel','reasoningEffort','allowedRoles','commonArgs','nonGitArgs','roleArgs','resolve','env','notes','probeArgs','probeContains') @('id','kind','enabled','readiness','executable','requestedModel','observedModel','reasoningEffort','allowedRoles','commonArgs','nonGitArgs','roleArgs','resolve','env','label','notes')
        if ($t.id -cnotmatch '^[a-z][a-z0-9_-]{0,63}$' -or $t.id -in $ids) { throw 'Use unique lowercase tool IDs' }; $ids+=$t.id
        if ($t.kind -notin @('json','claude','zcode','codex','grok')) { throw 'Use the json adapter contract for an additional CLI' }
        if ($t.enabled -isnot [bool] -or $t.readiness -notin @('unverified','ready','unavailable','blocked','disabled')) { throw 'Invalid enabled/readiness' }
        foreach ($k in @('label','executable','requestedModel','observedModel','reasoningEffort')) { String-Value $t[$k] }
        foreach ($k in @('commonArgs','nonGitArgs','allowedRoles','notes')) { String-Array $t[$k] }
        if (-not $t.allowedRoles.Count -or @($t.allowedRoles | Where-Object {$_ -notin @('executor','tester','reviewer','probe')}).Count) { throw 'Invalid roles' }
        Keys $t.roleArgs @('executor','tester','reviewer','probe') @($t.allowedRoles)
        foreach ($k in $t.roleArgs.Keys) { String-Array $t.roleArgs[$k] }
        Keys $t.resolve @('mode','root','pattern','requireVersionContains','probeMaxAgeDays') @('mode')
        if ($t.resolve.mode -notin @('fixed','discover-version-dir')) { throw 'Invalid executable resolution' }
        if ($t.resolve.mode -eq 'discover-version-dir') {
            if ($t.kind -ne 'codex') { throw 'Directory compatibility discovery uses the codex CLI adapter' }
            foreach ($key in @('root','pattern','requireVersionContains','probeMaxAgeDays')) { if (-not $t.resolve.Contains($key)) { throw "Missing resolve field: $key" } }
        } elseif ($t.enabled) {
            if (-not [IO.Path]::IsPathRooted($t.executable) -or -not (Test-Path -LiteralPath $t.executable -PathType Leaf)) { throw 'Enabled tool needs an existing absolute executable path' }
        }
        if ($t.kind -eq 'zcode' -and (-not $t.Contains('entryScript') -or ($t.enabled -and -not (Test-Path -LiteralPath $t.entryScript -PathType Leaf)))) { throw 'Configure the zcode CLI entryScript' }
        if ($t.env -isnot [Collections.IDictionary]) { throw 'env must be an object' }
        foreach ($k in $t.env.Keys) {
            if ($k -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Invalid environment variable name' }
            String-Value $t.env[$k]
        }
        if ($t.Contains('probeArgs')) { String-Array $t.probeArgs }
        if ($t.Contains('probeContains')) { String-Array $t.probeContains }
        $t.readiness='unverified'; $t.observedModel='unknown'; $t.notes=@()
    }
    if (@($Registry.preferenceOrder | Select-Object -Unique).Count -ne $Registry.preferenceOrder.Count -or @($Registry.preferenceOrder | Where-Object {$_ -notin $ids}).Count) { throw 'Preference entries must reference unique configured tool IDs' }
    return $Registry
}

function File-State([string]$Path) {
    $null = Safe-Path $Path 'File'
    if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{ exists=$false; sha256=$null; metadata=$null } }
    $item = Get-Item -LiteralPath $Path -Force
    if ($IsMacOS) {
        $meta=Get-CollabMacMetadata -Path $Path
        return [ordered]@{exists=$true;sha256=(Hash-File $Path);metadata=$meta}
    }
    # ADS, EFS, compression, read-only and sparse files have rollback semantics outside this contract.
    $unsupported = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Offline
    if (($item.Attributes -band $unsupported) -ne 0) { throw 'Unsupported file attributes for exact rollback' }
    if (@(Get-Item -LiteralPath $Path -Stream * | Where-Object Stream -ne ':$DATA').Count) { throw 'Alternate data streams are unsupported' }
    $acl = Get-Acl -LiteralPath $Path
    $sddl = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group)
    if (-not $sddl) { throw 'Readable owner/group/DACL SDDL required' }
    return [ordered]@{ exists=$true; sha256=(Hash-File $Path); metadata=[ordered]@{
        creationTicks=$item.CreationTimeUtc.Ticks; writeTicks=$item.LastWriteTimeUtc.Ticks; accessTicks=$item.LastAccessTimeUtc.Ticks
        attributes=[int]$item.Attributes; sddl=$sddl
    } }
}
function Restore-Metadata([string]$Path, $Metadata) {
    if ($IsMacOS) { Restore-CollabMacMetadata -Path $Path -Metadata $Metadata; return }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetSecurityDescriptorSddlForm($Metadata.sddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
    [IO.File]::SetCreationTimeUtc($Path, [datetime]::new([long]$Metadata.creationTicks, [DateTimeKind]::Utc))
    [IO.File]::SetLastWriteTimeUtc($Path, [datetime]::new([long]$Metadata.writeTicks, [DateTimeKind]::Utc))
    [IO.File]::SetLastAccessTimeUtc($Path, [datetime]::new([long]$Metadata.accessTicks, [DateTimeKind]::Utc))
    [IO.File]::SetAttributes($Path, [IO.FileAttributes][int]$Metadata.attributes)
}
function Same-State($A, $B) {
    if ($IsMacOS) {
        # Reads naturally update access time on macOS; preserve it in backup metadata,
        # compare stable metadata during concurrent-change checks.
        $aCopy=(Json $A)|ConvertFrom-Json -AsHashtable; $bCopy=(Json $B)|ConvertFrom-Json -AsHashtable
        if ($aCopy.metadata) { $aCopy.metadata.Remove('accessNs') }
        if ($bCopy.metadata) { $bCopy.metadata.Remove('accessNs') }
        return (Json $aCopy) -ceq (Json $bCopy)
    }
    return (Json $A) -ceq (Json $B)
}
function Assert-OriginalSecurity($Plan) {
    if ($IsMacOS) { return } # File-State captures ACL, xattrs, ownership, flags and times.
    foreach ($row in $Plan.files) {
        if ($row.action -eq 'write' -and $row.before.exists) {
            # Ordinary Get-Acl omits SACL. Never assume an unreadable audit descriptor is empty.
            try { $acl = Get-Acl -LiteralPath (Target $row.path) -Audit }
            catch { throw 'Cannot verify original audit metadata (SeSecurityPrivilege unavailable); refuse before target writes' }
            if ($acl.Sddl -match 'S:') { throw 'Audited/labeled originals require a separate full-security backup workflow' }
        }
    }
}
function Assert-State([string]$OwnLock = '') {
    $data = Join-Path $script:Root '.collaboration'
    $null = Safe-Path $data 'Directory'
    foreach ($p in @(Tree $data)) {
        $rel = [IO.Path]::GetRelativePath($data, $p).Replace('\','/')
        if ($rel -eq 'locks/project.lock' -and $OwnLock) {
            $l = Read-Json $p
            if ($l.lockId -ne $OwnLock -or $l.pid -ne $PID -or (ConvertTo-CollabLockUtcTime $l.ownerProcessStartTimeUtc).Ticks -ne (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks) { throw 'Lock identity changed' }
            continue
        }
        if ($rel -eq 'locks/recovery.lock') {
            $null = Safe-Path $p 'File'
            $guard = Open-CollabRecoveryGuard -DataRoot $data -Probe
            if (-not $guard.Ok) { throw "Recovery guard unavailable: $($guard.Code)" }
            continue
        }
        # Only explicitly isolated onboarding evidence is allowed alongside bootstrap infrastructure.
        if ($rel.StartsWith('onboarding/', [StringComparison]::OrdinalIgnoreCase)) { continue }
        throw "Existing project state/lock requires separate coordinator handling: $rel"
    }
    foreach ($p in @('locks/project.lock')) {
        $path = Join-Path $data $p
        $null = Safe-Path $path 'File'
        if (Test-Path -LiteralPath $path) {
            if (-not $OwnLock) { throw 'Existing lock refused; no automatic recovery' }
        }
    }
}
function Assets {
    $rows = @(); $script:Prepared = @{}
    foreach ($p in @(Tree $script:AssetRoot)) {
        $rel = [IO.Path]::GetRelativePath($script:AssetRoot, $p).Replace('\','/')
        $bytes = Read-Bytes $p
        $rows += [ordered]@{ path=$rel; sha256=(Hash-Bytes $bytes) }
        $script:Prepared[$rel] = $bytes
    }
    return [ordered]@{ files=$rows; digest=(Hash-Object $rows); initializerSha256=(Hash-File $PSCommandPath) }
}
function Decode-Agents([byte[]]$Bytes) {
    # Strict UTF-8 (with/without BOM) only. Prefix bytes are never decoded/reencoded for writing.
    $text = $script:Utf8.GetString($Bytes)
    if ($text.Contains([char]0) -or $text.Contains([char]0xfffd)) { throw 'Unsupported AGENTS encoding' }
    return $text
}
function Make-Plan([string]$OwnLock = '') {
    Assert-State $OwnLock
    $assets = Assets
    $configPath = Join-Path $script:AssetRoot '.agents/collaboration/config/collaboration.json'
    try { $sourceConfig = Read-Json $configPath }
    catch { throw "Cannot read configuration '$configPath' as JSON: $($_.Exception.Message)" }
    $configCheck = Test-CollabConfig -Config $sourceConfig -Path $configPath
    if (-not $configCheck.Ok) { throw ($configCheck.Reasons -join '; ') }
    $input = [ordered]@{ path=''; sha256='' }
    $toolRel = '.agents/collaboration/config/tools.json'
    if ($ToolsFile) {
        $tp = Safe-Path $ToolsFile 'File'
        if (-not (Test-Path -LiteralPath $tp -PathType Leaf)) { throw 'ToolsFile missing' }
        if (Under $tp $script:AssetRoot) { throw 'ToolsFile must be separately prepared, not an asset' }
        if ((Under $tp (Join-Path $script:Root '.agents/collaboration')) -or (Under $tp (Join-Path $script:Root 'scripts/collaboration')) -or $tp -in @((Target 'AGENTS.md'),(Target 'COLLABORATION.md'),(Target 'COLLABORATION-SETUP.md'))) { throw 'Tools input/output overlap' }
        $input.path = $tp; $input.sha256 = Hash-File $tp
        $registry = Validate-Tools (Read-Json $tp)
        $script:Prepared[$toolRel] = $script:Utf8.GetBytes((Json $registry) + "`n")
    } else { $null = Validate-Tools (Read-Json (Join-Path $script:AssetRoot $toolRel)) }
    $agentsPath = Target 'AGENTS.md'
    $prefix = [byte[]]@()
    $managed = $false
    if (Test-Path -LiteralPath $agentsPath) {
        $prefix = Read-Bytes $agentsPath
        $text = Decode-Agents $prefix
        $b = [regex]::Matches($text, [regex]::Escape($script:Begin)).Count
        $e = [regex]::Matches($text, [regex]::Escape($script:End)).Count
        if ($b -or $e) {
            $block = $script:Utf8.GetString($script:Prepared['AGENTS.md'])
            if ($b -ne 1 -or $e -ne 1 -or -not $text.EndsWith($block, [StringComparison]::Ordinal)) { throw 'Malformed, duplicate or different managed AGENTS section' }
            $managed = $true
            $script:Prepared['AGENTS.md'] = $prefix
        } else {
            $suffix = $script:Utf8.GetBytes("`r`n`r`n") + $script:Prepared['AGENTS.md']
            $script:Prepared['AGENTS.md'] = [byte[]]($prefix + $suffix)
        }
    }
    # Foreign suite files cannot be silently adopted even when their bytes match.
    foreach ($dir in @('.agents/collaboration','scripts/collaboration')) {
        foreach ($p in @(Tree (Join-Path $script:Root $dir))) {
            $rel = [IO.Path]::GetRelativePath($script:Root, $p).Replace('\','/')
            if (-not $managed -or -not $script:Prepared.ContainsKey($rel)) { throw 'Foreign collaboration file collision' }
        }
    }
    $rows = @()
    foreach ($rel in @($script:Prepared.Keys | Sort-Object)) {
        $path = Target $rel; $before = File-State $path; $bytes = $script:Prepared[$rel]; $after = Hash-Bytes $bytes
        if ($before.exists -and $rel -ne 'AGENTS.md' -and (-not $managed -or $before.sha256 -ne $after)) { throw "Existing collaboration file collision: $rel" }
        if ($managed -and (-not $before.exists -or $before.sha256 -ne $after)) { throw 'Partial or changed existing integration; no repair/upgrade mode' }
        $rows += [ordered]@{ path=$rel; before=$before; afterSha256=$after; size=$bytes.Length; action=$(if ($before.exists -and $before.sha256 -eq $after) {'unchanged'} else {'write'}) }
    }
    $plan = [ordered]@{
        schemaVersion=1; root=$script:Root; assets=$assets; toolsInput=$input; files=$rows
        infrastructure=@('.collaboration','.collaboration/locks','.collaboration/locks/project.lock','.collaboration/locks/recovery.lock')
        noOp=(@($rows | Where-Object action -eq 'write').Count -eq 0)
        platform=$(if ($IsWindows) {'windows'} else {'macos'}); metadataPolicy='Original bytes, permissions, ownership and timestamps; macOS includes ACL, flags and xattrs. Backup roundtrip checked before writes.'
    }
    $plan['binding'] = Hash-Object $plan
    return $plan
}
function Check-Plan($Saved, $Current) {
    Keys $Saved @('schemaVersion','root','assets','toolsInput','files','infrastructure','noOp','platform','metadataPolicy','binding') @('binding','root','assets','toolsInput','files','platform')
    $binding = $Saved.binding; $Saved.Remove('binding')
    $actual = Hash-Object $Saved; $Saved['binding'] = $binding
    if ($actual -cne $binding) { throw 'Plan binding corrupt' }
    if ($Saved.platform -cne $Current.platform -or $Saved.root -cne $Current.root -or (Json $Saved.assets) -cne (Json $Current.assets) -or (Json $Saved.toolsInput) -cne (Json $Current.toolsInput) -or $Saved.files.Count -ne $Current.files.Count) { throw 'Plan root/assets/input binding changed' }
    for ($i=0; $i -lt $Current.files.Count; $i++) {
        $a=$Saved.files[$i]; $b=$Current.files[$i]
        if ($a.path -cne $b.path -or $a.afterSha256 -cne $b.afterSha256 -or $a.size -ne $b.size) { throw 'Prepared output changed' }
        if (-not $Current.noOp -and -not (Same-State $a.before $b.before)) { throw 'Stale target baseline' }
    }
    if (-not $IsMacOS -and -not $Current.noOp -and $Saved.binding -cne $Current.binding) { throw 'Plan no longer matches exact proposal' }
}

function Durable-New([string]$Path, [byte[]]$Bytes) {
    $null = Safe-Path $Path 'File'
    $s = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $s.Write($Bytes,0,$Bytes.Length); $s.Flush($true) } finally { $s.Dispose() }
}
function Save-Journal {
    $bytes = $script:Utf8.GetBytes((Json $script:Journal))
    $null = Safe-Path $script:JournalPath 'File'; $null = Safe-Path $script:JournalTemp 'File'
    if (Test-Path -LiteralPath $script:JournalTemp) { throw 'Journal temporary file exists; preserve evidence for coordinator' }
    Durable-New $script:JournalTemp $bytes
    if ((Hash-File $script:JournalTemp) -ne (Hash-Bytes $bytes)) { throw 'Journal verification failed' }
    if (Test-Path -LiteralPath $script:JournalPath) { [IO.File]::Replace($script:JournalTemp,$script:JournalPath,[System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($script:JournalTemp,$script:JournalPath) }
}
function Get-BackupRoot([bool]$New) {
    if (-not $BackupDirectory) { throw 'Explicit BackupDirectory is required' }
    $b = Safe-Path $BackupDirectory 'Directory'
    if ($IsWindows -and [IO.DriveInfo]::new([IO.Path]::GetPathRoot($b)).DriveFormat -ne 'NTFS') { throw 'Backup must reside on local NTFS' }
    if (Under $script:Root $b) { throw 'Backup cannot contain root' }
    if (Under $b $script:Root) {
        if (-not (Under $b (Join-Path $script:Root '.collaboration/onboarding')) -or $b -eq (Join-Path $script:Root '.collaboration/onboarding')) { throw 'In-project backups require a dedicated .collaboration/onboarding child' }
    }
    if ((Under $b $script:AssetRoot) -or (Under $script:AssetRoot $b)) { throw 'Backup overlaps assets' }
    foreach ($inputPath in @($PlanFile,$ToolsFile)) {
        if ($inputPath -and (Under (Safe-Path $inputPath 'File') $b)) { throw 'Input overlaps backup directory' }
    }
    if ($New -and (Test-Path -LiteralPath $b)) { throw 'Apply backup directory must be absent; evidence never overwritten' }
    return $b
}
function Take-Lock {
    $null = Safe-Path (Join-Path $script:Root '.collaboration/locks/project.lock') 'File'
    $acquired = New-CollabLock -DataRoot (Join-Path $script:Root '.collaboration') -TaskId 'skill-onboarding' -Owner coordinator -Role coordinator -Reason "Explicit initializer $Mode"
    if (-not $acquired.Ok) { throw "Project lock refused: $($acquired.Code)" }
    $script:Lock = $acquired
}
function Release-Lock {
    if ($null -eq $script:Lock) { return }
    Assert-State $script:Lock.LockId
    $released = Remove-CollabLock -DataRoot (Join-Path $script:Root '.collaboration') -LockId $script:Lock.LockId
    if (-not $released.Ok) { throw 'Owned project lock release failed' }
    $script:Lock = $null
}
function Ensure-Directory([string]$Path) {
    $null = Safe-Path $Path 'Directory'
    if (-not (Test-Path -LiteralPath $Path)) { $null = [IO.Directory]::CreateDirectory($Path) }
    $null = Safe-Path $Path 'Directory'
}
function Write-Target($Entry, [byte[]]$Bytes, [bool]$Original = $false) {
    $p = Target $Entry.path; $tmp = Target $Entry.temp
    Ensure-Directory ([IO.Path]::GetDirectoryName($p))
    if (Test-Path -LiteralPath $tmp) { throw 'Recorded target temp exists; use rollback preflight' }
    Durable-New $tmp $Bytes
    if ((Hash-File $tmp) -ne (Hash-Bytes $Bytes)) { throw 'Prepared temp hash mismatch' }
    if ($Original) { Restore-Metadata $tmp $Entry.before.metadata }
    elseif ($IsMacOS -and $Entry.before.exists) {
        $preserved=(Json $Entry.before.metadata)|ConvertFrom-Json -AsHashtable
        $newMetadata=Get-CollabMacMetadata -Path $tmp
        $preserved.writeNs=$newMetadata.writeNs; $preserved.accessNs=$newMetadata.accessNs
        Restore-Metadata $tmp $preserved
    }
    if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp,$p,[System.Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($tmp,$p) }
    if ($Original) { Restore-Metadata $p $Entry.before.metadata }
}
function Apply-Plan {
    if (-not $Confirm -or -not $PlanFile) { throw 'Apply requires reviewed PlanFile, BackupDirectory and explicit Confirm' }
    $pf = Safe-Path $PlanFile 'File'
    if (Under $pf $script:AssetRoot) { throw 'PlanFile overlaps assets' }
    $saved = Read-Json $pf
    if ($saved.Contains('Plan')) { $saved = $saved.Plan }
    $current = Make-Plan
    Check-Plan $saved $current
    # Exact repeat does not even create evidence, directories or a lock.
    if ($current.noOp) {
        if (-not $BackupDirectory) { throw 'Explicit BackupDirectory is required even for no-op' }
        $null = Get-BackupRoot $false
        return @{ Ok=$true; Code='no_op'; Writes=0; Root=$script:Root }
    }
    $backup = Get-BackupRoot $true
    Assert-OriginalSecurity $current
    Take-Lock
    $current = Make-Plan $script:Lock.LockId
    Check-Plan $saved $current
    if ($current.noOp) { throw 'State changed while acquiring lock; review a fresh plan' }
    Assert-OriginalSecurity $current
    $backup = Get-BackupRoot $true
    Ensure-Directory $backup
    $script:JournalPath = Join-Path $backup 'journal.json'
    $id = [guid]::NewGuid().ToString('N')
    $script:JournalTemp = Join-Path $backup ('.journal-'+$id+'.tmp')
    $entries = @(); $index=0
    foreach ($row in $current.files) {
        $temp = (($row.path -split '/') | Select-Object -SkipLast 1) -join '/'
        $temp = $(if ($temp) { $temp+'/' } else { '' }) + '.collab-init-'+$id+'-'+$index+'.tmp'
        $null = Target $temp
        if (Test-Path -LiteralPath (Target $temp)) { throw 'Temporary collision' }
        $entries += [ordered]@{ path=$row.path; before=$row.before; afterSha256=$row.afterSha256; size=$row.size; state='prepared'; temp=$temp; backupFile=$(if ($row.before.exists) { "$index.original" } else { '' }); preparedFile="$index.prepared" }
        $index++
    }
    $script:Journal = [ordered]@{ schemaVersion=1; root=$script:Root; backupDirectory=$backup; id=$id; phase='backing_up'; plan=$current; files=$entries; error=''; directoryPolicy='Leave empty directories and .collaboration infrastructure; never recursively remove.' }
    Save-Journal
    # Backups and intended bytes are complete, readable and roundtrip-verified before any project target write.
    foreach ($entry in $entries) {
        $path = Target $entry.path
        if (-not (Same-State (File-State $path) $entry.before)) { throw 'Baseline changed before backup' }
        if ($entry.before.exists) {
            $dest=Join-Path $backup $entry.backupFile
            Durable-New $dest (Read-Bytes $path)
            Restore-Metadata $dest $entry.before.metadata
            if (-not (Same-State (File-State $dest) $entry.before)) { throw 'Exact metadata/ACL backup roundtrip unsupported' }
        }
        $prepared=Join-Path $backup $entry.preparedFile
        Durable-New $prepared $script:Prepared[$entry.path]
        if ((Hash-File $prepared) -ne $entry.afterSha256) { throw 'Prepared backup unreadable' }
    }
    $script:Journal.phase='prepared'; Save-Journal
    # Whole-target preflight after all backup operations and before the first target mutation.
    Assert-State $script:Lock.LockId
    if ((Json (Assets)) -cne (Json $current.assets)) { throw 'Assets changed after backup' }
    if ($current.toolsInput.path -and (Hash-File $current.toolsInput.path) -cne $current.toolsInput.sha256) { throw 'Tools input changed after backup' }
    foreach ($entry in $entries) {
        if (-not (Same-State (File-State (Target $entry.path)) $entry.before)) { throw 'All-target preflight changed' }
        if ($entry.before.exists -and -not (Same-State (File-State (Join-Path $backup $entry.backupFile)) $entry.before)) { throw 'Backup preflight mismatch' }
        if ((Hash-File (Join-Path $backup $entry.preparedFile)) -ne $entry.afterSha256) { throw 'Prepared preflight mismatch' }
    }
    $script:Journal.phase='applying'; Save-Journal
    foreach ($entry in $entries) {
        Assert-State $script:Lock.LockId
        if (-not (Same-State (File-State (Target $entry.path)) $entry.before)) { throw 'Target changed before write' }
        # The prepared journal already records this mutation intent and exact before/after states.
        Write-Target $entry (Read-Bytes (Join-Path $backup $entry.preparedFile))
        if ((Hash-File (Target $entry.path)) -ne $entry.afterSha256) { throw 'Target post-write verification failed' }
        $entry.state='committed'; Save-Journal
    }
    $script:Journal.phase='applied'; Save-Journal
    return @{ Ok=$true; Code='applied'; Writes=$entries.Count; Root=$script:Root; Journal=$script:JournalPath }
}

function Rollback-Preflight($J, [string]$Backup) {
    $null = @(Tree $Backup)
    Keys $J @('schemaVersion','root','backupDirectory','id','phase','plan','files','error','directoryPolicy') @('schemaVersion','root','backupDirectory','id','phase','plan','files')
    if ($J.schemaVersion -ne 1 -or $J.root -cne $script:Root -or $J.backupDirectory -cne $Backup -or $J.id -notmatch '^[a-f0-9]{32}$' -or $J.phase -notin @('prepared','applying','applied','failed','rolling_back','rolled_back')) { throw 'Journal root/identity/phase mismatch' }
    $asset = Assets
    if ((Json $asset) -cne (Json $J.plan.assets)) { throw 'Rollback requires original unchanged asset/initializer bundle' }
    $binding=$J.plan.binding; $J.plan.Remove('binding'); $actual=Hash-Object $J.plan; $J.plan['binding']=$binding
    if ($actual -cne $binding -or $J.plan.root -cne $script:Root) { throw 'Journal plan binding corrupt' }
    $allowed = @($script:Prepared.Keys | Sort-Object)
    if ($J.files.Count -ne $allowed.Count -or $J.plan.files.Count -ne $allowed.Count) { throw 'Incomplete journal inventory' }
    for ($i=0; $i -lt $allowed.Count; $i++) {
        $e=$J.files[$i]; $p=$J.plan.files[$i]
        if ($e.path -cne $allowed[$i] -or $p.path -cne $e.path -or $p.afterSha256 -cne $e.afterSha256 -or $p.size -ne $e.size -or -not (Same-State $e.before $p.before)) { throw 'Journal entry differs from bound plan' }
        if ($e.state -cnotin @('prepared','committed','restoring','restored')) { throw 'Unknown write-ahead state' }
        $parent = (($e.path -split '/') | Select-Object -SkipLast 1) -join '/'
        $expectedTemp = $(if ($parent) { $parent+'/' } else { '' }) + '.collab-init-'+$J.id+'-'+$i+'.tmp'
        if ($e.temp -cne $expectedTemp -or $e.preparedFile -cne "$i.prepared" -or $e.backupFile -cne $(if ($e.before.exists) { "$i.original" } else { '' })) { throw 'Unrecorded/unsafe journal path' }
        if ($e.before.exists -and $e.path -ne 'AGENTS.md') { throw 'Initializer never owns pre-existing suite files' }
        $original=$null
        if ($e.before.exists) {
            $original=Join-Path $Backup $e.backupFile
            if (-not (Same-State (File-State $original) $e.before)) { throw 'Original backup corrupt or metadata drift' }
        }
        $prepared=Safe-Path (Join-Path $Backup $e.preparedFile) 'File'
        $bytes=Read-Bytes $prepared
        if ((Hash-Bytes $bytes) -cne $e.afterSha256 -or $bytes.Length -ne $e.size) { throw 'Prepared backup corrupt' }
        if ($e.path -eq 'AGENTS.md') {
            $expected=$script:Prepared[$e.path]
            if ($e.before.exists) { $prefix=Read-Bytes $original; $null=Decode-Agents $prefix; $expected=[byte[]]($prefix + $script:Utf8.GetBytes("`r`n`r`n") + $expected) }
            if ((Hash-Bytes $expected) -cne $e.afterSha256) { throw 'AGENTS prepared bytes not bound to original' }
        } elseif ($e.path -eq '.agents/collaboration/config/tools.json') {
            $null=Validate-Tools (Read-Json $prepared)
        } elseif ((Hash-Bytes $script:Prepared[$e.path]) -cne $e.afterSha256) { throw 'Prepared asset bytes mismatch' }
        $path=Target $e.path; $current=File-State $path
        $old=($current.exists -eq $e.before.exists -and $current.sha256 -eq $e.before.sha256)
        $new=($current.exists -and $current.sha256 -eq $e.afterSha256)
        if (-not $old -and -not $new) { throw "Rollback target drift: $($e.path)" }
        if ($e.state -eq 'committed' -and -not $new) { throw 'Committed target unexpectedly reverted' }
        if ($e.state -eq 'restored' -and -not (Same-State $current $e.before)) { throw 'Restored target drift' }
        $tmp=Target $e.temp
        if (Test-Path -LiteralPath $tmp) {
            $hash=Hash-File $tmp
            if ($hash -ne $e.afterSha256 -and (-not $e.before.exists -or $hash -ne $e.before.sha256)) { throw 'Partial/unknown temp preserved; coordinator action required' }
        }
    }
}
function Rollback-Project {
    if (-not $Confirm) { throw 'Rollback requires explicit Confirm' }
    if ($PlanFile -or $ToolsFile) { throw 'Rollback takes only Root, BackupDirectory and Confirm; journal binds inputs' }
    $backup=Get-BackupRoot $false
    $script:JournalPath=Join-Path $backup 'journal.json'
    $script:Journal=Read-Json $script:JournalPath
    $script:JournalTemp=Join-Path $backup ('.journal-'+$script:Journal.id+'.tmp')
    Assert-State
    Rollback-Preflight $script:Journal $backup
    if (Test-Path -LiteralPath $script:JournalTemp) { throw 'Interrupted journal persistence; preserve for explicit coordinator handling' }
    if ($script:Journal.phase -eq 'rolled_back') { return @{Ok=$true;Code='no_op';Writes=0;Root=$script:Root} }
    Take-Lock
    Assert-State $script:Lock.LockId
    Rollback-Preflight $script:Journal $backup
    $script:Journal.phase='rolling_back'; Save-Journal
    $writes=0
    foreach ($entry in $script:Journal.files) {
        if ($entry.state -eq 'restored') { continue }
        Assert-State $script:Lock.LockId
        $path=Target $entry.path; $tmp=Target $entry.temp
        $entry.state='restoring'; Save-Journal
        # Only explicitly recorded, fully matching temporaries are removed.
        if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) }
        $current=File-State $path
        if ($entry.before.exists) {
            if ($current.sha256 -ne $entry.before.sha256) { Write-Target $entry (Read-Bytes (Join-Path $backup $entry.backupFile)) $true; $writes++ }
            else { Restore-Metadata $path $entry.before.metadata }
        } elseif ($current.exists) {
            if ($current.sha256 -ne $entry.afterSha256) { throw 'Rollback deletion hash mismatch' }
            [IO.File]::Delete($path); $writes++
        }
        if (-not (Same-State (File-State $path) $entry.before)) { throw 'Original state restoration failed' }
        $entry.state='restored'; Save-Journal
    }
    $script:Journal.phase='rolled_back'; $script:Journal.error=''; Save-Journal
    return @{Ok=$true;Code='rolled_back';Writes=$writes;Root=$script:Root;Journal=$script:JournalPath;Retained='Backup evidence, .collaboration infrastructure and empty directories'}
}

$result=$null; $exitCode=1
try {
    if (-not ($IsWindows -or $IsMacOS)) { throw 'Supported platforms: Windows and macOS' }
    if ($IsMacOS) { $null=Get-Command python3 -CommandType Application -ErrorAction Stop }
    # NTFS may update access time even for reads. Suppress that bookkeeping on this
    # handle, without changing any stored timestamp. No ACL grants or disk compilation.
    if ($IsWindows -and -not ('CollabInitializer.ReadOnlyBytes' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace CollabInitializer {
    public static class ReadOnlyBytes {
        [StructLayout(LayoutKind.Sequential)] private struct Time { public uint Low, High; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetFileTime(SafeFileHandle handle, IntPtr creation, ref Time access, IntPtr write);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, IntPtr buffer, uint size);
        public static string[] List(string path) {
            using (var handle = CreateFileW(path, 0x181, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open metadata-preserving directory handle");
                var noUpdate = new Time { Low=0xffffffff, High=0xffffffff };
                if (!SetFileTime(handle, IntPtr.Zero, ref noUpdate, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot suppress directory access-time bookkeeping");
                var names = new List<string>();
                IntPtr buffer = Marshal.AllocHGlobal(65536);
                try {
                    while (true) {
                        // FileIdBothDirectoryInfo; FILE_ID_BOTH_DIR_INFO.FileName is at 104.
                        if (!GetFileInformationByHandleEx(handle, 10, buffer, 65536)) {
                            int error=Marshal.GetLastWin32Error();
                            if (error==18) break;
                            throw new Win32Exception(error, "Directory enumeration failed");
                        }
                        int offset=0;
                        while (true) {
                            if (offset<0 || offset>65432) throw new IOException("Invalid directory record");
                            int next=Marshal.ReadInt32(buffer,offset);
                            int bytes=Marshal.ReadInt32(buffer,offset+60);
                            if (bytes<0 || (bytes&1)!=0 || offset+104+bytes>65536) throw new IOException("Invalid directory name");
                            string name=Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+104),bytes/2);
                            if (name!="." && name!="..") names.Add(name);
                            if (next==0) break;
                            if (next<104) throw new IOException("Invalid directory offset");
                            offset+=next;
                        }
                    }
                } finally { Marshal.FreeHGlobal(buffer); }
                return names.ToArray();
            }
        }
        public static byte[] Read(string path) {
            // READ_DATA | READ_ATTRIBUTES | WRITE_ATTRIBUTES. The latter permits
            // per-handle suppression only; inability to obtain it fails closed.
            using (var handle = CreateFileW(path, 0x181, 7, IntPtr.Zero, 3, 0x08000000, IntPtr.Zero)) {
                if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); throw new Win32Exception(error, "Cannot read file '" + path + "' (Win32 " + error + "): " + new Win32Exception(error).Message); }
                var noUpdate = new Time { Low=0xffffffff, High=0xffffffff };
                if (!SetFileTime(handle, IntPtr.Zero, ref noUpdate, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot suppress read access-time bookkeeping");
                using (var stream = new FileStream(handle, FileAccess.Read))
                using (var output = new MemoryStream()) { stream.CopyTo(output); return output.ToArray(); }
            }
        }
    }
}
'@
    }
    if ($Mode -cnotin @('Plan','Apply','Rollback')) { throw 'Mode must be Plan, Apply or Rollback' }
    $script:Root=Safe-Path $Root 'Directory'
    if (-not (Test-Path -LiteralPath $script:Root -PathType Container) -or $script:Root.Length -le 3) { throw 'Explicit existing project directory required' }
    if ($IsWindows -and [IO.DriveInfo]::new([IO.Path]::GetPathRoot($script:Root)).DriveFormat -ne 'NTFS') { throw 'Root must reside on local NTFS' }
    $null=Safe-Path $script:AssetRoot 'Directory'
    if ((Under $script:Root $script:AssetRoot) -or (Under $script:AssetRoot $script:Root)) { throw 'Root overlaps source assets' }
    # Only unchanged local pure helper libraries; never import/execute a target project module.
    . (Join-Path $script:AssetRoot 'scripts/collaboration/lib/Collab.Core.ps1')
    . (Join-Path $script:AssetRoot 'scripts/collaboration/lib/Collab.Parser.ps1')
    . (Join-Path $script:AssetRoot 'scripts/collaboration/lib/Collab.Lock.ps1')
    Set-StrictMode -Version 3.0
    switch ($Mode) {
        'Plan' {
            if ($Confirm -or $PlanFile -or $BackupDirectory) { throw 'Plan emits JSON only; caller saves stdout externally. Do not pass Confirm, PlanFile or BackupDirectory.' }
            $result=@{Ok=$true;Code='planned';Plan=(Make-Plan)}
        }
        'Apply' { $result=Apply-Plan }
        'Rollback' { $result=Rollback-Project }
    }
    $exitCode=0
} catch {
    $message=$_.Exception.Message
    # Failure is evidence only. Never auto-rollback or overwrite an uncertain journal temp.
    if ($script:Lock -and $script:Journal -and $script:JournalPath -and (Test-Path -LiteralPath $script:JournalPath)) {
        try { $script:Journal.error=$message; if ($script:Journal.phase -ne 'rolling_back') { $script:Journal.phase='failed' }; Save-Journal } catch { $message += '; journal update unavailable; retained existing evidence' }
    }
    $result=@{Ok=$false;Code='initializer_refused';Reasons=@($message);Journal=$script:JournalPath}
} finally {
    try { Release-Lock } catch { $result=@{Ok=$false;Code='lock_release_failed';Reasons=@($_.Exception.Message);Journal=$script:JournalPath}; $exitCode=1 }
}
$result | ConvertTo-Json -Depth 100
exit $exitCode
