#requires -Version 7.4
[CmdletBinding()]
param([string]$ScratchRoot)
$ErrorActionPreference='Stop'
$package=Split-Path -Parent $PSScriptRoot
if (-not $ScratchRoot) { $ScratchRoot=Join-Path ([IO.Path]::GetTempPath()) ('collab-distribution-'+[guid]::NewGuid().ToString('N')) }
if (Test-Path -LiteralPath $ScratchRoot) { throw 'Use a new scratch directory' }
$null=New-Item -ItemType Directory -Path $ScratchRoot
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Value,[string]$Name) { if (-not $Value) { throw "Check failed: $Name" }; $checks.Add($Name) }
$fixture=Join-Path $ScratchRoot 'package'
$null=New-Item -ItemType Directory -Path $fixture
foreach ($name in @('scripts','assets')) { Copy-Item -LiteralPath (Join-Path $package $name) -Destination $fixture -Recurse -Force }
$project=Join-Path $ScratchRoot 'project'
$null=New-Item -ItemType Directory -Path $project
$initializer=Join-Path $fixture 'scripts/Initialize-Project.ps1'
$assetRoot=Join-Path $fixture 'assets/project'
function Plan { $out=& pwsh -NoProfile -File $initializer -Root $project; $code=$LASTEXITCODE; return @{Exit=$code;Result=($out -join "`n" | ConvertFrom-Json)} }
foreach ($relative in @('.agents','scripts/collaboration/lib/Collab.Platform.ps1','.agents/collaboration/templates/worker.md')) {
    $path=Join-Path $assetRoot $relative
    Move-Item -LiteralPath $path -Destination ($path+'.held')
    try {
        $result=Plan
        Check ($result.Exit -ne 0 -and $result.Result.Code -eq 'package_incomplete') "missing $relative diagnosed"
        $expected=if ($relative -eq '.agents') {12} else {1}
        Check ($result.Result.MissingPaths.Count -eq $expected) "missing $relative list exact"
        Check (@(Get-ChildItem -LiteralPath $project -Force).Count -eq 0) "missing $relative leaves project unchanged"
    } finally { Move-Item -LiteralPath ($path+'.held') -Destination $path }
}
. (Join-Path $assetRoot 'scripts/collaboration/lib/Collab.Core.ps1')
$configPath=Join-Path $assetRoot '.agents/collaboration/config/collaboration.json'
$original=[IO.File]::ReadAllText($configPath)
$valid=$original|ConvertFrom-Json -AsHashtable
Check (Test-CollabConfig $valid).Ok 'valid dictionary configuration'
Check (Test-CollabConfig ($original|ConvertFrom-Json)).Ok 'valid object configuration'
foreach ($key in @('workerDenyPaths','immutablePaths','maintenancePaths','neverAllowWithinMaintenance')) { $valid.protected[$key]=@() }
Check (Test-CollabConfig $valid).Ok 'empty path arrays remain valid'
$cases=@(
    @{Name='missing protected';Key='protected';Edit={param($c) $c.Remove('protected')}},
    @{Name='missing maintenancePaths';Key='protected.maintenancePaths';Edit={param($c) $c.protected.Remove('maintenancePaths')}},
    @{Name='wrong serial';Key='protocol.serial';Edit={param($c) $c.protocol.serial='true'}},
    @{Name='null paths';Key='paths';Edit={param($c) $c.paths=$null}},
    @{Name='wrong exclude';Key='protocol.inventory.exclude';Edit={param($c) $c.protocol.inventory.exclude='build'}},
    @{Name='blank path member';Key='protected.workerDenyPaths';Edit={param($c) $c.protected.workerDenyPaths=@('')}},
    @{Name='zero file limit';Key='protocol.inventory.maxFiles';Edit={param($c) $c.protocol.inventory.maxFiles=0}},
    @{Name='overflow file limit';Key='protocol.inventory.maxFiles';Edit={param($c) $c.protocol.inventory.maxFiles=2147483648}},
    @{Name='fractional bytes';Key='protocol.inventory.maxHashBytes';Edit={param($c) $c.protocol.inventory.maxHashBytes=1.5}},
    @{Name='schema version';Key='schemaVersion';Edit={param($c) $c.schemaVersion=2}}
)
foreach ($case in $cases) {
    $config=$original|ConvertFrom-Json -AsHashtable
    $null=& $case.Edit $config
    [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 32))
    $result=Get-CollabConfig -Root $assetRoot
    Check (-not $result.Ok -and $result.Code -eq 'config_invalid' -and ($result.Reasons -join ' ').Contains($case.Key) -and ($result.Reasons -join ' ').Contains($configPath)) $case.Name
}
foreach ($json in @('null','[]','[{}]','42','"text"','{')) {
    [IO.File]::WriteAllText($configPath,$json)
    $result=Get-CollabConfig -Root $assetRoot
    Check (-not $result.Ok -and $result.Code -eq 'config_invalid') "invalid JSON root $json"
}
[IO.File]::WriteAllText($configPath,'{')
$result=Plan
Check ($result.Exit -ne 0 -and ($result.Result.Reasons -join ' ').Contains($configPath)) 'initializer malformed JSON names file'
$config=$original|ConvertFrom-Json -AsHashtable
$config.Remove('protected')
[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 32))
$result=Plan
Check ($result.Exit -ne 0 -and ($result.Result.Reasons -join ' ').Contains("field 'protected'")) 'initializer reports missing protected'
Check (@(Get-ChildItem -LiteralPath $project -Force).Count -eq 0) 'invalid source config leaves project unchanged'
Import-Module (Join-Path $assetRoot 'scripts/collaboration/Collab.psm1') -Force -DisableNameChecking
foreach ($command in @('Doctor','NewTask')) {
    $result=Invoke-CollabCommand $command -Root $assetRoot -Request @{}
    Check (-not $result.Ok -and ($result|ConvertTo-Json -Depth 8).Contains("field 'protected'")) "$command reports config field"
}
Check (-not (Test-Path -LiteralPath (Join-Path $assetRoot '.collaboration'))) 'invalid runtime config creates no state'
Move-Item -LiteralPath $configPath -Destination ($configPath+'.held')
try {
    $result=Get-CollabConfig -Root $assetRoot
    Check (-not $result.Ok -and $result.Code -eq 'config_missing' -and ($result.Reasons -join ' ').Contains($configPath)) 'missing runtime config names file'
} finally { Move-Item -LiteralPath ($configPath+'.held') -Destination $configPath }
[IO.File]::WriteAllText($configPath,$original)
if ($IsWindows) {
    $missingPlan=Join-Path $ScratchRoot 'absent/plan.json'
    $out=& pwsh -NoProfile -File $initializer -Root $project -Mode Apply -PlanFile $missingPlan -BackupDirectory (Join-Path $ScratchRoot 'unused-backup') -Confirm
    $result=$out|ConvertFrom-Json
    Check ($LASTEXITCODE -ne 0 -and ($result.Reasons -join ' ').Contains($missingPlan) -and ($result.Reasons -join ' ') -match 'Win32 3') 'missing input reports path and native error'
    Check (@(Get-ChildItem -LiteralPath $project -Force).Count -eq 0) 'missing input leaves project unchanged'
}
$plan=Plan
Check ($plan.Exit -eq 0 -and $plan.Result.Ok) 'complete package Plan'
$planFile=Join-Path $ScratchRoot 'plan.json'
$plan.Result|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $planFile -Encoding utf8NoBOM
$backup=Join-Path $ScratchRoot 'backup'
$out=& pwsh -NoProfile -File $initializer -Root $project -Mode Apply -PlanFile $planFile -BackupDirectory $backup -Confirm
Check ($LASTEXITCODE -eq 0 -and ($out|ConvertFrom-Json).Ok) 'complete package Apply'
$out=& pwsh -NoProfile -File (Join-Path $project 'scripts/collaboration/Collab.ps1') Doctor -Root $project
Check ($LASTEXITCODE -eq 0 -and ($out|ConvertFrom-Json).Ok) 'installed Doctor'
$out=& pwsh -NoProfile -File $initializer -Root $project -Mode Rollback -BackupDirectory $backup -Confirm
Check ($LASTEXITCODE -eq 0 -and ($out|ConvertFrom-Json).Ok) 'complete package Rollback'
$report=@{passed=$checks.Count;checks=@($checks);scope='Distribution and configuration diagnostics; isolated projects';scratch=$ScratchRoot}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $ScratchRoot 'verification.json') -Encoding utf8NoBOM
$report|ConvertTo-Json -Depth 8
