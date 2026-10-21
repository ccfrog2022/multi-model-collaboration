# Collab.Process.ps1 - managed worker launch and process inspection.
# macOS launches are delegated to Collab.Platform and platform_macos.py.
#
# Windows containment contract:
#   1. a Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is created first;
#   2. the child is created SUSPENDED with a hidden window and anonymous-pipe
#      stdio, then assigned to the job, and only then resumed (no launch race);
#   3. if any of the above fails, the tool is never executed (fail closed);
#   4. the owner records pid, process creation time and the invocation id, and
#      never terminates a process it cannot match on pid + creation time;
#   5. cleanup is judged from job accounting plus a process snapshot, and an
#      unverifiable cleanup is reported as "uncertain" (which blocks subsequent calls).

Set-StrictMode -Version 2.0

$script:CollabNativeLoaded = $false
$script:CollabNativeError = ''
if (-not (Test-Path variable:script:CollabNativeSource)) {
    $script:CollabNativeSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'native/Collab.Native.cs'
}

function Initialize-CollabNative {
    <# Compiles native/Collab.Native.cs once per session with Add-Type. #>
    [CmdletBinding()]
    param([string]$SourcePath)

    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $script:CollabNativeSource = $SourcePath
    }
    if ($script:CollabNativeLoaded) { return @{ Ok = $true; Code = 'ok' } }
    if (-not [string]::IsNullOrWhiteSpace($script:CollabNativeError)) {
        return @{ Ok = $false; Code = 'native_unavailable'; Reasons = @($script:CollabNativeError) }
    }
    $path = $script:CollabNativeSource
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path (Split-Path -Parent $script:CollabModuleRoot) 'collaboration/native/Collab.Native.cs'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:CollabNativeError = "Native interop source not found: $path"
        return @{ Ok = $false; Code = 'native_unavailable'; Reasons = @($script:CollabNativeError) }
    }
    try {
        Add-Type -Path $path -ErrorAction Stop
        $script:CollabNativeLoaded = $true
        return @{ Ok = $true; Code = 'ok'; SourcePath = $path }
    }
    catch {
        $script:CollabNativeError = "Add-Type failed for '$path': $($_.Exception.Message)"
        return @{ Ok = $false; Code = 'native_unavailable'; Reasons = @($script:CollabNativeError) }
    }
}

function Get-CollabProcessSnapshot {
    <# One Win32_Process snapshot: pid, parent pid, name, creation time (UTC). #>
    [CmdletBinding()]
    param()
    if ($IsMacOS) {
        try { return Invoke-CollabMacHelper @{operation='snapshot'} }
        catch { return @{Ok=$false;Code='process_query_failed';Reasons=@($_.Exception.Message)} }
    }
    try {
        $rows = Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate -ErrorAction Stop
    }
    catch {
        return @{ Ok = $false; Code = 'process_query_failed'; Reasons = @("Win32_Process query failed: $($_.Exception.Message)") }
    }
    $items = foreach ($row in $rows) {
        $created = $null
        if ($null -ne $row.CreationDate) {
            try { $created = ([datetime]$row.CreationDate).ToUniversalTime() } catch { $created = $null }
        }
        [pscustomobject]@{
            ProcessId       = [int]$row.ProcessId
            ParentProcessId = [int]$row.ParentProcessId
            Name            = [string]$row.Name
            CreationTimeUtc = $created
        }
    }
    return @{ Ok = $true; Code = 'ok'; Items = @($items) }
}

