# Collab.Lock.ps1 - one project-local exclusive lock that serialises every
# managed invocation and every state write across chats.
#
# Rules: the lock always lives inside the project data directory; it is created
# atomically with FileMode.CreateNew; the owner records pid, process creation
# time, a CSPRNG nonce and the task; a conflicting caller fails immediately and
# startup never clears or steals a lock; release requires the exact token; and
# recovery is an explicit, audited command that refuses on any unknown value.

Set-StrictMode -Version 2.0

function ConvertTo-CollabLockUtcTime {
    param([AllowNull()][object]$Value)

    # ConvertFrom-Json can return DateTime; stringifying it loses Kind/offset.
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)) {
        return [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    throw 'Lock timestamp is missing or invalid'
}

function Get-CollabLockPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)
    return (Join-Path $DataRoot 'locks/project.lock')
}

function Read-CollabLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $path = Get-CollabLockPath -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ Ok = $true; Code = 'free'; Held = $false; Lock = $null; Path = $path }
    }
    $read = Read-CollabJson -Path $path
    if (-not $read.Ok) {
        return @{ Ok = $false; Code = 'lock_unreadable'; Held = $true; Lock = $null; Path = $path; Reasons = $read.Reasons }
    }
    if ($null -eq $read.Value) {
        return @{ Ok = $false; Code = 'lock_unreadable'; Held = $true; Lock = $null; Path = $path; Reasons = @('Lock file is empty; ownership is unknown') }
    }
    $lock = $read.Value
    $missing = @()
    foreach ($field in @('lockId', 'pid', 'ownerProcessStartTimeUtc', 'nonce', 'acquiredAtUtc')) {
        $value = Get-CollabPropertyValue -Object $lock -Name $field
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { $missing += $field }
    }
    if ($missing.Count -gt 0) {
        return @{ Ok = $false; Code = 'lock_incomplete'; Held = $true; Lock = $lock; Path = $path; Reasons = @("Lock record is missing: $($missing -join ', ')") }
    }
    return @{ Ok = $true; Code = 'held'; Held = $true; Lock = $lock; Path = $path }
}

function Open-CollabRecoveryGuard {
    # Keep the inode/path stable: removing a released mutex file can split
    # contenders across different handles. The OS releases ownership on exit.
    param([string]$DataRoot, [switch]$Probe)
    $path = Join-Path $DataRoot 'locks/recovery.lock'
    try {
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery guard must be a regular file' }
        } elseif ($Probe) {
            return @{ Ok=$true; Code='available'; Active=$false; Present=$false; Path=$path; Handle=$null }
        }
        if (-not $Probe) { $null=New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force }
        $mode=if($Probe){[IO.FileMode]::Open}else{[IO.FileMode]::OpenOrCreate}
        $access=if($Probe){[IO.FileAccess]::Read}else{[IO.FileAccess]::ReadWrite}
        $sharing=if($Probe){[IO.FileShare]::ReadWrite}else{[IO.FileShare]::None}
        $handle=[IO.File]::Open($path,$mode,$access,$sharing)
        if($Probe){$handle.Dispose();$handle=$null}
        return @{Ok=$true;Code='available';Active=$false;Present=$true;Path=$path;Handle=$handle}
    } catch [IO.IOException] {
        # Sharing violations mean an owner still has the handle. Other I/O
        # failures remain visible as unverified, rather than claiming activity.
        $errorCode=$_.Exception.HResult -band 0xffff
        if ($errorCode -in @(11,32,33)) { return @{Ok=$false;Code='recovery_in_progress';Active=$true;Present=$true;Path=$path;Handle=$null;Reasons=@('Recovery guard is held by another operation')} }
        return @{Ok=$false;Code='recovery_guard_unavailable';Active=$null;Present=$true;Path=$path;Handle=$null;Reasons=@($_.Exception.Message)}
    } catch {
        return @{Ok=$false;Code='recovery_guard_unavailable';Active=$null;Present=$true;Path=$path;Handle=$null;Reasons=@($_.Exception.Message)}
    }
}

