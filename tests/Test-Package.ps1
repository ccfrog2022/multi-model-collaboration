#requires -Version 7.4
[CmdletBinding()]
param([string]$Python, [string]$ScratchRoot)
$ErrorActionPreference='Stop'
$package=Split-Path -Parent $PSScriptRoot
if (-not $Python) {
    $name=if ($IsWindows) {'python'} else {'python3'}
    $Python=(Get-Command $name -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
}
if (-not $ScratchRoot) { $ScratchRoot=Join-Path ([IO.Path]::GetTempPath()) ('collab-validation-'+[guid]::NewGuid().ToString('N')) }
if (Test-Path -LiteralPath $ScratchRoot) { throw 'Use a new scratch directory' }
$null=New-Item -ItemType Directory -Path $ScratchRoot
if ($IsMacOS) { $ScratchRoot=(& $Python -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' $ScratchRoot).Trim() }
$script:checks=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "Check failed: $Name" }
    $script:checks.Add(@{name=$Name;passed=$true})
}
function Json-File($Value,[string]$Path) {
    $Value|ConvertTo-Json -Depth 64|Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}
function Bootstrap([string]$Root,[string]$Name) {
    $null=New-Item -ItemType Directory -Path $Root
    $plan=Join-Path $ScratchRoot "$Name-plan.json"
    $backup=Join-Path $ScratchRoot "$Name-backup"
    $output=& pwsh -NoProfile -File (Join-Path $package 'scripts/Initialize-Project.ps1') -Root $Root
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    $output|Set-Content -LiteralPath $plan -Encoding utf8NoBOM
    $applied=& pwsh -NoProfile -File (Join-Path $package 'scripts/Initialize-Project.ps1') -Root $Root -Mode Apply -PlanFile $plan -BackupDirectory $backup -Confirm
    if ($LASTEXITCODE -ne 0) { throw ($applied -join [Environment]::NewLine) }
    Check (($applied|ConvertFrom-Json).Ok) "$Name initializer apply"
    return @{plan=$plan;backup=$backup}
}
try {
    foreach($file in Get-ChildItem -LiteralPath $package -Recurse -Force -File|Where-Object {$_.Extension -in @('.ps1','.psm1')}) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "Syntax error $($file.FullName): $errors" }
    }
    Check $true 'PowerShell package syntax'
    $root=Join-Path $ScratchRoot 'runtime'
    $setup=Bootstrap $root 'runtime'
    Import-Module (Join-Path $root 'scripts/collaboration/Collab.psm1') -Force -DisableNameChecking
    Check (Invoke-CollabCommand Status -Root $root).Ok 'initial Status'
    Check (Invoke-CollabCommand Doctor -Root $root).Ok 'initial Doctor'
    Check (-not (Resolve-CollabPath -Root $root -RelativePath '../escape').Ok) 'path traversal rejected'
    Check (-not (Resolve-CollabPath -Root $root -RelativePath '/outside').Ok) 'absolute path rejected'
    Check (Resolve-CollabPath -Root $root -RelativePath 'nested/file.txt').Ok 'portable nested path'
    $controlFixture=Join-Path $ScratchRoot 'control-snapshot'
    $null=New-Item -ItemType Directory -Path (Join-Path $controlFixture '.collaboration/tasks/sample/logs/call') -Force
    Set-Content -LiteralPath (Join-Path $controlFixture '.collaboration/tasks/sample/task.json') -Value '{}' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $controlFixture '.collaboration/tasks/sample/logs/call/stdout.log') -Value 'runtime output' -Encoding utf8NoBOM
    $snapshot=Get-CollabControlSnapshot -Root $controlFixture -DataRootRelative '.collaboration' -ExcludePath @('.collaboration/tasks/sample/logs/call/stdout.log')
    Check ($snapshot.Contains('.collaboration/tasks/sample/task.json') -and -not $snapshot.Contains('.collaboration/tasks/sample/logs/call/stdout.log')) 'control snapshot preserves state and excludes generated logs'

    $rollbackRoot=Join-Path $ScratchRoot 'rollback'
    $rollback=Bootstrap $rollbackRoot 'rollback'
    $repeat=& pwsh -NoProfile -File (Join-Path $package 'scripts/Initialize-Project.ps1') -Root $rollbackRoot -Mode Apply -PlanFile $rollback.plan -BackupDirectory $rollback.backup -Confirm
    Check (($LASTEXITCODE -eq 0) -and ($repeat|ConvertFrom-Json).Code -eq 'no_op') 'repeat Apply is unchanged'
    $revert=& pwsh -NoProfile -File (Join-Path $package 'scripts/Initialize-Project.ps1') -Root $rollbackRoot -Mode Rollback -BackupDirectory $rollback.backup -Confirm
    Check (($LASTEXITCODE -eq 0) -and ($revert|ConvertFrom-Json).Code -eq 'rolled_back') 'initializer Rollback'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbackRoot 'AGENTS.md'))) 'Rollback restores absent baseline'

    $registry=Get-Content -LiteralPath (Join-Path $package 'examples/tools.json') -Raw|ConvertFrom-Json -AsHashtable
    $entry=$registry.tools[0]
    $entry.executable=$Python; $entry.enabled=$true; $entry.readiness='ready'
    $worker=Join-Path $ScratchRoot 'fake_worker.py'
    Copy-Item -LiteralPath (Join-Path $package 'tests/fake_worker.py') -Destination $worker
    $entry.commonArgs=@('-B',$worker)+$entry.commonArgs
    $entry.probeArgs=@('-B',$worker,'--version'); $entry.probeContains=@('collab-test-adapter')
    $entry.requestedModel='user-chosen-model'
    $relativeEntry=$entry|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $relativeEntry.commonArgs=@('-B','fake_worker.py')
    $beforeFingerprint=Get-CollabToolFingerprint -Entry $relativeEntry -ExePath $Python -WorkingDirectory $ScratchRoot
    Add-Content -LiteralPath $worker -Value '# Relative path fingerprint fixture' -Encoding utf8NoBOM
    $afterFingerprint=Get-CollabToolFingerprint -Entry $relativeEntry -ExePath $Python -WorkingDirectory $ScratchRoot
    Check ($beforeFingerprint -ne $afterFingerprint) 'relative adapter script participates in capability fingerprint'
    Json-File $registry (Join-Path $root '.agents/collaboration/config/tools.json')
    Check (Invoke-CollabCommand ProbeTool -Root $root -Request @{Tool='my-worker'}).Ok 'arbitrary tool ID capability probe'
    Set-Content -LiteralPath (Join-Path $root 'value.txt') -Value '0' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $root 'frozen.txt') -Value 'baseline' -Encoding utf8NoBOM
    $inbox=Join-Path $root 'collaboration-artifacts'
    $null=New-Item -ItemType Directory -Path $inbox
    Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Perform the assigned role and report the actual result.' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $inbox 'plan.md') -Value 'Set value.txt to 42. Independently assert its contents.' -Encoding utf8NoBOM
    function Cmd([string]$Name,[hashtable]$Request) {
        $result=Invoke-CollabCommand $Name -Root $root -Request $Request
        if (-not $result.Ok) { throw "$Name failed: $($result|ConvertTo-Json -Depth 20 -Compress)" }
        return $result
    }
    function View([string]$Task) {
        return (Cmd Status @{TaskId=$Task}).Tasks[0]
    }
    function Dispatch([string]$Task,[string]$Role,[string]$Subject='result',[string]$Instance='') {
        $view=View $Task
        if (-not $Instance) { $Instance=$Role+'-'+[guid]::NewGuid().ToString('N') }
        $request=@{TaskId=$Task;Tool='my-worker';Role=$Role;InstanceId=$Instance;PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest}
        if ($Role -eq 'executor') {$request.WritePaths=@('value.txt')}
        if ($view.Task.grade -eq 'important') { $request.ExpectedPlanSha256=$view.PlanSha256 }
        if ($Role -eq 'reviewer') {
            $request.SubjectKind=$Subject
            $request.ExpectedSubjectSha256=if($Subject -eq 'plan'){$view.PlanSha256}else{$view.DiffDigest}
        }
        return Cmd Invoke $request
    }
    foreach ($grade in @('ordinary','important')) {
        $task='test-'+$grade
        $request=@{TaskId=$task;Grade=$grade;GradeReason='Fixture checks unchanged collaboration gates';Authorization='Run isolated package regression fixtures';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt');FrozenTest=@('frozen.txt')}
        if ($grade -eq 'important') {$request.PlanFile='collaboration-artifacts/plan.md'}
        $null=Cmd NewTask $request
        Check (-not (Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='premature'}).Ok) "$grade premature completion rejected"
        if ($grade -eq 'important') {
            Check (-not (Invoke-CollabCommand Advance -Root $root -Request @{TaskId=$task;To='implementing';Reason='premature'}).Ok) 'important implementation requires plan review'
            $review=Dispatch $task reviewer plan
            $null=Cmd RecordReview @{TaskId=$task;SubjectKind='plan';Verdict='PASS';InvocationId=$review.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$review.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=(View $task).PlanSha256;Findings=@()}
            $null=Cmd Advance @{TaskId=$task;To='plan_reviewed';Reason='independent plan passed'}
        }
        $null=Cmd Backup @{TaskId=$task}
        $null=Cmd Advance @{TaskId=$task;To='implementing';Reason='begin implementation'}
        $view=View $task
        $bad=@{TaskId=$task;Tool='my-worker';Role='executor';InstanceId='stale';PromptFile='collaboration-artifacts/prompt.txt';WritePaths=@('value.txt');ExpectedDigest='outdated'}
        Check (-not (Invoke-CollabCommand Invoke -Root $root -Request $bad).Ok) "$grade stale version rejected"
        Set-Content -LiteralPath (Join-Path $root 'frozen.txt') -Value 'changed' -Encoding utf8NoBOM
        $bad.ExpectedDigest=$view.DiffDigest
        Check (-not (Invoke-CollabCommand Invoke -Root $root -Request $bad).Ok) "$grade frozen test modification rejected"
        Set-Content -LiteralPath (Join-Path $root 'frozen.txt') -Value 'baseline' -Encoding utf8NoBOM
        if ($grade -eq 'ordinary') {
            Add-Content -LiteralPath $worker -Value '# Changed adapter fixture' -Encoding utf8NoBOM
            $probeRequest=@{TaskId=$task;Tool='my-worker';Role='executor';InstanceId='changed-adapter';PromptFile='collaboration-artifacts/prompt.txt';WritePaths=@('value.txt');ExpectedDigest=(View $task).DiffDigest}
            $rejected=Invoke-CollabCommand Invoke -Root $root -Request $probeRequest
            Check (-not $rejected.Ok -and ($rejected|ConvertTo-Json -Depth 20) -match 'ProbeTool') 'adapter changes require a current capability probe'
            $null=Cmd ProbeTool @{Tool='my-worker'}
        }
        $execution=Dispatch $task executor
        Check ($execution.Record.requestedModel -eq 'user-chosen-model' -and $execution.Record.observedModel -eq 'user-chosen-model') "$grade configurable model preserved"
        $null=Cmd Advance @{TaskId=$task;To='validating';Reason='implementation ready for independent test'}
        $view=View $task
        $bad=@{TaskId=$task;Tool='my-worker';Role='tester';InstanceId=$execution.Record.instanceId;PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=$view.DiffDigest}
        Check (-not (Invoke-CollabCommand Invoke -Root $root -Request $bad).Ok) "$grade implementation instance cannot test itself"
        $test=Dispatch $task tester
        Check (-not (Invoke-CollabCommand Complete -Root $root -Request @{TaskId=$task;Reason='no acceptance yet'}).Ok) "$grade acceptance evidence required"
        $null=Cmd RecordAcceptance @{TaskId=$task;AcceptanceId='A1';Status='passed';Kind='acceptance';EvidencePath=[IO.Path]::GetRelativePath($root,$test.Record.resultFilePath).Replace('\','/');Note='Independent fixture asserts current content equals 42'}
        if ($grade -eq 'important') {
            $review=Dispatch $task reviewer result
            $null=Cmd RecordReview @{TaskId=$task;SubjectKind='result';Verdict='PASS';InvocationId=$review.Record.invocationId;ArtifactPath=[IO.Path]::GetRelativePath($root,$review.Record.resultFilePath).Replace('\','/');ExpectedSubjectSha256=(View $task).DiffDigest;Findings=@()}
            $null=Cmd Advance @{TaskId=$task;To='result_reviewed';Reason='current result independently reviewed'}
        }
        $null=Cmd Complete @{TaskId=$task;Reason='Coordinator inspected current implementation and independent evidence'}
        Check ((View $task).Task.state -eq 'complete') "$grade full workflow completes"
    }
    . (Join-Path $PSScriptRoot 'Test-CoordinationCases.ps1')
    . (Join-Path $PSScriptRoot 'Test-ReworkReuseCases.ps1')
    . (Join-Path $PSScriptRoot 'Test-ContinuationEvidenceCases.ps1')
    . (Join-Path $PSScriptRoot 'Test-RecoveryCases.ps1')
    . (Join-Path $PSScriptRoot 'Test-ExceptionalCases.ps1')
    . (Join-Path $PSScriptRoot 'Test-PathIdentityCases.ps1')
    . (Join-Path $PSScriptRoot 'Test-LockRecoveryCases.ps1')
    $timeout=Invoke-CollabProcess -ExePath $Python -Arguments @('-B',$worker,'--sleep','60') -WorkingDirectory $ScratchRoot -LogDirectory (Join-Path $ScratchRoot 'timeout') -InvocationId timeout-test -TotalTimeoutSeconds 2 -IdleTimeoutSeconds 2 -GracefulSeconds 0 -ForceSeconds 5
    Check (($timeout.TimedOut -or $timeout.IdleTimedOut) -and $timeout.Cleanup -eq 'verified') 'timeout process cleanup'
    $tree=Invoke-CollabProcess -ExePath $Python -Arguments @('-B',$worker,'--child') -WorkingDirectory $ScratchRoot -LogDirectory (Join-Path $ScratchRoot 'process-tree') -InvocationId tree-test -TotalTimeoutSeconds 10 -IdleTimeoutSeconds 10 -GracefulSeconds 0 -ForceSeconds 5
    if ($IsMacOS) {
        Check ($tree.Cleanup -eq 'uncertain' -and $tree.ForkEventsObserved) 'macOS fork records unresolved containment'
    } else {
        Check ($tree.Cleanup -eq 'verified') 'spawned child cleanup'
    }
    $childId=(Get-Content -LiteralPath $tree.StdoutPath -Raw|ConvertFrom-Json).childPid
    Check (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'owned child no longer running'
    $bad=Parse-CollabResult -Kind json -ExitCode 0 -StdoutText '{"schemaVersion":1,"ok":true,"final":"done","session":{"id":"old","fresh":false}}' -StderrText ''
    Check (-not $bad.Accepted) 'resumed adapter session rejected'
    $bad=Parse-CollabResult -Kind json -ExitCode 0 -StdoutText '{"schemaVersion":1,"ok":true,"final":"done","session":{"id":"new","fresh":true},"readOnly":false}' -StderrText '' -ReadOnly
    Check (-not $bad.Accepted) 'read-only role capability required'
    foreach($events in @('null','{}','[{"type":"tool_call","name":"write","access":"read"}]','[{"type":"tool_call","name":"save_document","access":"write"}]','[{"type":"tool_call","name":"read_file"}]')) {
        $payload='{"schemaVersion":1,"ok":true,"final":"done","session":{"id":"new","fresh":true},"readOnly":true,"toolAuditComplete":true,"toolEvents":'+$events+'}'
        $bad=Parse-CollabResult -Kind json -ExitCode 0 -StdoutText $payload -StderrText '' -ReadOnly
        Check (-not $bad.Accepted) "invalid read-only audit rejected: $events"
    }
    $good=Parse-CollabResult -Kind json -ExitCode 0 -StdoutText '{"schemaVersion":1,"ok":true,"final":"done","session":{"id":"new","fresh":true},"readOnly":true,"toolAuditComplete":true,"toolEvents":[{"type":"tool_call","name":"read_file","access":"read"}]}' -StderrText '' -ReadOnly
    Check $good.Accepted 'complete read-only audit accepted'
    $large=[ordered]@{schemaVersion=1;ok=$true;final='done';session=@{id='large';fresh=$true};readOnly=$true;toolAuditComplete=$true;toolEvents=@(@{type='tool_call';name='Bash';access='read'})+@(1..20001|ForEach-Object {@{type='tool_call';name='Read';access='read'}})}
    $bad=Parse-CollabResult -Kind json -ExitCode 0 -StdoutText ($large|ConvertTo-Json -Depth 8 -Compress) -StderrText '' -ReadOnly
    Check (-not $bad.Accepted) 'large audit cannot hide a forbidden tool call'
    $large.toolEvents=@(1..20001|ForEach-Object {@{type='tool_call';name='Read';access='read'}})
    $bad=Parse-CollabResult -Kind json -ExitCode 0 -StdoutText ($large|ConvertTo-Json -Depth 8 -Compress) -StderrText '' -ReadOnly
    Check (-not $bad.Accepted -and ($bad.Reasons -join ' ') -match 'limit') 'truncated audit remains incomplete'

    # Tool aliases must not let the same actual model session satisfy independence.
    $alias=$entry|ConvertTo-Json -Depth 32|ConvertFrom-Json -AsHashtable
    $alias.id='worker-alias'
    $registry.tools+=@($alias)
    Json-File $registry (Join-Path $root '.agents/collaboration/config/tools.json')
    $null=Cmd ProbeTool @{Tool='worker-alias'}
    $sessionTask='test-session-reuse'
    $null=Cmd NewTask @{TaskId=$sessionTask;Grade='ordinary';GradeReason='Actual session regression';Authorization='Isolated test';Acceptance=@(@{id='A1';requirement='Independent session'});AllowedPath=@('value.txt');FrozenTest=@()}
    $null=Cmd Backup @{TaskId=$sessionTask}
    $null=Cmd Advance @{TaskId=$sessionTask;To='implementing';Reason='session fixture'}
    Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'REUSE_SESSION' -Encoding utf8NoBOM
    $null=Dispatch $sessionTask executor
    $null=Cmd Advance @{TaskId=$sessionTask;To='validating';Reason='independent session fixture'}
    $reuse=Invoke-CollabCommand Invoke -Root $root -Request @{TaskId=$sessionTask;Tool='worker-alias';Role='tester';InstanceId='alias-session';PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=(View $sessionTask).DiffDigest}
    Check (-not $reuse.Ok -and ($reuse|ConvertTo-Json -Depth 32) -match 'session') 'tool alias cannot reuse an actual implementation session'
    $lock=Get-CollabLockStatus -DataRoot (Join-Path $root '.collaboration')
    Check (-not $lock.Held) 'project lock released'
    $report=@{platform=$PSVersionTable.OS;passed=$script:checks.Count;checks=$script:checks;scope='Isolated synthetic workers; no model service requests';scratch=$ScratchRoot}
    Json-File $report (Join-Path $ScratchRoot 'verification.json')
    $report|ConvertTo-Json -Depth 8
} catch {
    @{passed=$script:checks.Count;error=$_.Exception.Message;scratch=$ScratchRoot;checks=$script:checks}|ConvertTo-Json -Depth 8
    throw
}