function Get-CollabProcessTree {
    <# Descendants of the given roots, breadth first, from a single snapshot. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$RootProcessId,
        [Parameter(Mandatory)]$Snapshot
    )
    if (-not $Snapshot.Ok) { return @() }
    $byParent = @{}
    foreach ($item in $Snapshot.Items) {
        $key = [int]$item.ParentProcessId
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.Generic.List[object] }
        $byParent[$key].Add($item)
    }
    $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($root in $RootProcessId) {
        if (-not $seen.ContainsKey($root)) {
            $seen[$root] = $true
            $queue.Enqueue([pscustomobject]@{ ProcessId = $root; Depth = 0 })
        }
    }
    $result = New-Object System.Collections.Generic.List[object]
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $byParent.ContainsKey([int]$current.ProcessId)) { continue }
        foreach ($child in $byParent[[int]$current.ProcessId]) {
            if ($seen.ContainsKey([int]$child.ProcessId)) { continue }
            $seen[[int]$child.ProcessId] = $true
            $result.Add([pscustomobject]@{
                    ProcessId       = [int]$child.ProcessId
                    ParentProcessId = [int]$child.ParentProcessId
                    Name            = [string]$child.Name
                    CreationTimeUtc = $child.CreationTimeUtc
                    Depth           = [int]$current.Depth + 1
                })
            $queue.Enqueue([pscustomobject]@{ ProcessId = [int]$child.ProcessId; Depth = [int]$current.Depth + 1 })
        }
    }
    return $result.ToArray()
}

function Test-CollabSameProcess {
    <# PID-reuse guard: the recorded pid must still carry the recorded creation
       time (2 second tolerance for CIM rounding). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [AllowNull()]$CreationTimeUtc,
        [Parameter(Mandatory)]$Snapshot
    )
    if (-not $Snapshot.Ok) { return $false }
    foreach ($item in $Snapshot.Items) {
        if ([int]$item.ProcessId -ne $ProcessId) { continue }
        if ($null -eq $CreationTimeUtc -or $null -eq $item.CreationTimeUtc) { return $false }
        $delta = [math]::Abs((([datetime]$item.CreationTimeUtc) - ([datetime]$CreationTimeUtc)).TotalSeconds)
        return ($delta -le $(if ($IsWindows) {2} else {0.000001}))
    }
    return $false
}

function Get-CollabCleanupVerdict {
    <#
      Pure decision function so tests can exercise every branch without processes.
      aliveRecorded: recorded processes still alive with a matching creation time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$QueryOk,
        [AllowEmptyCollection()][array]$AliveRecorded = @(),
        [bool]$JobAccountingOk = $false,
        [int]$JobActiveProcesses = 0,
        [bool]$JobClosed = $false,
        [int]$UnverifiedRecordedCount = 0
    )
    if (-not $QueryOk) {
        return @{ Cleanup = 'uncertain'; Reason = 'process snapshot unavailable; ownership cannot be proven' }
    }
    if ($UnverifiedRecordedCount -gt 0) {
        return @{ Cleanup = 'uncertain'; Reason = "$UnverifiedRecordedCount recorded process(es) had no creation timestamp" }
    }
    if (@($AliveRecorded).Count -gt 0) {
        $ids = (@($AliveRecorded) | ForEach-Object { $_.ProcessId }) -join ','
        return @{ Cleanup = 'failed'; Reason = "owned process(es) still alive after shutdown: $ids" }
    }
    if ($JobAccountingOk -and $JobActiveProcesses -gt 0) {
        return @{ Cleanup = 'failed'; Reason = "job object still reports $JobActiveProcesses active process(es)" }
    }
    if (-not $JobAccountingOk) {
        return @{ Cleanup = 'uncertain'; Reason = 'job accounting unavailable; closing a job is not proof of cleanup' }
    }
    return @{ Cleanup = 'verified'; Reason = 'no owned process remains (snapshot + job accounting)' }
}

