# Public command regressions. Worker processes are real; scan failures are injected
# after launch to reproduce inaccessible/incomplete inventories deterministically.
$caseDiff=@{added=@();removed=@();modified=@(@{path='A.txt';sha256='frozen-content';previousSha256='old'})}
$caseScope=Get-CollabScopeVerdict -Diff $caseDiff -Task @{allowedPaths=@('product.txt');frozenTests=@(@{path='a.txt';sha256='frozen-content'})} -Config @{}
Check ($caseScope.scopeCheck -eq 'violations' -and $caseScope.violations[0].kind -eq 'scope_write_outside_allowed') 'case-sensitive frozen alias cannot hide an unauthorized write with equal content'
$caseScope=Get-CollabScopeVerdict -Diff $caseDiff -Task @{allowedPaths=@('A.txt');frozenTests=@(@{path='a.txt';sha256='other'})} -Config @{}
Check ($caseScope.scopeCheck -eq 'clean') 'case-sensitive allowed file remains distinct from a frozen case variant'
$protectedConfig=(Get-CollabContext $root).Config|ConvertTo-Json -Depth 32|ConvertFrom-Json
$protectedConfig.protocol.inventory.exclude=@('build/**')
$protectedConfig.protected.workerDenyPaths+=@('build/critical.json')
$rejected=$false
try {$null=New-CollabInventorySnapshot -Root $root -DataRoot $data -Config $protectedConfig} catch {$rejected=$true}
Check $rejected 'generated-directory exclusion rejects a custom protected descendant'

function New-ExceptionalTask([string]$Name,[bool]$Maintenance=$false) {
    $request=@{TaskId=$Name;Grade='ordinary';GradeReason='Exception lifecycle regression';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt')}
    if($Maintenance){$request.Grade='important';$request.Maintenance=$true;$request.AllowedPath+=@('AGENTS.md');$request.PlanFile='collaboration-artifacts/plan.md'}
    $null=Cmd NewTask $request
    if($Maintenance){
        Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Review maintenance plan' -Encoding utf8NoBOM
        $review=Dispatch $Name reviewer plan
        $null=Cmd RecordReview @{TaskId=$Name;SubjectKind='plan';Verdict='PASS';InvocationId=$review.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$review.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=(View $Name).PlanSha256;Findings=@()}
        $null=Cmd Advance @{TaskId=$Name;To='plan_reviewed';Reason='independent plan review'}
    }
    $null=Cmd Backup @{TaskId=$Name}
    $null=Cmd Advance @{TaskId=$Name;To='implementing';Reason='exception fixture'}
}
function Exceptional-Invoke([string]$Name,[string]$Instance) {
    $view=View $Name
    $request=@{TaskId=$Name;Tool='my-worker';Role='executor';InstanceId=$Instance;PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest;WritePaths=@($view.Task.allowedPaths)}
    if($view.Task.grade -eq 'important'){$request.ExpectedPlanSha256=$view.PlanSha256}
    Invoke-CollabCommand Invoke -Root $root -Request $request
}
function Recovery-Request([string]$Name,$Run) {
    $directory=Join-Path $inbox $Name
    $null=New-Item -ItemType Directory -Path $directory -Force
    $proof=Join-Path $directory 'recovery.txt'
    Set-Content -LiteralPath $proof -Value 'Fixture checks recorded process exit and complete baseline restoration.' -Encoding utf8NoBOM
    @{TaskId=$Name;ExpectedRevision=(View $Name).Revision;ExpectedDigest=(View $Name).DiffDigest;InvocationIds=@($Run.invocationId);ViolationIds=@(Get-CollabOpenViolations $data | Where-Object {$_.taskId -ceq $Name} | ForEach-Object {$_.id});EvidencePath="collaboration-artifacts/$Name/recovery.txt";EvidenceSha256=(Get-CollabSha256 $proof);Reason='Verified exception recovery';ProcessVerification='Recorded root and descendants have exited';FileVerification='Restore content and compare complete prelaunch baseline'}
}

$task='preflight-failure'
New-ExceptionalTask $task
$configPath=Join-Path $root '.agents/collaboration/config/collaboration.json'
$configBytes=[IO.File]::ReadAllBytes($configPath)
try {
    $invalid=[Text.Encoding]::UTF8.GetString($configBytes)|ConvertFrom-Json -AsHashtable
    $invalid.protocol.inventory.maxFiles=1
    Json-File $invalid $configPath
    $failure=Exceptional-Invoke $task 'preflight-first'
    Check (-not $failure.Ok -and ($failure.Reasons -join ' ') -match 'Inventory incomplete') 'public Invoke rejects incomplete preflight inventory'
    Check (@(Get-CollabInvocationRecords -DataRoot $data -TaskId $task).Count -eq 0 -and $null -eq (Get-CollabCleanupFlag $data)) 'preflight failure creates no unresolved invocation or cleanup flag'
} finally { [IO.File]::WriteAllBytes($configPath,$configBytes) }
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Implement after corrected preflight' -Encoding utf8NoBOM
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='check recovered configuration'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Configuration corrected; normal workflow completes'}
Check ((View $task).Task.state -eq 'complete') 'preflight configuration correction permits complete workflow without fake process recovery'

$overlap='preflight-overlap'
$null=Cmd NewTask @{TaskId=$overlap;Grade='ordinary';GradeReason='Required exclusion overlap';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='explicit file remains inventoried'});AllowedPath=@('value.txt','coverage/report.json')}
$null=Cmd Backup @{TaskId=$overlap}
$null=Cmd Advance @{TaskId=$overlap;To='implementing';Reason='exercise prelaunch exclusion validation'}
try {
    $invalid=[Text.Encoding]::UTF8.GetString($configBytes)|ConvertFrom-Json -AsHashtable
    $invalid.protocol.inventory.exclude=@('coverage/**')
    Json-File $invalid $configPath
    $failure=Exceptional-Invoke $overlap 'overlap-before-launch'
    Check (-not $failure.Ok -and ($failure.Reasons -join ' ') -match 'cannot be excluded') 'public Invoke rejects task and generated-directory overlap before launch'
    Check (@(Get-CollabInvocationRecords -DataRoot $data -TaskId $overlap).Count -eq 0 -and $null -eq (Get-CollabCleanupFlag $data)) 'overlapping exclusion leaves no incomplete invocation or cleanup blocker'
} finally {[IO.File]::WriteAllBytes($configPath,$configBytes)}

