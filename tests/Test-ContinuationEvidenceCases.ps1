# Public-command recovery and immutable evidence regressions in the isolated fixture.
function New-ContinuationTask([string]$Task,[string]$Grade='ordinary',[bool]$RealWorkflow=$false) {
    Set-ReusePrompt 'Implement the assigned outcome'
    Set-Content -LiteralPath (Join-Path $root 'value_check.txt') -Value 'Independent report fixture baseline' -Encoding utf8NoBOM
    $request=@{TaskId=$Task;Grade=$Grade;GradeReason='Continuation evidence regression';Authorization='Isolated package regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt','value_check.txt');TesterWritePath=@('value_check.txt');FrozenTest=@();RequiresRealWorkflow=$RealWorkflow}
    if ($Grade -eq 'important') { $request.PlanFile='collaboration-artifacts/plan.md' }
    $null=Cmd NewTask $request
    if ($Grade -eq 'important') {
        $null=Record-FixtureReview $Task plan
        $null=Cmd Advance @{TaskId=$Task;To='plan_reviewed';Reason='Independent plan passed'}
    }
    $null=Cmd Backup @{TaskId=$Task}
    $null=Cmd Advance @{TaskId=$Task;To='implementing';Reason='Implement current task'}
    return Dispatch $Task executor
}
function Fail-ContinuationCall([string]$Task,[string]$Role='tester',[string]$Subject='result') {
    Set-ReusePrompt 'FAIL_RESULT'
    $view=View $Task
    $request=@{TaskId=$Task;Tool='my-worker';Role=$Role;InstanceId=($Role+'-failed-'+[guid]::NewGuid().ToString('N'));PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest;ExpectedPlanSha256=$view.PlanSha256}
    if ($Role -eq 'executor') { $request.WritePaths=@('value.txt') }
    if ($Role -eq 'reviewer') {
        $request.SubjectKind=$Subject
        $request.ExpectedSubjectSha256=if ($Subject -eq 'plan') {$view.PlanSha256} else {$view.DiffDigest}
    }
    $failure=Invoke-CollabCommand Invoke -Root $root -Request $request
    Check (-not $failure.Ok -and (View $Task).Task.state -eq 'handoff_required') "$Task records a clean invocation failure"
    Set-ReusePrompt 'Perform current verification'
    return $failure
}
foreach ($grade in @('ordinary','important')) {
    $task="continuation-$grade"
    $execution=New-ContinuationTask $task $grade $true
    $sourceId=$execution.Record.invocationId
    $null=Cmd Advance @{TaskId=$task;To='validating';Reason='Independent validation'}
    $oldTest=Dispatch $task tester
    $oldEvidence=Record-FixtureAcceptance $task $oldTest real_workflow
    $oldReview=$null
    if ($grade -eq 'important') { $oldReview=Record-FixtureReview $task result }
    $beforeDigest=(View $task).DiffDigest
    $failure=Fail-ContinuationCall $task
    $failureHash=Get-CollabSha256 $failure.Path
    Check ((View $task).DiffDigest -eq $beforeDigest) "$grade failed tester leaves subject content unchanged"
    Check (-not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $sourceId)).Ok) "$grade unresolved failure cannot carry implementation into a revision"
    $null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Inspect failure and retry verification with an independent worker'}
    $continued=View $task
    Check ($continued.Task.acceptance[0].status -eq 'pending' -and @($continued.Task.acceptance[0].evidence).Count -eq 0 -and -not $continued.Task.realWorkflowVerified) "$grade handoff invalidates old acceptance and real-workflow proof"
    Check (-not (Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='Try old successful tester and evidence'}).Ok) "$grade old success cannot hide a later failed verification"
    Check (-not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $sourceId)).Ok) "$grade handoff alone does not qualify for implementation reuse"
    $premature=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';Kind='real_workflow';EvidencePath='value_check.txt';Note='Try registering another artifact before replacement testing'}
    Check (-not $premature.Ok) "$grade a different artifact cannot replace post-handoff independent testing"
    foreach ($path in @($oldTest.Record.resultFilePath,$oldEvidence.Record.absolutePath)) {
        $relabel=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';Kind='real_workflow';EvidencePath=[IO.Path]::GetRelativePath($root,$path).Replace('\','/');Note='Attempt to reuse pre-handoff workflow proof'}
        Check (-not $relabel.Ok -and ($relabel.Reasons -join ' ') -match 'evidence_before_handoff') "$grade pre-handoff evidence cannot be relabeled: $([IO.Path]::GetFileName($path))"
    }
    $test=Dispatch $task tester
    Check (-not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $sourceId)).Ok) "$grade fresh tester without fresh acceptance is not recovered reuse"
    # Even after new testing, old immutable outputs retain their original boundary.
    $relabel=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';Kind='real_workflow';EvidencePath=$oldEvidence.Record.path;Note='Attempt to relabel old workflow proof after fresh testing'}
    Check (-not $relabel.Ok -and ($relabel.Reasons -join ' ') -match 'evidence_before_handoff') "$grade fresh tester cannot make an old evidence snapshot current"
    $pending=Cmd RecordAcceptance @{TaskId=$task;AcceptanceId='A1';Status='pending';Kind='acceptance';EvidencePath=[IO.Path]::GetRelativePath($root,$test.Record.resultFilePath).Replace('\','/');Note='Preserve intermediate verification awaiting coordinator disposition'}
    Check ((View $task).Task.acceptance[0].status -eq 'pending') "$grade intermediate pending evidence remains visible after handoff"
    $null=Record-FixtureAcceptance $task $test real_workflow
    Check (@((View $task).Task.acceptance[0].evidence).Count -eq 2 -and $pending.Record.status -eq 'pending') "$grade passed verification retains the earlier pending evidence"
    if ($grade -eq 'important') {
        Check (-not (Invoke-CollabCommand Advance -Root $root -Request @{TaskId=$task;To='result_reviewed';Reason='Try the pre-failure review'}).Ok) 'important handoff invalidates the pre-failure result review'
        $relabel=Invoke-CollabCommand RecordReview -Root $root -Request @{TaskId=$task;SubjectKind='result';Verdict='PASS';InvocationId=$oldReview.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$oldReview.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=(View $task).DiffDigest;Findings=@()}
        Check (-not $relabel.Ok) 'old reviewer invocation cannot be re-registered after handoff'
        Check (-not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $sourceId)).Ok) 'important recovered reuse still requires a fresh result review'
        $null=Record-FixtureReview $task result
        $null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='Fresh result independently reviewed'}
    }
    $rework=Cmd Rework (Reuse-Request $task $sourceId)
    Check ($rework.Task.state -eq 'validating' -and $rework.Task.revision -eq 2) "$grade verified clean recovery allows bounded implementation reuse"
    Check ((Get-CollabSha256 $failure.Path) -eq $failureHash) "$grade recovery and reuse preserve failed invocation bytes"
    $test=Dispatch $task tester
    $null=Record-FixtureAcceptance $task $test real_workflow
    if ($grade -eq 'important') {
        $null=Record-FixtureReview $task result
        $null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='New revision independently reviewed'}
    }
    $null=Cmd Complete @{TaskId=$task;Reason='Fresh verification, acceptance and required review passed'}
    $calls=@(Get-CollabInvocationRecords -DataRoot (Join-Path $root '.collaboration') -TaskId $task)
    Check (@($calls | Where-Object {$_.role -eq 'executor'}).Count -eq 1) "$grade recovered validation rework does not launch an empty executor"
}

