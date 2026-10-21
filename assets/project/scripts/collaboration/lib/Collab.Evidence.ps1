# Collab.Evidence.ps1 - backups, evidence records, review records, violations,
# the post-run file inventory and the handoff draft.
#
# Everything here validates structure: the file exists, the hash matches, the
# instance is distinct. None of it proves that the work is correct, and the
# README says so explicitly.

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- violations

function Get-CollabViolationPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)
    return (Join-Path $DataRoot 'violations.json')
}

function Get-CollabViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)
    $read = Read-CollabJson -Path (Get-CollabViolationPath -DataRoot $DataRoot)
    if (-not $read.Ok) { throw ($read.Reasons -join '; ') }; if ($null -eq $read.Value) { return @() }
    return @($read.Value.items)
}

function Get-CollabOpenViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)
    return @(Get-CollabViolations -DataRoot $DataRoot | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.clearedAtUtc) -and -not (Test-CollabRecoveredItem -DataRoot $DataRoot -Kind violation -Item $_) })
}

function Add-CollabViolation {
    <# Records a violation and blocks further launches until the coordinator
       clears it explicitly. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Detail,
        [string]$TaskId = '',
        [string]$InvocationId = '',
        [string]$Actor = 'runner'
    )
    $items = @(Get-CollabViolations -DataRoot $DataRoot)
    $entry = [ordered]@{
        id           = "V$(New-CollabNonce -Bytes 6)"
        atUtc        = Format-CollabTime -Time (Get-CollabUtcNow)
        kind         = $Kind
        detail       = $Detail
        taskId       = $TaskId
        invocationId = $InvocationId
        actor        = $Actor
        blocking     = $true
        clearedAtUtc = $null
        clearedBy    = $null
        clearedReason = $null
    }
    $items += $entry
    $null = Write-CollabJsonAtomic -Path (Get-CollabViolationPath -DataRoot $DataRoot) -Object ([ordered]@{
            schemaVersion = 1
            updatedAtUtc  = Format-CollabTime -Time (Get-CollabUtcNow)
            items         = @($items)
        })
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'violation_recorded' -Actor $Actor -TaskId $TaskId -Detail @{ kind = $Kind; detail = $Detail; violationId = $entry.id }
    return $entry
}

function Clear-CollabViolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$ViolationId,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Actor = 'coordinator'
    )
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return @{ Ok = $false; Code = 'reason_required'; Reasons = @('Clearing a violation requires a reason') }
    }
    $items = @(Get-CollabViolations -DataRoot $DataRoot)
    $found = $false
    foreach ($item in $items) {
        if ($item.id -eq $ViolationId) {
            $item.clearedAtUtc = Format-CollabTime -Time (Get-CollabUtcNow)
            $item.clearedBy = $Actor
            $item.clearedReason = $Reason
            $found = $true
        }
    }
    if (-not $found) {
        return @{ Ok = $false; Code = 'violation_not_found'; Reasons = @("No violation '$ViolationId'") }
    }
    $null = Write-CollabJsonAtomic -Path (Get-CollabViolationPath -DataRoot $DataRoot) -Object ([ordered]@{
            schemaVersion = 1
            updatedAtUtc  = Format-CollabTime -Time (Get-CollabUtcNow)
            items         = @($items)
        })
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'violation_cleared' -Actor $Actor -Detail @{ violationId = $ViolationId; reason = $Reason }
    return @{ Ok = $true; Code = 'cleared' }
}

# ------------------------------------------------------------ cleanup flag

function Get-CollabCleanupFlag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)
    $read = Read-CollabJson -Path (Join-Path $DataRoot 'cleanup-uncertain.json')
    if (-not $read.Ok) { throw ($read.Reasons -join '; ') }; if ($null -eq $read.Value) { return $null }
    if (Test-CollabRecoveredItem -DataRoot $DataRoot -Kind cleanup -Item $read.Value) { return $null }
    return $read.Value
}

function Set-CollabCleanupFlag {
    <# Set when an invocation's process cleanup cannot be proven. While it is set
       no new writer may be started. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$InvocationId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Cleanup,
        [Parameter(Mandatory)][string]$Detail
    )
    if ($Cleanup -eq 'verified') {
        return $null
    }
    $flag = [ordered]@{
        atUtc        = Format-CollabTime -Time (Get-CollabUtcNow)
        invocationId = $InvocationId
        taskId       = $TaskId
        cleanup      = $Cleanup
        detail       = $Detail
        acknowledged = $false
    }
    $null = Write-CollabJsonAtomic -Path (Join-Path $DataRoot 'cleanup-uncertain.json') -Object $flag
    return $flag
}

function Clear-CollabCleanupFlag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$Reason,
        [switch]$Confirm,
        [string]$Actor = 'coordinator'
    )
    if (-not $Confirm) {
        return @{ Ok = $false; Code = 'confirm_required'; Reasons = @('Acknowledging an uncertain cleanup requires -Confirm') }
    }
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return @{ Ok = $false; Code = 'reason_required'; Reasons = @('Acknowledging an uncertain cleanup requires a reason') }
    }
    $path = Join-Path $DataRoot 'cleanup-uncertain.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ Ok = $false; Code = 'flag_absent'; Reasons = @('No cleanup flag is set') }
    }
    Remove-Item -LiteralPath $path -Force
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'cleanup_flag_cleared' -Actor $Actor -Detail @{ reason = $Reason }
    return @{ Ok = $true; Code = 'cleared' }
}

# ------------------------------------------------------------------ backup

