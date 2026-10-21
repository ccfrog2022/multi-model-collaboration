# Revision-bound rework and role context.
Set-StrictMode -Version 2.0

function Get-CollabRevision {
    param($Object,[string]$Field='revision')
    $value=Get-CollabPropertyValue -Object $Object -Name $Field
    if ($null -eq $value) { return 1 }
    return [int]$value
}

function Get-CollabPlanPath {
    param([string]$DataRoot,$Task)
    if ($null -eq $Task.plan) { return (Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId).Plan }
    $relative=[string]$Task.plan.storedPath
    if (-not $relative.StartsWith(".collaboration/tasks/$($Task.taskId)/",[StringComparison]::Ordinal)) { throw 'Stored plan must belong to this task' }
    return (Assert-CollabOk (Resolve-CollabPath -Root (Split-Path -Parent $DataRoot) -RelativePath $relative)).FullPath
}

function Get-CollabEffectiveExecutors {
    param([string]$DataRoot,$Task,[array]$Runs)
    $current=@($Runs | Where-Object { $_.role -eq 'executor' -and $_.accepted -eq $true -and (Get-CollabRevision $_) -eq (Get-CollabRevision $Task) })
    $reuse=Get-CollabPropertyValue $Task 'reusedImplementation'
    if ($null -eq $reuse) { return $current }
    $source=@($Runs | Where-Object { $_.invocationId -ceq $reuse.invocationId })
    if ($source.Count -ne 1) { throw 'Reused implementation invocation is missing' }
    $run=$source[0]
    $paths=Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
    $recordPath=Join-Path $paths.Logs "$($run.invocationId)/invocation.json"
    if ($run.role -ne 'executor' -or -not $run.accepted -or $run.scopeCheck -ne 'clean' -or
        -not (Test-CollabEffectiveCleanup -DataRoot $DataRoot -Run $run) -or
        (Get-CollabRevision $run 'planRevision') -ne (Get-CollabRevision $Task 'planRevision') -or
        (Get-CollabRevision $run) -ge (Get-CollabRevision $Task) -or
        (Get-CollabSha256 $recordPath) -ne $reuse.recordSha256 -or
        (Get-CollabSha256 $run.resultFilePath) -ne $run.resultSha256) { throw 'Reused implementation evidence is invalid' }
    $expected=Get-CollabPropertyValue $run 'implementationDigest'
    if (-not $expected -or $expected -ne (Get-CollabInventoryDigest -DataRoot $DataRoot -TaskId $Task.taskId -ImplementationOnly)) {
        throw 'Implementation changed; start implementation rework'
    }
    return @($current)+@($run)
}

function Test-CollabCleanInvocationFailure {
    param($Run)
    return (-not $Run.accepted -and $Run.scopeCheck -eq 'clean' -and
        (Get-CollabPropertyValue $Run 'controlCheck') -eq 'clean' -and
        $Run.cleanup -eq 'verified' -and $Run.classification -notin @('runner_error','policy_violation'))
}

function Test-CollabFailureBindings {
    param([string]$DataRoot,$Task,$Boundary,[array]$Runs)
    $reasons=[Collections.Generic.List[string]]::new()
    $paths=Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
    if ((Get-CollabRevision $Boundary) -ne (Get-CollabRevision $Task)) { $reasons.Add('Handoff boundary revision mismatch') }
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($binding in @($Boundary.failures)) {
        $match=@($Runs | Where-Object {
            $_.invocationId -ceq $binding.invocationId -and -not $_.accepted -and
            (Get-CollabRevision $_) -eq (Get-CollabRevision $Task)
        })
        $hash=Get-CollabSha256 (Join-Path $paths.Logs "$($binding.invocationId)/invocation.json")
        if (-not $ids.Add([string]$binding.invocationId) -or $match.Count -ne 1 -or
            -not $binding.recordSha256 -or $hash -ne $binding.recordSha256) {
            $reasons.Add("Handoff failure evidence missing or changed: $($binding.invocationId)")
        }
    }
    if (-not $ids.Count) { $reasons.Add('Handoff boundary has no failure evidence') }
    return @{Ok=($reasons.Count -eq 0);Code='handoff_failure_bindings';Reasons=@($reasons)}
}

