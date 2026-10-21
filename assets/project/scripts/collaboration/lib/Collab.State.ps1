# Collab.State.ps1 - task records, the stage machine and the transition gates.
#
# The state machine is structural: it proves that the required records exist,
# point at existing files and agree on hashes. It never claims to prove that an
# implementation is correct - the coordinator still has to read the evidence.

Set-StrictMode -Version 2.0

$script:CollabStates = @('planned', 'plan_reviewed', 'implementing', 'validating', 'result_reviewed', 'complete', 'blocked', 'failed_closed', 'handoff_required', 'cancelled')
$script:CollabWorkerRoles = @('executor', 'tester', 'reviewer')
$script:CollabAllRoles = @('coordinator', 'executor', 'tester', 'reviewer', 'probe')

function Get-CollabStateList {
    [CmdletBinding()]
    param()
    return $script:CollabStates
}

function Get-CollabRoleList {
    [CmdletBinding()]
    param()
    return @{ workers = $script:CollabWorkerRoles; all = $script:CollabAllRoles }
}

function Get-CollabTaskRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)
    return (Join-Path $DataRoot 'tasks')
}

function Get-CollabTaskPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId
    )
    $idCheck = Assert-CollabIdentifier -Value $TaskId -What 'task id'
    if (-not $idCheck.Ok) { return $idCheck }
    $taskDirectory = Join-Path (Get-CollabTaskRoot -DataRoot $DataRoot) $TaskId
    return @{
        Ok        = $true
        Code      = 'ok'
        Directory = $taskDirectory
        TaskFile  = Join-Path $taskDirectory 'task.json'
        Creation  = Join-Path $taskDirectory 'creation.json'
        Plan      = Join-Path $taskDirectory 'plan.md'
        Evidence  = Join-Path $taskDirectory 'evidence'
        Reviews   = Join-Path $taskDirectory 'reviews'
        Inventory = Join-Path $taskDirectory 'inventory'
        Logs      = Join-Path $taskDirectory 'logs'
        Handoff   = Join-Path $taskDirectory 'handoff'
        Relative  = ".collaboration/tasks/$TaskId"
    }
}

function Test-CollabTaskCreationBinding {
    <# Only NewTask creates this binding. Never infer a missing legacy grade. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$TaskId)
    $read = Read-CollabJson -Path $Paths.Creation
    if (-not $read.Ok -or $null -eq $read.Value) {
        return @{ Ok=$false; Code='grade_binding_missing'; Reasons=@('Creation-time grade binding is missing or unreadable; legacy grades are never inferred.') }
    }
    $binding = $read.Value
    $grade = [string](Get-CollabPropertyValue -Object $binding -Name 'grade')
    $created = Get-CollabPropertyValue -Object $binding -Name 'createdAtUtc'
    $taskCreated = Get-CollabPropertyValue -Object $Task -Name 'createdAtUtc'
    $sameCreation = $false
    if ($null -ne $created -and $null -ne $taskCreated) {
        try { $sameCreation = ([datetime]$created).ToUniversalTime().Ticks -eq ([datetime]$taskCreated).ToUniversalTime().Ticks } catch { $sameCreation = $false }
    }
    if ($grade -notin @('ordinary','important') -or -not $sameCreation -or
        [string](Get-CollabPropertyValue -Object $binding -Name 'taskId') -cne $TaskId -or
        [string](Get-CollabPropertyValue -Object $Task -Name 'taskId') -cne $TaskId -or
        [string](Get-CollabPropertyValue -Object $Task -Name 'grade') -cne $grade) {
        return @{ Ok=$false; Code='grade_immutable'; Reasons=@('Task identity, creation time or grade differs from its immutable creation binding. Create a new task instead.') }
    }
    foreach ($field in @('allowedPaths','testerWritePaths')) {
        $original=Get-CollabPropertyValue $binding $field
        $current=Get-CollabPropertyValue $Task $field
        if ($null -ne $original -and (ConvertTo-Json -InputObject @($original) -Compress) -cne (ConvertTo-Json -InputObject @($current) -Compress)) { return @{Ok=$false;Code='scope_binding_changed';Reasons=@("Creation-bound $field changed")} }
        if ($field -eq 'testerWritePaths' -and $null -eq $original -and @($current | Where-Object {$null -ne $_}).Count) { return @{Ok=$false;Code='role_binding_missing';Reasons=@('Create a task with TesterWritePath before assigning test-file writes')} }
    }
    return @{ Ok=$true; Code='ok' }
}