function New-CollabBackup {
    <# Copies every affected existing file and records hash + metadata, plus the
       baseline of paths that do not exist yet. Required before implementing. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BackupPath,
        [string]$Actor = 'coordinator'
    )
    $idCheck = Assert-CollabIdentifier -Value $TaskId -What 'task id'
    if (-not $idCheck.Ok) { return $idCheck }
    if (@($BackupPath).Count -eq 0) {
        return @{ Ok = $false; Code = 'backup_paths_empty'; Reasons = @('Backup requires at least one path') }
    }
    $backupDirectory = Join-Path (Join-Path $DataRoot 'backups') $TaskId
    if (Test-Path -LiteralPath (Join-Path $backupDirectory 'manifest.json')) { return @{ Ok=$false; Code='backup_exists'; Reasons=@('Original baseline is preserved; Rework retains it and each writing invocation captures its current baseline') } }
    $filesDirectory = Join-Path $backupDirectory 'files'
    if (-not (Test-Path -LiteralPath $filesDirectory)) { New-Item -ItemType Directory -Force -Path $filesDirectory | Out-Null }

    $originals = @()
    $absent = @()
    $reasons = @()
    foreach ($path in @($BackupPath)) {
        $resolved = Resolve-CollabPath -Root $Root -RelativePath $path
        if (-not $resolved.Ok) {
            $reasons += "backup path rejected ($($resolved.Code)): $path"
            continue
        }
        if (Test-Path -LiteralPath $resolved.FullPath -PathType Container) { $reasons += "Backup requires exact file: $path"; continue }
        $record = Get-CollabFileRecord -Path $resolved.FullPath
        if ($record.Existed -and $record.Sddl -eq 'unavailable') { $reasons += "ACL unavailable: $path"; continue }
        if (-not $record.Existed) {
            $absent += $resolved.RelativePath
            continue
        }
        $target = Join-Path $filesDirectory $resolved.RelativePath
        $targetDirectory = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDirectory)) { New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null }
        Copy-Item -LiteralPath $resolved.FullPath -Destination $target -Force
        if ($IsMacOS) { Restore-CollabMacMetadata -Path $target -Metadata $record.PlatformMetadata }
        if ((Get-CollabSha256 -Path $target) -ne $record.Sha256) { throw "Unreadable backup or hash mismatch: $path" }
        $originals += [ordered]@{
            path              = $resolved.RelativePath
            absolutePath      = $resolved.FullPath
            backupFile        = $target
            existed           = $true
            sha256            = $record.Sha256
            size              = $record.Size
            creationTimeUtc   = $record.CreationTimeUtc
            lastWriteTimeUtc  = $record.LastWriteTimeUtc
            lastAccessTimeUtc = $record.LastAccessTimeUtc
            attributes        = $record.Attributes
            sddl              = $record.Sddl
            platformMetadata  = $record.PlatformMetadata
        }
    }
    if ($reasons.Count -gt 0) {
        return @{ Ok = $false; Code = 'backup_path_invalid'; Reasons = @($reasons) }
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        taskId        = $TaskId
        createdAtUtc  = Format-CollabTime -Time (Get-CollabUtcNow)
        actor         = $Actor
        originals     = @($originals)
        absentBefore  = @($absent)
        rollback      = 'Restore each original from backupFile with its recorded timestamps, attributes and ACL, then verify sha256. Delete only new files that are unchanged since delivery and inside the project root. Never delete backups during cleanup.'
    }
    $manifestPath = Join-Path $backupDirectory 'manifest.json'
    $null = Write-CollabJsonAtomic -Path $manifestPath -Object $manifest
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'backup_created' -Actor $Actor -TaskId $TaskId -Detail @{
        originals = @($originals | ForEach-Object { $_.path })
        absent    = @($absent)
        manifest  = $manifestPath
    }
    return @{ Ok = $true; Code = 'backed_up'; Path = $manifestPath; Manifest = $manifest }
}

function Get-CollabBackupManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId
    )
    $path = Join-Path (Join-Path $DataRoot 'backups') (Join-Path $TaskId 'manifest.json')
    $read = Read-CollabJson -Path $path
    if (-not $read.Ok) { return $read }
    if ($null -eq $read.Value) {
        return @{ Ok = $false; Code = 'backup_missing'; Reasons = @("No backup manifest at $path") }
    }
    return @{ Ok = $true; Code = 'ok'; Manifest = $read.Value; Path = $path }
}