# A failed review requires replacement evidence for the same subject kind.
foreach ($subject in @('plan','result')) {
    $task="continuation-reviewer-$subject"
    $execution=New-ContinuationTask $task important
    if ($subject -eq 'plan') {
        $view=View $task
        $null=Cmd Rework @{TaskId=$task;ExpectedRevision=$view.Revision;ExpectedDigest=$view.DiffDigest;Reason='Implement a new revision retaining the independently reviewed plan'}
        $execution=Dispatch $task executor
    }
    $null=Cmd Advance @{TaskId=$task;To='validating';Reason='Verify current implementation'}
    $oldTest=Dispatch $task tester
    $null=Record-FixtureAcceptance $task $oldTest
    $null=Record-FixtureReview $task result
    $oldReview=@(Get-CollabReviewRecords -DataRoot (Join-Path $root '.collaboration') -TaskId $task | Where-Object {$_.subjectKind -eq $subject})[0]
    if ($subject -eq 'plan') { Check ((View $task).Revision -eq 2 -and $oldReview.revision -eq 1) 'plan recovery fixture retains a plan reviewer from an earlier task revision' }
    $failure=Fail-ContinuationCall $task reviewer $subject
    $failureHash=Get-CollabSha256 $failure.Path
    $null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Inspect failed review and request replacement review of the same subject'}
    $relabel=Invoke-CollabCommand RecordReview -Root $root -Request @{TaskId=$task;SubjectKind=$subject;Verdict='PASS';InvocationId=$oldReview.reviewerInvocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$oldReview.artifactPath).Replace('\','/');ExpectedSubjectSha256=$oldReview.subjectSha256;Findings=@()}
    Check (-not $relabel.Ok -and $relabel.Code -eq 'review_before_handoff') "$subject review cannot reuse the pre-handoff reviewer invocation"
    if ($subject -eq 'plan') {
        $view=View $task
        $premature=Invoke-CollabCommand Invoke -Root $root -Request @{TaskId=$task;Tool='my-worker';Role='tester';InstanceId='plan-failure-premature-test';PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest;ExpectedPlanSha256=$view.PlanSha256}
        Check (-not $premature.Ok) 'failed plan-review invocation requires replacement plan review before testing'
        $null=Record-FixtureReview $task plan
    }
    $test=Dispatch $task tester
    if ($subject -eq 'result') {
        $premature=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath=[IO.Path]::GetRelativePath($root,$test.Record.resultFilePath).Replace('\','/');Note='Try to substitute a tester for a failed reviewer'}
        Check (-not $premature.Ok -and ($premature.Reasons -join ' ') -match 'reviewer') 'fresh testing cannot stand in for a failed result reviewer'
    }
    $null=Record-FixtureReview $task result
    $null=Record-FixtureAcceptance $task $test
    $null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='Current subject independently reviewed after handoff'}
    $null=Cmd Complete @{TaskId=$task;Reason='Replacement review, independent testing and fresh acceptance passed'}
    Check ((View $task).Task.state -eq 'complete' -and (Get-CollabSha256 $failure.Path) -eq $failureHash) "$subject reviewer continuation completes while preserving the failure record"
}

# Executor failure remains conservative even when later verification is successful.
$task='continuation-executor-failure'
$execution=New-ContinuationTask $task
$failure=Fail-ContinuationCall $task executor
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Inspect failed implementation attempt'}
Check ((View $task).Task.state -eq 'implementing' -and -not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $execution.Record.invocationId)).Ok) 'executor failure cannot skip replacement implementation through handoff or reuse'
if ((View $task).Task.state -eq 'implementing') {
    $null=Dispatch $task executor
    $null=Cmd Advance @{TaskId=$task;To='validating';Reason='Verify replacement implementation'}
}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Replacement executor and fresh independent evidence passed'}

