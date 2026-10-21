# Recovery adds verified resolutions while preserving original incident records.
Set-StrictMode -Version 2.0

function Get-CollabInventoryFiles {
    param([string]$Root,[string[]]$ExcludedDirectories=@())
    $pending=[Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
            $relative=[IO.Path]::GetRelativePath($Root,$item.FullName).Replace('\','/')
            if ($item.PSIsContainer -and @($ExcludedDirectories | Where-Object {[string]::Equals($_,$relative,(Get-CollabPathComparison))}).Count) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Inventory reparse path: $relative" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $item }
        }
    }
}

function Get-CollabRecoveryRecords {
    param([string]$DataRoot)
    $directory=Join-Path $DataRoot 'recoveries'
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File) {
        $record=(Assert-CollabOk (Read-CollabJson $file.FullName)).Value
        $root=Split-Path -Parent $DataRoot
        $valid=$true
        foreach ($artifact in @($record.bindings)) {
            $safe=Assert-CollabOk (Resolve-CollabPath -Root $root -RelativePath $artifact.path)
            if ((Get-CollabSha256 $safe.FullPath) -ne $artifact.sha256) { $valid=$false; break }
        }
        if ($valid) { $record }
    }
}

function Test-CollabRecoveredItem {
    param([string]$DataRoot,[string]$Kind,$Item)
    $hash=Get-CollabTextSha256 ($Item | ConvertTo-Json -Depth 64 -Compress)
    foreach ($record in @(Get-CollabRecoveryRecords $DataRoot)) {
        if ($Kind -eq 'violation' -and @($record.violations | Where-Object {$_.id -eq $Item.id -and $_.sha256 -eq $hash}).Count) { return $true }
        if ($Kind -eq 'cleanup' -and $record.cleanupFlagSha256 -eq $hash) { return $true }
    }
    return $false
}

function Test-CollabEffectiveCleanup {
    param([string]$DataRoot,$Run)
    if ($Run.cleanup -eq 'verified') { return $true }
    foreach ($record in @(Get-CollabRecoveryRecords $DataRoot)) {
        if ($Run.invocationId -cin @($record.invocationIds)) { return $true }
    }
    return $false
}

function Test-CollabRecordedProcessAbsence {
    param($Run,$Snapshot)
    $process=Get-CollabPropertyValue $Run 'process'
    if ($null -eq $process) { throw 'Recovery needs the persisted process record; restore missing records before recovery' }
    if ((Get-CollabPropertyValue $process 'Cleanup') -eq 'not_started' -and (Get-CollabPropertyValue $process 'Launched') -eq $false -and -not (Get-CollabPropertyValue $process 'Pid')) { return }
    $identities=@(@{pid=(Get-CollabPropertyValue $process 'Pid');start=(Get-CollabPropertyValue $process 'ProcessStartTimeUtc')})
    $children=Get-CollabPropertyValue $process 'Descendants'
    if (-not (Test-CollabHasProperty $process 'Descendants')) { throw 'Recovery needs the recorded descendant list' }
    foreach ($child in $children) { $identities+=@{pid=$child.ProcessId;start=$child.CreationTimeUtc} }
    if (-not $Snapshot.Ok) { throw 'Process enumeration failed' }
    foreach ($identity in $identities) {
        if ([int]$identity.pid -le 0 -or -not $identity.start) { throw 'Process identity is incomplete' }
        $null=ConvertTo-CollabLockUtcTime $identity.start
        if (@($Snapshot.Items | Where-Object {$_.ProcessId -eq [int]$identity.pid}).Count) { throw "Recorded PID is present; verify identity before recovery: $($identity.pid)" }
    }
}

