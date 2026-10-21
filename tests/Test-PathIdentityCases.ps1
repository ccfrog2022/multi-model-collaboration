# Shares Check/Cmd/View and the isolated project fixture with Test-Package.ps1.
$caseResult = & (Get-Module Collab) {
    # Run the actual snapshot producer with a case-sensitive filesystem view.
    function Get-CollabControlFileList { return @("$root/.collaboration/tasks/A/plan.md", "$root/.collaboration/tasks/a/plan.md") }
    function Resolve-CollabPath { param($Root,$RelativePath) return @{Ok=$true;FullPath=$RelativePath} }
    function Get-CollabSha256 { param($Path) if ($Path -clike '*/A/*') { return 'upper' }; return 'lower' }
    $snapshot = Get-CollabControlSnapshot -Root $root -DataRootRelative '.collaboration'
    $after = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($key in $snapshot.Keys) { $after[$key]=$snapshot[$key] }
    $after['.collaboration/tasks/A/plan.md']='changed'
    $diff = Compare-CollabControlSnapshot -Before $snapshot -After $after
    @{Count=$snapshot.Count;Diff=$diff}
}
Check ($caseResult.Count -eq 2) 'control snapshot retains both case-distinct paths'
Check (-not $caseResult.Diff.clean -and @($caseResult.Diff.modified).Count -eq 1 -and $caseResult.Diff.modified[0] -ceq '.collaboration/tasks/A/plan.md') 'control comparison detects upper-case path mutation without folding keys'
$identity = Get-CollabPathIdentityMap -Root $root -Path @('future/value.txt','future/VALUE.TXT')
if ($identity['future/value.txt'] -ceq $identity['future/VALUE.TXT']) {
    $result=Invoke-CollabCommand NewTask -Root $root -Request @{TaskId='identity-alias';Grade='ordinary';GradeReason='Path identity regression';Authorization='Isolated fixture';Acceptance=@(@{id='A1';requirement='Distinct ownership'});AllowedPath=@('future/value.txt','future/VALUE.TXT');TesterWritePath=@('future/VALUE.TXT')}
    Check (-not $result.Ok) 'case aliases for missing files cannot be split across executor and tester'
} else {
    Check $true 'case-sensitive filesystem gives missing targets distinct identities'
}

