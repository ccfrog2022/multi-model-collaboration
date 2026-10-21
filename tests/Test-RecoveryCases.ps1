# Isolated runtime regression, sharing Cmd/View/Dispatch from Test-Package.
$data=Join-Path $root '.collaboration'
$ctx=Get-CollabContext -Root $root
$scan=New-CollabInventorySnapshot -Root $root -DataRoot $data -Config $ctx.Config
Check (@($scan.files.Keys | Where-Object {$_ -like '.collaboration/*'}).Count -eq 0) 'project inventories omit historical collaboration data'
$controls=Get-CollabControlSnapshot -Root $root -DataRootRelative '.collaboration'
Check (@($controls.Keys | Where-Object {$_ -like '.collaboration/*/invocation.json'}).Count -gt 0) 'separate control snapshot still hashes historical invocation records'
$null=New-Item -ItemType Directory -Path (Join-Path $root 'node_modules') -Force
Set-Content -LiteralPath (Join-Path $root 'node_modules/cache.txt') -Value 'fixture dependency' -Encoding utf8NoBOM
$config=$ctx.Config | ConvertTo-Json -Depth 32 | ConvertFrom-Json
$config.protocol.inventory.exclude=@('node_modules/**')
$scan=New-CollabInventorySnapshot -Root $root -DataRoot $data -Config $config
Check (-not $scan.files.Contains('node_modules/cache.txt') -and $scan.files.Contains('value.txt')) 'configured generated-directory exclusion prunes traversal while source remains hashed'
$rejected=$false
try { $null=New-CollabInventorySnapshot -Root $root -DataRoot $data -Config $config -RequiredPath @('node_modules/cache.txt') } catch { $rejected=$true }
Check $rejected 'task or frozen paths cannot be excluded'
$config.protocol.inventory.exclude=@('src/**')
$rejected=$false
try { $null=New-CollabInventorySnapshot -Root $root -DataRoot $data -Config $config } catch { $rejected=$true }
Check $rejected 'source-directory exclusion rejected'
$config.protocol.inventory.exclude=@('.collaboration/build/**')
$rejected=$false
try { $null=New-CollabInventorySnapshot -Root $root -DataRoot $data -Config $config } catch { $rejected=$true }
Check $rejected 'protected control-directory exclusion rejected'

$task='role-boundary'
$null=Cmd NewTask @{TaskId=$task;Grade='ordinary';GradeReason='Independent writing roles';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42 independently tested'});AllowedPath=@('value.txt','value_check.txt');TesterWritePath=@('value_check.txt')}
$bound=Read-CollabTask -DataRoot $data -TaskId $task
$altered=$bound.Task | ConvertTo-Json -Depth 64 | ConvertFrom-Json
$altered.testerWritePaths=@('value.txt')
Check (-not (Test-CollabTaskCreationBinding -Paths $bound.Paths -Task $altered -TaskId $task).Ok) 'test ownership cannot be reassigned after task creation'
$null=Cmd Backup @{TaskId=$task}
$null=Cmd Advance @{TaskId=$task;To='implementing';Reason='implement product file'}
$bad=@{TaskId=$task;Tool='my-worker';Role='executor';InstanceId='executor-cross-role';PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=(View $task).DiffDigest;WritePaths=@('value_check.txt')}
Check (-not (Invoke-CollabCommand Invoke -Root $root -Request $bad).Ok) 'executor cannot write tester-owned files'
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Implement value' -Encoding utf8NoBOM
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='independent test authoring'}
$bad.Role='tester';$bad.InstanceId='tester-cross-role';$bad.WritePaths=@('value.txt');$bad.ExpectedDigest=(View $task).DiffDigest
Check (-not (Invoke-CollabCommand Invoke -Root $root -Request $bad).Ok) 'tester cannot write product files even when task allows them'
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'WRITE_TEST_FILE' -Encoding utf8NoBOM
$bad.InstanceId='tester-write-owned';$bad.WritePaths=@('value_check.txt')
$test=Cmd Invoke $bad
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Independent tester authored its own file and verified product'}
Check ((View $task).Task.state -eq 'complete') 'role-separated test authoring completes the unified workflow'