function Get-CollabFailureReplacement {
    # A replacement either follows this boundary or is bound by an earlier
    # handoff. Both paths verify the same role, current subject and originals.
    param([string]$DataRoot,$Task,$Failure,$Binding,$Boundary,[array]$Runs,[array]$Reviews)
    $paths=Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
    $carried=Get-CollabPropertyValue $Binding 'replacement'
    $revision=Get-CollabRevision $Task
    $kind=[string](Get-CollabPropertyValue $Failure 'subjectKind')
    $expected=if ($Failure.role -eq 'executor') {
        Get-CollabInventoryDigest -DataRoot $DataRoot -TaskId $Task.taskId -ImplementationOnly
    } elseif ($Failure.role -eq 'reviewer' -and $kind -eq 'plan') {
        Get-CollabSha256 (Get-CollabPlanPath -DataRoot $DataRoot -Task $Task)
    } else { Get-CollabInventoryDigest -DataRoot $DataRoot -TaskId $Task.taskId }
    foreach ($run in @($Runs)) {
        if (-not $run.accepted -or $run.role -ne $Failure.role -or
            (Get-CollabRevision $run) -ne $revision -or
            (Get-CollabRevision $run 'planRevision') -ne (Get-CollabRevision $Task 'planRevision') -or
            $run.scopeCheck -ne 'clean' -or -not (Test-CollabEffectiveCleanup -DataRoot $DataRoot -Run $run) -or
            -not $run.resultSha256 -or (Get-CollabSha256 $run.resultFilePath) -ne $run.resultSha256) { continue }
        $recordHash=Get-CollabSha256 (Join-Path $paths.Logs "$($run.invocationId)/invocation.json")
        if (-not $recordHash) { continue }
        $isCarried=$null -ne $carried -and $run.invocationId -ceq $carried.invocationId -and $recordHash -eq $carried.recordSha256
        if ($run.invocationId -cin @($Boundary.priorInvocationIds) -and -not $isCarried) { continue }
        $replacement=@{invocationId=$run.invocationId;recordSha256=$recordHash}
        switch ($Failure.role) {
            executor {
                if ((Get-CollabPropertyValue $run 'implementationDigest') -eq $expected) { return $replacement }
            }
            { $_ -in @('tester','probe') } {
                if ($run.afterDigest -eq $expected) { return $replacement }
            }
            reviewer {
                if ($run.subjectKind -ne $kind -or $run.subjectSha256 -ne $expected) { continue }
                foreach ($review in @($Reviews)) {
                    if ($review.reviewerInvocationId -cne $run.invocationId -or
                        (Get-CollabRevision $review) -ne $revision -or
                        (Get-CollabRevision $review 'planRevision') -ne (Get-CollabRevision $Task 'planRevision') -or
                        $review.subjectKind -ne $kind -or $review.subjectSha256 -ne $expected -or
                        $review.verdict -notin @('PASS','PASS WITH NITS') -or @($review.blockingFindings).Count -or
                        (Get-CollabSha256 $review.artifactPath) -ne $review.artifactSha256) { continue }
                    $reviewHash=Get-CollabSha256 (Join-Path $paths.Reviews "$($review.reviewId).json")
                    if (-not $reviewHash) { continue }
                    if ($review.reviewId -cin @($Boundary.priorReviewIds) -and
                        (-not $isCarried -or $review.reviewId -cne (Get-CollabPropertyValue $carried 'reviewId') -or
                         $reviewHash -ne (Get-CollabPropertyValue $carried 'reviewRecordSha256'))) { continue }
                    $replacement.reviewId=$review.reviewId
                    $replacement.reviewRecordSha256=$reviewHash
                    return $replacement
                }
            }
        }
    }
    return $null
}