function Read-CollabTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId
    )
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $TaskId
    if (-not $paths.Ok) { return $paths }
    $read = Read-CollabJson -Path $paths.TaskFile
    if (-not $read.Ok) { return $read }
    if ($null -eq $read.Value) {
        return @{ Ok = $false; Code = 'task_missing'; Reasons = @("No task record for '$TaskId' at $($paths.TaskFile)") }
    }
    $binding = Test-CollabTaskCreationBinding -Paths $paths -Task $read.Value -TaskId $TaskId
    if (-not $binding.Ok) { return $binding }
    return @{ Ok = $true; Code = 'ok'; Task = $read.Value; Paths = $paths }
}

function Get-CollabAllTasks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)
    $tasks = @()
    $root = Get-CollabTaskRoot -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $tasks }
    foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $read = Read-CollabTask -DataRoot $DataRoot -TaskId $directory.Name
        if ($read.Ok) { $tasks += $read.Task }
    }
    return @($tasks)
}

function Save-CollabTask {
    <# Atomic write with two invariants enforced here: the grade is immutable and
       the schema version never goes backwards. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task
    )
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
    if (-not $paths.Ok) { return $paths }
    $binding = Test-CollabTaskCreationBinding -Paths $paths -Task $Task -TaskId $Task.taskId
    if (-not $binding.Ok) { return $binding }

    if (Test-Path -LiteralPath $paths.TaskFile -PathType Leaf) {
        $existing = Read-CollabJson -Path $paths.TaskFile
        if (-not $existing.Ok) {
            return @{ Ok = $false; Code = 'task_unreadable'; Reasons = @("Existing task record is unreadable; refusing to overwrite: $($existing.Reasons -join '; ')") }
        }
        if ($null -ne $existing.Value -and [string]$existing.Value.grade -ne [string]$Task.grade) {
            return @{ Ok = $false; Code = 'grade_immutable'; Reasons = @("Grade is immutable: recorded '$($existing.Value.grade)' vs new '$($Task.grade)'. Create a new task instead.") }
        }
        if ($null -eq $existing.Value) { return @{ Ok=$false; Code='task_unreadable'; Reasons=@('Existing task record is empty; refusing to overwrite') } }
        $existingBinding = Test-CollabTaskCreationBinding -Paths $paths -Task $existing.Value -TaskId $Task.taskId
        if (-not $existingBinding.Ok) { return $existingBinding }
    }
    $Task.updatedAtUtc = Format-CollabTime -Time (Get-CollabUtcNow)
    Write-CollabJsonAtomic -Path $paths.TaskFile -Object $Task | Out-Null
    return @{ Ok = $true; Code = 'ok'; Path = $paths.TaskFile; Task = $Task }
}

function Test-CollabMaintenancePaths {
    <# Maintenance/rules/control-suite edits require grade=important plus an
       explicit maintenance flag; the historical integration report and live
       control state are never editable through a task. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedPath,
        [Parameter(Mandatory)]$Config
    )
    $immutable = @($Config.protected.immutablePaths)
    $maintenance = @($Config.protected.maintenancePaths)
    $never = @($Config.protected.neverAllowWithinMaintenance)
    $needsMaintenance = @()
    $blocked = @()
    foreach ($path in $AllowedPath) {
        if (Test-CollabPathMatchesAny -Path $path -Patterns $immutable) {
            $blocked += "immutable path is never editable through a task: $path"
            continue
        }
        if (Test-CollabPathMatchesAny -Path $path -Patterns $never) {
            $blocked += "live control state can never be an allowed path: $path"
            continue
        }
        if (Test-CollabPathMatchesAny -Path $path -Patterns $maintenance) {
            $needsMaintenance += $path
        }
    }
    return @{ NeedsMaintenance = @($needsMaintenance); Blocked = @($blocked) }
}

function Test-CollabWorkerDeny {
    <# A normal worker scope must not contain collaboration control data. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedPath,
        [Parameter(Mandatory)]$Config,
        [switch]$Maintenance
    )
    $deny = @($Config.protected.workerDenyPaths)
    $never = @($Config.protected.neverAllowWithinMaintenance)
    $hits = @()
    foreach ($path in $AllowedPath) {
        if (-not (Test-CollabPathMatchesAny -Path $path -Patterns $deny)) { continue }
        if ($Maintenance -and -not (Test-CollabPathMatchesAny -Path $path -Patterns $never)) { continue }
        $hits += $path
    }
    return @($hits)
}