function Stop-CollabOwnedProcess {
    <# Terminates a recorded descendant by pid only after re-verifying the
       creation time, so a reused pid can never be killed. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [AllowNull()]$CreationTimeUtc,
        [Parameter(Mandatory)]$Snapshot
    )
    if (-not (Test-CollabSameProcess -ProcessId $ProcessId -CreationTimeUtc $CreationTimeUtc -Snapshot $Snapshot)) {
        return @{ Ok = $false; Action = 'skipped'; Reason = "pid $ProcessId does not match the recorded process (absent or reused)" }
    }
    try {
        $nativeError = ''
        if (-not [Collab.Interop.Native]::TerminateOwned($ProcessId, ([datetime]$CreationTimeUtc).ToUniversalTime(), [ref]$nativeError)) { throw $nativeError }
        return @{ Ok = $true; Action = 'terminated'; Reason = "pid $ProcessId terminated" }
    }
    catch {
        return @{ Ok = $false; Action = 'failed'; Reason = "Stop-Process failed for pid ${ProcessId}: $($_.Exception.Message)" }
    }
}

function New-CollabStreamReader {
    <# Incremental reader with secret redaction and a carry buffer, so a secret
       split across two reads is still redacted before it is written to disk. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$SinkPath
    )
    $directory = Split-Path -Parent $SinkPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Set-Content -LiteralPath $SinkPath -Value '' -Encoding utf8NoBOM
    return [pscustomobject]@{
        SourcePath = $SourcePath
        SinkPath   = $SinkPath
        Position   = [long]0
        Carry      = ''
        Redactions = 0
        LastWrite  = $null
        Bytes      = [long]0
    }
}