function Test-CollabContinuationGate {
    param([string]$DataRoot,$Task,[array]$Runs,[switch]$VerificationOnly)
    $reasons=[Collections.Generic.List[string]]::new()
    $revision=Get-CollabRevision $Task
    $current=@($Runs | Where-Object { (Get-CollabRevision $_) -eq $revision })
    $failed=@($current | Where-Object { -not $_.accepted })
    $boundary=Get-CollabPropertyValue $Task 'continuation'
    if ($failed.Count -eq 0 -and $null -eq $boundary) { return @{Ok=$true;Code='continuation_verified';Reasons=@()} }
    if ($null -eq $boundary -or (Get-CollabRevision $boundary) -ne $revision) {
        return @{Ok=$false;Code='continuation_pending';Reasons=@('Current failures need an explicit Handoff boundary or full implementation Rework')}
    }
    $covered=@($boundary.failures)
    foreach ($failure in $failed) {
        if (-not (Test-CollabCleanInvocationFailure $failure)) {
            $reasons.Add("Failure requires full implementation Rework after recovery: $($failure.invocationId)")
        }
        if (@($covered | Where-Object { $_.invocationId -ceq $failure.invocationId }).Count -ne 1) {
            $reasons.Add("Failure has no current Handoff disposition: $($failure.invocationId)")
        }
    }
    $integrity=Test-CollabFailureBindings -DataRoot $DataRoot -Task $Task -Boundary $boundary -Runs $current
    foreach ($reason in $integrity.Reasons) { $reasons.Add($reason) }
    $digest=Get-CollabInventoryDigest -DataRoot $DataRoot -TaskId $Task.taskId
    $fresh=@($current | Where-Object {
        $_.accepted -and $_.invocationId -cnotin @($boundary.priorInvocationIds) -and
        $_.scopeCheck -eq 'clean' -and (Test-CollabEffectiveCleanup -DataRoot $DataRoot -Run $_) -and
        $_.resultSha256 -and (Get-CollabSha256 $_.resultFilePath) -eq $_.resultSha256
    })
    $freshTesters=@($fresh | Where-Object { $_.role -eq 'tester' -and $_.afterDigest -eq $digest })
    if (-not $freshTesters.Count) { $reasons.Add('Handoff requires a subsequent successful tester for the current subject') }
    $reviews=@(Get-CollabReviewRecords -DataRoot $DataRoot -TaskId $Task.taskId)
    $freshReviews=@($reviews | Where-Object {
        (Get-CollabRevision $_) -eq $revision -and $_.reviewId -cnotin @($boundary.priorReviewIds) -and
        $_.reviewerInvocationId -cin @($fresh.invocationId) -and $_.verdict -in @('PASS','PASS WITH NITS') -and
        @($_.blockingFindings).Count -eq 0 -and (Get-CollabSha256 $_.artifactPath) -eq $_.artifactSha256
    })
    foreach ($failure in $failed) {
        $binding=@($covered | Where-Object { $_.invocationId -ceq $failure.invocationId })
        $replacement=if ($binding.Count -eq 1) {
            Get-CollabFailureReplacement -DataRoot $DataRoot -Task $Task -Failure $failure -Binding $binding[0] -Boundary $boundary -Runs $current -Reviews $reviews
        } else { $null }
        if ($null -eq $replacement) { $reasons.Add("Handoff requires successful replacement verification for $($failure.role): $($failure.invocationId)") }
    }
    if (-not $VerificationOnly) {
        $evidence=@(Get-CollabEvidenceRecords -DataRoot $DataRoot -TaskId $Task.taskId)
        $freshEvidence=@($evidence | Where-Object {
            (Get-CollabRevision $_) -eq $revision -and $_.evidenceId -cnotin @($boundary.priorEvidenceIds) -and
            $_.subjectSha256 -eq $digest -and
            (Get-CollabSha256 $_.absolutePath) -eq $_.sha256
        })
        foreach ($item in @($Task.acceptance)) {
            $passed=@($freshEvidence | Where-Object { $_.evidenceId -cin @($item.evidence) -and $_.status -eq 'passed' })
            if ($item.status -ne 'passed' -or -not $passed.Count -or
                @($item.evidence | Where-Object { $_ -cnotin @($freshEvidence.evidenceId) }).Count) {
                $reasons.Add("Handoff requires fresh acceptance evidence: $($item.id)")
            }
        }
        if ($Task.requiresRealWorkflow -and (-not $Task.realWorkflowVerified -or
            -not @($freshEvidence | Where-Object { $_.kind -eq 'real_workflow' -and $_.status -eq 'passed' }).Count)) {
            $reasons.Add('Handoff requires fresh real-workflow verification')
        }
        if ($Task.grade -eq 'important' -and -not @($freshReviews | Where-Object {
            $_.subjectKind -eq 'result' -and $_.subjectSha256 -eq $digest
        }).Count) { $reasons.Add('Handoff requires a fresh independent result review') }
    }
    return @{Ok=($reasons.Count -eq 0);Code=$(if ($reasons.Count) {'continuation_pending'} else {'continuation_verified'});Reasons=@($reasons)}
}