$task='recovery-loop'
$null=Cmd NewTask @{TaskId=$task;Grade='ordinary';GradeReason='Recovery regression';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='value equals 42'});AllowedPath=@('value.txt');FrozenTest=@('frozen.txt')}
$null=Cmd Backup @{TaskId=$task}
$null=Cmd Advance @{TaskId=$task;To='implementing';Reason='produce a controlled failure'}
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Produce an initially accepted implementation' -Encoding utf8NoBOM
$beforeIncident=Dispatch $task executor
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'OUTSIDE_WRITE' -Encoding utf8NoBOM
$failure=Invoke-CollabCommand Invoke -Root $root -Request @{TaskId=$task;Tool='my-worker';Role='executor';InstanceId='failing-executor';PromptFile='collaboration-artifacts/prompt.txt';ExpectedDigest=(View $task).DiffDigest;WritePaths=@('value.txt')}
Check (-not $failure.Ok -and (View $task).Task.state -eq 'failed_closed') 'out-of-scope mutation produces an incident and stops the task'
$null=New-Item -ItemType Directory -Path (Join-Path $inbox $task) -Force
$evidence=Join-Path $inbox "$task/recovery.txt"
Set-Content -LiteralPath $evidence -Value 'Synthetic recovery: original process and descendants exited; remove unexpected.txt and check frozen test, original backup, current source.' -Encoding utf8NoBOM
# Deliberately simulate an unresolved cleanup label on a real exited fixture process.
$record=Get-Content -LiteralPath $failure.Path -Raw|ConvertFrom-Json -AsHashtable
$record.cleanup='uncertain'
Json-File $record $failure.Path
$null=Set-CollabCleanupFlag -DataRoot $data -TaskId $task -InvocationId $record.invocationId -Cleanup uncertain -Detail 'Synthetic missing cleanup certification'
# This assertion concerns this exited invocation. Unrelated historical PIDs can
# legitimately be reused by Windows and are conservatively refused by recovery.
$cleanupFixture=Join-Path $ScratchRoot 'pending-cleanup-tasks'
$cleanupLog=Join-Path $cleanupFixture "$task/logs/$($record.invocationId)"
$null=New-Item -ItemType Directory -Path $cleanupLog -Force
Copy-Item -LiteralPath $failure.Path -Destination (Join-Path $cleanupLog 'invocation.json')
Check (@(Get-CollabSurvivingInvocationProcesses -TaskRoot $cleanupFixture).Count -eq 0) 'lock recovery can verify exited processes despite a pending cleanup label'
$originalHash=Get-CollabSha256 $failure.Path
$violations=@(Get-CollabOpenViolations $data)
$request=@{TaskId=$task;ExpectedRevision=1;ExpectedDigest=(View $task).DiffDigest;InvocationIds=@($record.invocationId);ViolationIds=@($violations|ForEach-Object {$_.id});EvidencePath="collaboration-artifacts/$task/recovery.txt";EvidenceSha256=(Get-CollabSha256 $evidence);Reason='Repair the isolated scope failure';ProcessVerification='Fixture process and recorded children exited; process listing checked';FileVerification='Restore unexpected path, frozen test and check original backup'}
Check (-not (Invoke-CollabCommand RecoverTask -Root $root -Request $request).Ok) 'recovery refuses an unrestored out-of-scope file'
Remove-Item -LiteralPath (Join-Path $root 'unexpected.txt')
$originalBytes=[IO.File]::ReadAllBytes($failure.Path)
try {
    $record.process.Pid=$PID
    $record.process.ProcessStartTimeUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    Json-File $record $failure.Path
    Check (-not (Invoke-CollabCommand RecoverTask -Root $root -Request $request).Ok) 'recovery refuses a currently live recorded PID'
} finally { [IO.File]::WriteAllBytes($failure.Path,$originalBytes) }
$recovered=Cmd RecoverTask $request
Check ($recovered.NextCommand -eq 'Rework' -and (View $task).Task.state -eq 'blocked') 'recovery requires a new revision instead of accepting failed work'
Check ((Get-CollabSha256 $failure.Path) -eq $originalHash -and @((Get-CollabViolations $data)|Where-Object {$_.taskId -eq $task -and -not $_.clearedAtUtc}).Count -gt 0) 'recovery preserves original invocation and violation records'
Check ($null -eq (Get-CollabCleanupFlag $data) -and @(Get-CollabOpenViolations $data).Count -eq 0) 'valid recovery evidence resolves effective cleanup and scope blockers'
Check (-not (Invoke-CollabCommand Rework -Root $root -Request (Reuse-Request $task $beforeIncident.Record.invocationId)).Ok) 'incident recovery still requires full implementation rework despite an older accepted executor'
$proofBytes=[IO.File]::ReadAllBytes($evidence)
try {
    Set-Content -LiteralPath $evidence -Value 'changed proof' -Encoding utf8NoBOM
    Check ($null -ne (Get-CollabCleanupFlag $data)) 'changed recovery evidence reactivates incident checks'
    Check (-not (Invoke-CollabCommand Rework -Root $root -Request @{TaskId=$task;ExpectedRevision=1;ExpectedDigest=(View $task).DiffDigest;Reason='Attempt stale proof'}).Ok) 'rework rejects recovery whose evidence changed'
} finally { [IO.File]::WriteAllBytes($evidence,$proofBytes) }
$null=Cmd Rework @{TaskId=$task;ExpectedRevision=1;ExpectedDigest=(View $task).DiffDigest;Reason='Reimplement and independently verify after incident resolution'}
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Implement current revision' -Encoding utf8NoBOM
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='independent test after recovery'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Fresh independent evidence after recovery'}
Check ((View $task).Task.state -eq 'complete') 'failed task completes after verified recovery and fresh independent testing'

if ($IsWindows) {
    $invalid=@{TaskId='duplicate-role-scope';Grade='ordinary';GradeReason='Case alias regression';Authorization='Isolated regression';Acceptance=@(@{id='A1';requirement='independent writes'});AllowedPath=@('value.txt','VALUE.TXT');TesterWritePath=@('VALUE.TXT')}
    Check (-not (Invoke-CollabCommand NewTask -Root $root -Request $invalid).Ok) 'Windows path aliases cannot divide one file between two roles'
    $invalid.TaskId='frozen-role-scope';$invalid.AllowedPath=@('FROZEN.TXT');$invalid.TesterWritePath=@('FROZEN.TXT');$invalid.FrozenTest=@('frozen.txt')
    Check (-not (Invoke-CollabCommand NewTask -Root $root -Request $invalid).Ok) 'Windows frozen-test aliases cannot become tester write paths'
}

$noLaunch=[pscustomobject]@{process=[pscustomobject]@{Cleanup='not_started';Launched=$false;Pid=$null;Descendants=@()}}
Test-CollabRecordedProcessAbsence -Run $noLaunch -Snapshot @{Ok=$true;Items=@()}
Check $true 'verified prelaunch failure can be recovered without a PID'
$noLaunch.process.Launched=$true
$rejected=$false
try { Test-CollabRecordedProcessAbsence -Run $noLaunch -Snapshot @{Ok=$true;Items=@()} } catch { $rejected=$true }
Check $rejected 'launched process with missing identity remains unresolved'