function New-CollabTaskRecord {
    <# Creates the task record. Fails closed on unset grade, empty authorization,
       empty acceptance, unsafe or forbidden paths and unreadable frozen tests. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Grade,
        [Parameter(Mandatory)][AllowEmptyString()][string]$GradeReason,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Authorization,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Acceptance,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedPath,
        [AllowEmptyCollection()][string[]]$FrozenTest = @(),
        [AllowEmptyCollection()][string[]]$TesterWritePath = @(),
        [switch]$Maintenance,
        [string]$PlanFile,
        [switch]$RequiresRealWorkflow,
        [string]$Actor = 'coordinator',
        [string]$Notes = ''
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($Actor -ne 'coordinator') { return New-CollabOutcome -Ok $false -Code 'coordinator_required' }
    $prior = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $TaskId
    if (-not $prior.Ok) { return $prior }
    if ((Test-Path -LiteralPath $prior.TaskFile) -or (Test-Path -LiteralPath $prior.Creation)) { return New-CollabOutcome -Ok $false -Code 'task_exists' }

    $idCheck = Assert-CollabIdentifier -Value $TaskId -What 'task id'
    if (-not $idCheck.Ok) { return New-CollabOutcome -Ok $false -Code $idCheck.Code -Reasons $idCheck.Reasons }

    if ($Grade -notin @('important', 'ordinary')) {
        $reasons.Add("grade must be 'important' or 'ordinary' (got '$Grade'); the grade is never inferred")
    }
    if ([string]::IsNullOrWhiteSpace($GradeReason)) { $reasons.Add('grade reason must not be empty') }
    if ([string]::IsNullOrWhiteSpace($Authorization)) { $reasons.Add('authorization prose must not be empty (a boolean flag is not accepted)') }
    if (@($Acceptance).Count -eq 0) { $reasons.Add('at least one acceptance item is required') }
    if (@($AllowedPath).Count -eq 0) { $reasons.Add('at least one allowed path is required') }

    $acceptanceItems = @()
    $seenIds = @{}
    foreach ($item in @($Acceptance)) {
        $itemId = [string](Get-CollabPropertyValue -Object $item -Name 'id')
        $requirement = [string](Get-CollabPropertyValue -Object $item -Name 'requirement')
        if ([string]::IsNullOrWhiteSpace($itemId) -or [string]::IsNullOrWhiteSpace($requirement)) {
            $reasons.Add('each acceptance item needs a non-empty id and requirement')
            continue
        }
        if ($seenIds.ContainsKey($itemId)) { $reasons.Add("duplicate acceptance id '$itemId'"); continue }
        $seenIds[$itemId] = $true
        $acceptanceItems += [ordered]@{
            id          = $itemId
            requirement = $requirement
            status      = 'pending'
            evidence    = @()
            verifiedAtUtc = $null
        }
    }

    $safeAllowed = @()
    foreach ($path in @($AllowedPath)) {
        $resolved = Resolve-CollabPath -Root $Root -RelativePath $path
        if (-not $resolved.Ok) {
            $reasons.Add("allowed path rejected ($($resolved.Code)): $path - $($resolved.Reasons -join '; ')")
            continue
        }
        if (Test-Path -LiteralPath $resolved.FullPath -PathType Container) {
            $reasons.Add("Use exact file scopes: $path")
            continue
        }
        $safeAllowed += $resolved.RelativePath
    }

    $identities = Get-CollabPathIdentityMap -Root $Root -Path @($safeAllowed + @($FrozenTest))
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $safeAllowed) {
        if (-not $seenPaths.Add($identities[$path])) { $reasons.Add("Duplicate allowed file identity by path: $path") }
    }
    $testerPaths=@()
    foreach ($path in $TesterWritePath) {
        $safe=Resolve-CollabPath -Root $Root -RelativePath $path
        if (-not $safe.Ok -or $safe.RelativePath -cnotin $safeAllowed -or @($FrozenTest | Where-Object {$identities[$_] -ceq $identities[$safe.RelativePath]}).Count -gt 0) { $reasons.Add("TesterWritePath must name an allowed, unfrozen test file: $path"); continue }
        $testerPaths+=$safe.RelativePath
    }
    $maintenanceCheck = Test-CollabMaintenancePaths -AllowedPath $safeAllowed -Config $Config
    foreach ($blockedPath in $maintenanceCheck.Blocked) { $reasons.Add($blockedPath) }
    if ($maintenanceCheck.NeedsMaintenance.Count -gt 0) {
        if (-not $Maintenance) {
            $reasons.Add("path(s) touch the maintenance surface and require -Maintenance: $($maintenanceCheck.NeedsMaintenance -join ', ')")
        }
        elseif ($Grade -ne 'important') {
            $reasons.Add('maintenance/rules/control-suite work must be graded important; the grade is never silently upgraded - create the task as important')
        }
    }
    if ($Maintenance -and $Grade -ne 'important') {
        $reasons.Add('-Maintenance requires grade important')
    }
    $workerDenyHits = @(Test-CollabWorkerDeny -AllowedPath $safeAllowed -Config $Config -Maintenance:$Maintenance)
    if ($workerDenyHits.Count -gt 0) {
        $reasons.Add("allowed path(s) collide with the worker deny list: $($workerDenyHits -join ', ')")
    }

    $frozenEntries = @()
    foreach ($test in @($FrozenTest)) {
        $resolved = Resolve-CollabPath -Root $Root -RelativePath $test
        if (-not $resolved.Ok) {
            $reasons.Add("frozen test path rejected ($($resolved.Code)): $test")
            continue
        }
        if (-not (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf)) {
            $reasons.Add("frozen test file does not exist yet (record it after it is written): $test")
            continue
        }
        $frozenEntries += [ordered]@{ path = $resolved.RelativePath; sha256 = (Get-CollabSha256 -Path $resolved.FullPath) }
    }

    $planRecord = $null
    if (-not [string]::IsNullOrWhiteSpace($PlanFile)) {
        $planResolved = Resolve-CollabPath -Root $Root -RelativePath $PlanFile
        if (-not $planResolved.Ok) { return $planResolved }
        $planPath = $planResolved.FullPath
        if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
            $reasons.Add("plan file not found: $PlanFile")
        }
        else {
            $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $TaskId
            if (-not $paths.Ok) { $reasons.Add($paths.Reasons -join '; ') }
            else {

                $planRecord = [ordered]@{
                    sourcePath   = $planPath
                    storedPath   = '.collaboration/tasks/' + $TaskId + '/plan.md'
                    sha256       = (Get-CollabSha256 -Path $planPath)
                    capturedAtUtc = Format-CollabTime -Time (Get-CollabUtcNow)
                }
            }
        }
    }
    if ($Grade -eq 'important' -and $null -eq $planRecord) {
        $reasons.Add('important tasks require a plan file (use the plan review gate before implementing)')
    }

    if ($reasons.Count -gt 0) {
        return New-CollabOutcome -Ok $false -Code 'task_invalid' -Reasons @($reasons)
    }

    if ($null -ne $planRecord) {
        New-Item -ItemType Directory -Force -Path $prior.Directory | Out-Null
        Copy-Item -LiteralPath $planPath -Destination $prior.Plan -ErrorAction Stop
    }
    $now = Get-CollabUtcNow
    $record = [ordered]@{
        schemaVersion           = 1
        taskId                  = $TaskId
        revision                = 1
        planRevision            = 1
        grade                   = $Grade
        gradeReason             = $GradeReason
        authorization           = $Authorization
        maintenance             = [bool]$Maintenance
        maintenanceAllowlist    = @($safeAllowed | Where-Object { Test-CollabPathMatchesAny -Path $_ -Patterns @($Config.protected.maintenancePaths) })
        acceptance              = @($acceptanceItems)
        allowedPaths            = @($safeAllowed)
        testerWritePaths        = @($testerPaths)
        frozenTests             = @($frozenEntries)
        requiresRealWorkflow    = [bool]$RequiresRealWorkflow
        state                   = 'planned'
        stateHistory            = @([ordered]@{ atUtc = Format-CollabTime -Time $now; from = ''; to = 'planned'; actor = $Actor; reason = 'task created' })
        blockers                = @()
        reviews                 = @()
        createdAtUtc            = Format-CollabTime -Time $now
        updatedAtUtc            = Format-CollabTime -Time $now
        plan                    = $planRecord
        backupManifest          = $null
        controlSnapshotSha256   = $null
        realWorkflowVerified    = $false
        desktopWorkflowVerified = $false
        cleanupVerified         = $false
        coordinatorSignoff      = $null
        notes                   = $Notes
    }

    # CreateNew prevents replacement of a prior binding, including partial creation.
    New-Item -ItemType Directory -Force -Path $prior.Directory | Out-Null
    $binding = [ordered]@{ taskId=$TaskId; grade=$Grade; createdAtUtc=$record.createdAtUtc; allowedPaths=@($safeAllowed); testerWritePaths=@($testerPaths) }
    try {
        $stream = [IO.File]::Open($prior.Creation, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($binding | ConvertTo-Json))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally { $stream.Dispose() }
    } catch { return New-CollabOutcome -Ok $false -Code 'grade_binding_create_failed' -Reasons @($_.Exception.Message) }
    $saved = Save-CollabTask -DataRoot $DataRoot -Task $record
    if (-not $saved.Ok) { return $saved }
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'task_created' -Actor $Actor -TaskId $TaskId -Detail @{
        grade         = $Grade
        maintenance   = [bool]$Maintenance
        allowedPaths  = @($safeAllowed)
        acceptanceIds = @($acceptanceItems | ForEach-Object { $_.id })
    }
    return New-CollabOutcome -Ok $true -Code 'created' -Data @{ Task = $record; Path = $saved.Path }
}