foreach ($fault in @('project','control','maintenance','control-state')) {
    $task="scan-interrupted-$fault"
    New-ExceptionalTask $task ($fault -eq 'maintenance')
    $taskFile=(Get-CollabTaskPaths -DataRoot $data -TaskId $task).TaskFile
    $taskBytes=[IO.File]::ReadAllBytes($taskFile)
    $prompt=if($fault -eq 'maintenance'){'OUTSIDE_WRITE MAINTENANCE_WRITE'}elseif($fault -eq 'control-state'){'OUTSIDE_WRITE TAMPER_TASK'}else{'OUTSIDE_WRITE'}
    Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value $prompt -Encoding utf8NoBOM
    $module=Get-Module Collab
    & $module {
        param($Fault)
        $script:exceptionScanName=if($Fault -eq 'project'){'New-CollabInventorySnapshot'}else{'Get-CollabControlSnapshot'}
        $script:exceptionScanOriginal=(Get-Command $script:exceptionScanName).ScriptBlock
        $script:exceptionScanCount=0
        # Preserve exact public parameters while injecting an actual terminating exception.
        if($Fault -eq 'project') {
            Set-Item Function:script:New-CollabInventorySnapshot {
                param($Root,$DataRoot,$Config,$Label='snapshot',$ExcludePath=@(),$RequiredPath=@())
                $script:exceptionScanCount++
                if($script:exceptionScanCount -eq 2){throw 'Injected postlaunch inventory read failure'}
                & $script:exceptionScanOriginal @PSBoundParameters
            }
        } else {
            Set-Item Function:script:Get-CollabControlSnapshot {
                param($Root,$DataRootRelative,$ExcludePath=@())
                $script:exceptionScanCount++
                if($script:exceptionScanCount -eq 2){throw 'Injected postlaunch control read failure'}
                & $script:exceptionScanOriginal @PSBoundParameters
            }
        }
    } $fault
    try { $failure=Exceptional-Invoke $task "scan-failure-$fault" }
    finally { & $module { Set-Item ("Function:script:"+$script:exceptionScanName) $script:exceptionScanOriginal } }
    $run=@(Get-CollabInvocationRecords -DataRoot $data -TaskId $task | Where-Object {$_.instanceId -ceq "scan-failure-$fault"})[0]
    Check (-not $failure.Ok -and $run.scopeCheck -eq 'pending' -and $run.process.Pid -gt 0) "$fault scan failure persists process identity and unknown scope"
    if($fault -eq 'control-state'){
        Check ($run.stateUpdateError -eq 'task_unreadable' -and $run.process.Cleanup -eq 'verified') 'task state write failure preserves the earlier authoritative process record'
        [IO.File]::WriteAllBytes($taskFile,$taskBytes)
    }
    if ($fault -eq 'project') {
        # Preserve the historical uncertain label so Handoff must use recovery evidence.
        $run.cleanup='uncertain'
        Json-File $run (Join-Path (Split-Path -Parent $run.resultFilePath) 'invocation.json')
    }
    $request=Recovery-Request $task $run
    $blocked=Invoke-CollabCommand RecoverTask -Root $root -Request $request
    Check (-not $blocked.Ok -and ($blocked.Reasons -join ' ') -match 'unexpected.txt') "$fault scan recovery discovers unrecorded out-of-scope mutation"
    Remove-Item -LiteralPath (Join-Path $root 'unexpected.txt')
    $baseline=Join-Path $root $run.baselinePath
    $baselineBytes=[IO.File]::ReadAllBytes($baseline)
    try {
        Set-Content -LiteralPath $baseline -Value '{}' -Encoding utf8NoBOM
        Check (-not (Invoke-CollabCommand RecoverTask -Root $root -Request $request).Ok) "$fault scan recovery rejects changed baseline"
    } finally { [IO.File]::WriteAllBytes($baseline,$baselineBytes) }
    if($fault -eq 'control'){
        & $module {
            $script:originalTransitionForRecovery=(Get-Command Set-CollabTaskState).ScriptBlock
            Set-Item Function:script:Set-CollabTaskState {param($DataRoot,$Task,$To,$Reason) @{Ok=$false;Code='injected_state_write_failure';Reasons=@('Injected state write failure after recovery record')}}
        }
        try {$interruptedRecovery=Invoke-CollabCommand RecoverTask -Root $root -Request $request}
        finally {& $module {Set-Item Function:script:Set-CollabTaskState $script:originalTransitionForRecovery}}
        $pendingRecords=@(Get-CollabRecoveryRecords $data | Where-Object {$_.taskId -ceq $task})
        Check (-not $interruptedRecovery.Ok -and $pendingRecords.Count -eq 1 -and (View $task).Task.state -eq 'failed_closed') 'state write failure after recovery record remains visible and retryable'
    }
    $null=Cmd RecoverTask $request
    if($fault -eq 'control'){
        Check (@(Get-CollabRecoveryRecords $data | Where-Object {$_.taskId -ceq $task}).Count -eq 1) 'interrupted recovery reuses its verified record while finishing the task transition'
    }
    $repeatRecovery=Invoke-CollabCommand RecoverTask -Root $root -Request $request
    Check (-not $repeatRecovery.Ok -and ($repeatRecovery.Reasons -join ' ') -match 'already has effective recovery') "$fault recovery cannot replay an already resolved invocation"
    if($fault -eq 'maintenance'){Check ((Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw) -match 'Maintenance fixture') 'control recovery retains authorized maintenance changes'}
    $null=Cmd Rework @{TaskId=$task;ExpectedRevision=1;ExpectedDigest=(View $task).DiffDigest;Reason='New independent revision after verified scan recovery'}
    # Exercise Handoff after a previously recovered cleanup label.
    Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'FAIL_RESULT' -Encoding utf8NoBOM
    $failedAgain=Exceptional-Invoke $task "normal-failure-$fault"
    Check (-not $failedAgain.Ok -and (View $task).Task.state -eq 'handoff_required') "$fault recovered task can reach ordinary handoff"
    $null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Inspect failed output and continue with fresh instance'}
    Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Implement after handoff' -Encoding utf8NoBOM
    $null=Dispatch $task executor
    $null=Cmd Advance @{TaskId=$task;To='validating';Reason='independent test after handoff'}
    $test=Dispatch $task tester
    $null=Record-FixtureAcceptance $task $test
    if($fault -eq 'maintenance'){
        $review=Dispatch $task reviewer result
        $null=Cmd RecordReview @{TaskId=$task;SubjectKind='result';Verdict='PASS';InvocationId=$review.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$review.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=(View $task).DiffDigest;Findings=@()}
        $null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='independent result review after recovered maintenance'}
    }
    $null=Cmd Complete @{TaskId=$task;Reason='Recovered task handed off and independently verified'}
    Check ((View $task).Task.state -eq 'complete') "$fault scan recovery rework handoff and completion succeed"
}

$task='invocation-self-repair'
New-ExceptionalTask $task
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'TAMPER_RECORD' -Encoding utf8NoBOM
$failure=Exceptional-Invoke $task 'record-tamper'
Check (-not $failure.Ok -and $failure.Record.classification -eq 'policy_violation') 'worker invocation record mutation is detected'
Check (@($failure.Record.repairPaths | Where-Object {$_.path -like '*/invocation.json'}).Count -eq 0 -and $failure.Record.process.Pid -gt 0) 'supervisor rewrites invocation without contradictory self-restoration requirement'
$request=Recovery-Request $task $failure.Record
$null=Cmd RecoverTask $request
Check ((View $task).Task.state -eq 'blocked') 'rewritten authoritative invocation remains recoverable'