# Fixed report filenames remain writable while registered historical bytes are retained.
$task='immutable-evidence'
$execution=New-ContinuationTask $task
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='Write independent report'}
$test=Invoke-ReuseTester $task 'WRITE_TEST_FILE'
$first=Cmd RecordAcceptance @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath='value_check.txt';Note='Current independent report inspected'}
$firstSnapshot=$first.Record.absolutePath
$firstHash=Get-CollabSha256 $firstSnapshot
Check ($first.Record.path -match '/evidence/artifacts/E[^/]+\.txt$' -and $first.Record.sourcePath -eq 'value_check.txt' -and $first.Record.sourceAbsolutePath -eq (Join-Path $root 'value_check.txt')) 'evidence records immutable snapshot and original source provenance'
Check ($firstSnapshot -ne (Join-Path $root 'value_check.txt') -and $firstHash -eq (Get-CollabSha256 (Join-Path $root 'value_check.txt'))) 'evidence snapshot initially contains exact source bytes'
$null=Cmd Rework (Reuse-Request $task $execution.Record.invocationId)
$test=Invoke-ReuseTester $task 'WRITE_TEST_FILE_UPDATED'
Check ((Get-CollabSha256 $firstSnapshot) -eq $firstHash -and (Get-CollabSha256 (Join-Path $root 'value_check.txt')) -ne $firstHash) 'overwriting a tester report preserves registered historical bytes'
$relabel=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath=$first.Record.path}
Check (-not $relabel.Ok) 'previous revision snapshot cannot be registered as fresh evidence'
$second=Cmd RecordAcceptance @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath='value_check.txt';Note='Updated independent report inspected'}
Check ($second.Record.absolutePath -ne $firstSnapshot -and (Get-CollabSha256 $second.Record.absolutePath) -eq (Get-CollabSha256 (Join-Path $root 'value_check.txt'))) 'same report source can create a distinct current revision snapshot'
$snapshotBytes=[IO.File]::ReadAllBytes($second.Record.absolutePath)
try {
    [IO.File]::WriteAllText($second.Record.absolutePath,'corrupt immutable evidence fixture')
    Check (-not (Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='Try altered snapshot'}).Ok) 'corrupted current evidence snapshot prevents completion'
} finally { [IO.File]::WriteAllBytes($second.Record.absolutePath,$snapshotBytes) }
$null=Cmd Complete @{TaskId=$task;Reason='Current snapshot and independent report verified'}