function Get-CollabTaskChangedInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId
    )
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $TaskId
    $entries = @()
    if ($paths.Ok -and (Test-Path -LiteralPath $paths.Inventory -PathType Container)) {
        foreach ($file in (Get-ChildItem -LiteralPath $paths.Inventory -Filter '*.diff.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $read = Read-CollabJson -Path $file.FullName
            if (-not $read.Ok -or $null -eq $read.Value) { continue }
            foreach ($group in @('added', 'modified', 'removed')) {
                foreach ($entry in @(Get-CollabPropertyValue -Object $read.Value -Name $group)) {
                    $entries += [ordered]@{
                        kind = $group
                        path = [string](Get-CollabPropertyValue -Object $entry -Name 'path')
                        hash = [string](Get-CollabPropertyValue -Object $entry -Name 'sha256')
                    }
                }
            }
        }
    }
    return @($entries | Sort-Object -Property path, kind)
}

function Get-CollabInventoryDigest {
    <# Digest over current content and absence of the task's allowed files.
       Result review binds this digest, so a later content change invalidates it. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [switch]$ImplementationOnly
    )
    # Bind the live exact-file scope, including absent files, not just old diff logs.
    $read = Read-CollabTask -DataRoot $DataRoot -TaskId $TaskId
    if (-not $read.Ok) { throw "Cannot digest missing task: $TaskId" }
    $projectRoot = Split-Path -Parent $DataRoot
    $selectedPaths = @($read.Task.allowedPaths)
    if ($ImplementationOnly) {
        $testerPaths = @(Get-CollabPropertyValue $read.Task 'testerWritePaths')
        $selectedPaths = @($selectedPaths | Where-Object { $_ -cnotin $testerPaths })
    }
    $entries = foreach ($path in @($selectedPaths | Sort-Object -Unique -CaseSensitive)) {
        $resolved = Resolve-CollabPath -Root $projectRoot -RelativePath $path
        if (-not $resolved.Ok) { throw "Unsafe digest path: $path" }
        $hash = Get-CollabSha256 -Path $resolved.FullPath
        if ($null -eq $hash) { $hash = 'ABSENT' }
        "$path|$hash"
    }
    return Get-CollabTextSha256 -Text ($entries -join "`n")
}