function Start-CollabRework {
    param($Context,$Task,[hashtable]$Request)
    foreach ($key in $Request.Keys) {
        if ($key -notin @('TaskId','ExpectedRevision','ExpectedDigest','Reason','PlanFile','ReuseImplementationFrom')) { throw "Unsupported Rework field: $key" }
    }
    $root=$Context.Root; $data=$Context.DataRoot
    $revision=Get-CollabRevision $Task
    if ($Request['ExpectedRevision'] -ne $revision) { throw 'Rework ExpectedRevision mismatch' }
    if ($Request['ExpectedDigest'] -ne (Get-CollabInventoryDigest -DataRoot $data -TaskId $Task.taskId)) { throw 'Rework ExpectedDigest mismatch' }
    if ([string]::IsNullOrWhiteSpace($Request['Reason'])) { throw 'Rework needs the issue and intended correction in Reason' }
    if ($Task.state -notin @('planned','plan_reviewed','implementing','validating','result_reviewed','blocked','handoff_required')) { throw "Rework cannot enter from $($Task.state)" }
    if (@(Get-CollabOpenViolations -DataRoot $data).Count -or $null -ne (Get-CollabCleanupFlag -DataRoot $data)) { throw 'Resolve project violations and cleanup before rework' }
    $runs=@(Get-CollabInvocationRecords -DataRoot $data -TaskId $Task.taskId)
    if (@($runs | Where-Object {-not (Test-CollabEffectiveCleanup -DataRoot $data -Run $_)}).Count) { throw 'Rework requires verified cleanup for every prior invocation' }
    if (@($Task.blockers | Where-Object {$_.kind -ne 'review_fail'}).Count) { throw 'Rework handles review findings; other blockers require separate resolution' }
    foreach ($test in @($Task.frozenTests)) {
        $path=(Assert-CollabOk (Resolve-CollabPath -Root $root -RelativePath $test.path)).FullPath
        if ((Get-CollabSha256 $path) -ne $test.sha256) { throw 'Frozen test changed before rework' }
    }
    $planBytes=$null
    $nextRevision=$revision+1
    $planRevision=Get-CollabRevision $Task 'planRevision'
    $target='implementing'
    if ($Request['PlanFile']) {
        $source=(Assert-CollabOk (Resolve-CollabPath -Root $root -RelativePath $Request['PlanFile'])).FullPath
        $planBytes=[IO.File]::ReadAllBytes($source)
        if (-not $planBytes.Length) { throw 'Revised plan is empty' }
        $planRevision=$nextRevision
        $target='planned'
    } elseif ($Task.grade -eq 'important') {
        $null=Get-CollabSubject -Context $Context -Task $Task -Kind plan
        $null=Assert-CollabOk (Test-CollabReviewGate -Root $root -DataRoot $data -Task $Task -SubjectKind plan)
    }
    $reuse=$null
    if ($Request['ReuseImplementationFrom']) {
        if ($Request['PlanFile']) { throw 'Plan changes require fresh implementation' }
        $current=@($runs | Where-Object { (Get-CollabRevision $_) -eq $revision })
        if (@($current | Where-Object { -not $_.accepted }).Count) {
            $recovery=Test-CollabContinuationGate -DataRoot $data -Task $Task -Runs $runs
            if (-not $recovery.Ok) { throw ('Failed invocations require verified Handoff continuation or full implementation rework: '+($recovery.Reasons -join '; ')) }
        }
        $candidates=@(Get-CollabEffectiveExecutors -DataRoot $data -Task $Task -Runs $runs)
        $source=@($candidates | Where-Object { $_.invocationId -ceq $Request['ReuseImplementationFrom'] })
        if ($source.Count -ne 1) { throw 'Choose an accepted implementation from the current revision or its existing reuse binding' }
        $source=$source[0]
        $expected=Get-CollabPropertyValue $source 'implementationDigest'
        if (-not $expected -or $expected -ne (Get-CollabInventoryDigest -DataRoot $data -TaskId $Task.taskId -ImplementationOnly) -or
            (Get-CollabRevision $source 'planRevision') -ne $planRevision -or $source.scopeCheck -ne 'clean' -or
            (Get-CollabSha256 $source.resultFilePath) -ne $source.resultSha256) { throw 'Implementation reuse requires unchanged files, plan and intact evidence' }
        $sourcePath=Join-Path (Get-CollabTaskPaths -DataRoot $data -TaskId $Task.taskId).Logs "$($source.invocationId)/invocation.json"
        $reuse=@{invocationId=$source.invocationId;recordSha256=(Get-CollabSha256 $sourcePath)}
        $target='validating'
    }
    if ($target -in @('implementing','validating')) { $null=Assert-CollabOk (Test-CollabBackupGate -Root $root -DataRoot $data -Task $Task -IntegrityOnly) }
    $paths=Get-CollabTaskPaths -DataRoot $data -TaskId $Task.taskId
    $id="r$nextRevision-$(New-CollabNonce -Bytes 6)"
    # Save the complete prior state before the single atomic task-pointer update.
    $archive=Join-Path $paths.Directory "revisions/$id.json"
    $null=Write-CollabJsonAtomic -Path $archive -Object @{previous=$Task;nextRevision=$nextRevision;reason=$Request['Reason'];atUtc=(Format-CollabTime (Get-CollabUtcNow))}
    $next=$Task | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    if ($null -ne $planBytes) {
        $planRelative="$($paths.Relative)/revisions/$id-plan.md"
        $planPath=Join-Path $root $planRelative
        [IO.File]::WriteAllBytes($planPath,$planBytes)
        $next.plan=[pscustomobject]@{storedPath=$planRelative;sourcePath=$source;sha256=(Get-CollabSha256 $planPath);capturedAtUtc=(Format-CollabTime (Get-CollabUtcNow))}
    }
    $next | Add-Member -NotePropertyName revision -NotePropertyValue $nextRevision -Force
    $next | Add-Member -NotePropertyName planRevision -NotePropertyValue $planRevision -Force
    $next | Add-Member -NotePropertyName reworkReason -NotePropertyValue $Request['Reason'] -Force
    $next | Add-Member -NotePropertyName reusedImplementation -NotePropertyValue $reuse -Force
    $next | Add-Member -NotePropertyName continuation -NotePropertyValue $null -Force
    foreach ($item in @($next.acceptance)) { $item.status='pending'; $item.evidence=@(); $item.verifiedAtUtc=$null }
    $next.realWorkflowVerified=$false
    $next.coordinatorSignoff=$null
    $next.blockers=@()
    $next.stateHistory=@($next.stateHistory)+@([pscustomobject]@{atUtc=(Format-CollabTime (Get-CollabUtcNow));from=$Task.state;to=$target;actor='coordinator';reason=$Request['Reason'];revision=$nextRevision})
    $next.state=$target
    $null=Assert-CollabOk (Save-CollabTask -DataRoot $data -Task $next)
    $null=Add-CollabAudit -DataRoot $data -Action rework_started -TaskId $Task.taskId -Detail @{revision=$nextRevision;planRevision=$planRevision;archive=$archive}
    return @{Ok=$true;Code='rework_started';Task=$next;Archive=$archive}
}

