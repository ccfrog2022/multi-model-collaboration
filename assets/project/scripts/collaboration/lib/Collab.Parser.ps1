# Collab.Parser.ps1 - turn captured process output into a structured verdict.
#
# Contract: a call is accepted only when the native exit code, the tool's own
# structured error fields and the terminal result all agree. A timeout never
# yields an accepted result, and an unknown payload shape is "incomplete"
# rather than success. Requested and observed model are always reported
# separately; a model that the tool did not report stays "unknown".

Set-StrictMode -Version 2.0

$script:CollabFailureCategories = @('quota', 'auth', 'network', 'rate', 'timeout', 'execution', 'incomplete', 'policy_violation')
$script:CollabDeniedToolNames = @('bash', 'shell', 'edit', 'write', 'multiedit', 'notebookedit', 'str_replace_editor', 'apply_patch', 'task', 'agent', 'subagent')

function Get-CollabFailureCategoryList {
    [CmdletBinding()]
    param()
    return $script:CollabFailureCategories
}

function ConvertFrom-CollabJsonDocument {
    <# Tolerant single-document JSON extraction: direct parse first, then the
       outermost brace span (some CLIs print a banner before the JSON). #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ Ok = $false; Code = 'empty'; Reasons = @('No output captured') }
    }
    try {
        return @{ Ok = $true; Code = 'ok'; Value = ($Text | ConvertFrom-Json -Depth 64) }
    }
    catch {
        $start = $Text.IndexOf('{')
        $end = $Text.LastIndexOf('}')
        if ($start -ge 0 -and $end -gt $start) {
            $candidate = $Text.Substring($start, $end - $start + 1)
            try {
                return @{ Ok = $true; Code = 'ok'; Value = ($candidate | ConvertFrom-Json -Depth 64) }
            }
            catch {
                return @{ Ok = $false; Code = 'json_invalid'; Reasons = @('Output is not a parseable JSON document') }
            }
        }
        return @{ Ok = $false; Code = 'json_invalid'; Reasons = @('Output is not a parseable JSON document') }
    }
}

function ConvertFrom-CollabJsonLines {
    <# JSONL reader: returns parsed events plus the count of non-JSON lines. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $events = New-Object System.Collections.Generic.List[object]
    $skipped = 0
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ Ok = $false; Code = 'empty'; Reasons = @('No output captured'); Events = @(); SkippedLines = 0 }
    }
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('{')) { $skipped++; continue }
        try {
            $events.Add(($trimmed | ConvertFrom-Json -Depth 64))
        }
        catch {
            $skipped++
        }
    }
    return @{ Ok = $true; Code = 'ok'; Events = @($events.ToArray()); SkippedLines = $skipped }
}

function Get-CollabPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Find-CollabToolCalls {
    <# Recursively collects tool-call names from a parsed payload, so a
       read-only review can be rejected when a write tool was actually used. #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [int]$MaxNodes = 20000
    )
    $names = New-Object System.Collections.Generic.List[string]
    $visited = 0
    $stack = New-Object System.Collections.Generic.Stack[object]
    if ($null -ne $Object) { $stack.Push($Object) }
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $visited++
        if ($visited -gt $MaxNodes) { throw 'Tool audit exceeded the traversal limit' }
        if ($null -eq $current) { continue }
        if ($current -is [string] -or $current.GetType().IsPrimitive) { continue }
        if ($current -is [System.Collections.IEnumerable] -and -not ($current -is [System.Collections.IDictionary])) {
            foreach ($item in $current) { if ($null -ne $item) { $stack.Push($item) } }
            continue
        }
        $type = Get-CollabPropertyValue -Object $current -Name 'type'
        $name = Get-CollabPropertyValue -Object $current -Name 'name'
        if ($null -ne $type -and $null -ne $name) {
            $typeText = [string]$type
            if ($typeText -in @('tool_use', 'tool_call', 'tool_invocation', 'function_call')) {
                $names.Add([string]$name)
            }
        }
        foreach ($property in $current.PSObject.Properties) {
            $value = $property.Value
            if ($null -eq $value) { continue }
            if ($value -is [string] -or $value.GetType().IsPrimitive) { continue }
            $stack.Push($value)
        }
    }
    return @($names.ToArray())
}