$identityCode = @'
import importlib.util, os, stat, sys
from types import SimpleNamespace
from unittest.mock import patch
spec = importlib.util.spec_from_file_location("collab_platform_identity", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

directory = SimpleNamespace(st_dev=7, st_ino=10, st_mode=stat.S_IFDIR)
file = SimpleNamespace(st_dev=7, st_ino=20, st_mode=stat.S_IFREG)
def metadata(path, **kwargs):
    key = path.replace("\\", "/")
    if key.endswith("/volume") or key.endswith("/VOLUME"):
        return directory
    if key.endswith("/volume/existing.txt") or key.endswith("/volume/EXISTING.TXT") or key.endswith("/volume/hardlink.txt"):
        return file
    raise FileNotFoundError(path)

base = os.path.abspath("volume")
with patch.object(module.os, "stat", side_effect=metadata):
    with patch.object(module.os, "pathconf", return_value=0, create=True) as query:
        assert module.path_identity(base+"/new/FILE.txt") == module.path_identity(base+"/NEW/file.txt")
        assert module.path_identity(base+"/new/file.txt") == module.path_identity(os.path.abspath("VOLUME")+"/NEW/FILE.TXT")
        assert module.path_identity(base+"/caf\u00e9.txt") == module.path_identity(base+"/cafe\u0301.txt")
        assert module.path_identity(base+"/existing.txt") == module.path_identity(base+"/EXISTING.TXT")
        assert module.path_identity(base+"/existing.txt") == module.path_identity(base+"/hardlink.txt")
        assert module.path_name_identity(base+"/existing.txt") != module.path_name_identity(base+"/hardlink.txt")
        assert module.path_name_identity(base+"/existing.txt") == module.path_name_identity(base+"/EXISTING.TXT")
        assert module.path_name_identity(base+"/new/FILE.txt") == module.path_name_identity(base+"/NEW/file.txt")
        assert all(call.args[1] == 11 for call in query.call_args_list)
    with patch.object(module.os, "pathconf", return_value=1, create=True):
        assert module.path_identity(base+"/new/FILE.txt") != module.path_identity(base+"/new/file.txt")
        assert module.path_name_identity(base+"/EXISTING.TXT") != module.path_name_identity(base+"/existing.txt")
    with patch.object(module.os, "pathconf", return_value=-1, create=True):
        try:
            module.path_identity(base+"/new/file.txt")
        except ValueError:
            pass
        else:
            raise AssertionError("Unknown filesystem case semantics accepted")
print("path identity mocked semantics: passed")
'@
$native = Join-Path $package 'assets/project/scripts/collaboration/native/platform_macos.py'
$identityOutput = & $Python -B -c $identityCode $native
Check ($LASTEXITCODE -eq 0) ('macOS identity helper: existing aliases, hardlinks, missing-parent aliases, Unicode, sensitive and unknown volumes; '+($identityOutput -join ' '))

$controlRoot=Join-Path $ScratchRoot 'control-path-regression'
$controlTarget=Join-Path $ScratchRoot 'control-path-target'
$null=New-Item -ItemType Directory -Path (Join-Path $controlRoot '.collaboration/nested'),$controlTarget -Force
$sentinel=Join-Path $controlTarget 'sentinel.txt'
Set-Content -LiteralPath $sentinel -Value 'outside control tree' -Encoding utf8NoBOM
$temporaryNamed=Join-Path $controlRoot '.collaboration/evidence.tmp-fixture'
Set-Content -LiteralPath $temporaryNamed -Value 'fixed evidence name' -Encoding utf8NoBOM
$snapshot=Get-CollabControlSnapshot -Root $controlRoot -DataRootRelative '.collaboration'
Check ($snapshot.Contains('.collaboration/evidence.tmp-fixture')) 'control snapshot hashes fixed files whose names contain tmp'
$linkType=if ($IsWindows) {'Junction'} else {'SymbolicLink'}
$controlLink=Join-Path $controlRoot '.collaboration/nested/link'
try {
    $null=New-Item -ItemType $linkType -Path $controlLink -Target $controlTarget
    $rejected=$false
    try { $null=Get-CollabControlSnapshot -Root $controlRoot -DataRootRelative '.collaboration' } catch { $rejected=$true }
    Check $rejected 'control snapshot rejects a nested directory reparse point'
} finally {
    # Only unlink this fixture-owned directory entry; leave its target intact.
    if (Test-Path -LiteralPath $controlLink) { [IO.Directory]::Delete($controlLink) }
}
$rootLink=Join-Path $controlRoot 'linked-control-root'
try {
    $null=New-Item -ItemType $linkType -Path $rootLink -Target $controlTarget
    $rejected=$false
    try { $null=Get-CollabControlSnapshot -Root $controlRoot -DataRootRelative 'linked-control-root' } catch { $rejected=$true }
    Check $rejected 'control snapshot rejects a reparse point at the control tree root'
    $rejected=$false
    try { $null=Get-CollabControlSnapshot -Root $rootLink -DataRootRelative '.collaboration' } catch { $rejected=$true }
    Check $rejected 'control snapshot rejects a reparse point as the project root'
} finally {
    if (Test-Path -LiteralPath $rootLink) { [IO.Directory]::Delete($rootLink) }
}
Check (Test-Path -LiteralPath $sentinel -PathType Leaf) 'reparse fixtures unlink their own entries and preserve the external target'

$macPrelaunch = & (Get-Module Collab) {
    function Get-Command { throw 'fixture: python3 lookup failed before helper launch' }
    Invoke-CollabMacProcess -Request @{
        operation='run';InvocationId='fixture-no-helper';ExePath='fixture-worker';Arguments=@()
        WorkingDirectory=$root;LogDirectory=$root;GracefulSeconds=0
    }
}
Check (-not $macPrelaunch.Ok -and $macPrelaunch.Cleanup -ceq 'not_started' -and $macPrelaunch.Launched -eq $false -and -not $macPrelaunch.Pid -and $macPrelaunch.Contains('Descendants') -and $macPrelaunch.Contains('ExitCode') -and $macPrelaunch.Contains('TimedOut') -and $macPrelaunch.Contains('IdleTimedOut') -and $macPrelaunch.Contains('StdoutPath') -and $macPrelaunch.Contains('StderrPath')) 'macOS helper lookup failure returns a complete proven not-started record'
$macAfterLaunch = & (Get-Module Collab) {
    $mockInput=[pscustomobject]@{}
    $mockInput | Add-Member ScriptMethod Close {}
    $mockOutput=[pscustomobject]@{}
    $mockOutput | Add-Member ScriptMethod ReadToEndAsync { throw 'fixture: output reader failed after helper launch' }
    $mockProcess=[pscustomobject]@{StartInfo=$null;StandardInput=$mockInput;StandardOutput=$mockOutput;Disposed=$false}
    $mockProcess | Add-Member ScriptMethod Start { return $true }
    $mockProcess | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
    function Get-Command { return [pscustomobject]@{Source='fixture-python3'} }
    function New-Object { return $mockProcess }
    $launchError=$null
    try {
        $null=Invoke-CollabMacProcess -Request @{operation='run';InvocationId='fixture-started';ExePath='fixture-worker';Arguments=@();WorkingDirectory=$root;LogDirectory=$root;GracefulSeconds=0}
    } catch { $launchError=$_.Exception }
    @{Error=$launchError;Disposed=$mockProcess.Disposed}
}
Check ($null -ne $macAfterLaunch.Error -and $macAfterLaunch.Error.Data['CollabMacHelperLaunchState'] -ceq 'started' -and $macAfterLaunch.Disposed) 'failure after helper start remains unknown to managed recovery and is never labelled not-started'
$macStartBoundary = & (Get-Module Collab) {
    function Get-Command { return [pscustomobject]@{Source='fixture-python3'} }
    foreach ($mode in @('false','throws')) {
        $mockProcess=[pscustomobject]@{StartInfo=$null;Mode=$mode;Disposed=$false}
        $mockProcess | Add-Member ScriptMethod Start { if ($this.Mode -eq 'throws') { throw 'fixture: Start outcome ambiguous' }; return $false }
        $mockProcess | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        function New-Object { return $mockProcess }
        $record=$null; $launchError=$null
        try {
            $record=Invoke-CollabMacProcess -Request @{operation='run';InvocationId='fixture-start-boundary';ExePath='fixture-worker';Arguments=@();WorkingDirectory=$root;LogDirectory=$root;GracefulSeconds=0}
        } catch { $launchError=$_.Exception }
        @{Mode=$mode;Record=$record;Error=$launchError;Disposed=$mockProcess.Disposed}
    }
}
Check ($macStartBoundary[0].Record.Cleanup -ceq 'not_started' -and $macStartBoundary[0].Disposed) 'helper Start returning false records proven non-launch'
Check ($null -eq $macStartBoundary[1].Record -and $macStartBoundary[1].Error.Data['CollabMacHelperLaunchState'] -ceq 'unknown' -and $macStartBoundary[1].Disposed) 'helper Start throwing preserves unknown launch outcome'

$task='helper-not-started'
New-ExceptionalTask $task
Set-Content -LiteralPath (Join-Path $inbox 'prompt.txt') -Value 'Implement after helper availability check' -Encoding utf8NoBOM
$module=Get-Module Collab
& $module {
    $script:originalProcessForHelperCase=(Get-Command Invoke-CollabProcess).ScriptBlock
    Set-Item Function:script:Invoke-CollabProcess {
        param($ExePath,$Arguments,$WorkingDirectory,$Environment,$LogDirectory,$InvocationId,$TotalTimeoutSeconds,$IdleTimeoutSeconds)
        function Get-Command { throw 'fixture: interpreter unavailable before helper start' }
        Invoke-CollabMacProcess -Request @{operation='run';ExePath=$ExePath;Arguments=$Arguments;WorkingDirectory=$WorkingDirectory;LogDirectory=$LogDirectory;InvocationId=$InvocationId;GracefulSeconds=0}
    }
}
try { $failedHelper=Exceptional-Invoke $task 'unavailable-helper' }
finally { & $module {Set-Item Function:script:Invoke-CollabProcess $script:originalProcessForHelperCase} }
Check (-not $failedHelper.Ok -and $failedHelper.Record.process.Launched -eq $false -and $failedHelper.Record.cleanup -eq 'not_started') 'public Invoke persists a structured helper prelaunch failure'
$request=Recovery-Request $task $failedHelper.Record
$null=Cmd RecoverTask $request
$null=Cmd Rework @{TaskId=$task;ExpectedRevision=1;ExpectedDigest=(View $task).DiffDigest;Reason='Interpreter availability corrected; run a fresh instance'}
$null=Dispatch $task executor
$null=Cmd Advance @{TaskId=$task;To='validating';Reason='independent check after helper recovery'}
$test=Dispatch $task tester
$null=Record-FixtureAcceptance $task $test
$null=Cmd Complete @{TaskId=$task;Reason='Structured prelaunch recovery completed normal workflow'}
Check ((View $task).Task.state -eq 'complete') 'public helper prelaunch failure recovers through rework and independent completion'