function New-CollabRoleContext {
    param($Context,$Task,[hashtable]$Request)
    $role=[string]$Request['Role']
    if ($role -notin @('executor','tester','reviewer','probe')) { throw 'PrepareContext requires a worker Role' }
    $revision=Get-CollabRevision $Task
    $digest=Get-CollabInventoryDigest -DataRoot $Context.DataRoot -TaskId $Task.taskId
    if ($Request['ExpectedRevision'] -ne $revision -or $Request['ExpectedDigest'] -ne $digest) { throw 'PrepareContext current revision/digest required' }
    $briefPath=(Assert-CollabOk (Resolve-CollabPath -Root $Context.Root -RelativePath $Request['PromptFile'])).FullPath
    $brief=(Protect-CollabSecret ([IO.File]::ReadAllText($briefPath))).Text
    if ([string]::IsNullOrWhiteSpace($brief)) { throw 'Context brief is empty' }
    $references=@()
    $paths=@('AGENTS.md','COLLABORATION.md','COLLABORATION-SETUP.md','.agents/collaboration/README.md')
    if ($Request.ContainsKey('References')) { $paths+=@($Request['References']) }
    if ($null -ne $Task.plan) { $paths+=$Task.plan.storedPath }
    $prior=@()
    if ($Request.ContainsKey('PriorInvocationIds')) {
        foreach ($id in @($Request['PriorInvocationIds'])) {
            $matches=@(Get-CollabInvocationRecords -DataRoot $Context.DataRoot -TaskId $Task.taskId | Where-Object {$_.invocationId -ceq $id})
            if ($matches.Count -ne 1) { throw "Unknown prior invocation: $id" }
            $run=$matches[0]
            $paths += [IO.Path]::GetRelativePath($Context.Root,$run.resultFilePath).Replace('\','/')
            $prior+=@{invocationId=$id;role=$run.role;revision=(Get-CollabRevision $run);accepted=$run.accepted}
        }
    }
    foreach ($path in @($paths | Sort-Object -Unique -CaseSensitive)) {
        $safe=Assert-CollabOk (Resolve-CollabPath -Root $Context.Root -RelativePath $path)
        $hash=Get-CollabSha256 $safe.FullPath
        if (-not $hash) { throw "Context reference missing: $path" }
        $references+=@{path=$safe.RelativePath;sha256=$hash}
    }
    $focus=@{executor='Implement the assigned change within the exact write paths.';tester='Independently test acceptance requirements and relevant regressions.';reviewer='Review the stated plan or result and cite concrete findings.';probe='Inspect the assigned compatibility question with read-only tools.'}[$role]
    $delta=(Protect-CollabSecret ([string]$Request['Delta'])).Text
    $lines=@(
        "Task: $($Task.taskId); revision: $revision; role: $role"
        "Scope digest: $digest"
        "Focus: $focus"
        "Acceptance: $(($Task.acceptance | ForEach-Object { "$($_.id): $($_.requirement)" }) -join '; ')"
        "Current request:`n$brief"
        "Changes and unresolved issues:`n$delta"
        'Read the referenced project rules and role-relevant material directly. References are bound to this dispatch; source text is kept in its authoritative file.'
    )
    foreach ($reference in $references) { $lines+="- $($reference.path) [SHA256 $($reference.sha256)]" }
    if ($prior.Count) { $lines+="Prior invocation index: $($prior|ConvertTo-Json -Depth 8 -Compress)" }
    $lines+='Return concrete changes or findings, commands and actual results, evidence paths, remaining issues and cleanup. Cite paths instead of repeating source files.'
    $text=$lines -join "`n"
    $contextId='C'+(New-CollabNonce -Bytes 8)
    $directory=Join-Path (Get-CollabTaskPaths -DataRoot $Context.DataRoot -TaskId $Task.taskId).Directory 'context'
    $promptPath=Join-Path $directory "$contextId.md"
    $null=Write-CollabRedactedFile -Path $promptPath -Text $text
    $pack=@{contextId=$contextId;taskId=$Task.taskId;role=$role;revision=$revision;planRevision=(Get-CollabRevision $Task 'planRevision');digest=$digest;references=$references;promptPath=$promptPath;promptSha256=(Get-CollabSha256 $promptPath);priorInvocations=$prior;atUtc=(Format-CollabTime (Get-CollabUtcNow))}
    $manifest=Join-Path $directory "$contextId.json"
    $null=Write-CollabJsonAtomic -Path $manifest -Object $pack
    return @{Ok=$true;Code='context_prepared';ContextId=$contextId;Revision=$revision;PromptPath=$promptPath;Manifest=$manifest;ReferenceCount=$references.Count}
}

function Read-CollabRoleContext {
    param($Context,$Task,[string]$Role,[string]$ContextId)
    $null=Assert-CollabOk (Assert-CollabIdentifier -Value $ContextId -What 'context id')
    $path=Join-Path (Get-CollabTaskPaths -DataRoot $Context.DataRoot -TaskId $Task.taskId).Directory "context/$ContextId.json"
    $pack=(Assert-CollabOk (Read-CollabJson $path)).Value
    if ($null -eq $pack -or $pack.taskId -cne $Task.taskId -or $pack.contextId -cne $ContextId -or $pack.role -cne $Role) { throw 'Context identity/role mismatch' }
    if ($pack.revision -ne (Get-CollabRevision $Task) -or $pack.planRevision -ne (Get-CollabRevision $Task 'planRevision') -or $pack.digest -ne (Get-CollabInventoryDigest -DataRoot $Context.DataRoot -TaskId $Task.taskId)) { throw 'Context is stale; prepare current role context' }
    $expected=Join-Path (Split-Path -Parent $path) "$ContextId.md"
    if ($pack.promptPath -cne $expected -or (Get-CollabSha256 $expected) -ne $pack.promptSha256) { throw 'Context prompt changed' }
    foreach ($reference in @($pack.references)) {
        $safe=Assert-CollabOk (Resolve-CollabPath -Root $Context.Root -RelativePath $reference.path)
        if ((Get-CollabSha256 $safe.FullPath) -ne $reference.sha256) { throw "Context reference changed: $($reference.path)" }
    }
    return $pack
}
