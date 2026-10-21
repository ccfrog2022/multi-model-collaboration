# Platform services shared by the initializer and project runtime.
Set-StrictMode -Version 2.0

function Get-CollabPathComparison {
    if ($IsWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-CollabPathIdentityMap {
    <# Read-only identities for exact file scopes. Missing macOS targets inherit
       the nearest existing directory's filesystem semantics. NamesOnly compares
       directory entries so a new hardlink cannot acquire another path's scope. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path,
        [switch]$NamesOnly
    )
    $map = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    if (-not $Path.Count) { return ,$map }
    $full = @($Path | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $Root $_)) })
    if ($IsMacOS) {
        $result = Invoke-CollabMacHelper @{operation='path_identities';paths=$full;namesOnly=[bool]$NamesOnly}
        if (@($result.identities).Count -ne $Path.Count) { throw 'Incomplete filesystem identity response' }
        for ($i=0; $i -lt $Path.Count; $i++) { $map[$Path[$i]] = [string]$result.identities[$i] }
    } else {
        for ($i=0; $i -lt $Path.Count; $i++) {
            $map[$Path[$i]] = if ($IsWindows) { $full[$i].ToUpperInvariant() } else { $full[$i] }
        }
    }
    return ,$map
}

function Test-CollabSamePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    if ([string]::Equals($Left,$Right,[StringComparison]::Ordinal)) { return $true }
    $identities = Get-CollabPathIdentityMap -Root $Root -Path @($Left,$Right)
    return [string]::Equals($identities[$Left],$identities[$Right],[StringComparison]::Ordinal)
}

function Invoke-CollabMacHelper {
    param([Parameter(Mandatory)][hashtable]$Request)
    $process = $null
    $launchState = 'not_started'
    try {
        $python = Get-Command python3 -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'native/platform_macos.py'
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $python.Source
        $info.ArgumentList.Add('-B')
        $info.ArgumentList.Add($helper)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = New-Object -TypeName Diagnostics.Process
        $process.StartInfo = $info
        # An exception inside Start is ambiguous; only a false return proves
        # that the helper did not launch after the start boundary was entered.
        $launchState = 'unknown'
        if (-not $process.Start()) { $launchState='not_started'; throw 'macOS helper could not start' }
        $launchState = 'started'
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 64 -Compress))
        $process.StandardInput.Flush()
        # Keep stdin open as the supervisor's lifetime channel during a run.
        $limit = 60000
        if ($Request.operation -eq 'run') {
            $limit = ([int]$Request.TotalTimeoutSeconds + [int]$Request.GracefulSeconds + [int]$Request.ForceSeconds + 60) * 1000
        }
        if (-not $process.WaitForExit($limit)) {
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(30000)) { throw 'macOS helper still owns cleanup; inspect process.json before continuing' }
            throw 'macOS helper exceeded its supervisor deadline'
        }
        $text = $output.GetAwaiter().GetResult()
        $errorText = $errors.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "macOS helper failed: $errorText $text" }
        $result = $text | ConvertFrom-Json -AsHashtable -Depth 64
        if ($result.ContainsKey('error')) { throw $result.error }
        return $result
    } catch {
        $_.Exception.Data['CollabMacHelperLaunchState'] = $launchState
        throw
    } finally {
        if ($null -ne $process) {
            try { $process.StandardInput.Close() } catch {}
            $process.Dispose()
        }
    }
}

function Get-CollabMacMetadata {
    param([Parameter(Mandatory)][string]$Path)
    return (Invoke-CollabMacHelper @{operation='metadata';path=$Path}).metadata
}

function Restore-CollabMacMetadata {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Metadata)
    $null = Invoke-CollabMacHelper @{operation='restore';path=$Path;metadata=$Metadata}
}