# Failure to create the artifact must not publish evidence or change acceptance.
$task='evidence-copy-failure'
$null=New-ContinuationTask $task
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='Independent validation'}
$test=Dispatch $task tester
$paths=Get-CollabTaskPaths -DataRoot (Join-Path $root '.collaboration') -TaskId $task
$artifacts=Join-Path $paths.Evidence 'artifacts'
Check (-not (Test-Path -LiteralPath $artifacts)) 'copy-failure fixture starts without artifact directory'
$beforeTask=Get-CollabSha256 $paths.TaskFile
$null=New-Item -ItemType Directory -Path $paths.Evidence -Force
Set-Content -LiteralPath $artifacts -Value 'Fixture blocks artifact directory creation' -Encoding utf8NoBOM
try {
    $failedCopy=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath=[IO.Path]::GetRelativePath($root,$test.Record.resultFilePath).Replace('\','/')}
    Check (-not $failedCopy.Ok) 'artifact copy failure is reported'
    Check ((Get-CollabSha256 $paths.TaskFile) -eq $beforeTask -and @(Get-CollabEvidenceRecords -DataRoot (Join-Path $root '.collaboration') -TaskId $task).Count -eq 0) 'artifact copy failure leaves task acceptance and evidence records unchanged'
} finally { Remove-Item -LiteralPath $artifacts -Force }
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Retry saved intact evidence successfully'}
Set-ReusePrompt 'Perform the assigned work'

# Consecutive failures preserve resolved roles while each boundary gets fresh validation.
foreach ($grade in @('ordinary','important')) {
    $task="successive-handoff-$grade"
    $null=New-ContinuationTask $task $grade
    $firstFailure=Fail-ContinuationCall $task executor
    $firstFailureHash=Get-CollabSha256 $firstFailure.Path
    $null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Replace failed executor'}
    $replacement=Dispatch $task executor
    $null=Cmd Advance @{TaskId=$task;To='validating';Reason='Test replacement implementation'}
    foreach ($attempt in @(2,3)) {
        $null=Fail-ContinuationCall $task tester
        $handoff=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Retry failed tester, retaining resolved implementation'}
        $view=View $task
        $binding=@($view.Task.continuation.failures | Where-Object {$_.invocationId -eq $firstFailure.Record.invocationId})[0]
        Check ($view.Task.state -eq 'validating' -and $binding.replacement.invocationId -eq $replacement.Record.invocationId) "$grade handoff $attempt retains the successful executor replacement"
        Check (@($handoff.Draft.failureResolutions | Where-Object {$_.replacementInvocationId -eq $replacement.Record.invocationId}).Count -eq 1) "$grade handoff $attempt exposes retained replacement to the successor"
        Check (-not (Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='Attempt completion before new tester'}).Ok) "$grade handoff $attempt still requires new independent validation"
        $test=Dispatch $task tester
        $null=Record-FixtureAcceptance $task $test
        if ($grade -eq 'important') {
            if ($attempt -eq 3) {
                Check (-not (Invoke-CollabCommand Advance -Root $root -Request @{TaskId=$task;To='result_reviewed';Reason='Try prior boundary result review'}).Ok) 'retained executor never carries the important result review across a boundary'
            }
            $null=Record-FixtureReview $task result
        }
    }
    $savedResult=[IO.File]::ReadAllBytes($replacement.Record.resultFilePath)
    try {
        [IO.File]::WriteAllText($replacement.Record.resultFilePath,'damaged replacement output')
        Check (-not (Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='Try damaged replacement evidence'}).Ok) "$grade damaged carried replacement prevents completion"
        Check (-not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $replacement.Record.invocationId)).Ok) "$grade damaged carried replacement prevents implementation reuse"
    } finally { [IO.File]::WriteAllBytes($replacement.Record.resultFilePath,$savedResult) }
    if ($grade -eq 'important') { $null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='Current result review passed'} }
    $null=Cmd Complete @{TaskId=$task;Reason='Continuation meets current acceptance without a new revision'}
    $runs=@(Get-CollabInvocationRecords -DataRoot (Join-Path $root '.collaboration') -TaskId $task)
    Check ((View $task).Revision -eq 1 -and @($runs | Where-Object {$_.role -eq 'executor'}).Count -eq 3) "$grade consecutive handoffs finish in the same revision with no repeated executor"
    Check ((Get-CollabSha256 $firstFailure.Path) -eq $firstFailureHash) "$grade consecutive handoffs preserve original failure bytes"
}