function Get-CollabInvocationRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TaskId
    )
    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $TaskId
    $records = @()
    if (-not $paths.Ok -or -not (Test-Path -LiteralPath $paths.Logs -PathType Container)) { return $records }
    foreach ($file in (Get-ChildItem -LiteralPath $paths.Logs -Recurse -Filter 'invocation.json' -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $read = Read-CollabJson -Path $file.FullName
        if ($read.Ok -and $null -ne $read.Value) { $records += $read.Value }
    }
    return @($records)
}

function Test-CollabTransition {
    <# Gate evaluation for a state transition. Returns Ok=$false with reasons when
       the structural evidence for the target stage is missing. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$To,
        [switch]$RealWorkflowVerified,
        [switch]$DesktopWorkflowVerified
    )
    $checks = New-Object System.Collections.Generic.List[object]
    $reasons = New-Object System.Collections.Generic.List[string]
    $state = [string]$Task.state

    if ($To -notin $script:CollabStates) {
        return New-CollabOutcome -Ok $false -Code 'state_unknown' -Reasons @("Unknown target state '$To'")
    }

    $terminal = @('complete', 'cancelled')
    if ($state -in $terminal) {
        return New-CollabOutcome -Ok $false -Code 'state_terminal' -Reasons @("Task is already '$state'; no further transition is allowed")
    }
    if ($state -eq $To) {
        return New-CollabOutcome -Ok $false -Code 'state_unchanged' -Reasons @("Task is already in state '$To'")
    }
    $predecessors = @{
        plan_reviewed=@('planned'); implementing=@('planned','plan_reviewed');
        validating=@('implementing'); result_reviewed=@('validating'); complete=@('validating','result_reviewed')
    }
    if ($predecessors.ContainsKey($To) -and $state -notin $predecessors[$To]) {
        return New-CollabOutcome -Ok $false -Code 'state_order' -Reasons @("Cannot advance from '$state' to '$To'")
    }
    if ($state -in @('failed_closed', 'handoff_required') -and $To -notin @('cancelled', 'blocked', 'handoff_required', 'failed_closed')) {
        return New-CollabOutcome -Ok $false -Code 'state_frozen' -Reasons @("State '$state' must be resolved by the coordinator (handoff or cancel) before '$To'")
    }

    $addCheck = {
        param([string]$Id, [bool]$Ok, [string]$Detail)
        $checks.Add([ordered]@{ id = $Id; ok = $Ok; detail = $Detail })
        if (-not $Ok) { $reasons.Add("${Id}: $Detail") }
    }

    $openViolations = @(Get-CollabOpenViolations -DataRoot $DataRoot)
    $cleanupFlag = Get-CollabCleanupFlag -DataRoot $DataRoot
    $blockers = @($Task.blockers)

    & $addCheck 'no_blockers' ($blockers.Count -eq 0) ("blockers: " + (@($blockers | ForEach-Object { $_.reason }) -join '; '))
    & $addCheck 'no_open_violations' ($openViolations.Count -eq 0) ("open violation(s): " + (@($openViolations | ForEach-Object { "$($_.kind)@$($_.invocationId)" }) -join ', '))
    & $addCheck 'cleanup_not_uncertain' ($null -eq $cleanupFlag) 'cleanup must be proven'

    switch ($To) {
        'plan_reviewed' {
            & $addCheck 'grade_important' ([string]$Task.grade -eq 'important') "grade is '$($Task.grade)'"
            $gate = Test-CollabReviewGate -Root $Root -DataRoot $DataRoot -Task $Task -SubjectKind 'plan'
            & $addCheck 'plan_review_accepted' $gate.Ok ($gate.Reasons -join '; ')
        }
        'implementing' {
            & $addCheck 'authorization_recorded' (-not [string]::IsNullOrWhiteSpace([string]$Task.authorization)) 'authorization prose is empty'
            & $addCheck 'acceptance_defined' (@($Task.acceptance).Count -gt 0) 'no acceptance items'
            & $addCheck 'allowed_paths_defined' (@($Task.allowedPaths).Count -gt 0) 'no allowed paths'
            if ([string]$Task.grade -eq 'important') {
                $gate = Test-CollabReviewGate -Root $Root -DataRoot $DataRoot -Task $Task -SubjectKind 'plan'
                & $addCheck 'plan_review_accepted' $gate.Ok ($gate.Reasons -join '; ')
            }
            else {
                $checks.Add([ordered]@{ id = 'plan_review_not_required'; ok = $true; detail = 'ordinary grade: independent plan review is optional' })
            }
            $maintenanceCheck = Test-CollabMaintenancePaths -AllowedPath @($Task.allowedPaths) -Config $Config
            & $addCheck 'maintenance_flag_consistent' `
                (($maintenanceCheck.NeedsMaintenance.Count -eq 0) -or ([bool]$Task.maintenance -and [string]$Task.grade -eq 'important')) `
                'allowed paths touch the maintenance surface without -Maintenance + important grade'
            $backupGate = Test-CollabBackupGate -Root $Root -DataRoot $DataRoot -Task $Task -IntegrityOnly:((Get-CollabRevision $Task) -gt 1)
            & $addCheck 'backup_manifest_valid' $backupGate.Ok ($backupGate.Reasons -join '; ')
        }
        'validating' {
            $invocations = @(Get-CollabInvocationRecords -DataRoot $DataRoot -TaskId $Task.taskId | Where-Object {(Get-CollabRevision $_) -eq (Get-CollabRevision $Task)})
            $executorRuns = @($invocations | Where-Object { $_.role -eq 'executor' -and $_.accepted -eq $true })
            & $addCheck 'executor_invocation_accepted' ($executorRuns.Count -gt 0) 'no accepted executor invocation recorded'
            & $addCheck 'scope_checked' `
                (@($invocations | Where-Object { $_.role -eq 'executor' -and $_.accepted -eq $true -and $_.scopeCheck -in @('clean', 'not_applicable') }).Count -gt 0) `
                'no accepted executor invocation with a clean scope check'
        }
        'result_reviewed' {
            & $addCheck 'grade_important' ([string]$Task.grade -eq 'important') "grade is '$($Task.grade)'"
            $gate = Test-CollabReviewGate -Root $Root -DataRoot $DataRoot -Task $Task -SubjectKind 'result'
            & $addCheck 'result_review_accepted' $gate.Ok ($gate.Reasons -join '; ')
        }
        'complete' {
            $completion = Test-CollabCompletionGate -Root $Root -DataRoot $DataRoot -Task $Task -RealWorkflowVerified:$RealWorkflowVerified -DesktopWorkflowVerified:$DesktopWorkflowVerified
            foreach ($check in $completion.Data.Checks) { $checks.Add($check) }
            foreach ($reason in $completion.Reasons) { $reasons.Add($reason) }
        }
        'blocked' { $checks.Add([ordered]@{ id = 'blocked_is_always_allowed'; ok = $true; detail = 'blocking a task is always permitted' }) }
        'failed_closed' { $checks.Add([ordered]@{ id = 'failed_closed_allowed'; ok = $true; detail = 'fail-closed is always permitted' }) }
        'handoff_required' { $checks.Add([ordered]@{ id = 'handoff_allowed'; ok = $true; detail = 'handoff is always permitted' }) }
        'cancelled' { $checks.Add([ordered]@{ id = 'cancel_allowed'; ok = $true; detail = 'cancelling is always permitted' }) }
        default {
            return New-CollabOutcome -Ok $false -Code 'state_transition_unsupported' -Reasons @("Transition to '$To' is not defined")
        }
    }

    $ok = ($reasons.Count -eq 0)
    $code = 'gate_refused'
    if ($ok) { $code = 'gate_passed' }
    return New-CollabOutcome -Ok $ok -Code $code -Reasons @($reasons) -Data @{ Checks = $checks.ToArray(); To = $To; From = $state }
}

