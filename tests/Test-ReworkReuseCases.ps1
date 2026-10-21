# Public-command scenarios for bounded implementation reuse and finding IDs.
function Set-ReusePrompt([string]$Text) {
    Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value $Text -Encoding utf8NoBOM
}
function Reuse-Request([string]$Task,[string]$Invocation) {
    $view=View $Task
    return @{TaskId=$Task;ExpectedRevision=$view.Revision;ExpectedDigest=$view.DiffDigest;Reason='Extend independent verification while implementation remains unchanged';ReuseImplementationFrom=$Invocation}
}
function Invoke-ReuseTester([string]$Task,[string]$Text='WRITE_TEST_FILE_UPDATED') {
    Set-ReusePrompt $Text
    $view=View $Task
    return Cmd Invoke @{TaskId=$Task;Tool='my-worker';Role='tester';InstanceId=('tester-'+[guid]::NewGuid().ToString('N'));PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest;ExpectedRevision=$view.Revision;ExpectedPlanSha256=$view.PlanSha256;WritePaths=@('value_check.txt')}
}
$task='reuse-implementation'
Set-ReusePrompt 'Implement and verify the assigned acceptance'
Set-Content -LiteralPath (Join-Path $root 'value.txt') -Value '0' -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $root 'value_check.txt') -Value 'test placeholder' -Encoding utf8NoBOM
$null=Cmd NewTask @{TaskId=$task;Grade='important';GradeReason='Implementation reuse regression';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt','value_check.txt');TesterWritePath=@('value_check.txt');FrozenTest=@('frozen.txt');PlanFile='collaboration-artifacts/plan.md';RequiresRealWorkflow=$true}
$null=Record-FixtureReview $task plan
$null=Cmd Advance @{TaskId=$task;To='plan_reviewed';Reason='Plan checked'}
$null=Cmd Backup @{TaskId=$task}
$null=Cmd Advance @{TaskId=$task;To='implementing';Reason='Implement'}
$execution=Dispatch $task executor
$sourceId=$execution.Record.invocationId
Check ([bool]$execution.Record.implementationDigest) 'executor records implementation-only content digest'
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='Independent testing'}
$oldTest=Invoke-ReuseTester $task 'WRITE_TEST_FILE'
$null=Record-FixtureAcceptance $task $oldTest real_workflow
Check ((View $task).DiffDigest -ne $execution.Record.afterDigest) 'tester-owned changes alter the complete subject'
Set-ReusePrompt 'FAIL_REVIEW'
$oldReview=Record-FixtureReview $task result FAIL
$request=Reuse-Request $task $sourceId
$bad=$request.Clone(); $bad.PlanFile='collaboration-artifacts/plan.md'
Check (-not (Invoke-CollabCommand Rework -Root $root -Request $bad).Ok) 'plan replacement cannot carry prior implementation'
$bad=$request.Clone(); $bad.ReuseImplementationFrom=$oldTest.Record.invocationId
Check (-not (Invoke-CollabCommand Rework -Root $root -Request $bad).Ok) 'tester invocation cannot provide implementation reuse'
$sourceFile=$execution.Path
$original=[IO.File]::ReadAllBytes($sourceFile)
try {
    $legacy=[IO.File]::ReadAllText($sourceFile)|ConvertFrom-Json -AsHashtable
    $legacy.Remove('implementationDigest'); Json-File $legacy $sourceFile
    Check (-not (Invoke-CollabCommand Rework -Root $root -Request $request).Ok) 'legacy implementation without content digest cannot be reused'
} finally { [IO.File]::WriteAllBytes($sourceFile,$original) }
$resultBytes=[IO.File]::ReadAllBytes($execution.Record.resultFilePath)
try {
    [IO.File]::WriteAllText($execution.Record.resultFilePath,'damaged result')
    Check (-not (Invoke-CollabCommand Rework -Root $root -Request $request).Ok) 'damaged implementation result prevents reuse'
} finally { [IO.File]::WriteAllBytes($execution.Record.resultFilePath,$resultBytes) }
$valueBytes=[IO.File]::ReadAllBytes((Join-Path $root 'value.txt'))
try {
    [IO.File]::WriteAllText((Join-Path $root 'value.txt'),'43')
    $changed=Reuse-Request $task $sourceId
    Check (-not (Invoke-CollabCommand Rework -Root $root -Request $changed).Ok) 'changed implementation prevents reuse even with current full digest'
} finally { [IO.File]::WriteAllBytes((Join-Path $root 'value.txt'),$valueBytes) }
Check ((View $task).Revision -eq 1) 'rejected reuse requests preserve revision'
$rework=Cmd Rework $request
Check ($rework.Task.state -eq 'validating' -and $rework.Task.reusedImplementation.invocationId -eq $sourceId) 'test-only rework enters validation with bound implementation source'
Check ($rework.Task.acceptance[0].status -eq 'pending' -and -not $rework.Task.realWorkflowVerified) 'reuse resets acceptance and real-workflow evidence'
Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($sourceFile)) -eq [Convert]::ToBase64String($original)) 'reuse preserves original invocation bytes'
Check (-not (Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='Try old evidence'}).Ok) 'reused implementation cannot complete without current verification'
$oldEvidence=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath=[IO.Path]::GetRelativePath($root,$oldTest.Record.resultFilePath).Replace('\','/')}
Check (-not $oldEvidence.Ok) 'implementation reuse does not relabel old tester evidence'
$view=View $task
$oldReviewRequest=@{TaskId=$task;SubjectKind='result';Verdict='FAIL';InvocationId=$oldReview.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$oldReview.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=$view.DiffDigest}
Check (-not (Invoke-CollabCommand RecordReview -Root $root -Request $oldReviewRequest).Ok) 'implementation reuse still rejects old result review'
$invoke=@{TaskId=$task;Tool='my-worker';Role='tester';InstanceId='reuse-preflight';PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest;ExpectedPlanSha256=$view.PlanSha256}
try {
    $changedRecord=[IO.File]::ReadAllText($sourceFile)|ConvertFrom-Json -AsHashtable
    $changedRecord.observedModel='changed-evidence'; Json-File $changedRecord $sourceFile
    Check (-not (Invoke-CollabCommand Invoke -Root $root -Request $invoke).Ok) 'reuse checks source invocation hash before next launch'
} finally { [IO.File]::WriteAllBytes($sourceFile,$original) }
try {
    [IO.File]::WriteAllText((Join-Path $root 'value.txt'),'43')
    $invoke.ExpectedDigest=(View $task).DiffDigest
    Check (-not (Invoke-CollabCommand Invoke -Root $root -Request $invoke).Ok) 'implementation drift after reuse blocks launch'
} finally { [IO.File]::WriteAllBytes((Join-Path $root 'value.txt'),$valueBytes) }
$test=Invoke-ReuseTester $task
$null=Record-FixtureAcceptance $task $test real_workflow
Check (-not (Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='Try skipping current review'}).Ok) 'important test-only repair still requires fresh result review'
$null=Record-FixtureReview $task result
$null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='Current result accepted'}
try {
    [IO.File]::WriteAllText((Join-Path $root 'value.txt'),'43')
    $drift=Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='Drifted implementation'}
    Check (-not $drift.Ok -and ($drift.Reasons -join ' ') -match 'Implementation changed') 'completion rechecks reused implementation content'
} finally { [IO.File]::WriteAllBytes((Join-Path $root 'value.txt'),$valueBytes) }
try {
    [IO.File]::WriteAllText($execution.Record.resultFilePath,'changed source evidence')
    $damaged=Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='Damaged source result'}
    Check (-not $damaged.Ok -and ($damaged.Reasons -join ' ') -match 'Reused implementation evidence is invalid') 'completion checks original reused result integrity'
} finally { [IO.File]::WriteAllBytes($execution.Record.resultFilePath,$resultBytes) }
$null=Cmd Rework (Reuse-Request $task $sourceId)
Check ((View $task).Revision -eq 3 -and (View $task).Task.state -eq 'validating') 'consecutive test-only revisions retain the original implementation binding'
Set-ReusePrompt 'FAIL_RESULT'
$view=View $task
$failed=Invoke-CollabCommand Invoke -Root $root -Request @{TaskId=$task;Tool='my-worker';Role='tester';InstanceId='reuse-failed-tester';PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest;ExpectedPlanSha256=$view.PlanSha256}
Check (-not $failed.Ok -and (View $task).Task.state -eq 'handoff_required') 'tester invocation failure retains handoff state'
Check (-not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $sourceId)).Ok) 'failed invocation requires full rework when starting another revision'
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Inspect clean failed tester output; new tester retries current verification'}
Check ((View $task).Task.state -eq 'validating') 'handoff retains valid reused implementation and resumes testing'
$test=Invoke-ReuseTester $task
$null=Record-FixtureAcceptance $task $test real_workflow
$null=Record-FixtureReview $task result
$null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='Current review accepted'}
$null=Cmd Complete @{TaskId=$task;Reason='Current tests, workflow and review verified'}
Check ((View $task).Task.state -eq 'complete') 'test-only revisions complete with current independent evidence'
$calls=@(Get-CollabInvocationRecords -DataRoot (Join-Path $root '.collaboration') -TaskId $task)
Check (@($calls | Where-Object {$_.role -eq 'executor'}).Count -eq 1) 'test-only repair and handoff require no empty executor invocation'