# A new executor failure, changed implementation or damaged source invalidates retention.
foreach ($cause in @('new-executor-failure','implementation-change','replacement-record-change')) {
    $task="handoff-invalid-$cause"
    $null=New-ContinuationTask $task
    $null=Fail-ContinuationCall $task executor
    $null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Replace initial executor failure'}
    $replacement=Dispatch $task executor
    if ($cause -eq 'new-executor-failure') {
        $null=Fail-ContinuationCall $task executor
    } else {
        $null=Cmd Advance @{TaskId=$task;To='validating';Reason='Validate implementation'}
        $null=Fail-ContinuationCall $task tester
    }
    # The first new boundary binds the original replacement record hash.
    $null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Inspect later failure'}
    if ($cause -ne 'new-executor-failure') {
        $null=Fail-ContinuationCall $task tester
        $savedRecord=[IO.File]::ReadAllBytes($replacement.Path)
        try {
            if ($cause -eq 'implementation-change') { [IO.File]::WriteAllText((Join-Path $root 'value.txt'),"43`n") }
            else { [IO.File]::AppendAllText($replacement.Path,"`n ") }
            $null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Recheck retained replacement against current content and originals'}
        } finally { [IO.File]::WriteAllBytes($replacement.Path,$savedRecord) }
    }
    Check ((View $task).Task.state -eq 'implementing') "$cause requires replacement implementation"
    $null=Dispatch $task executor
    $null=Cmd Advance @{TaskId=$task;To='validating';Reason='Test fresh replacement implementation'}
    $test=Dispatch $task tester
    $null=Record-FixtureAcceptance $task $test
    $null=Cmd Complete @{TaskId=$task;Reason='Replacement and current verification passed'}
}

