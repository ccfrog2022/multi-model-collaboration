#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory,Position=0)]
    [ValidateSet('Status','Doctor','NewTask','Backup','Invoke','RecordReview','RecordAcceptance','Advance','Complete','Handoff','RecoverLock','ProbeTool','Rework','PrepareContext','RecoverTask')]
    [string]$Command,
    [string]$Root,
    [string]$RequestFile,
    [string]$Actor='coordinator'
)
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Collab.psm1') -Force -DisableNameChecking -ErrorAction Stop
    $request=@{}
    if ($RequestFile) { $request=Get-Content -LiteralPath $RequestFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 64 }
    $result=Invoke-CollabCommand -Command $Command -Root $Root -Request $request -Actor $Actor
    $result | ConvertTo-Json -Depth 64
    if (-not $result.Ok) { exit 1 }
    exit 0
} catch {
    @{Ok=$false;Code='entry_failed';Reasons=@($_.Exception.Message)} | ConvertTo-Json -Depth 8
    exit 1
}