function Test-CollabCompletionGate {
    <# Completion demands: every acceptance item passed with evidence, no
       blockers, verified cleanup, a valid review for the current subject, and -
       when the task claims it - recorded proof of the real user workflow. A
       pending desktop proof can never be counted as passed. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task,
        [switch]$RealWorkflowVerified,
        [switch]$DesktopWorkflowVerified
    )
    $checks = New-Object System.Collections.Generic.List[object]
    $reasons = New-Object System.Collections.Generic.List[string]
    $addCheck = {
        param([string]$Id, [bool]$Ok, [string]$Detail)
        $checks.Add([ordered]@{ id = $Id; ok = $Ok; detail = $Detail })
        if (-not $Ok) { $reasons.Add("${Id}: $Detail") }
    }

    & $addCheck 'acceptance_nonempty' (@($Task.acceptance).Count -gt 0) 'acceptance is empty'
    $pending = @($Task.acceptance | Where-Object { $_.status -ne 'passed' })
    & $addCheck 'acceptance_all_passed' ($pending.Count -eq 0) ("pending/failed items: " + (@($pending | ForEach-Object { "$($_.id)=$($_.status)" }) -join ', '))

    foreach ($item in @($Task.acceptance)) {
        $evidenceList = @($item.evidence)
        & $addCheck "acceptance_evidence_$($item.id)" ($evidenceList.Count -gt 0) "acceptance item $($item.id) has no evidence record"
    }

    $blockers = @($Task.blockers)
    & $addCheck 'no_blockers' ($blockers.Count -eq 0) ("blockers: " + (@($blockers | ForEach-Object { $_.reason }) -join '; '))

    $paths = Get-CollabTaskPaths -DataRoot $DataRoot -TaskId $Task.taskId
    $invocations = Get-CollabInvocationRecords -DataRoot $DataRoot -TaskId $Task.taskId
    $currentRuns=@($invocations | Where-Object {(Get-CollabRevision $_) -eq (Get-CollabRevision $Task)})
    $continuation=Test-CollabContinuationGate -DataRoot $DataRoot -Task $Task -Runs @($invocations)
    & $addCheck 'continuation_verified' $continuation.Ok ($continuation.Reasons -join '; ')
    $executors = @(Get-CollabEffectiveExecutors -DataRoot $DataRoot -Task $Task -Runs $invocations)
    $testers = @($currentRuns | Where-Object { $_.role -eq 'tester' -and $_.accepted -eq $true })
    & $addCheck 'implementation_and_test' ($executors.Count -gt 0 -and $testers.Count -gt 0) 'accepted executor and separate tester required'
    $overlap = @($testers | Where-Object { $_.instanceId -in @($executors.instanceId) })
    & $addCheck 'independent_tester' ($overlap.Count -eq 0) 'tester instance overlaps implementation'
    $currentDigest = Get-CollabInventoryDigest -DataRoot $DataRoot -TaskId $Task.taskId
    & $addCheck 'tested_current_subject' (@($testers | Where-Object { $_.afterDigest -eq $currentDigest }).Count -gt 0) 'no accepted tester for current file digest'
    $evidenceRecords = @(Get-CollabEvidenceRecords -DataRoot $DataRoot -TaskId $Task.taskId)
    foreach ($item in @($Task.acceptance)) {
        foreach ($id in @($item.evidence)) {
            $entry = @($evidenceRecords | Where-Object { $_.evidenceId -eq $id })
            $valid = $entry.Count -eq 1
            if ($valid) { $valid = (Get-CollabSha256 -Path $entry[0].absolutePath) -eq $entry[0].sha256 -and (Get-CollabRevision $entry[0]) -eq (Get-CollabRevision $Task) -and (Get-CollabPropertyValue $entry[0] 'subjectSha256') -eq $currentDigest }
            & $addCheck "evidence_$id" $valid 'evidence missing or changed'
        }
    }
    $unclean = @($invocations | Where-Object { -not (Test-CollabEffectiveCleanup -DataRoot $DataRoot -Run $_) })
    & $addCheck 'cleanup_verified' ($unclean.Count -eq 0) ("invocation(s) without verified cleanup: " + (@($unclean | ForEach-Object { $_.invocationId }) -join ', '))
    $incompleteScope = @($invocations | Where-Object { $_.role -in @('executor', 'tester') -and $_.accepted -eq $true -and $_.scopeCheck -notin @('clean', 'not_applicable') })
    & $addCheck 'scope_checks_complete' ($incompleteScope.Count -eq 0) ("invocation(s) with an incomplete or violated scope check: " + (@($incompleteScope | ForEach-Object { $_.invocationId }) -join ', '))

    if ([string]$Task.grade -eq 'important') {
        $gate = Test-CollabReviewGate -Root $Root -DataRoot $DataRoot -Task $Task -SubjectKind 'result'
        & $addCheck 'result_review_accepted' $gate.Ok ($gate.Reasons -join '; ')
    }
    else {
        $checks.Add([ordered]@{ id = 'result_review_not_required'; ok = $true; detail = 'ordinary grade: independent result review is optional' })
    }

    & $addCheck 'state_result_reviewed' `
        (([string]$Task.state -eq 'result_reviewed') -or ([string]$Task.grade -eq 'ordinary' -and [string]$Task.state -eq 'validating')) `
        "task state is '$($Task.state)'"

    if ([bool]$Task.requiresRealWorkflow) {
        & $addCheck 'real_workflow_recorded' ([bool]$Task.realWorkflowVerified -and @($evidenceRecords | Where-Object { $_.kind -eq 'real_workflow' -and $_.status -eq 'passed' -and (Get-CollabRevision $_) -eq (Get-CollabRevision $Task) -and (Get-CollabPropertyValue $_ 'subjectSha256') -eq $currentDigest -and (Get-CollabSha256 -Path $_.absolutePath) -eq $_.sha256 }).Count -gt 0) 'the current revision real user workflow has not been recorded as verified'
    }
    $desktopDetail = 'desktop auto-load remains PENDING (never counted as passed)'
    if ($DesktopWorkflowVerified) { $desktopDetail = 'desktop auto-load verified by the user' }
    $checks.Add([ordered]@{ id = 'desktop_workflow_status'; ok = $true; detail = $desktopDetail })

    $openViolations = @(Get-CollabOpenViolations -DataRoot $DataRoot)
    & $addCheck 'no_open_violations' ($openViolations.Count -eq 0) ("open violation(s): " + (@($openViolations | ForEach-Object { $_.kind }) -join ', '))
    $cleanupFlag = Get-CollabCleanupFlag -DataRoot $DataRoot
    & $addCheck 'cleanup_not_uncertain' ($null -eq $cleanupFlag) 'cleanup must be proven'

    $ok = ($reasons.Count -eq 0)
    $code = 'gate_refused'
    if ($ok) { $code = 'gate_passed' }
    return New-CollabOutcome -Ok $ok -Code $code -Reasons @($reasons) -Data @{ Checks = $checks.ToArray() }
}