function Test-CollabBackupGate {
    <# Gate before implementing: a readable manifest whose recorded hashes still
       match the files on disk, and coverage of every existing file under the
       task's allowed paths (bounded, to stay honest about the limit). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task,
        [int]$MaxCoverageFiles = 500,
        [switch]$IntegrityOnly
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $checks = New-Object System.Collections.Generic.List[object]
    $read = Get-CollabBackupManifest -DataRoot $DataRoot -TaskId $Task.taskId
    if (-not $read.Ok) {
        return New-CollabOutcome -Ok $false -Code 'backup_missing' -Reasons @($read.Reasons)
    }
    $manifest = $read.Manifest
    $covered = @{}
    foreach ($entry in @($manifest.originals)) {
        $covered[[string]$entry.path] = $true
        if (-not (Test-Path -LiteralPath ([string]$entry.backupFile) -PathType Leaf)) {
            $reasons.Add("backup copy is missing for $($entry.path)")
            continue
        }
        $current = Get-CollabSha256 -Path ([string]$entry.absolutePath)
        if (-not $IntegrityOnly -and $current -ne [string]$entry.sha256) {
            $reasons.Add("file changed since backup: $($entry.path)")
        }
        if ((Get-CollabSha256 -Path ([string]$entry.backupFile)) -ne [string]$entry.sha256) {
            $reasons.Add("backup copy hash mismatch: $($entry.path)")
        }
    }
    foreach ($path in @($manifest.absentBefore)) {
        $covered[[string]$path] = $true
        if (-not $IntegrityOnly -and (Test-Path -LiteralPath (Join-Path $Root $path))) { $reasons.Add("Absent baseline now exists: $path") }
    }
    foreach ($path in @($Task.allowedPaths)) { if (-not $covered.ContainsKey([string]$path)) { $reasons.Add("Missing original/new-file baseline: $path") } }

    $existing = @()
    foreach ($pattern in @($Task.allowedPaths)) {
        $literal = $pattern -replace '/\*\*$', '' -replace '\*\*', ''
        if ($literal -match '[\*\?]') { continue }
        $resolved = Resolve-CollabPath -Root $Root -RelativePath $literal
        if (-not $resolved.Ok) { continue }
        if (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf) {
            $existing += $resolved.RelativePath
        }
        elseif (Test-Path -LiteralPath $resolved.FullPath -PathType Container) {
            foreach ($file in (Get-ChildItem -LiteralPath $resolved.FullPath -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $existing += $file.FullName.Substring($Root.Length).TrimStart([char[]]'\/').Replace('\', '/')
            }
        }
    }
    $existing = @($existing | Sort-Object -Unique -CaseSensitive)
    if ($existing.Count -gt $MaxCoverageFiles) {
        $reasons.Add("allowed paths contain $($existing.Count) files; the coverage check is limited to $MaxCoverageFiles (narrow the scope or raise the limit consciously)")
    }
    else {
        foreach ($path in $existing) {
            if (-not $covered.ContainsKey($path)) {
                $reasons.Add("existing file under an allowed path is not covered by the backup: $path")
            }
        }
    }
    $checks.Add([ordered]@{ id = 'backup_manifest_readable'; ok = $true; detail = $read.Path })
    $checks.Add([ordered]@{ id = 'backup_entries'; ok = $true; detail = "$(@($manifest.originals).Count) original(s), $(@($manifest.absentBefore).Count) absent baseline(s)" })
    $ok = ($reasons.Count -eq 0)
    $code = 'gate_refused'
    if ($ok) { $code = 'gate_passed' }
    return New-CollabOutcome -Ok $ok -Code $code -Reasons @($reasons) -Data @{ Checks = $checks.ToArray(); ManifestPath = $read.Path }
}

# --------------------------------------------------------------- inventory

function New-CollabInventorySnapshot {
    <# Project file map used to detect out-of-scope changes. Collaboration
       data is checked separately by the control snapshot. Configured generated
       directories are pruned before traversal. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Config,
        [string]$Label = 'snapshot',
        [string[]]$ExcludePath = @(),
        [string[]]$RequiredPath = @()
    )
    $maxFiles = 20000
    $maxHashBytes = 8388608
    if ($null -ne $Config.protocol.inventory) {
        if ($null -ne $Config.protocol.inventory.maxFiles) { $maxFiles = [int]$Config.protocol.inventory.maxFiles }
        if ($null -ne $Config.protocol.inventory.maxHashBytes) { $maxHashBytes = [long]$Config.protocol.inventory.maxHashBytes }
    }
    $dataRelative = $DataRoot.Substring($Root.Length).TrimStart([char[]]'\/').Replace('\', '/')
    $exclude = @($ExcludePath)

    $map = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $truncated = $false
    $skipped = 0
    $excludedDirectories=@($dataRelative)
    foreach ($pattern in @($Config.protocol.inventory.exclude)) {
        if ($pattern -notmatch '^(?:[A-Za-z0-9_.-]+/)*(node_modules|dist|build|coverage|\.cache|\.next|\.pytest_cache|__pycache__)/\*\*$') { throw "Inventory exclusion must identify a generated directory ending in /**: $pattern" }
        $directory=$pattern.Substring(0,$pattern.Length-3)
        $null=Assert-CollabOk (Resolve-CollabPath -Root $Root -RelativePath $directory)
        if (Test-CollabPathMatchesAny -Path $directory -Patterns @($Config.protected.workerDenyPaths)) { throw 'Protected paths remain inventoried' }
        foreach ($protected in @($Config.protected.workerDenyPaths)) {
            # A protected descendant must not disappear inside an excluded parent.
            $prefix=([string]$protected -split '[*?]',2)[0].TrimEnd('/')
            if (-not $prefix -or $prefix.StartsWith($directory+'/',[StringComparison]::OrdinalIgnoreCase) -or
                $directory.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                throw "Inventory exclusion overlaps protected pattern: $protected"
            }
        }
        if (@($RequiredPath | Where-Object { $_ -eq $directory -or $_.StartsWith($directory+'/',[StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Required task and frozen-test paths cannot be excluded' }
        $excludedDirectories+=$directory
    }
    $files = Get-CollabInventoryFiles -Root $Root -ExcludedDirectories $excludedDirectories
    $count = 0
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart([char[]]'\/').Replace('\', '/')
        if (Test-CollabPathMatchesAny -Path $relative -Patterns $exclude) { continue }
        $safe = Resolve-CollabPath -Root $Root -RelativePath $relative
        if (-not $safe.Ok) { throw "Inventory path refused: $relative" }
        $count++
        if ($count -gt $maxFiles) { $truncated = $true; break }
        $hash = $null
        $skipReason = $null
        if ($file.Length -le $maxHashBytes) {
            $hash = Get-CollabSha256 -Path $file.FullName
        }
        else {
            $skipReason = "size $($file.Length) exceeds maxHashBytes $maxHashBytes"
            $skipped++
        }
        $map[$relative] = [ordered]@{
            size      = [long]$file.Length
            mtimeUtc  = $file.LastWriteTimeUtc.ToString('o')
            sha256    = $hash
            hashSkipped = $skipReason
        }
    }
    return [ordered]@{
        label       = $Label
        capturedAtUtc = Format-CollabTime -Time (Get-CollabUtcNow)
        fileCount   = $count
        truncated   = $truncated
        skippedHash = $skipped
        files       = $map
    }
}

function Compare-CollabInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After
    )
    $beforeMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if ($Before.files -is [System.Collections.IDictionary]) { foreach ($key in $Before.files.Keys) { $beforeMap[$key] = $Before.files[$key] } }
    else { foreach ($property in $Before.files.PSObject.Properties) { $beforeMap[$property.Name] = $property.Value } }
    $afterMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if ($After.files -is [System.Collections.IDictionary]) { foreach ($key in $After.files.Keys) { $afterMap[$key] = $After.files[$key] } }
    else { foreach ($property in $After.files.PSObject.Properties) { $afterMap[$property.Name] = $property.Value } }

    $added = @()
    $removed = @()
    $modified = @()
    foreach ($key in $afterMap.Keys) {
        if (-not $beforeMap.ContainsKey($key)) {
            $added += [ordered]@{ path = $key; sha256 = [string]$afterMap[$key].sha256; size = [long]$afterMap[$key].size }
            continue
        }
        $old = $beforeMap[$key]
        $new = $afterMap[$key]
        if ([string]$old.sha256 -ne [string]$new.sha256 -or [long]$old.size -ne [long]$new.size -or [string]$old.mtimeUtc -ne [string]$new.mtimeUtc) {
            $modified += [ordered]@{ path = $key; sha256 = [string]$new.sha256; previousSha256 = [string]$old.sha256 }
        }
    }
    foreach ($key in $beforeMap.Keys) {
        if (-not $afterMap.ContainsKey($key)) {
            $removed += [ordered]@{ path = $key; sha256 = [string]$beforeMap[$key].sha256 }
        }
    }
    $added = @($added | Sort-Object -Property path)
    $modified = @($modified | Sort-Object -Property path)
    $removed = @($removed | Sort-Object -Property path)
    return [ordered]@{
        added    = $added
        modified = $modified
        removed  = $removed
        changeCount = ($added.Count + $modified.Count + $removed.Count)
    }
}

function Get-CollabScopeVerdict {
    <# Classifies a diff against the task's allowed paths and frozen tests. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Diff,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$Config,
        [bool]$InventoryComplete = $true,
        [string]$Root = ''
    )
    $allowedPatterns = @($Task.allowedPaths)
    $frozen = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $identity=$null
    if ($Root) {
        $identity=Get-CollabPathIdentityMap -Root $Root -NamesOnly -Path @($allowedPatterns + @($Task.frozenTests | ForEach-Object {$_.path}) + @($Diff.added+$Diff.modified+$Diff.removed | ForEach-Object {$_.path}))
        $allowedPatterns=@($allowedPatterns | ForEach-Object {$identity[$_]})
    }
    foreach ($test in @($Task.frozenTests)) {
        $key=if($Root){$identity[[string]$test.path]}else{[string]$test.path}
        $frozen[$key] = [string]$test.sha256
    }
    $violations = @()

    foreach ($entry in @($Diff.added)) {
        $path = [string]$entry.path
        $key=if($Root){$identity[$path]}else{$path}
        if ($frozen.ContainsKey($key)) {
            $violations += [ordered]@{ kind = 'frozen_test_created'; path = $path; detail = 'a frozen test file appeared during the run' }
            continue
        }
        if ($key -cnotin $allowedPatterns) {
            $violations += [ordered]@{ kind = 'scope_write_outside_allowed'; path = $path; detail = 'new file outside the allowed paths' }
        }
    }
    foreach ($entry in @($Diff.modified)) {
        $path = [string]$entry.path
        $key=if($Root){$identity[$path]}else{$path}
        if ($frozen.ContainsKey($key)) {
            if ([string]$entry.sha256 -ne $frozen[$key]) {
                $violations += [ordered]@{ kind = 'frozen_test_modified'; path = $path; detail = 'frozen test content changed (hash mismatch)' }
            }
            continue
        }
        if ($key -cnotin $allowedPatterns) {
            $violations += [ordered]@{ kind = 'scope_write_outside_allowed'; path = $path; detail = 'modified file outside the allowed paths' }
        }
    }
    foreach ($entry in @($Diff.removed)) {
        $path = [string]$entry.path
        $key=if($Root){$identity[$path]}else{$path}
        if ($frozen.ContainsKey($key)) {
            $violations += [ordered]@{ kind = 'frozen_test_deleted'; path = $path; detail = 'frozen test deleted' }
            continue
        }
        if ($key -cnotin $allowedPatterns) {
            $violations += [ordered]@{ kind = 'deleted_outside_allowed'; path = $path; detail = 'deleted file outside the allowed paths' }
        }
    }

    $scopeCheck = 'clean'
    if ($violations.Count -gt 0) { $scopeCheck = 'violations' }
    elseif (-not $InventoryComplete) { $scopeCheck = 'incomplete' }
    return [ordered]@{
        scopeCheck = $scopeCheck
        violations = @($violations)
        inventoryComplete = $InventoryComplete
    }
}

# ---------------------------------------------------------------- evidence

function Add-CollabEvidence {
    <# Copies the submitted artifact into task-owned evidence storage, then
       records that immutable copy and its source provenance. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$EvidencePath,
        [string]$AcceptanceId = '',
        [string]$Status = '',
        [string]$Note = '',
        [string]$Actor = 'coordinator'
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $candidate = $EvidencePath
    if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $rootFull $candidate }
    $candidate = [System.IO.Path]::GetFullPath($candidate)
    if (-not $candidate.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, (Get-CollabPathComparison))) {
        return @{ Ok = $false; Code = 'evidence_outside_root'; Reasons = @("Evidence must live inside the project root: $EvidencePath") }
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return @{ Ok = $false; Code = 'evidence_missing'; Reasons = @("Evidence file does not exist: $EvidencePath") }
    }
    $relative = $candidate.Substring($rootFull.Length).TrimStart([char[]]'\/').Replace('\', '/')
    $safeEvidence = Resolve-CollabPath -Root $Root -RelativePath $relative
    if (-not $safeEvidence.Ok) { return $safeEvidence }
    $allowedScopes = @($Task.allowedPaths) + @((($Config.paths.workerInbox) + '/' + $Task.taskId + '/**'), ('.collaboration/tasks/' + $Task.taskId + '/**'))
    if (-not (Test-CollabPathMatchesAny -Path $relative -Patterns $allowedScopes)) {
        return @{ Ok = $false; Code = 'evidence_out_of_scope'; Reasons = @("Evidence is outside the task scope and the worker inbox: $relative") }
    }
    if ($Status -and $Status -notin @('passed','failed','pending')) {
        return @{Ok=$false;Code='status_invalid';Reasons=@('Acceptance status must be passed/failed/pending')}
    }
    if ($AcceptanceId -and $AcceptanceId -notin @($Task.acceptance.id)) {
        return @{Ok=$false;Code='acceptance_not_found';Reasons=@("No acceptance item '$AcceptanceId'")}
    }
    $evidenceRecords=@(Get-CollabEvidenceRecords -DataRoot $DataRoot -TaskId $Task.taskId)
    $runs=@(Get-CollabInvocationRecords -DataRoot $DataRoot -TaskId $Task.taskId)
    $oldEvidence=@($evidenceRecords | Where-Object {
        [string]::Equals([string]$_.path,$relative,(Get-CollabPathComparison)) -and (Get-CollabRevision $_) -ne (Get-CollabRevision $Task)
    })
    $oldRuns=@($runs | Where-Object {
        [string]::Equals([string]$_.resultFilePath,$candidate,(Get-CollabPathComparison)) -and (Get-CollabRevision $_) -ne (Get-CollabRevision $Task)
    })
    if ($oldEvidence.Count -or $oldRuns.Count) { return @{Ok=$false;Code='evidence_revision_stale';Reasons=@('Use a new evidence artifact for the current revision')} }
    $continuation=Get-CollabPropertyValue $Task 'continuation'
    if ($null -ne $continuation) {
        $priorArtifacts=@($evidenceRecords | Where-Object {
            $_.evidenceId -in @($continuation.priorEvidenceIds) -and
            [string]::Equals([string]$_.absolutePath,$candidate,(Get-CollabPathComparison))
        })
        $priorRuns=@($runs | Where-Object {
            $_.invocationId -in @($continuation.priorInvocationIds) -and
            [string]::Equals([string]$_.resultFilePath,$candidate,(Get-CollabPathComparison))
        })
        if ($priorArtifacts.Count -or $priorRuns.Count) {
            return @{Ok=$false;Code='evidence_before_handoff';Reasons=@('Use successor verification evidence after the current Handoff')}
        }
        if ($Status -eq 'passed') {
            $gate=Test-CollabContinuationGate -DataRoot $DataRoot -Task $Task -Runs $runs -VerificationOnly
            if (-not $gate.Ok) { return $gate }
        }
    }
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
    if (-not $paths.Ok) { return $paths }
    $evidenceId="E$(New-CollabNonce -Bytes 6)"
    $artifactRelative="$($paths.Relative)/evidence/artifacts/$evidenceId$([IO.Path]::GetExtension($candidate))"
    $artifact=Assert-CollabOk (Resolve-CollabPath -Root $Root -RelativePath $artifactRelative)
    $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $artifact.FullPath))
    # A record is published only after the complete copy and source hash agree.
    # CreateNew makes a failed/interrupted copy an unreferenced artifact, never
    # a replacement for an already registered original.
    $inputStream=$null; $outputStream=$null
    try {
        $inputStream=[IO.File]::Open($candidate,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sourceHash=Get-CollabSha256 -Path $candidate
        $outputStream=[IO.File]::Open($artifact.FullPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush($true)
        $outputStream.Dispose(); $outputStream=$null
        $artifactHash=Get-CollabSha256 -Path $artifact.FullPath
        if ($artifactHash -ne $sourceHash -or (Get-CollabSha256 -Path $candidate) -ne $sourceHash) {
            throw 'Evidence source changed during preservation'
        }
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
    }
    $record = [ordered]@{
        evidenceId   = $evidenceId
        revision     = Get-CollabRevision $Task
        subjectSha256 = Get-CollabInventoryDigest -DataRoot $DataRoot -TaskId $Task.taskId
        taskId       = $Task.taskId
        kind         = $Kind
        acceptanceId = $AcceptanceId
        status       = $Status
        note         = $Note
        path         = $artifactRelative
        absolutePath = $artifact.FullPath
        sourcePath   = $relative
        sourceAbsolutePath = $candidate
        sha256       = $artifactHash
        size         = (Get-Item -LiteralPath $artifact.FullPath).Length
        actor        = $Actor
        recordedAtUtc = Format-CollabTime -Time (Get-CollabUtcNow)
    }
    $recordPath = Join-Path $paths.Evidence ($record.evidenceId + '.json')
    $null = Write-CollabJsonAtomic -Path $recordPath -Object $record

    if (-not [string]::IsNullOrWhiteSpace($AcceptanceId)) {
        $found = $false
        foreach ($item in @($Task.acceptance)) {
            if ($item.id -ne $AcceptanceId) { continue }
            $found = $true
            $evidenceList = @($item.evidence)
            $evidenceList += $record.evidenceId
            $item.evidence = @($evidenceList)
            if (-not [string]::IsNullOrWhiteSpace($Status)) {
                if ($Status -notin @('passed', 'failed', 'pending')) {
                    return @{ Ok = $false; Code = 'status_invalid'; Reasons = @("Acceptance status must be passed/failed/pending (got '$Status')") }
                }
                $item.status = $Status
                $item.verifiedAtUtc = Format-CollabTime -Time (Get-CollabUtcNow)
            }
        }
        if (-not $found) {
            return @{ Ok = $false; Code = 'acceptance_not_found'; Reasons = @("No acceptance item '$AcceptanceId'") }
        }
        $saved = Save-CollabTask -DataRoot $DataRoot -Task $Task
        if (-not $saved.Ok) { return $saved }
    }
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'evidence_recorded' -Actor $Actor -TaskId $Task.taskId -Detail @{
        kind = $Kind; acceptanceId = $AcceptanceId; status = $Status; path = $relative
    }
    return @{ Ok = $true; Code = 'recorded'; Record = $record; Path = $recordPath }
}

function Get-CollabEvidenceRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId
    )
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $TaskId
    $records = @()
    if (-not $paths.Ok -or -not (Test-Path -LiteralPath $paths.Evidence -PathType Container)) { return $records }
    foreach ($file in (Get-ChildItem -LiteralPath $paths.Evidence -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $read = Read-CollabJson -Path $file.FullName
        if ($read.Ok -and $null -ne $read.Value) { $records += $read.Value }
    }
    return @($records)
}

# ------------------------------------------------------------------ review

function Add-CollabReview {
    <#
      Records a review verdict bound to a subject hash. Validation performed here:
        * the referenced invocation exists, has role=reviewer and was accepted;
        * the review artifact is that invocation's own output (path or hash);
        * the reviewer instance differs from implementation and test instances;
          model and tool selection follow project configuration;
        * the subject hash matches the current plan text or the current
          live allowed-file scope digest;
        * PASS WITH NITS requires every recorded finding to be non-blocking;
        * FAIL records a blocker and moves the task to blocked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$SubjectKind,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][string]$InvocationId,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [string]$ExpectedSubjectSha256 = '',
        [string]$Adjudication = '',
        [AllowEmptyCollection()][array]$Findings = @(),
        [AllowEmptyCollection()][string[]]$ImplementationInvocationId = @(),
        [string]$Actor = 'coordinator'
    )
    if ($SubjectKind -notin @('plan', 'result')) {
        return @{ Ok = $false; Code = 'subject_invalid'; Reasons = @("Subject must be 'plan' or 'result' (got '$SubjectKind')") }
    }
    if ($Verdict -notin @('PASS', 'PASS WITH NITS', 'FAIL')) {
        return @{ Ok = $false; Code = 'verdict_invalid'; Reasons = @("Verdict must be PASS, PASS WITH NITS or FAIL (got '$Verdict')") }
    }

    $invocations = Get-CollabInvocationRecords -DataRoot $DataRoot -TaskId $Task.taskId
    $reviewerRun = @($invocations | Where-Object { $_.invocationId -eq $InvocationId })
    if ($reviewerRun.Count -eq 0) {
        return @{ Ok = $false; Code = 'review_invocation_missing'; Reasons = @("No invocation record '$InvocationId' for task '$($Task.taskId)'") }
    }
    $reviewerRun = $reviewerRun[0]
    $boundary=Get-CollabPropertyValue $Task 'continuation'
    if ($null -ne $boundary -and $InvocationId -cin @($boundary.priorInvocationIds)) {
        return @{Ok=$false;Code='review_before_handoff';Reasons=@('Record a review from a new invocation after the current Handoff')}
    }
    $revisionField=if ($SubjectKind -eq 'plan') {'planRevision'} else {'revision'}
    if ((Get-CollabRevision $reviewerRun $revisionField) -ne (Get-CollabRevision $Task $revisionField)) {
        return @{Ok=$false;Code='review_revision_stale';Reasons=@('Reviewer invocation belongs to an earlier revision')}
    }
    if ([string]$reviewerRun.role -ne 'reviewer') {
        return @{ Ok = $false; Code = 'review_invocation_role'; Reasons = @("Invocation '$InvocationId' has role '$($reviewerRun.role)', not 'reviewer'") }
    }
    if ($reviewerRun.accepted -ne $true) {
        return @{ Ok = $false; Code = 'review_invocation_not_accepted'; Reasons = @("Invocation '$InvocationId' was not accepted: $(@($reviewerRun.parser.reasons) -join '; ')") }
    }

    $resolvedArtifact = Resolve-CollabPath -Root $Root -RelativePath $ArtifactPath
    if (-not $resolvedArtifact.Ok) { return $resolvedArtifact }
    $artifactFull = $resolvedArtifact.FullPath
    $artifactHash = Get-CollabSha256 -Path $artifactFull
    if (-not $artifactHash -or $artifactHash -ne [string]$reviewerRun.resultSha256) {
        return @{ Ok=$false; Code='review_artifact_unbound'; Reasons=@('Artifact must match the immutable accepted final output hash') }
    }
    # Parse only the reserved declaration line, never verdict words in prose.
    $outputLines = @([IO.File]::ReadAllText($artifactFull) -split '\r\n|\n|\r' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $declarations = @($outputLines | Where-Object { $_ -match '\bCOLLAB_VERDICT\b' })
    $supportedDeclarations = @('COLLAB_VERDICT: PASS', 'COLLAB_VERDICT: PASS WITH NITS', 'COLLAB_VERDICT: FAIL')
    if ($declarations.Count -ne 1 -or $outputLines.Count -eq 0 -or
        $supportedDeclarations -cnotcontains $declarations[0] -or $outputLines[-1] -cne $declarations[0]) {
        return @{ Ok=$false; Code='review_verdict_protocol'; Reasons=@('Accepted final output must contain exactly one supported COLLAB_VERDICT declaration, exactly matching the final nonempty line') }
    }
    $declaredVerdict = $declarations[0].Substring('COLLAB_VERDICT: '.Length)
    if ($Verdict -cne $declaredVerdict) {
        return @{ Ok=$false; Code='review_verdict_mismatch'; Reasons=@('Submitted Verdict must equal the declaration in the accepted final output') }
    }
    $independentIds = @()
    foreach ($run in @($invocations | Where-Object { $_.role -in @('executor', 'tester') })) { $independentIds += [string]$run.invocationId }
    $independentIds += @($ImplementationInvocationId)
    if ([string]$InvocationId -in $independentIds) {
        return @{ Ok = $false; Code = 'reviewer_not_independent'; Reasons = @('The reviewer invocation is also recorded as an implementation or test instance') }
    }
    $instanceIds = @($invocations | Where-Object { $_.role -in @('executor','tester') } | ForEach-Object { $_.instanceId })
    if ([string]::IsNullOrWhiteSpace([string]$reviewerRun.instanceId) -or $reviewerRun.instanceId -in $instanceIds) {
        return @{ Ok=$false; Code='reviewer_not_independent'; Reasons=@('Reviewer must have a distinct instance') }
    }
    $subjectSha = ''
    if ($SubjectKind -eq 'plan') {
        if ($null -eq $Task.plan) {
            return @{ Ok = $false; Code = 'plan_missing'; Reasons = @('The task has no stored plan to review') }
        }
        $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
        $subjectSha = Get-CollabSha256 -Path (Get-CollabPlanPath -DataRoot $DataRoot -Task $Task)
        if ($subjectSha -ne [string]$Task.plan.sha256) {
            return @{ Ok = $false; Code = 'plan_changed'; Reasons = @('The stored plan file no longer matches the hash recorded at task creation') }
        }
    }
    else {
        $subjectSha = Get-CollabInventoryDigest -DataRoot $DataRoot -TaskId $Task.taskId
    }

    if (-not $ExpectedSubjectSha256 -or $ExpectedSubjectSha256 -ne $subjectSha -or
        $reviewerRun.subjectSha256 -ne $subjectSha -or $reviewerRun.subjectKind -ne $SubjectKind) {
        return @{ Ok=$false; Code='review_subject_stale'; Reasons=@('Expected subject, reviewer launch subject and current subject must agree') }
    }
    if ($Verdict -eq 'PASS WITH NITS' -and [string]::IsNullOrWhiteSpace($Adjudication)) {
        return @{ Ok=$false; Code='adjudication_required'; Reasons=@('Coordinator must explicitly adjudicate every finding as nonblocking') }
    }
    $findingList = @()
    $blocking = @()
    $findingIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($finding in @($Findings)) {
        $entry = [ordered]@{
            id       = [string](Get-CollabPropertyValue -Object $finding -Name 'id')
            severity = [string](Get-CollabPropertyValue -Object $finding -Name 'severity')
            blocking = [bool](Get-CollabPropertyValue -Object $finding -Name 'blocking')
            text     = [string](Get-CollabPropertyValue -Object $finding -Name 'text')
            location = [string](Get-CollabPropertyValue -Object $finding -Name 'location')
        }
        if ([string]::IsNullOrWhiteSpace($entry.text)) {
            return @{ Ok = $false; Code = 'finding_invalid'; Reasons = @('Every finding needs a non-empty text') }
        }
        if ([string]::IsNullOrWhiteSpace($entry.id) -or -not $findingIds.Add($entry.id.Trim())) {
            return @{ Ok = $false; Code = 'finding_id_invalid'; Reasons = @('Findings need non-empty, distinct IDs within the review') }
        }
        $entry.id = $entry.id.Trim()
        if ($entry.blocking) { $blocking += $entry.id }
        $findingList += $entry
    }

    if ($Verdict -eq 'PASS WITH NITS') {
        if ($findingList.Count -eq 0) {
            return @{ Ok = $false; Code = 'nits_missing'; Reasons = @('PASS WITH NITS requires the findings to be recorded explicitly') }
        }
        if ($blocking.Count -gt 0) {
            return @{ Ok = $false; Code = 'nits_blocking'; Reasons = @("Blocking finding(s) cannot be accepted as nits: $($blocking -join ', ')") }
        }
    }

    if ($Verdict -eq 'PASS' -and $blocking.Count -gt 0) { return @{ Ok=$false; Code='blocking_findings' } }
    $reviewId = "R$(New-CollabNonce -Bytes 6)"
    $record = [ordered]@{
        schemaVersion         = 1
        reviewId              = $reviewId
        revision              = Get-CollabRevision $Task
        planRevision          = Get-CollabRevision $Task 'planRevision'
        taskId                = $Task.taskId
        subjectKind           = $SubjectKind
        subjectSha256         = $subjectSha
        verdict               = $Verdict
        adjudication          = $Adjudication
        reviewerRole          = 'reviewer'
        reviewerTool          = [string]$reviewerRun.tool
        reviewerInvocationId  = $InvocationId
        reviewerInstanceId    = [string]$reviewerRun.instanceId
        artifactPath          = $artifactFull
        artifactSha256        = $artifactHash
        findings              = @($findingList)
        blockingFindings      = @($blocking)
        actor                 = $Actor
        recordedAtUtc         = Format-CollabTime -Time (Get-CollabUtcNow)
    }
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
    $recordPath = Join-Path $paths.Reviews ($reviewId + '.json')
    $null = Write-CollabJsonAtomic -Path $recordPath -Object $record

    $reviews = @($Task.reviews)
    $reviews += [ordered]@{
        reviewId      = $reviewId
        subjectKind   = $SubjectKind
        verdict       = $Verdict
        subjectSha256 = $subjectSha
        reviewPath    = ".collaboration/tasks/$($Task.taskId)/reviews/$reviewId.json"
        recordedAtUtc = $record.recordedAtUtc
    }
    $Task.reviews = @($reviews)
    if ($Verdict -eq 'FAIL') {
        Add-CollabBlocker -DataRoot $DataRoot -Task $Task -Reason "Independent $SubjectKind review returned FAIL (${reviewId})" -Kind 'review_fail' -Actor $Actor | Out-Null
        Set-CollabTaskState -DataRoot $DataRoot -Task $Task -To 'blocked' -Reason "review FAIL: $reviewId" -Actor $Actor | Out-Null
        $null = Add-CollabAudit -DataRoot $DataRoot -Action 'review_recorded' -Actor $Actor -TaskId $Task.taskId -Detail @{ reviewId = $reviewId; verdict = $Verdict; subjectKind = $SubjectKind; state = 'blocked' }
        return @{ Ok = $true; Code = 'review_blocking'; Record = $record; Path = $recordPath }
    }

    $saved = Save-CollabTask -DataRoot $DataRoot -Task $Task
    if (-not $saved.Ok) { return $saved }
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'review_recorded' -Actor $Actor -TaskId $Task.taskId -Detail @{ reviewId = $reviewId; verdict = $Verdict; subjectKind = $SubjectKind }
    return @{ Ok = $true; Code = 'review_accepted'; Record = $record; Path = $recordPath }
}

function Get-CollabReviewRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId
    )
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $TaskId
    $records = @()
    if (-not $paths.Ok -or -not (Test-Path -LiteralPath $paths.Reviews -PathType Container)) { return $records }
    foreach ($file in (Get-ChildItem -LiteralPath $paths.Reviews -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $read = Read-CollabJson -Path $file.FullName
        if ($read.Ok -and $null -ne $read.Value) { $records += $read.Value }
    }
    return @($records)
}

