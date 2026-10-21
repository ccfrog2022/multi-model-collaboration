# Invoked by Test-Package.ps1 in its isolated project fixture.
function Record-FixtureReview([string]$Task,[string]$Subject='result',[string]$Verdict='PASS') {
    $review=Dispatch $Task reviewer $Subject
    $view=View $Task
    $hash=if($Subject -eq 'plan'){$view.PlanSha256}else{$view.DiffDigest}
    $null=Cmd RecordReview @{TaskId=$Task;SubjectKind=$Subject;Verdict=$Verdict;InvocationId=$review.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$review.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=$hash;Findings=@()}
    return $review
}
function Record-FixtureAcceptance([string]$Task,$Test,[string]$Kind='acceptance') {
    return Cmd RecordAcceptance @{TaskId=$Task;AcceptanceId='A1';Status='passed';Kind=$Kind;EvidencePath=[IO.Path]::GetRelativePath($root,$Test.Record.resultFilePath).Replace('\','/');Note='Fixture operator checked current value and result'}
}
Set-Content -LiteralPath (Join-Path $root 'value.txt') -Value '0' -Encoding utf8NoBOM
$task='revision-loop'
$null=Cmd NewTask @{TaskId=$task;Grade='important';GradeReason='Revision acceptance regression';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt');FrozenTest=@('frozen.txt');PlanFile='collaboration-artifacts/plan.md';RequiresRealWorkflow=$true}
$null=Record-FixtureReview $task plan
$null=Cmd Advance @{TaskId=$task;To='plan_reviewed';Reason='plan accepted'}
$originalBackup=Cmd Backup @{TaskId=$task}
$backupHash=Get-CollabSha256 $originalBackup.Path
$null=Cmd Advance @{TaskId=$task;To='implementing';Reason='implement'}
$execution=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='test independently'}
Set-Content -LiteralPath (Join-Path $inbox 'reference.txt') -Value ('reference background ' * 2000) -Encoding utf8NoBOM
$view=View $task
$pack=Cmd PrepareContext @{TaskId=$task;Role='tester';ExpectedRevision=$view.Revision;ExpectedDigest=$view.DiffDigest;PromptFile='collaboration-artifacts/prompt.txt';References=@('value.txt','collaboration-artifacts/reference.txt');PriorInvocationIds=@($execution.Record.invocationId);Delta='Implementation ready; inspect the current value and boundaries.'}
Check (([IO.File]::ReadAllText($pack.PromptPath).Length) -lt (Get-Item -LiteralPath (Join-Path $inbox 'reference.txt')).Length) 'context references large source without copying its contents'
$contextRequest=@{TaskId=$task;Tool='my-worker';Role='tester';InstanceId='context-tester';ContextId=$pack.ContextId;ExpectedDigest=$view.DiffDigest;ExpectedRevision=$view.Revision;ExpectedPlanSha256=$view.PlanSha256}
$oldText=[IO.File]::ReadAllText((Join-Path $inbox 'reference.txt'))
[IO.File]::WriteAllText((Join-Path $inbox 'reference.txt'),'changed reference')
$stale=Invoke-CollabCommand Invoke -Root $root -Request $contextRequest
Check (-not $stale.Ok -and ($stale.Reasons -join ' ') -match 'reference changed') 'changed referenced source invalidates context'
[IO.File]::WriteAllText((Join-Path $inbox 'reference.txt'),$oldText)
$test=Cmd Invoke $contextRequest
Check ($test.Record.contextId -eq $pack.ContextId) 'managed invocation consumes bound context'
$null=Record-FixtureAcceptance $task $test real_workflow
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'FAIL_REVIEW' -Encoding utf8NoBOM
$failedReview=Record-FixtureReview $task result FAIL
Check ((View $task).Task.state -eq 'blocked') 'result FAIL blocks current revision'
$before=View $task
$originalCopy=([IO.File]::ReadAllText($originalBackup.Path)|ConvertFrom-Json).originals[0].backupFile
$originalBytes=[IO.File]::ReadAllBytes($originalCopy)
try {
    [IO.File]::WriteAllText($originalCopy,'damaged fixture backup')
    $invalid=Invoke-CollabCommand Rework -Root $root -Request @{TaskId=$task;ExpectedRevision=$before.Revision;ExpectedDigest=$before.DiffDigest;Reason='Corrupt backup regression'}
    Check (-not $invalid.Ok) 'rework still rejects a damaged original backup'
} finally { [IO.File]::WriteAllBytes($originalCopy,$originalBytes) }
$bad=Invoke-CollabCommand Rework -Root $root -Request @{TaskId=$task;ExpectedRevision=999;ExpectedDigest=$before.DiffDigest;Reason='Fix review finding'}
Check (-not $bad.Ok) 'stale rework revision rejected'
$null=Cmd Rework @{TaskId=$task;ExpectedRevision=$before.Revision;ExpectedDigest=$before.DiffDigest;Reason='Correct the independently reported result finding'}
$view=View $task
Check ($view.Revision -eq 2 -and $view.PlanRevision -eq 1 -and $view.Task.state -eq 'implementing') 'result rework retains approved plan within the same task'
Check ($view.Task.acceptance[0].status -eq 'pending' -and @($view.Task.acceptance[0].evidence).Count -eq 0 -and -not $view.Task.realWorkflowVerified) 'rework invalidates acceptance and real workflow proof'
Check ((Get-CollabSha256 $originalBackup.Path) -eq $backupHash -and (Test-Path -LiteralPath $failedReview.Path)) 'rework preserves original backup and previous invocation evidence'
Check (-not (Invoke-CollabCommand Advance -Root $root -Request @{TaskId=$task;To='validating';Reason='reuse old execution'}).Ok) 'old executor cannot advance new revision'
$oldReview=Invoke-CollabCommand RecordReview -Root $root -Request @{TaskId=$task;SubjectKind='result';Verdict='FAIL';InvocationId=$failedReview.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$failedReview.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=$view.DiffDigest}
Check (-not $oldReview.Ok -and $oldReview.Code -eq 'review_revision_stale') 'old review cannot be registered in the new revision even with the same digest'
$replay=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath=[IO.Path]::GetRelativePath($root,$test.Record.resultFilePath).Replace('\','/')}
Check (-not $replay.Ok) 'old acceptance artifact cannot be relabeled as current evidence'
if ($IsWindows) {
    $alias=[IO.Path]::GetRelativePath($root,$test.Record.resultFilePath).Replace('\','/').ToUpperInvariant()
    $replay=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath=$alias}
    Check (-not $replay.Ok) 'Windows case alias cannot relabel old evidence'
}
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Perform current revision' -Encoding utf8NoBOM
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='new implementation'}
$view=View $task
$contextRequest.ExpectedRevision=$view.Revision; $contextRequest.ExpectedDigest=$view.DiffDigest; $contextRequest.InstanceId='stale-context-tester'
$stale=Invoke-CollabCommand Invoke -Root $root -Request $contextRequest
Check (-not $stale.Ok -and ($stale.Reasons -join ' ') -match 'Context is stale') 'context from previous revision cannot be reused'
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test real_workflow
Check (-not (Invoke-CollabCommand Advance -Root $root -Request @{TaskId=$task;To='result_reviewed';Reason='reuse review'}).Ok) 'new revision requires fresh result review'
$null=Record-FixtureReview $task result
$null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='fresh result review'}
$null=Cmd Complete @{TaskId=$task;Reason='rework independently tested and reviewed'}
Check ((View $task).Task.state -eq 'complete') 'same-task result repair completes with fresh quality evidence'
Check (-not (Invoke-CollabCommand Rework -Root $root -Request @{TaskId=$task;ExpectedRevision=2;ExpectedDigest=(View $task).DiffDigest;Reason='reopen'}).Ok) 'completed task remains terminal'
# A failed plan can be revised without replacing the task identity or old plan.
Remove-Item -LiteralPath (Join-Path $root 'value.txt')
$task='plan-repair'
$null=Cmd NewTask @{TaskId=$task;Grade='important';GradeReason='Plan revision regression';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt');FrozenTest=@();PlanFile='collaboration-artifacts/plan.md'}
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'FAIL_REVIEW' -Encoding utf8NoBOM
$null=Record-FixtureReview $task plan FAIL
$view=View $task
$rework=Cmd Rework @{TaskId=$task;ExpectedRevision=$view.Revision;ExpectedDigest=$view.DiffDigest;Reason='Add explicit edge-case verification';PlanFile='collaboration-artifacts/plan.md'}
Check ($rework.Task.state -eq 'planned' -and $rework.Task.planRevision -eq 2 -and (Test-Path -LiteralPath (Join-Path $root '.collaboration/tasks/plan-repair/plan.md'))) 'plan rework keeps the original plan and requires a new plan review'
Check (-not (Invoke-CollabCommand Advance -Root $root -Request @{TaskId=$task;To='implementing';Reason='skip review'}).Ok) 'revised plan cannot skip independent review'
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Verify revised plan and deliver current work' -Encoding utf8NoBOM
$null=Record-FixtureReview $task plan
$null=Cmd Advance @{TaskId=$task;To='plan_reviewed';Reason='new plan approved'}
$null=Cmd Backup @{TaskId=$task}
$null=Cmd Advance @{TaskId=$task;To='implementing';Reason='approved revised plan'}
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='validate revised plan'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Record-FixtureReview $task result
$null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='result approved'}
$view=View $task
$null=Cmd Rework @{TaskId=$task;ExpectedRevision=$view.Revision;ExpectedDigest=$view.DiffDigest;Reason='Refine plan after creating the implementation file';PlanFile='collaboration-artifacts/plan.md'}
$null=Record-FixtureReview $task plan
$null=Cmd Advance @{TaskId=$task;To='plan_reviewed';Reason='revised plan accepted'}
$null=Cmd Advance @{TaskId=$task;To='implementing';Reason='retain original absent-file backup'}
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='new revision implementation'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Record-FixtureReview $task result
$null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='new result accepted'}
$null=Cmd Complete @{TaskId=$task;Reason='plan repair completed'}
Check ((View $task).Revision -eq 3) 'plan revision after new-file implementation preserves absent-file original baseline'
Check ((View $task).Task.state -eq 'complete') 'same-task plan repair completes through both independent reviews'