function Get-CollabFailureCategory {
    <# Fixed failure vocabulary. Decided from the native exit code plus the
       captured text, before any retry decision is taken. #>
    [CmdletBinding()]
    param(
        [AllowNull()]$ExitCode,
        [AllowNull()][string]$Text
    )
    $haystack = if ($null -eq $Text) { '' } else { $Text }
    $quota = @('insufficient_quota', 'quota exceeded', 'exceeded your current quota', 'credit balance is too low', 'out of credits', '额度不足', '额度已用尽')
    $auth = @('invalid_api_key', 'invalid api key', 'unauthorized', 'authentication_error', 'authentication failed', 'no api key', 'not logged in', 'invalid token')
    $rate = @('rate limit', 'rate_limit', 'too many requests', 'overloaded', 'slow down', '并发')
    $network = @('econnreset', 'econnrefused', 'etimedout', 'enotfound', 'getaddrinfo', 'socket hang up', 'network error', 'fetch failed', 'connection reset', 'proxy', 'bad gateway', 'service unavailable', 'gateway timeout')

    foreach ($pattern in $quota) { if ($haystack -match [regex]::Escape($pattern)) { return 'quota' } }
    foreach ($pattern in $auth) { if ($haystack -match [regex]::Escape($pattern)) { return 'auth' } }
    if ($haystack -match '(?i)"?api_error_status"?\s*[:=]\s*40[13]') { return 'auth' }
    foreach ($pattern in $rate) { if ($haystack -match [regex]::Escape($pattern)) { return 'rate' } }
    foreach ($pattern in $network) { if ($haystack -match [regex]::Escape($pattern)) { return 'network' } }
    if ($haystack -match '(?i)"?api_error_status"?\s*[:=]\s*(429)') { return 'rate' }
    if ($haystack -match '(?i)"?api_error_status"?\s*[:=]\s*5\d\d') { return 'network' }
    if ($null -ne $ExitCode -and $haystack -match 'HTTP\s*(429)') { return 'rate' }
    return 'execution'
}

function Get-CollabObservedModel {
    [CmdletBinding()]
    param(
        [AllowNull()]$Document,
        [string]$Kind
    )
    if ($null -eq $Document) { return 'unknown' }
    $usage = Get-CollabPropertyValue -Object $Document -Name 'modelUsage'
    if ($null -ne $usage) {
        $names = @()
        foreach ($property in $usage.PSObject.Properties) { $names += $property.Name }
        if ($names.Count -gt 0) { return ($names -join ',') }
    }
    $model = Get-CollabPropertyValue -Object $Document -Name 'model'
    if ($null -ne $model -and -not [string]::IsNullOrWhiteSpace([string]$model)) { return [string]$model }
    if ($Kind -eq 'zcode') {
        $usageBlock = Get-CollabPropertyValue -Object $Document -Name 'usage'
        if ($null -ne $usageBlock) {
            $modelName = Get-CollabPropertyValue -Object $usageBlock -Name 'model'
            if ($null -ne $modelName -and -not [string]::IsNullOrWhiteSpace([string]$modelName)) { return [string]$modelName }
        }
    }
    return 'unknown'
}