function Test-CollabReviewGate {
    <# Independent-review gate for important tasks. The accepted review must bind
       the CURRENT subject hash, so an outdated review cannot authorise a stage. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$SubjectKind
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $revisionField=if ($SubjectKind -eq 'plan') {'planRevision'} else {'revision'}
    $reviews = @(Get-CollabReviewRecords -DataRoot $DataRoot -TaskId $Task.taskId | Where-Object { $_.subjectKind -eq $SubjectKind -and (Get-CollabRevision $_ $revisionField) -eq (Get-CollabRevision $Task $revisionField) })
    if ($reviews.Count -eq 0) {
        return New-CollabOutcome -Ok $false -Code 'review_missing' -Reasons @("No $SubjectKind review has been recorded for task '$($Task.taskId)'")
    }

    $currentSha = ''
    if ($SubjectKind -eq 'plan') {
        $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
        $planPath=Get-CollabPlanPath -DataRoot $DataRoot -Task $Task
        if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
            return New-CollabOutcome -Ok $false -Code 'plan_missing' -Reasons @('The stored plan file is missing')
        }
        $currentSha = Get-CollabSha256 -Path $planPath
    }
    else {
        $currentSha = Get-CollabInventoryDigest -DataRoot $DataRoot -TaskId $Task.taskId
    }

    $boundary=Get-CollabPropertyValue $Task 'continuation'
    $requireFresh=$false
    if ($null -ne $boundary) {
        $runs=@(Get-CollabInvocationRecords -DataRoot $DataRoot -TaskId $Task.taskId)
        $integrity=Test-CollabFailureBindings -DataRoot $DataRoot -Task $Task -Boundary $boundary -Runs $runs
        if (-not $integrity.Ok) { return New-CollabOutcome -Ok $false -Code 'handoff_failure_bindings' -Reasons $integrity.Reasons }
        $requireFresh=$SubjectKind -eq 'result'
        if ($SubjectKind -eq 'plan') {
            $planFailures=@($runs | Where-Object {
                $_.invocationId -cin @($boundary.failures.invocationId) -and
                $_.role -eq 'reviewer' -and $_.subjectKind -eq 'plan'
            })
            foreach ($failure in $planFailures) {
                $binding=@($boundary.failures | Where-Object { $_.invocationId -ceq $failure.invocationId })
                if ($binding.Count -ne 1 -or $null -eq (Get-CollabFailureReplacement -DataRoot $DataRoot -Task $Task -Failure $failure -Binding $binding[0] -Boundary $boundary -Runs $runs -Reviews $reviews)) {
                    $requireFresh=$true
                }
            }
        }
    }
    $accepted = @()
    foreach ($review in $reviews) {
        if ($review.verdict -eq 'FAIL') {
            $reasons.Add("$SubjectKind review $($review.reviewId) returned FAIL")
            continue
        }
        if ($requireFresh -and ($review.reviewId -cin @($boundary.priorReviewIds) -or
            $review.reviewerInvocationId -cin @($boundary.priorInvocationIds))) {
            $reasons.Add("$SubjectKind review predates the current Handoff")
            continue
        }
        if ([string]$review.subjectSha256 -ne $currentSha) {
            $reasons.Add("$SubjectKind review $($review.reviewId) binds a stale subject hash")
            continue
        }
        if ($review.verdict -notin @('PASS','PASS WITH NITS')) { continue }
        if ($review.verdict -eq 'PASS WITH NITS') {
            if ([string]::IsNullOrWhiteSpace([string](Get-CollabPropertyValue -Object $review -Name 'adjudication'))) { continue }
            $blocking = @($review.blockingFindings)
            if ($blocking.Count -gt 0) {
                $reasons.Add("$SubjectKind review $($review.reviewId) is PASS WITH NITS but has blocking findings")
                continue
            }
            if (@($review.findings).Count -eq 0) {
                $reasons.Add("$SubjectKind review $($review.reviewId) is PASS WITH NITS without recorded findings")
                continue
            }
        }
        if (-not (Test-Path -LiteralPath ([string]$review.artifactPath) -PathType Leaf)) {
            $reasons.Add("$SubjectKind review $($review.reviewId) artifact no longer exists")
            continue
        }
        if ((Get-CollabSha256 -Path ([string]$review.artifactPath)) -ne [string]$review.artifactSha256) {
            $reasons.Add("$SubjectKind review $($review.reviewId) artifact has changed since it was recorded")
            continue
        }
        $accepted += $review
    }

    if (@($reviews | Where-Object { $_.verdict -eq 'FAIL' -and $_.subjectSha256 -eq $currentSha }).Count -gt 0) { return New-CollabOutcome -Ok $false -Code 'review_failed' -Reasons @('Current revision has a FAIL review; start Rework for correction and fresh review') }
    if ($accepted.Count -eq 0) {
        if ($reasons.Count -eq 0) { $reasons.Add("No acceptable $SubjectKind review found") }
        return New-CollabOutcome -Ok $false -Code 'review_not_accepted' -Reasons @($reasons)
    }
    return New-CollabOutcome -Ok $true -Code 'review_accepted' -Data @{ Review = $accepted[0]; SubjectSha256 = $currentSha }
}