# Resolved plan-review failures stay resolved across later tester failures.
$task='successive-plan-handoff'
$null=New-ContinuationTask $task important
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='Validate implementation'}
$planFailure=Fail-ContinuationCall $task reviewer plan
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Replace failed plan review'}
$planFailureBytes=[IO.File]::ReadAllBytes($planFailure.Path)
foreach ($damage in @('missing','invalid-json','accepted-changed')) {
    try {
        switch ($damage) {
            missing { [IO.File]::Delete($planFailure.Path) }
            invalid-json { [IO.File]::WriteAllText($planFailure.Path,'{broken') }
            accepted-changed {
                $record=[Text.Encoding]::UTF8.GetString($planFailureBytes) | ConvertFrom-Json -AsHashtable
                $record.accepted=$true
                Json-File $record $planFailure.Path
            }
        }
        $view=View $task
        $rejected=Invoke-CollabCommand Invoke -Root $root -Request @{TaskId=$task;Tool='my-worker';Role='tester';InstanceId="plan-history-$damage";PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest;ExpectedPlanSha256=$view.PlanSha256}
        Check (-not $rejected.Ok -and ($rejected.Reasons -join ' ') -match 'failure evidence missing or changed') "$damage plan-review failure cannot reactivate an old plan review before launch"
    } finally { [IO.File]::WriteAllBytes($planFailure.Path,$planFailureBytes) }
}
$planReplacement=Record-FixtureReview $task plan
$null=Fail-ContinuationCall $task tester
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Retain current plan replacement and retry testing'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Record-FixtureReview $task result
$null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='Current result passed independent review'}
$null=Cmd Complete @{TaskId=$task;Reason='Retained plan review and new result validation passed'}
$runs=@(Get-CollabInvocationRecords -DataRoot (Join-Path $root '.collaboration') -TaskId $task)
Check (@($runs | Where-Object {$_.role -eq 'reviewer' -and $_.subjectKind -eq 'plan'}).Count -eq 3) 'later tester failure does not dispatch an already resolved plan reviewer again'

# A later boundary must preserve every original failure binding.
$task='handoff-failure-originals'
$null=New-ContinuationTask $task
$originalFailure=Fail-ContinuationCall $task executor
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Replace first failure'}
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='Independent test'}
$null=Fail-ContinuationCall $task tester
$paths=Get-CollabTaskPaths -DataRoot (Join-Path $root '.collaboration') -TaskId $task
$taskHash=Get-CollabSha256 $paths.TaskFile
$failureBytes=[IO.File]::ReadAllBytes($originalFailure.Path)
foreach ($damage in @('missing','invalid-json','accepted-changed')) {
    try {
        switch ($damage) {
            missing { [IO.File]::Delete($originalFailure.Path) }
            invalid-json { [IO.File]::WriteAllText($originalFailure.Path,'{broken') }
            accepted-changed {
                $record=[Text.Encoding]::UTF8.GetString($failureBytes) | ConvertFrom-Json -AsHashtable
                $record.accepted=$true
                Json-File $record $originalFailure.Path
            }
        }
        $rejected=Invoke-CollabCommand Handoff -Root $root -Request @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Try damaged prior failure'}
        Check (-not $rejected.Ok -and ($rejected.Reasons -join ' ') -match 'failure evidence missing or changed') "$damage historical failure cannot disappear from the next handoff"
        Check ((Get-CollabSha256 $paths.TaskFile) -eq $taskHash) "$damage rejected handoff preserves prior task boundary"
    } finally { [IO.File]::WriteAllBytes($originalFailure.Path,$failureBytes) }
}
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Continue with original failure records intact'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Original history and current validation verified'}
$completed=View $task
Check (-not (Invoke-CollabCommand Rework -Root $root -Request @{TaskId=$task;ExpectedRevision=$completed.Revision;ExpectedDigest=$completed.DiffDigest;Reason='Try reopening completed task'}).Ok) 'completed continuation remains terminal and cannot start another revision'