function New-CollabLock {
    <# Atomically takes the project lock. Fails on conflict; never waits, never
       steals, never touches a lock outside the project data directory. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$TaskId = '',
        [string]$Owner = 'coordinator',
        [string]$Reason = '',
        [string]$Role = 'coordinator'
    )

    $guard=Open-CollabRecoveryGuard -DataRoot $DataRoot
    if(-not $guard.Ok){return $guard}
    try {
    $existing = Read-CollabLock -DataRoot $DataRoot
    if ($existing.Held) {
        $ownerText = if ($null -ne $existing.Lock) { "pid $($existing.Lock.pid)" } else { 'unreadable' }
        $reasons = if (Get-CollabPropertyValue -Object $existing -Name 'Reasons') { $existing.Reasons } else { @("lock held by $ownerText") }
        return @{ Ok = $false; Code = 'lock_conflict'; Reasons = $reasons; Lock = $existing.Lock }
    }

    $path = Get-CollabLockPath -DataRoot $DataRoot
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $now = Get-CollabUtcNow
    $lockId = New-CollabNonce -Bytes 16
    $record = [ordered]@{
        schemaVersion            = 1
        lockId                   = $lockId
        nonce                    = New-CollabNonce -Bytes 16
        pid                      = $PID
        ownerProcessStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        owner                    = $Owner
        role                     = $Role
        taskId                   = $TaskId
        reason                   = $Reason
        acquiredAtUtc            = Format-CollabTime -Time $now
        host                     = [System.Environment]::MachineName
        containment              = 'windows-job-object'
    }

    $json = $record | ConvertTo-Json -Depth 8
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        return @{ Ok = $false; Code = 'lock_conflict'; Reasons = @('Another chat created the lock first (atomic create failed)') }
    }
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    finally {
        $stream.Dispose()
    }
    return @{ Ok = $true; Code = 'acquired'; LockId = $lockId; Path = $path; Lock = $record }
    } finally { $guard.Handle.Dispose() }
}

function Test-CollabLockOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$LockId
    )
    $current = Read-CollabLock -DataRoot $DataRoot
    if (-not $current.Held -or $null -eq $current.Lock) { return $false }
    return ([string]$current.Lock.lockId -eq $LockId)
}

function Remove-CollabLock {
    <# Releases the lock only when the caller still holds the exact token. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$LockId
    )
    $current = Read-CollabLock -DataRoot $DataRoot
    if (-not $current.Held) {
        return @{ Ok = $false; Code = 'lock_not_held'; Reasons = @('No lock file is present; nothing to release') }
    }
    if ($null -eq $current.Lock) {
        return @{ Ok = $false; Code = 'lock_unreadable'; Reasons = @('Lock file exists but ownership cannot be verified; refusing to delete') }
    }
    if ([string]$current.Lock.lockId -ne $LockId) {
        return @{ Ok = $false; Code = 'lock_owner_mismatch'; Reasons = @("Lock token mismatch: held '$($current.Lock.lockId)' vs caller '$LockId'") }
    }
    try {
        Remove-Item -LiteralPath $current.Path -Force -ErrorAction Stop
        return @{ Ok = $true; Code = 'released'; Path = $current.Path }
    }
    catch {
        return @{ Ok = $false; Code = 'lock_release_failed'; Reasons = @("Could not remove lock file: $($_.Exception.Message)") }
    }
}