# ----------------------------------------------------------------- handoff

function New-CollabHandoffDraft {
    <# Writes the handoff draft (JSON + Markdown) so a successor can continue from
       a proven state. Called only after the previous writer stopped and its
       cleanup was verified. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$State,
        [string]$Actor = 'coordinator'
    )
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
    if (-not $paths.Ok) { return $paths }
    if (-not (Test-Path -LiteralPath $paths.Handoff)) { New-Item -ItemType Directory -Force -Path $paths.Handoff | Out-Null }

    $invocations = Get-CollabInvocationRecords -DataRoot $DataRoot -TaskId $Task.taskId
    $unclean = @($invocations | Where-Object { -not (Test-CollabEffectiveCleanup -DataRoot $DataRoot -Run $_) })
    if ($unclean.Count -gt 0) {
        return @{
            Ok = $false; Code = 'handoff_cleanup_unverified'
            Reasons = @('Refusing to write a handoff draft while owned processes may survive: ' + (@($unclean | ForEach-Object { $_.invocationId }) -join ', '))
        }
    }
    $changed = @(Get-CollabTaskChangedInventory -DataRoot $DataRoot -TaskId $Task.taskId)
    $pending = @($Task.acceptance | Where-Object { $_.status -ne 'passed' })
    $stamp = (Get-CollabUtcNow).ToString('yyyyMMdd-HHmmss')
    $draft = [ordered]@{
        schemaVersion   = 1
        taskId          = $Task.taskId
        grade           = $Task.grade
        state           = $State
        previousState   = $Task.state
        reason          = $Reason
        createdAtUtc    = Format-CollabTime -Time (Get-CollabUtcNow)
        actor           = $Actor
        changedFiles    = @($changed)
        acceptancePending = @($pending | ForEach-Object { "$($_.id)=$($_.status)" })
        blockers        = @($Task.blockers)
        failureResolutions = @(foreach ($binding in @((Get-CollabPropertyValue $Task 'continuation').failures)) {
            $replacement=Get-CollabPropertyValue $binding 'replacement'
            @{failureInvocationId=$binding.invocationId;replacementInvocationId=$(if ($null -ne $replacement) {$replacement.invocationId} else {$null})}
        })
        invocationSummary = @($invocations | ForEach-Object {
                [ordered]@{
                    invocationId = $_.invocationId
                    role         = $_.role
                    tool         = $_.tool
                    accepted     = $_.accepted
                    classification = $_.classification
                    cleanup      = $_.cleanup
                    effectiveCleanup = (Test-CollabEffectiveCleanup -DataRoot $DataRoot -Run $_)
                }
            })
        successorInstructions = @(
            'Do not replay the previous writer''s mutations blindly.',
            'Read the evidence and review records named above before continuing.',
            'The successor works inside the recorded allowed paths only and must not modify frozen tests.',
            'The successor must not commit, must not delegate to another CLI and must not edit collaboration control data.'
        )
    }
    $jsonPath = Join-Path $paths.Handoff "handoff-$stamp.json"
    $null = Write-CollabJsonAtomic -Path $jsonPath -Object $draft

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Task handoff - $($Task.taskId)")
    $lines.Add('')
    $lines.Add("- grade: $($Task.grade)")
    $lines.Add("- state: $($Task.state) -> $State")
    $lines.Add("- reason: $Reason")
    $lines.Add("- created: $($draft.createdAtUtc)")
    $lines.Add('')
    $lines.Add('## Changed files recorded so far')
    if ($changed.Count -eq 0) { $lines.Add('(none recorded)') }
    foreach ($entry in $changed) { $lines.Add("- $($entry.kind) $($entry.path)") }
    $lines.Add('')
    $lines.Add('## Acceptance still pending')
    if ($pending.Count -eq 0) { $lines.Add('(none)') }
    foreach ($item in $pending) { $lines.Add("- $($item.id) [$($item.status)] $($item.requirement)") }
    $lines.Add('')
    $lines.Add('## Failure continuation')
    foreach ($resolution in $draft.failureResolutions) {
        $outcome=if ($resolution.replacementInvocationId) { "replacement retained: $($resolution.replacementInvocationId)" } else { 'replacement work pending' }
        $lines.Add("- $($resolution.failureInvocationId): $outcome")
    }
    $lines.Add('')
    $lines.Add('## Successor instructions')
    foreach ($line in $draft.successorInstructions) { $lines.Add("- $line") }
    $markdownPath = Join-Path $paths.Handoff "handoff-$stamp.md"
    Set-Content -LiteralPath $markdownPath -Value ($lines -join [System.Environment]::NewLine) -Encoding utf8NoBOM

    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'handoff_written' -Actor $Actor -TaskId $Task.taskId -Detail @{ state = $State; reason = $Reason; json = $jsonPath; markdown = $markdownPath }
    return @{ Ok = $true; Code = 'handoff_written'; JsonPath = $jsonPath; MarkdownPath = $markdownPath; Draft = $draft }
}