function Set-CollabTaskState {
    <# Applies a transition that has already passed its gate. The state history is
       append-only and the previous state is recorded as the transition source. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$To,
        [string]$Reason = '',
        [string]$Actor = 'coordinator'
    )
    $from = [string]$Task.state
    $Task.state = $To
    $history = @($Task.stateHistory)
    $history += [ordered]@{
        atUtc  = Format-CollabTime -Time (Get-CollabUtcNow)
        from   = $from
        to     = $To
        actor  = $Actor
        reason = $Reason
    }
    $Task.stateHistory = @($history)
    if ($To -eq 'complete') { $Task.coordinatorSignoff = $Actor }
    $saved = Save-CollabTask -DataRoot $DataRoot -Task $Task
    if ($saved.Ok) {
        $null = Add-CollabAudit -DataRoot $DataRoot -Action 'state_transition' -Actor $Actor -TaskId $Task.taskId -Detail @{ from = $from; to = $To; reason = $Reason }
    }
    return $saved
}

function Add-CollabBlocker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Kind = 'review_fail',
        [string]$Actor = 'coordinator'
    )
    $blockers = @($Task.blockers)
    $blockers += [ordered]@{
        id     = "B$(New-CollabNonce -Bytes 4)"
        atUtc  = Format-CollabTime -Time (Get-CollabUtcNow)
        kind   = $Kind
        reason = $Reason
        actor  = $Actor
    }
    $Task.blockers = @($blockers)
    $saved = Save-CollabTask -DataRoot $DataRoot -Task $Task
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'blocker_added' -Actor $Actor -TaskId $Task.taskId -Detail @{ kind = $Kind; reason = $Reason }
    return $saved
}

function Remove-CollabBlocker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$BlockerId,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Actor = 'coordinator'
    )
    $remaining = @($Task.blockers | Where-Object { $_.id -ne $BlockerId })
    if ($remaining.Count -eq @($Task.blockers).Count) {
        return @{ Ok = $false; Code = 'blocker_not_found'; Reasons = @("No blocker '$BlockerId'") }
    }
    $Task.blockers = @($remaining)
    $saved = Save-CollabTask -DataRoot $DataRoot -Task $Task
    $null = Add-CollabAudit -DataRoot $DataRoot -Action 'blocker_removed' -Actor $Actor -TaskId $Task.taskId -Detail @{ blockerId = $BlockerId; reason = $Reason }
    return $saved
}