function Test-CollabRecoveryScope {
    param($Context,$Task,$Run,[string]$EvidencePath,[string]$RecoveryRecordPath='')
    $root=$Context.Root
    $baselineName=Get-CollabPropertyValue $Run 'baselinePath'
    if (-not $baselineName) {
        if ($Run.scopeCheck -notin @('clean','violations') -or $Run.classification -eq 'runner_error') {
            throw 'Interrupted legacy invocation needs its complete prelaunch baseline before scope can be verified'
        }
        return
    }
    $safe=Assert-CollabOk (Resolve-CollabPath -Root $root -RelativePath $baselineName)
    if ((Get-CollabSha256 $safe.FullPath) -ne $Run.baselineSha256) { throw 'Restore the invocation baseline before recovery' }
    # Hashtable JSON preserves distinct file names on case-sensitive volumes.
    $baseline=[IO.File]::ReadAllText($safe.FullPath) | ConvertFrom-Json -AsHashtable -Depth 64
    $current=New-CollabInventorySnapshot -Root $root -DataRoot $Context.DataRoot -Config $baseline.config -RequiredPath @($Task.allowedPaths + @($Task.frozenTests | ForEach-Object {$_.path}))
    if ($current.truncated -or $current.skippedHash) { throw 'Recovery needs a complete inventory using the invocation scan configuration' }
    $diff=Compare-CollabInventory -Before $baseline.project -After $current
    # Restoration is by content; restoring original bytes may change mtime.
    $diff.modified=@($diff.modified | Where-Object {$_.sha256 -cne $_.previousSha256})
    $paths=@($diff.added + $diff.modified + $diff.removed | ForEach-Object {$_.path})
    $identities=Get-CollabPathIdentityMap -Root $root -NamesOnly -Path @($paths + @($Run.writePaths))
    foreach ($path in $paths) {
        if ($path -ceq $EvidencePath -and -not $baseline.project.files.Contains($path)) { continue }
        if (@($Run.writePaths | Where-Object {$identities[$_] -ceq $identities[$path]}).Count) { continue }
        throw "Restore the out-of-scope path found by recovery inventory: $path"
    }
    if ((Get-CollabPropertyValue $Run 'controlCheck') -eq 'pending') {
        $expected=$baseline.control
        foreach ($item in @($Run.recoveryControlOverrides)) { $expected[$item.path]=$item.sha256 }
        $recordName=[IO.Path]::GetRelativePath($root,(Join-Path (Split-Path -Parent $Run.resultFilePath) 'invocation.json')).Replace('\','/')
        $exclude=@($baseline.excludedPaths)+@($recordName,'.collaboration/locks/project.lock','.collaboration/locks/recovery.lock')
        if ($RecoveryRecordPath) { $exclude+=$RecoveryRecordPath }
        foreach ($path in $exclude) { if ($expected.Contains($path)) { $expected.Remove($path) } }
        $actual=Get-CollabControlSnapshot -Root $root -DataRootRelative '.collaboration' -ExcludePath $exclude
        $delta=Compare-CollabControlSnapshot -Before $expected -After $actual
        $changes=@($delta.added+$delta.modified+$delta.removed | Where-Object {
            -not ($Task.maintenance -and $_ -cin @($Task.maintenanceAllowlist) -and $_ -cin @($Run.writePaths))
        })
        if ($changes.Count) { throw ('Restore control paths found by recovery scan: '+($changes -join ', ')) }
    }
}

function Repair-CollabTask {
    param($Context,$Task,[hashtable]$Request)
    foreach ($key in $Request.Keys) {
        if ($key -notin @('TaskId','ExpectedRevision','ExpectedDigest','InvocationIds','ViolationIds','EvidencePath','EvidenceSha256','Reason','ProcessVerification','FileVerification')) { throw "Unsupported RecoverTask field: $key" }
    }
    $root=$Context.Root; $data=$Context.DataRoot
    if ($Task.state -in @('complete','cancelled')) { throw 'Completed and cancelled tasks retain their terminal state' }
    if ($Request['ExpectedRevision'] -ne (Get-CollabRevision $Task) -or $Request['ExpectedDigest'] -ne (Get-CollabInventoryDigest -DataRoot $data -TaskId $Task.taskId)) { throw 'Recovery revision/digest mismatch' }
    foreach ($field in @('Reason','ProcessVerification','FileVerification')) {
        if ([string]::IsNullOrWhiteSpace($Request[$field])) { throw "Recovery requires $field with concrete checks and results" }
    }
    $artifact=Assert-CollabOk (Resolve-CollabPath -Root $root -RelativePath $Request['EvidencePath'])
    $taskInbox="$($Context.Config.paths.workerInbox)/$($Task.taskId)/"
    if (-not $artifact.RelativePath.StartsWith($taskInbox,[StringComparison]::Ordinal)) { throw 'Recovery evidence belongs in this task worker inbox' }
    $artifactHash=Get-CollabSha256 $artifact.FullPath
    if (-not $artifactHash -or $artifactHash -ne $Request['EvidenceSha256'] -or (Get-Item -LiteralPath $artifact.FullPath).Length -eq 0) { throw 'Recovery evidence hash mismatch or empty evidence' }
    $runs=@(Get-CollabInvocationRecords -DataRoot $data -TaskId $Task.taskId)
    $selected=@($runs | Where-Object {$_.invocationId -cin @($Request['InvocationIds'])})
    if (-not $selected.Count -or $selected.Count -ne @($Request['InvocationIds'] | Select-Object -Unique).Count) { throw 'Select existing task invocations for recovery' }
    $recoveries=@(Get-CollabRecoveryRecords $data)
    $resolvedIds=@($recoveries | ForEach-Object {$_.invocationIds})
    $resumeRecovery=$null
    if (@($selected | Where-Object {$_.invocationId -cin $resolvedIds}).Count) {
        # Resume only the interrupted state update of this exact verified transaction.
        $taskPath=(Get-CollabTaskPaths -DataRoot $data -TaskId $Task.taskId).TaskFile
        $matches=@($recoveries | Where-Object {
            $_.taskId -ceq $Task.taskId -and $_.revision -eq (Get-CollabRevision $Task) -and
            $_.digest -eq $Request['ExpectedDigest'] -and
            (Get-CollabPropertyValue $_ 'taskBeforeSha256') -eq (Get-CollabSha256 $taskPath) -and
            @($_.invocationIds).Count -eq $selected.Count -and
            -not @($_.invocationIds | Where-Object {$_ -cnotin @($selected.invocationId)}).Count -and
            @($_.bindings | Where-Object {$_.path -ceq $artifact.RelativePath -and $_.sha256 -eq $artifactHash}).Count
        })
        if ($Task.state -eq 'blocked' -or $matches.Count -ne 1) { throw 'Selected invocation already has effective recovery evidence' }
        $resumeRecovery=$matches[0]
    }
    $unresolved=@($runs | Where-Object {-not (Test-CollabEffectiveCleanup -DataRoot $data -Run $_)})
    foreach ($run in $unresolved) { if ($run.invocationId -cnotin @($Request['InvocationIds'])) { throw 'Include every unresolved task invocation' } }
    $violations=@(Get-CollabOpenViolations $data | Where-Object {$_.taskId -ceq $Task.taskId})
    if ($null -ne $resumeRecovery) {
        $violations=@(Get-CollabViolations $data | Where-Object {$_.id -cin @($resumeRecovery.violations | ForEach-Object {$_.id})})
    }
    foreach ($violation in $violations) {
        if ($violation.id -cnotin @($Request['ViolationIds']) -or $violation.invocationId -cnotin @($Request['InvocationIds'])) { throw 'Include all current task violations and their invocations' }
    }
    if (@($Request['ViolationIds'] | Where-Object {$_ -cnotin @($violations | ForEach-Object {$_.id})}).Count) { throw 'Unknown or already resolved violation ID' }
    $flagRead=Assert-CollabOk (Read-CollabJson (Join-Path $data 'cleanup-uncertain.json'))
    $flag=$flagRead.Value
    if ($null -ne $flag -and $flag.taskId -cne $Task.taskId) { $flag=$null }
    if ($null -ne $flag -and -not (Test-CollabRecoveredItem -DataRoot $data -Kind cleanup -Item $flag)) {
        if ($flag.taskId -cne $Task.taskId -or $flag.invocationId -cnotin @($Request['InvocationIds'])) { throw 'Cleanup flag belongs to another invocation' }
    }
    if ($Task.state -ne 'failed_closed' -and -not $unresolved.Count -and -not $violations.Count -and
        -not @($selected | Where-Object {$_.classification -eq 'runner_error'}).Count -and $null -eq $resumeRecovery) { throw 'Use Handoff or Rework for a normal retry' }
    $snapshot=Get-CollabProcessSnapshot
    $bindings=@(@{path=$artifact.RelativePath;sha256=$artifactHash})
    foreach ($run in $selected) {
        Test-CollabRecordedProcessAbsence -Run $run -Snapshot $snapshot
        $resumePath=if($null -ne $resumeRecovery){".collaboration/recoveries/$($resumeRecovery.recoveryId).json"}else{''}
        Test-CollabRecoveryScope -Context $Context -Task $Task -Run $run -EvidencePath $artifact.RelativePath -RecoveryRecordPath $resumePath
        if ($run.classification -eq 'policy_violation' -and -not (Test-CollabHasProperty $run 'repairPaths')) { throw 'This legacy incident lacks recorded repair paths; restore its baseline and capture a reviewed migration before recovery' }
        foreach ($repair in @(Get-CollabPropertyValue $run 'repairPaths')) {
            if ($null -eq $repair) { continue }
            $safe=Assert-CollabOk (Resolve-CollabPath -Root $root -RelativePath $repair.path)
            if ((-not $repair.sha256 -and (Test-Path -LiteralPath $safe.FullPath)) -or (Get-CollabSha256 $safe.FullPath) -ne $repair.sha256) { throw "Restore the recorded out-of-scope path first: $($repair.path)" }
        }
        $recordPath=Join-Path (Split-Path -Parent $run.resultFilePath) 'invocation.json'
        $bindings+=@{path=[IO.Path]::GetRelativePath($root,$recordPath).Replace('\','/');sha256=(Get-CollabSha256 $recordPath)}
        if (Get-CollabPropertyValue $run 'baselinePath') { $bindings+=@{path=$run.baselinePath;sha256=$run.baselineSha256} }
    }
    foreach ($test in @($Task.frozenTests)) {
        $safe=Assert-CollabOk (Resolve-CollabPath -Root $root -RelativePath $test.path)
        if ((Get-CollabSha256 $safe.FullPath) -ne $test.sha256) { throw 'Restore frozen tests before recovery' }
    }
    $null=Assert-CollabOk (Test-CollabBackupGate -Root $root -DataRoot $data -Task $Task -IntegrityOnly)
    $inventory=New-CollabInventorySnapshot -Root $root -DataRoot $data -Config $Context.Config -RequiredPath @($Task.allowedPaths + @($Task.frozenTests | ForEach-Object {$_.path}))
    if ($inventory.truncated -or $inventory.skippedHash) { throw 'Recovery needs a complete current inventory' }
    $id='R'+(New-CollabNonce -Bytes 8)
    $record=@{recoveryId=$id;taskId=$Task.taskId;revision=(Get-CollabRevision $Task);atUtc=(Format-CollabTime (Get-CollabUtcNow));invocationIds=@($selected.invocationId);violations=@($violations | ForEach-Object {@{id=$_.id;sha256=(Get-CollabTextSha256 ($_ | ConvertTo-Json -Depth 64 -Compress))}});cleanupFlagSha256=$(if($null -ne $flag){Get-CollabTextSha256 ($flag|ConvertTo-Json -Depth 64 -Compress)}else{$null});bindings=$bindings;reason=(Protect-CollabSecret $Request['Reason']).Text;processVerification=(Protect-CollabSecret $Request['ProcessVerification']).Text;fileVerification=(Protect-CollabSecret $Request['FileVerification']).Text;digest=$Request['ExpectedDigest']}
    $path=Join-Path $data "recoveries/$id.json"
    if ($null -ne $resumeRecovery) {
        $id=$resumeRecovery.recoveryId
        $path=Join-Path $data "recoveries/$id.json"
    } else {
        $record.taskBeforeSha256=Get-CollabSha256 (Get-CollabTaskPaths -DataRoot $data -TaskId $Task.taskId).TaskFile
        $null=Write-CollabJsonAtomic -Path $path -Object $record
    }
    # Recovery resolves incidents, not acceptance. A new revision follows through Rework.
    $null=Assert-CollabOk (Set-CollabTaskState -DataRoot $data -Task $Task -To blocked -Reason "Recovery $id verified; begin Rework with fresh execution and testing")
    $null=Add-CollabAudit -DataRoot $data -TaskId $Task.taskId -Action task_recovered -Detail @{recoveryId=$id}
    return @{Ok=$true;Code='task_recovered';RecoveryId=$id;Path=$path;NextCommand='Rework'}
}

function Test-CollabHasProperty {
    param($Object,[string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}