function Get-CollabLockStatus {
    <# Read-only view used by Status/Doctor. Never mutates the lock. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [int]$StaleWarnMinutes = 60
    )
    $guard=Open-CollabRecoveryGuard -DataRoot $DataRoot -Probe
    $recovery=[ordered]@{code=$guard.Code;active=$guard.Active;present=$guard.Present;path=$guard.Path;verified=$guard.Ok -or $guard.Active -eq $true}
    $current = Read-CollabLock -DataRoot $DataRoot
    if (-not $current.Held) {
        return [ordered]@{ held = $false; code = $current.Code; path = $current.Path; recovery=$recovery }
    }
    $lock = $current.Lock
    $status = [ordered]@{
        held           = $true
        recovery       = $recovery
        code           = $current.Code
        path           = $current.Path
        readable       = ($null -ne $lock)
        reasons        = @(Get-CollabPropertyValue -Object $current -Name 'Reasons')
    }
    if ($null -eq $lock) { return $status }

    $ownerPid = [int]$lock.pid
    $ownerStart = $null
    try { $ownerStart = ConvertTo-CollabLockUtcTime $lock.ownerProcessStartTimeUtc } catch { $ownerStart = $null }
    $snapshot = Get-CollabProcessSnapshot
    $alive = $false
    if ($snapshot.Ok -and $null -ne $ownerStart) {
        $alive = Test-CollabSameProcess -ProcessId $ownerPid -CreationTimeUtc $ownerStart -Snapshot $snapshot
    }
    $status['ownerPid'] = $ownerPid
    $status['ownerProcessStartTimeUtc'] = $lock.ownerProcessStartTimeUtc
    $status['ownerTaskId'] = $lock.taskId
    $status['ownerRole'] = $lock.role
    $status['ownerReason'] = $lock.reason
    $status['acquiredAtUtc'] = $lock.acquiredAtUtc
    $status['ownerAlive'] = $alive
    $status['ownerAliveVerified'] = ($snapshot.Ok -and $null -ne $ownerStart)
    $status['probeOk'] = $snapshot.Ok
    $ageMinutes = $null
    try { $ageMinutes = [math]::Round(((Get-CollabUtcNow) - (ConvertTo-CollabLockUtcTime $lock.acquiredAtUtc)).TotalMinutes, 1) } catch { $ageMinutes = $null }
    $status['ageMinutes'] = $ageMinutes
    $status['staleWarning'] = ($null -ne $ageMinutes -and $ageMinutes -gt $StaleWarnMinutes)
    return $status
}

function Invoke-WithCollabLock {
    <# Acquire -> run -> release. Releasing is mandatory: if the lock cannot be
       released the caller fails closed instead of continuing unlocked. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$TaskId = '',
        [string]$Reason = '',
        [string]$Role = 'coordinator',
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $acquire = New-CollabLock -DataRoot $DataRoot -TaskId $TaskId -Reason $Reason -Role $Role
    if (-not $acquire.Ok) { return $acquire }
    $body = $null
    try {
        $body = & $Action $acquire.LockId
    }
    finally {
        $release = Remove-CollabLock -DataRoot $DataRoot -LockId $acquire.LockId
        if (-not $release.Ok) {
            $body = New-CollabOutcome -Ok $false -Code $release.Code -Reasons $release.Reasons
        }
    }
    return $body
}

