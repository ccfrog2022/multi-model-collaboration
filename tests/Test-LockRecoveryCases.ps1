# Uses Bootstrap / Check from Test-Package. Every child is task-owned.
$lockRoot=Join-Path $ScratchRoot 'lock-recovery'
$null=Bootstrap $lockRoot 'lock-recovery'
$lockData=Join-Path $lockRoot '.collaboration'
$lockDirectory=Join-Path $lockData 'locks'
$null=New-Item -ItemType Directory -Path $lockDirectory -Force
$guardPath=Join-Path $lockDirectory 'recovery.lock'
[IO.File]::WriteAllText($guardPath,'')
$legacy=New-CollabLock -DataRoot $lockData -Reason 'legacy empty recovery marker'
Check $legacy.Ok 'legacy recovery marker does not block new project lock acquisition'
$alive=Invoke-CollabCommand RecoverLock -Root $lockRoot -Request @{LockToken=$legacy.LockId;Reason='Verify live owner identity';Confirm=$true}
Check (-not $alive.Ok -and $alive.Code -eq 'lock_owner_alive') 'public recovery preserves a live project lock owner'
$mismatch=Invoke-CollabCommand RecoverLock -Root $lockRoot -Request @{LockToken=('0'*32);Reason='Token mismatch';Confirm=$true}
Check (-not $mismatch.Ok -and $mismatch.Code -eq 'lock_token_mismatch') 'public recovery verifies the exact project lock token'
$null=Remove-CollabLock -DataRoot $lockData -LockId $legacy.LockId
$orphan=Invoke-CollabCommand RecoverLock -Root $lockRoot -Request @{LockToken=$legacy.LockId;Reason='Recover an orphan legacy marker';Confirm=$true}
Check ($orphan.Ok -and $orphan.Code -eq 'lock_already_free') 'public recovery handles a legacy guard with no remaining project lock'