function Read-CollabStreamDelta {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Reader)

    if (-not (Test-Path -LiteralPath $Reader.SourcePath)) { return }
    try {
        $stream = [System.IO.File]::Open($Reader.SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    }
    catch {
        return
    }
    try {
        if ($stream.Length -le $Reader.Position) { return }
        [void]$stream.Seek($Reader.Position, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ([int][math]::Min(262144, $stream.Length - $Reader.Position))
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $Reader.Position = $stream.Position
        $Reader.Bytes += $read
    }
    finally {
        $stream.Dispose()
    }
    if ($read -le 0) { return }

    $text = $Reader.Carry + [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    $lastNewline = $text.LastIndexOf("`n")
    if ($lastNewline -ge 0) {
        $complete = $text.Substring(0, $lastNewline + 1)
        $Reader.Carry = $text.Substring($lastNewline + 1)
    }
    else {
        $complete = ''
        $Reader.Carry = $text
    }
    if ($Reader.Carry.Length -gt 1048576) {
        $complete += $Reader.Carry
        $Reader.Carry = ''
    }
    if ($complete.Length -eq 0) {
        $Reader.LastWrite = Get-CollabUtcNow
        return
    }
    $redacted = Protect-CollabSecret -Text $complete
    $Reader.Redactions += $redacted.Count
    [System.IO.File]::AppendAllText($Reader.SinkPath, $redacted.Text, [System.Text.UTF8Encoding]::new($false))
    $Reader.LastWrite = Get-CollabUtcNow
}

function Complete-CollabStreamReader {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Reader)
    Read-CollabStreamDelta -Reader $Reader
    if ($Reader.Carry.Length -gt 0) {
        $redacted = Protect-CollabSecret -Text $Reader.Carry
        $Reader.Redactions += $redacted.Count
        [System.IO.File]::AppendAllText($Reader.SinkPath, $redacted.Text, [System.Text.UTF8Encoding]::new($false))
        $Reader.Carry = ''
    }
}

function Invoke-CollabMacProcess {
    <# Keep proven pre-helper failures recoverable while preserving uncertain
       launch outcomes as unknown for the managed invocation's recovery gate. #>
    param([Parameter(Mandatory)][hashtable]$Request)
    $started = Get-CollabUtcNow
    try { return Invoke-CollabMacHelper -Request $Request }
    catch {
        if ($_.Exception.Data['CollabMacHelperLaunchState'] -cne 'not_started') { throw }
        $ended = Get-CollabUtcNow
        return [ordered]@{
            InvocationId=$Request.InvocationId; ExePath=$Request.ExePath
            Arguments=@($Request.Arguments); WorkingDirectory=$Request.WorkingDirectory
            LogDirectory=$Request.LogDirectory; Pid=$null; ProcessStartTimeUtc=$null
            Launched=$false; ExitCode=$null; RootExited=$false
            TimedOut=$false; IdleTimedOut=$false; ForcedTermination=$false
            GracefulWaitSeconds=$Request.GracefulSeconds
            Descendants=@(); DescendantCount=0
            Cleanup='not_started'; CleanupDetail='macOS supervisor helper did not start'
            Redactions=0; StdoutPath=$null; StderrPath=$null; ResultFile=$null
            StartedAtUtc=(Format-CollabTime $started); EndedAtUtc=(Format-CollabTime $ended)
            DurationMs=[int]($ended-$started).TotalMilliseconds
            Errors=@($_.Exception.Message); Ok=$false
        }
    }
}

function Invoke-CollabProcess {
    <#
      Runs one tool invocation inside a Job Object. Returns a structured record;
      "Ok" only reports that the runner itself worked. Whether the tool's answer
      is acceptable is decided by Collab.Parser.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$InvocationId,
        [int]$TotalTimeoutSeconds = 900,
        [int]$IdleTimeoutSeconds = 240,
        [int]$GracefulSeconds = 10,
        [int]$ForceSeconds = 20,
        [int]$PollMilliseconds = 500,
        [string]$ResultFileName = 'result.txt'
    )

    if ($IsMacOS) {
        $request = @{}
        foreach ($key in $PSBoundParameters.Keys) { $request[$key] = $PSBoundParameters[$key] }
        $request.operation='run'; $request.TotalTimeoutSeconds=$TotalTimeoutSeconds
        $request.IdleTimeoutSeconds=$IdleTimeoutSeconds; $request.GracefulSeconds=$GracefulSeconds; $request.ForceSeconds=$ForceSeconds
        return Invoke-CollabMacProcess -Request $request
    }
    if (-not $IsWindows) { throw 'Supported platforms: Windows and macOS' }
    $startedAt = Get-CollabUtcNow
    $record = [ordered]@{
        InvocationId        = $InvocationId
        ExePath             = $ExePath
        Arguments           = @($Arguments)
        WorkingDirectory    = $WorkingDirectory
        LogDirectory        = $LogDirectory
        Pid                 = $null
        ProcessStartTimeUtc = $null
        JobCreated          = $false
        JobAssigned         = $false
        Launched            = $false
        ExitCode            = $null
        RootExited          = $false
        TimedOut            = $false
        IdleTimedOut        = $false
        ForcedTermination   = $false
        GracefulWaitSeconds = $GracefulSeconds
        Descendants         = @()
        DescendantCount     = 0
        JobTotalProcesses   = $null
        JobActiveAtExit     = $null
        JobAccountingOk     = $false
        JobClosed           = $false
        Cleanup             = 'not_started'
        CleanupDetail       = ''
        Redactions          = 0
        StdoutPath          = $null
        StderrPath          = $null
        ResultFile          = $null
        StartedAtUtc        = Format-CollabTime -Time $startedAt
        EndedAtUtc          = $null
        DurationMs          = $null
        Errors              = @()
        Ok                  = $false
    }

    $job = [IntPtr]::Zero
    $launch = $null
    $descendants = @{}
    $runnerFailed = $false
    try {
        $native = Initialize-CollabNative
        if (-not $native.Ok) { throw ($native.Reasons -join '; ') }
        [void][System.IO.Directory]::CreateDirectory($LogDirectory)
        $record.StdoutPath = Join-Path $LogDirectory 'stdout.log'
        $record.StderrPath = Join-Path $LogDirectory 'stderr.log'
        $record.ResultFile = Join-Path $LogDirectory $ResultFileName
        $nativeEnvironment = [System.Collections.Generic.Dictionary[string,string]]::new()
        foreach ($key in $Environment.Keys) { $nativeEnvironment[[string]$key] = [string]$Environment[$key] }
        $nativeError = ''
        $job = [Collab.Interop.Native]::CreateKillOnCloseJob([ref]$nativeError)
        if ($job -eq [IntPtr]::Zero) { throw "job creation failed: $nativeError" }
        $record.JobCreated = $true
        $launch = [Collab.Interop.Native]::StartSuspended($ExePath, $Arguments, $WorkingDirectory, $nativeEnvironment, $record.StdoutPath, $record.StderrPath)
        if (-not $launch.Ok) { throw $launch.Error }
        $record.Pid = $launch.ProcessId
        if ($null -ne $launch.CreationTimeUtc) { $record.ProcessStartTimeUtc = Format-CollabTime $launch.CreationTimeUtc }
        if (-not [Collab.Interop.Native]::AssignToJob($job, $launch.ProcessHandle, [ref]$nativeError)) { throw "job assignment failed: $nativeError" }
        $record.JobAssigned = $true
        if (-not [Collab.Interop.Native]::Resume($launch.ThreadHandle, [ref]$nativeError)) { throw "resume failed: $nativeError" }
        $record.Launched = $true
        $lastActivity = Get-CollabUtcNow
        $lastOutputBytes = $launch.OutputBytes
        $lastTreeScan = [datetime]::MinValue
        while ($true) {
            $bytesBefore = $lastOutputBytes
            $wait = [Collab.Interop.Native]::WaitFor($launch.ProcessHandle, 0)
            $now = Get-CollabUtcNow
            if ($launch.OutputBytes -gt $bytesBefore) { $lastActivity = $now }; $lastOutputBytes=$launch.OutputBytes
            if ($wait -eq 'error') { throw 'native process wait failed' }
            if ($wait -eq 'signaled') { break }
            if (($now - $startedAt).TotalSeconds -ge $TotalTimeoutSeconds) { $record.TimedOut = $true; break }
            if (($now - $lastActivity).TotalSeconds -ge $IdleTimeoutSeconds) { $record.IdleTimedOut = $true; break }
            if (($now - $lastTreeScan).TotalSeconds -ge 2) {
                $snapshot = Get-CollabProcessSnapshot
                $lastTreeScan = $now
                if (Test-CollabSameProcess -ProcessId $launch.ProcessId -CreationTimeUtc $launch.CreationTimeUtc -Snapshot $snapshot) {
                    foreach ($child in @(Get-CollabProcessTree -RootProcessId @($launch.ProcessId) -Snapshot $snapshot)) {
                        $key = "$($child.ProcessId):$($child.CreationTimeUtc)"
                        $descendants[$key] = $child
                    }
                }
            }
            Start-Sleep -Milliseconds ([math]::Max(10, $PollMilliseconds))
        }
    }
    catch {
        $runnerFailed = $true
        $record.Errors += (Protect-CollabSecret -Text $_.Exception.Message).Text
    }
    finally {
        try {
            if ($job -ne [IntPtr]::Zero) {
                # Give owned applications a bounded opportunity to exit. Hidden CLI
                # processes have no console control channel; GUI roots may close.
                $nativeError = ''
                if ($null -ne $launch -and $launch.Ok -and -not $record.JobAssigned) {
                    if (-not [Collab.Interop.Native]::Terminate($launch.ProcessHandle, 31, [ref]$nativeError)) { throw $nativeError }
                    if ([Collab.Interop.Native]::WaitFor($launch.ProcessHandle, 5000) -ne 'signaled') { throw 'unassigned suspended child termination unverified' }
                }
                $accounting = [Collab.Interop.Native]::QueryJob($job)
                $graceDeadline = (Get-CollabUtcNow).AddSeconds([math]::Max(0,$GracefulSeconds))
                if ($record.Launched -and $GracefulSeconds -gt 0 -and $null -ne $launch.CreationTimeUtc) {
                    $rootProcess = $null
                    try {
                        $rootProcess = [Diagnostics.Process]::GetProcessById($launch.ProcessId)
                        if ($rootProcess.StartTime.ToUniversalTime() -eq $launch.CreationTimeUtc -and $rootProcess.MainWindowHandle -ne [IntPtr]::Zero) { [void]$rootProcess.CloseMainWindow() }
                    } catch { } finally { if ($null -ne $rootProcess) { $rootProcess.Dispose() } }
                }
                while ($accounting.Ok -and $accounting.ActiveProcesses -gt 0 -and (Get-CollabUtcNow) -lt $graceDeadline) {
                    if ($null -ne $launch -and $launch.Ok) { [Collab.Interop.Native]::DrainOutput($launch, $false) }
                    Start-Sleep -Milliseconds 50
                    $accounting = [Collab.Interop.Native]::QueryJob($job)
                }
                if (-not $accounting.Ok -or $accounting.ActiveProcesses -gt 0) {
                    $record.ForcedTermination = $true
                    if (-not [Collab.Interop.Native]::TerminateJob($job, 42, [ref]$nativeError)) { throw $nativeError }
                }
                $deadline = (Get-CollabUtcNow).AddSeconds([math]::Max(1,$ForceSeconds))
                do {
                    if ($null -ne $launch -and $launch.Ok) { [Collab.Interop.Native]::DrainOutput($launch, $false) }
                    $accounting = [Collab.Interop.Native]::QueryJob($job)
                    if ($accounting.Ok -and $accounting.ActiveProcesses -eq 0) { break }
                    Start-Sleep -Milliseconds 50
                } while ((Get-CollabUtcNow) -lt $deadline)
                $record.JobAccountingOk = $accounting.Ok
                if ($accounting.Ok) { $record.JobTotalProcesses = $accounting.TotalProcesses; $record.JobActiveAtExit = $accounting.ActiveProcesses }
                $record.Cleanup = if ($accounting.Ok -and $accounting.ActiveProcesses -eq 0) { 'verified' } else { 'uncertain' }
                $record.CleanupDetail = if ($record.Cleanup -eq 'verified') { 'retained job handle reports zero active members after shutdown' } else { 'no zero-active accounting proof; cleanup not certified' }
                if ($null -ne $launch -and $launch.Ok) {
                    $exitCode = 0
                    if ([Collab.Interop.Native]::WaitFor($launch.ProcessHandle, 1000) -eq 'signaled' -and [Collab.Interop.Native]::TryGetExitCode($launch.ProcessHandle, [ref]$exitCode)) { $record.ExitCode = $exitCode; $record.RootExited = $true }
                    [Collab.Interop.Native]::DrainOutput($launch, $true)
                    $record.Redactions = $launch.Redactions
                }
            } else {
                $record.Cleanup = 'not_started'
                $record.CleanupDetail = 'no child was created'
            }
        }
        catch {
            $runnerFailed = $true
            $record.Errors += (Protect-CollabSecret -Text $_.Exception.Message).Text
            $record.Cleanup = 'uncertain'
            $record.CleanupDetail = 'cleanup exception; no cleanup certification'
        }
        finally {
            # Kill-on-close is the last safety net, never used as accounting proof.
            if ($job -ne [IntPtr]::Zero) { [Collab.Interop.Native]::Close($job); $record.JobClosed = $true }
            if ($null -ne $launch -and $launch.Ok) {
                try { [Collab.Interop.Native]::Close($launch.ProcessHandle) }
                catch { $runnerFailed = $true; $record.Errors += (Protect-CollabSecret -Text $_.Exception.Message).Text }
                finally { [Collab.Interop.Native]::Close($launch.ThreadHandle) }
            }
            $record.Descendants = @($descendants.Values)
            $record.DescendantCount = $descendants.Count
            $record.EndedAtUtc = Format-CollabTime (Get-CollabUtcNow)
            $record.DurationMs = [long](((Get-CollabUtcNow) - $startedAt).TotalMilliseconds)
            $record.Ok = (-not $runnerFailed -and $record.RootExited -and $record.Cleanup -eq 'verified')
        }
    }
    return $record
}