function Get-CollabSurvivingInvocationProcesses {
    <# Looks for invocation records whose owned process is still alive. Used by
       lock recovery: a live recorded invocation tree refuses recovery. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskRoot)
    $survivors = @()
    $snapshot = Get-CollabProcessSnapshot
    try {
        if (-not (Test-Path -LiteralPath $TaskRoot -ErrorAction Stop)) { return $survivors }
        if (-not (Get-Item -LiteralPath $TaskRoot -Force -ErrorAction Stop).PSIsContainer) { throw 'Task root is not a directory' }
        # Managed records have exactly this depth; nested evidence is not live state.
        # Do not require task.json: missing/corrupt task state must not hide cleanup.
        $files = @(
            foreach ($taskDirectory in @(Get-ChildItem -LiteralPath $TaskRoot -Directory -Force -ErrorAction Stop)) {
                $logs = Join-Path $taskDirectory.FullName 'logs'
                if (-not (Test-Path -LiteralPath $logs -ErrorAction Stop)) { continue }
                if (-not (Get-Item -LiteralPath $logs -Force -ErrorAction Stop).PSIsContainer) { throw 'Task logs is not a directory' }
                foreach ($invocationDirectory in @(Get-ChildItem -LiteralPath $logs -Directory -Force -ErrorAction Stop)) {
                    Get-ChildItem -LiteralPath $invocationDirectory.FullName -Filter 'invocation.json' -Force -ErrorAction Stop
                }
            }
        )
    }
    catch { return @([pscustomobject]@{ invocationId=$TaskRoot; pid=0; verified=$false }) }
    foreach ($file in $files) {
        $read = Read-CollabJson -Path $file.FullName
        if (-not $read.Ok -or $null -eq $read.Value) {
            $survivors += [pscustomobject]@{ invocationId=$file.FullName; pid=0; verified=$false }; continue
        }
        $record = $read.Value
        $invocationId = Get-CollabPropertyValue -Object $record -Name 'invocationId'
        $process = Get-CollabPropertyValue -Object $record -Name 'process'
        # A cleanup label is necessary, but never overrides process evidence.
        # Lock recovery checks process absence; task recovery separately resolves cleanup evidence.
        if ($null -eq $process) {
            $survivors += [pscustomobject]@{ invocationId=$invocationId; pid=0; verified=$false }
            continue
        }
        if ((Get-CollabPropertyValue $process 'Cleanup') -eq 'not_started' -and (Get-CollabPropertyValue $process 'Launched') -eq $false -and -not (Get-CollabPropertyValue $process 'Pid')) { continue }
        $processStart = Get-CollabPropertyValue -Object $process -Name 'ProcessStartTimeUtc'
        if ($null -eq $processStart) { $processStart = Get-CollabPropertyValue -Object $process -Name 'startTimeUtc' }
        $identities = @(@{ pid=(Get-CollabPropertyValue -Object $process -Name 'pid'); start=$processStart })
        $descendants = Get-CollabPropertyValue -Object $process -Name 'Descendants'
        if ($null -eq $descendants -and $null -eq $process.PSObject.Properties['Descendants']) {
            $survivors += [pscustomobject]@{ invocationId=$invocationId; pid=0; verified=$false }
        }
        foreach ($child in $descendants) {
            $identities += @{ pid=(Get-CollabPropertyValue -Object $child -Name 'ProcessId'); start=(Get-CollabPropertyValue -Object $child -Name 'CreationTimeUtc') }
        }
        foreach ($identity in $identities) {
            $processPid = 0
            $created = $null
            $validPid = [int]::TryParse([string]$identity.pid, [ref]$processPid) -and $processPid -gt 0
            try { $created = ConvertTo-CollabLockUtcTime $identity.start } catch { $created = $null }
            if (-not $validPid -or $null -eq $created -or -not $snapshot.Ok) {
                $survivors += [pscustomobject]@{ invocationId=$invocationId; pid=$processPid; verified=$false }
                continue
            }
            # Any present PID refuses: matching live identity, reuse, or unknown identity.
            if (@($snapshot.Items | Where-Object { [int]$_.ProcessId -eq $processPid }).Count -gt 0) {
                $same = Test-CollabSameProcess -ProcessId $processPid -CreationTimeUtc $created -Snapshot $snapshot
                $survivors += [pscustomobject]@{ invocationId=$invocationId; pid=$processPid; verified=$same }
            }
        }
    }
    return @($survivors)
}