$holderScript=Join-Path $ScratchRoot 'hold-recovery-guard.ps1'
@'
param($ModulePath,$DataRoot,$ReadyPath)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force -DisableNameChecking
$owned=New-CollabLock -DataRoot $DataRoot -Reason 'Crash fixture owner'
if(-not $owned.Ok){throw $owned.Code}
$guard=Open-CollabRecoveryGuard -DataRoot $DataRoot
if(-not $guard.Ok){throw $guard.Code}
try {
    [IO.File]::WriteAllText($ReadyPath,($owned.Lock | ConvertTo-Json -Depth 8))
    [Threading.Thread]::Sleep(60000)
} finally {$guard.Handle.Dispose()}
'@ | Set-Content -LiteralPath $holderScript -Encoding utf8NoBOM
$readyPath=Join-Path $ScratchRoot 'recovery-guard-ready.json'
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=(Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
foreach($argument in @('-NoProfile','-File',$holderScript,(Join-Path $lockRoot 'scripts/collaboration/Collab.psm1'),$lockData,$readyPath)){$start.ArgumentList.Add($argument)}
$holder=[Diagnostics.Process]::Start($start)
try {
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    while(-not (Test-Path -LiteralPath $readyPath) -and -not $holder.HasExited -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    Check (Test-Path -LiteralPath $readyPath) 'task-owned crash fixture acquired recovery guard'
    $owned=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json
    $beforeHash=Get-CollabSha256 (Join-Path $lockDirectory 'project.lock')
    $status=Invoke-CollabCommand Status -Root $lockRoot
    Check ($status.Ok -and $status.Lock.recovery.active -eq $true) 'Status exposes an active recovery guard'
    $busy=Invoke-CollabCommand RecoverLock -Root $lockRoot -Request @{LockToken=$owned.lockId;Reason='Concurrent recovery contender';Confirm=$true}
    Check (-not $busy.Ok -and $busy.Code -eq 'recovery_in_progress') 'public recovery cannot race an active recovery handle'
    $contender=New-CollabLock -DataRoot $lockData -Reason 'Concurrent project lock contender'
    Check (-not $contender.Ok -and $contender.Code -eq 'recovery_in_progress') 'new project lock acquisition uses the same recovery mutex'
    Check ((Get-CollabSha256 (Join-Path $lockDirectory 'project.lock')) -eq $beforeHash -and (Test-Path -LiteralPath $guardPath)) 'losing contenders preserve both lock files'
    # Simulate abrupt owner death without executing its finally.
    $holder.Kill();$holder.WaitForExit()
    Check $holder.HasExited 'task-owned crash fixture exited'
    $status=Invoke-CollabCommand Status -Root $lockRoot
    Check ($status.Lock.recovery.active -eq $false -and $status.Lock.recovery.present) 'OS releases guard ownership after crash while the stable file remains'
    $repair=Invoke-CollabCommand RecoverLock -Root $lockRoot -Request @{LockToken=$owned.lockId;Reason='Recover after owned crash fixture exited';Confirm=$true}
    Check ($repair.Ok -and $repair.Code -eq 'recovered') 'public RecoverLock succeeds after a crashed recovery owner'
    Check ((Get-CollabSha256 $repair.Archive) -eq $beforeHash) 'recovery preserves the exact original project lock archive'
    # Construct the crash window after archive move but before audit append.
    $auditPath=Join-Path $lockData 'audit.jsonl'
    [IO.File]::WriteAllText($auditPath,'')
    $repeat=Invoke-CollabCommand RecoverLock -Root $lockRoot -Request @{LockToken=$owned.lockId;Reason='Retry after project lock was archived';Confirm=$true}
    Check ($repeat.Ok -and $repeat.Code -eq 'recovery_reconfirmed') 'public RecoverLock resumes the already archived recovery outcome'
    Check ((Get-Content -LiteralPath $auditPath -Raw) -match 'lock_recovery_reconfirmed') 'archive-only recovery retry appends an explicit audit event'
    $guardOne=Open-CollabRecoveryGuard $lockData
    try {
        $guardTwo=Open-CollabRecoveryGuard $lockData
        Check (-not $guardTwo.Ok) 'second guard owner fails without deleting the first guard'
    } finally {$guardOne.Handle.Dispose()}
    Check (Test-Path -LiteralPath $guardPath) 'guard release retains a stable mutex path'
    $next=New-CollabLock -DataRoot $lockData -Reason 'post recovery acquisition'
    try {
        Check $next.Ok 'normal project lock acquisition works after crash recovery'
        $oldRetry=Invoke-CollabCommand RecoverLock -Root $lockRoot -Request @{LockToken=$owned.lockId;Reason='Old recovery token after new acquisition';Confirm=$true}
        Check (-not $oldRetry.Ok -and $oldRetry.Code -eq 'lock_token_mismatch' -and (Test-CollabLockOwnership $lockData $next.LockId)) 'old recovery retry cannot change a newly acquired project lock'
    } finally {if($next.Ok){$null=Remove-CollabLock -DataRoot $lockData -LockId $next.LockId}}
} finally {
    if(-not $holder.HasExited){$holder.Kill();$holder.WaitForExit()}
    $holder.Dispose()
}

$rollbackLockRoot=Join-Path $ScratchRoot 'lock-rollback'
$rollbackLockSetup=Bootstrap $rollbackLockRoot 'lock-rollback'
$rollbackLockData=Join-Path $rollbackLockRoot '.collaboration'
$rollbackGuard=Open-CollabRecoveryGuard $rollbackLockData
try {
    $refused=& pwsh -NoProfile -File (Join-Path $package 'scripts/Initialize-Project.ps1') -Root $rollbackLockRoot -Mode Rollback -BackupDirectory $rollbackLockSetup.backup -Confirm
    Check ($LASTEXITCODE -ne 0 -and -not ($refused|ConvertFrom-Json).Ok) 'initializer rollback rejects an active recovery guard'
    Check (Test-Path -LiteralPath (Join-Path $rollbackLockRoot 'AGENTS.md')) 'refused rollback preserves installed files'
} finally {$rollbackGuard.Handle.Dispose()}
$rolledBack=& pwsh -NoProfile -File (Join-Path $package 'scripts/Initialize-Project.ps1') -Root $rollbackLockRoot -Mode Rollback -BackupDirectory $rollbackLockSetup.backup -Confirm
Check ($LASTEXITCODE -eq 0 -and ($rolledBack|ConvertFrom-Json).Ok) 'initializer rollback accepts an available persistent guard'
Check ((Test-Path -LiteralPath (Join-Path $rollbackLockData 'locks/recovery.lock')) -and -not (Test-Path -LiteralPath (Join-Path $rollbackLockRoot 'AGENTS.md'))) 'rollback preserves stable guard infrastructure and restores absent files'