function Parse-CollabResult {
    <#
      Parses one invocation's captured output. Returns:
        Accepted         - the tool produced a complete, trustworthy answer
        Classification   - completed | quota | auth | network | rate | timeout |
                           execution | incomplete | policy_violation
        ObservedModel    - what the tool reported, else "unknown"
        FinalText        - terminal answer (empty when not accepted)
        ResultSha256     - hash of FinalText, used to bind review artifacts
        PolicyViolations - denied tools seen in a read-only invocation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [AllowNull()]$ExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdoutText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StderrText,
        [switch]$TimedOut,
        [switch]$IdleTimedOut,
        [switch]$ReadOnly,
        [AllowNull()][string]$ResultFileText
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $result = [ordered]@{
        Kind             = $Kind
        Accepted         = $false
        Classification   = 'incomplete'
        ObservedModel    = 'unknown'
        FinalText        = ''
        ResultSha256     = ''
        PolicyViolations = @()
        ToolAudit        = 'not_reported'
        Reasons          = @()
        ParserNotes      = @()
    }

    if ($TimedOut -or $IdleTimedOut) {
        $result.Classification = 'timeout'
        $result.Reasons = @('timeout: partial output is never accepted as success')
        return $result
    }

    $combined = "$StdoutText`n$StderrText"
    if ($null -eq $ExitCode -or [string]::IsNullOrWhiteSpace([string]$ExitCode)) {
        $result.Reasons = @('native exit code is unknown; explicit zero is required')
        return $result
    }
    if ($null -ne $ExitCode -and [int]$ExitCode -ne 0) {
        $result.Classification = Get-CollabFailureCategory -ExitCode $ExitCode -Text $combined
        $result.Reasons = @("native exit code $ExitCode with classification '$($result.Classification)'")
        return $result
    }

    switch ($Kind) {
        'json' {
            $parsed=ConvertFrom-CollabJsonDocument -Text $StdoutText
            if (-not $parsed.Ok) { $result.Reasons=@('Adapter must return one JSON result object'); return $result }
            $document=$parsed.Value
            $ok=Get-CollabPropertyValue -Object $document -Name 'ok'
            $session=Get-CollabPropertyValue -Object $document -Name 'session'
            $fresh=Get-CollabPropertyValue -Object $session -Name 'fresh'
            $sessionId=[string](Get-CollabPropertyValue -Object $session -Name 'id')
            $final=Get-CollabPropertyValue -Object $document -Name 'final'
            $readOnlyReport=Get-CollabPropertyValue -Object $document -Name 'readOnly'
            if ((Get-CollabPropertyValue -Object $document -Name 'schemaVersion') -ne 1 -or
                $ok -isnot [bool] -or -not $ok -or $fresh -isnot [bool] -or -not $fresh -or
                [string]::IsNullOrWhiteSpace($sessionId) -or $final -isnot [string] -or
                [string]::IsNullOrWhiteSpace($final)) {
                $result.Reasons=@('Adapter result needs schemaVersion=1, ok=true, nonempty final and a fresh session identity')
                return $result
            }
            if ($ReadOnly -and ($readOnlyReport -isnot [bool] -or -not $readOnlyReport)) {
                $result.Reasons=@('Read-only role requires adapter readOnly=true'); return $result
            }
            $eventsProperty=$document.PSObject.Properties['toolEvents']
            $events=$null
            if ($null -ne $eventsProperty) { $events=$eventsProperty.Value }
            $auditComplete=Get-CollabPropertyValue -Object $document -Name 'toolAuditComplete'
            if ($ReadOnly -and ($auditComplete -isnot [bool] -or -not $auditComplete -or $events -isnot [array])) {
                $result.Reasons=@('Read-only adapter must include complete toolEvents audit'); return $result
            }
            if ($ReadOnly) {
                foreach ($event in $events) {
                    $eventName=Get-CollabPropertyValue -Object $event -Name 'name'
                    if ((Get-CollabPropertyValue -Object $event -Name 'type') -cne 'tool_call' -or
                        $eventName -isnot [string] -or [string]::IsNullOrWhiteSpace($eventName) -or
                        $eventName.ToLowerInvariant() -in $script:CollabDeniedToolNames -or
                        (Get-CollabPropertyValue -Object $event -Name 'access') -cne 'read') {
                        $result.Classification='policy_violation'
                        $result.Reasons=@('Read-only toolEvents must describe named read tool calls'); return $result
                    }
                }
            }
            try {
                $denied=@(Find-CollabToolCalls -Object $document | Where-Object {([string]$_).ToLowerInvariant() -in $script:CollabDeniedToolNames})
            } catch {
                $result.Reasons=@($_.Exception.Message); return $result
            }
            if ($ReadOnly -and $denied.Count -gt 0) {
                $result.Classification='policy_violation';$result.PolicyViolations=$denied
                $result.Reasons=@('Adapter read-only claim conflicts with reported tool calls'); return $result
            }
            $result['SessionId']=$sessionId
            $model=[string](Get-CollabPropertyValue -Object $document -Name 'model')
            if ($model) { $result.ObservedModel=$model }
            $result.FinalText=$final
            $result.ResultSha256=Get-CollabTextSha256 -Text $final
            $result.Accepted=$true
            $result.Classification='completed'
            $result.ToolAudit='adapter_report'
            return $result
        }
        'claude' {
            $parsed = ConvertFrom-CollabJsonDocument -Text $StdoutText
            if (-not $parsed.Ok) {
                $result.Reasons = @("claude: $($parsed.Reasons -join '; ')")
                return $result
            }
            $document = $parsed.Value
            $result.ObservedModel = Get-CollabObservedModel -Document $document -Kind 'claude'
            $isError = Get-CollabPropertyValue -Object $document -Name 'is_error'
            $terminal = [string](Get-CollabPropertyValue -Object $document -Name 'terminal_reason')
            $apiStatus = Get-CollabPropertyValue -Object $document -Name 'api_error_status'
            $text = [string](Get-CollabPropertyValue -Object $document -Name 'result')
            $subtype = [string](Get-CollabPropertyValue -Object $document -Name 'subtype')
            if ($null -ne $isError -and [bool]$isError) { $reasons.Add('is_error=true') }
            if ($null -ne $apiStatus) { $reasons.Add("api_error_status=$apiStatus") }
            if ($terminal -ne 'completed') { $reasons.Add("terminal_reason='$terminal'") }
            if ([string]::IsNullOrWhiteSpace($text)) { $reasons.Add('empty result text') }
            if ($reasons.Count -gt 0) {
                $result.Classification = Get-CollabFailureCategory -ExitCode 0 -Text $combined
                if ($result.Classification -eq 'execution' -and $null -ne $apiStatus) {
                    $result.ParserNotes = @("endpoint/protocol error (api_error_status=$apiStatus)")
                }
                $result.Reasons = @($reasons)
                if ($subtype -eq 'success') {
                    $result.ParserNotes += "subtype='success' ignored because error fields disagree"
                }
                return $result
            }
            $result.FinalText = $text
        }
        'grok' {
            $parsed = ConvertFrom-CollabJsonDocument -Text $StdoutText
            if (-not $parsed.Ok) {
                $result.Reasons = @("grok: $($parsed.Reasons -join '; ')")
                return $result
            }
            $document = $parsed.Value
            $result.ObservedModel = Get-CollabObservedModel -Document $document -Kind 'grok'
            $text = [string](Get-CollabPropertyValue -Object $document -Name 'text')
            $stop = [string](Get-CollabPropertyValue -Object $document -Name 'stopReason')
            if ([string]::IsNullOrWhiteSpace($stop)) { $stop = [string](Get-CollabPropertyValue -Object $document -Name 'stop_reason') }
            if ([string]::IsNullOrWhiteSpace($text)) { $reasons.Add('empty text') }
            if ($stop -notin @('end_turn', 'endTurn', 'stop', 'stop_sequence', 'completed')) {
                $reasons.Add("abnormal stop reason '$stop'")
            }
            try { $toolCalls = @(Find-CollabToolCalls -Object $document) }
            catch { $result.Reasons=@($_.Exception.Message); return $result }
            if ($toolCalls.Count -gt 0) {
                $result.ToolAudit = 'tool_calls_reported'
                $result.ParserNotes += ("tool calls in transcript: " + ($toolCalls -join ','))
            }
            else {
                $result.ToolAudit = 'no_tool_calls_reported'
            }
            if ($ReadOnly) {
                $denied = @($toolCalls | Where-Object { ([string]$_).ToLowerInvariant() -in $script:CollabDeniedToolNames })
                if ($denied.Count -gt 0) {
                    $result.PolicyViolations = $denied
                    $result.Classification = 'policy_violation'
                    $result.Reasons = @("read-only invocation used denied tool(s): $($denied -join ',')")
                    return $result
                }
            }
            if ($reasons.Count -gt 0) {
                $result.Classification = 'incomplete'
                $result.Reasons = @($reasons)
                return $result
            }
            $result.FinalText = $text
        }
        'zcode' {
            $parsed = ConvertFrom-CollabJsonDocument -Text $StdoutText
            if (-not $parsed.Ok) {
                $result.Reasons = @("zcode: $($parsed.Reasons -join '; ')")
                return $result
            }
            $document = $parsed.Value
            $result.ObservedModel = Get-CollabObservedModel -Document $document -Kind 'zcode'
            $text = [string](Get-CollabPropertyValue -Object $document -Name 'response')
            $error = Get-CollabPropertyValue -Object $document -Name 'error'
            $projection = Get-CollabPropertyValue -Object $document -Name 'projection'
            $status = ''
            if ($null -ne $projection) { $status = [string](Get-CollabPropertyValue -Object $projection -Name 'status') }
            if ([string]::IsNullOrWhiteSpace($text)) { $reasons.Add('empty response') }
            if ($null -ne $error -and -not [string]::IsNullOrWhiteSpace([string]$error)) { $reasons.Add("error field: $error") }
            if (-not [string]::IsNullOrWhiteSpace($status) -and $status -notin @('idle', 'completed', 'done')) {
                $reasons.Add("projection status '$status'")
            }
            if ($reasons.Count -gt 0) {
                $result.Classification = Get-CollabFailureCategory -ExitCode 0 -Text $combined
                if ($result.Classification -eq 'execution' -and $reasons -contains 'empty response') { $result.Classification = 'incomplete' }
                $result.Reasons = @($reasons)
                return $result
            }
            $result.FinalText = $text
        }
        'codex' {
            $parsed = ConvertFrom-CollabJsonLines -Text $StdoutText
            if (-not $parsed.Ok) {
                $result.Reasons = @("codex: $($parsed.Reasons -join '; ')")
                return $result
            }
            $events = @($parsed.Events)
            $turnCompleted = $false
            $terminalFailure = $false
            $finalText = ''
            $observedModels = @()
            foreach ($event in $events) {
                $type = [string](Get-CollabPropertyValue -Object $event -Name 'type')
                if ($type -in @('turn.completed', 'turn_completed')) {
                    $turnCompleted = $true
                    $modelName = Get-CollabPropertyValue -Object $event -Name 'model'
                    if ($null -ne $modelName -and -not [string]::IsNullOrWhiteSpace([string]$modelName)) { $observedModels += [string]$modelName }
                }
                if ($type -in @('turn.failed', 'error', 'stream_error', 'turn.aborted')) {
                    $terminalFailure = $true
                    $message = Get-CollabPropertyValue -Object $event -Name 'message'
                    if ($null -ne $message) { $reasons.Add("terminal event '$type': $message") }
                    else { $reasons.Add("terminal event '$type'") }
                }
                $item = Get-CollabPropertyValue -Object $event -Name 'item'
                if ($null -ne $item) {
                    $itemType = [string](Get-CollabPropertyValue -Object $item -Name 'type')
                    if ($itemType -eq 'agent_message') {
                        $itemText = [string](Get-CollabPropertyValue -Object $item -Name 'text')
                        if (-not [string]::IsNullOrWhiteSpace($itemText)) { $finalText = $itemText }
                    }
                }
            }
            if ($observedModels.Count -gt 0) { $result.ObservedModel = ($observedModels | Select-Object -Unique) -join ',' }
            if (-not [string]::IsNullOrWhiteSpace($ResultFileText)) { $finalText = $ResultFileText }
            if ($parsed.SkippedLines -gt 0) { $result.ParserNotes += "$($parsed.SkippedLines) non-JSON line(s) ignored" }
            if (-not $turnCompleted) { $reasons.Add('no turn.completed event') }
            if ($terminalFailure) { $result.Classification = 'execution' }
            if ([string]::IsNullOrWhiteSpace($finalText)) { $reasons.Add('no final agent message') }
            if ($reasons.Count -gt 0) {
                if ($result.Classification -ne 'execution') { $result.Classification = 'incomplete' }
                $result.Reasons = @($reasons)
                return $result
            }
            $result.FinalText = $finalText
        }
        default {
            $result.Reasons = @("Unknown tool kind '$Kind'")
            return $result
        }
    }

    $result.Accepted = $true
    $result.Classification = 'completed'
    $result.ResultSha256 = Get-CollabTextSha256 -Text $result.FinalText
    return $result
}