function Repair-CollabLock {
    <#
      Explicit lock recovery. Refuses unless: the lock record is complete and
      readable, the recorded owner process is provably gone (pid + creation time),
      no recorded invocation tree survives, the caller repeats the recorded lock
      token, and a human confirmation plus a reason are supplied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskRoot,
        [Parameter(Mandatory)][string]$LockToken,
        [Parameter(Mandatory)][string]$Reason,
        [switch]$Confirm,
        [string]$Actor = 'coordinator'
    )
    if (-not $Confirm) {
        return @{ Ok = $false; Code = 'confirm_required'; Reasons = @('RecoverLock requires -Confirm') }
    }
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return @{ Ok = $false; Code = 'reason_required'; Reasons = @('RecoverLock requires a non-empty -Reason') }
    }
    $guard=Open-CollabRecoveryGuard -DataRoot $DataRoot
    if(-not $guard.Ok){return $guard}
    try {
    $current = Read-CollabLock -DataRoot $DataRoot
    if (-not $current.Held) {
        # A recovery may have crashed after moving project.lock and before the
        # audit append. Repeat the original token to finish that audit step.
        if ($LockToken -notmatch '^[a-fA-F0-9]{32}$') { return @{Ok=$false;Code='lock_token_mismatch';Reasons=@('Repeat a recorded project lock token')} }
        $archive=Join-Path $DataRoot ('locks/recovered-' + $LockToken + '.json')
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            return @{Ok=$true;Code='lock_already_free';RecoveryGuard='available';Reasons=@('No project lock is held; the recovery guard is available')}
        }
        if ((Get-Item -LiteralPath $archive -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovered lock archive must be a regular file' }
        $archived=Read-CollabJson -Path $archive
        if(-not $archived.Ok -or $null -eq $archived.Value -or [string](Get-CollabPropertyValue $archived.Value 'lockId') -ne $LockToken) { throw 'Recovered lock archive is unreadable or has a different identity' }
        $null=Add-CollabAudit -DataRoot $DataRoot -Action 'lock_recovery_reconfirmed' -Actor $Actor -TaskId ([string](Get-CollabPropertyValue $archived.Value 'taskId')) -Detail @{lockId=$LockToken;reason=$Reason;archive=$archive}
        return @{Ok=$true;Code='recovery_reconfirmed';Lock=$archived.Value;Archive=$archive}
    }
    if ($null -eq $current.Lock -or -not $current.Ok) {
        return @{ Ok = $false; Code = 'lock_unreadable'; Reasons = @('Lock ownership is unknown; inspect the lock record before recovery.') }
    }
    $lock = $current.Lock
    if ([string]$lock.lockId -cne $LockToken -or $LockToken -notmatch '^[a-fA-F0-9]{32}$') {
        return @{ Ok = $false; Code = 'lock_token_mismatch'; Reasons = @('Repeated token does not match the recorded lock id') }
    }

    $ownerStart = $null
    try { $ownerStart = ConvertTo-CollabLockUtcTime $lock.ownerProcessStartTimeUtc } catch { $ownerStart = $null }
    if ($null -eq $ownerStart) {
        return @{ Ok = $false; Code = 'lock_owner_unknown'; Reasons = @('Recorded owner creation time is unparseable') }
    }
    $snapshot = Get-CollabProcessSnapshot
    if (-not $snapshot.Ok) {
        return @{ Ok = $false; Code = 'lock_probe_failed'; Reasons = @('Process snapshot unavailable; cannot prove the owner is gone') }
    }
    if (Test-CollabSameProcess -ProcessId ([int]$lock.pid) -CreationTimeUtc $ownerStart -Snapshot $snapshot) {
        return @{ Ok = $false; Code = 'lock_owner_alive'; Reasons = @("Owner pid $($lock.pid) is still alive with the recorded creation time") }
    }
    if (@($snapshot.Items | Where-Object { [int]$_.ProcessId -eq [int]$lock.pid }).Count -gt 0) {
        return @{ Ok=$false; Code='lock_pid_reused'; Reasons=@('Owner PID exists with a different or unknown creation time') }
    }
    $survivors = @(Get-CollabSurvivingInvocationProcesses -TaskRoot $TaskRoot)
    if ($survivors.Count -gt 0) {
        return @{ Ok = $false; Code = 'lock_surviving_processes'; Reasons = @('Recorded invocation process absence is unproven') }
    }
    $latest = Read-CollabLock -DataRoot $DataRoot
    if (-not $latest.Ok -or -not $latest.Held -or $latest.Lock.lockId -cne $LockToken -or $latest.Lock.nonce -cne $lock.nonce) { throw 'Lock changed during recovery' }
    $archive = Join-Path $DataRoot ('locks/recovered-' + $LockToken + '.json')
    [IO.File]::Move($current.Path, $archive, $false)
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'lock_recovered' -Actor $Actor -TaskId ([string]$lock.taskId) -Detail @{
        lockId=[string]$lock.lockId;ownerPid=[int]$lock.pid;ownerStartUtc=$ownerStart.ToString('o');reason=$Reason
    }
    return @{ Ok = $true; Code = 'recovered'; Lock = $lock; Archive=$archive }
    } finally { $guard.Handle.Dispose() }
}