# Optional roles also retain their resolved work; they do not replace fresh testing.
$task='successive-optional-roles'
$null=New-ContinuationTask $task
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='Independent validation'}
$null=Fail-ContinuationCall $task probe
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Complete compatibility probe'}
$null=Dispatch $task probe
$null=Fail-ContinuationCall $task reviewer result
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Complete optional result review'}
$null=Record-FixtureReview $task result
$null=Fail-ContinuationCall $task tester
$null=Cmd Handoff @{TaskId=$task;ExpectedDigest=(View $task).DiffDigest;Reason='Retain resolved optional roles and retry tester'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Resolved optional roles and fresh independent test passed'}
$runs=@(Get-CollabInvocationRecords -DataRoot (Join-Path $root '.collaboration') -TaskId $task)
Check (@($runs | Where-Object {$_.role -eq 'probe'}).Count -eq 2 -and @($runs | Where-Object {$_.role -eq 'reviewer'}).Count -eq 2) 'ordinary continuation retains resolved probe and optional result reviewer without repeated dispatch'

# Upgrade guidance: keep a legacy source in place and submit a new task inbox report.
$task='legacy-evidence-path'
$execution=New-ContinuationTask $task
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='Independent report'}
$test=Invoke-ReuseTester $task 'WRITE_TEST_FILE'
$registered=Cmd RecordAcceptance @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath='value_check.txt'}
$legacy=Get-Content -LiteralPath $registered.Path -Raw | ConvertFrom-Json -AsHashtable
$legacy.path='value_check.txt'; $legacy.absolutePath=Join-Path $root 'value_check.txt'
$legacy.Remove('sourcePath'); $legacy.Remove('sourceAbsolutePath')
Json-File $legacy $registered.Path
$legacyHash=Get-CollabSha256 $registered.Path
$originalReport=[IO.File]::ReadAllBytes($legacy.absolutePath)
$null=Cmd Rework (Reuse-Request $task $execution.Record.invocationId)
Set-ReusePrompt 'Verify the current implementation while preserving the legacy report'
$test=Dispatch $task tester
try {
    [IO.File]::WriteAllText($legacy.absolutePath,'New report at the legacy path')
    $stale=Invoke-CollabCommand RecordAcceptance -Root $root -Request @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath='value_check.txt'}
    Check (-not $stale.Ok -and ($stale.Reasons -join ' ') -match 'evidence_revision_stale') 'regenerated legacy source still requires a separate report path'
} finally { [IO.File]::WriteAllBytes($legacy.absolutePath,$originalReport) }
$reportRelative="collaboration-artifacts/$task/report-r2.txt"
$report=Join-Path $root $reportRelative
$null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
Copy-Item -LiteralPath $test.Record.resultFilePath -Destination $report
$null=Cmd RecordAcceptance @{TaskId=$task;AcceptanceId='A1';Status='passed';EvidencePath=$reportRelative;Note='Current independent output at a new task inbox path'}
$null=Cmd Complete @{TaskId=$task;Reason='New evidence registered with legacy originals preserved'}
Check ((Get-CollabSha256 $legacy.absolutePath) -eq $legacy.sha256 -and (Get-CollabSha256 $registered.Path) -eq $legacyHash) 'legacy workflow preserves original source and record while completing the new revision'
Set-ReusePrompt 'Perform the assigned work'