# A new implementation revision explicitly drops reuse and performs real work.
$task='reuse-reset'
Set-ReusePrompt 'Implement the approved outcome'
$null=Cmd NewTask @{TaskId=$task;Grade='ordinary';GradeReason='Reset reuse';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt');FrozenTest=@()}
$null=Cmd Backup @{TaskId=$task}
$null=Cmd Advance @{TaskId=$task;To='implementing';Reason='Implement'}
$execution=Dispatch $task executor
$null=Cmd Rework (Reuse-Request $task $execution.Record.invocationId)
$view=View $task
$null=Cmd Rework @{TaskId=$task;ExpectedRevision=$view.Revision;ExpectedDigest=$view.DiffDigest;Reason='Implementation work is now required'}
Check ($null -eq (View $task).Task.reusedImplementation -and (View $task).Task.state -eq 'implementing') 'default rework clears prior implementation reuse'
Check (-not (Invoke-CollabCommand Advance -Root $root -Request @{TaskId=$task;To='validating';Reason='Try old implementation'}).Ok) 'default rework again requires current implementation'
Check (-not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $execution.Record.invocationId)).Ok) 'unrelated older revision cannot be selected after clearing reuse'
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='Fresh implementation'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Full rework verified'}

# Existing calls retain their original completion path without new digest fields.
$task='legacy-implementation'
$null=Cmd NewTask @{TaskId=$task;Grade='ordinary';GradeReason='Existing record compatibility';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt');FrozenTest=@()}
$null=Cmd Backup @{TaskId=$task}
$null=Cmd Advance @{TaskId=$task;To='implementing';Reason='Legacy implementation fixture'}
$legacyExecution=Dispatch $task executor
$originalLegacy=[IO.File]::ReadAllBytes($legacyExecution.Path)
try {
    $legacy=[IO.File]::ReadAllText($legacyExecution.Path)|ConvertFrom-Json -AsHashtable
    $legacy.Remove('implementationDigest')
    $legacy.usage=@{inputTokens=120;outputTokens=30;totalTokens=150}
    $legacy.promptChars=100
    Json-File $legacy $legacyExecution.Path
    $null=Cmd Advance @{TaskId=$task;To='validating';Reason='Existing accepted implementation'}
    $test=Dispatch $task tester
    $null=Record-FixtureAcceptance $task $test
    $null=Cmd Complete @{TaskId=$task;Reason='Existing record completed using its original workflow'}
    Check ((View $task).Task.state -eq 'complete') 'legacy calls with extra statistics and without reuse digest still complete normally'
} finally { [IO.File]::WriteAllBytes($legacyExecution.Path,$originalLegacy) }

# Finding IDs are local review identifiers, not a new issue management system.
$task='finding-ids'
Set-ReusePrompt 'NITS_REVIEW'
$null=Cmd NewTask @{TaskId=$task;Grade='important';GradeReason='Review findings';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt');FrozenTest=@();PlanFile='collaboration-artifacts/plan.md'}
$review=Dispatch $task reviewer plan
$request=@{TaskId=$task;SubjectKind='plan';Verdict='PASS WITH NITS';InvocationId=$review.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$review.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=(View $task).PlanSha256;Adjudication='F1 and F2: reviewed and nonblocking for this fixture'}
$request.Findings=@(@{id='';text='Actual small issue';blocking=$false})
Check (-not (Invoke-CollabCommand RecordReview -Root $root -Request $request).Ok) 'review rejects empty finding ID'
$request.Findings=@(@{id='F1';text='First issue';blocking=$false},@{id=' f1 ';text='Duplicate identity';blocking=$false})
Check (-not (Invoke-CollabCommand RecordReview -Root $root -Request $request).Ok) 'review rejects duplicate IDs including whitespace and case aliases'
$request.Findings=@(@{id='F1';text='First issue';blocking=$false},@{id='F2';text='Second issue';blocking=$false})
$record=Cmd RecordReview $request
Check ($record.Record.findings.Count -eq 2) 'review preserves distinct issue IDs and findings'
Set-ReusePrompt 'Perform the assigned work'
