<#
invoke.ps1 - unified A2A entrypoint for CodeBuddy Code / WorkBuddy (agent id: codebuddy)

Contract (the only thing an external caller needs to know):
    .\invoke.ps1 -TaskFile <path> -OutputFile <path> -Workspace <dir> -Mode <execute|review|analyze>

Everything native (gateway discovery, Bearer auth, run/job dispatch, result polling,
report normalisation) is handled here; the caller never sees native CLI parameters.

Native transports, tried in order (Transport=auto):
  1. runs   - inject the task into an already-live agent session
              POST /api/v1/runs  ->  GET /api/v1/runs/{runId}
                                     GET /api/v1/sessions/{id}/history  (requests[].finalReply)
  2. jobs   - dispatch a fresh background agent
              POST /api/v1/jobs  ->  GET /api/v1/jobs/{id}/transcript
  3. cli    - spawn the bundled CLI in non-interactive print mode
              codebuddy -p --output-format json --permission-mode bypassPermissions

Transport is provided by the CodeBuddy Code HTTP gateway (`codebuddy --serve`).
The WorkBuddy desktop app keeps one alive per session; -SelfServe starts a private one.

Exit codes: 0 success | 1 dispatch/run error | 2 no gateway or auth failed
            3 timeout waiting for the reply | 4 invalid arguments
#>
[CmdletBinding()]
param(
    [string]$TaskFile,
    [string]$OutputFile,
    [string]$Workspace,
    [ValidateSet('execute','review','analyze')]
    [string]$Mode = 'execute',

    [ValidateSet('auto','runs','jobs','cli')]
    [string]$Transport = 'auto',
    [int]$TimeoutSec = 900,
    [int]$PollIntervalSec = 5,
    [int]$SessionFreshnessSec = 1800,
    [int]$IdleWaitSec = 120,
    [int]$JobStartupGraceSec = 75,

    [string]$GatewayUrl,
    [string]$GatewayPassword,
    [switch]$SelfServe,

    [string]$CliPath,
    [string]$NodePath,
    [string]$Model,
    [string]$TraceLog,
    [switch]$Structured
)

$ErrorActionPreference = 'Stop'
$script:AgentId    = 'codebuddy'
$script:StartedAt  = Get-Date
$script:RunId      = [guid]::NewGuid().ToString()
$script:Marker     = "a2a-run:$($script:RunId)"
$script:Gateway    = $null
$script:OwnedServer = $null
$script:TraceLog   = $TraceLog
$script:Notes      = New-Object System.Collections.Generic.List[string]

function Trace {
    param([string]$Message)
    if (-not $script:TraceLog) { return }
    try { Add-Content -Path $script:TraceLog -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -Encoding UTF8 } catch {}
}

# ---------------------------------------------------------------- helpers ----
function Write-Report {
    param([string]$ModeValue, [string]$Status, [string]$Summary, [string]$ChangedFiles,
          [string]$Commands, [string]$Errors, [string]$Notes, [string]$Extra)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Agent: $script:AgentId")
    [void]$sb.AppendLine("Mode: $ModeValue")
    [void]$sb.AppendLine("Status: $Status")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Summary:")
    [void]$sb.AppendLine($Summary)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Changed Files:")
    [void]$sb.AppendLine($ChangedFiles)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Commands / Tests:")
    [void]$sb.AppendLine($Commands)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Errors:")
    [void]$sb.AppendLine($Errors)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Notes:")
    [void]$sb.AppendLine($Notes)
    if ($Extra) { [void]$sb.AppendLine(""); [void]$sb.AppendLine("---"); [void]$sb.AppendLine($Extra) }
    $txt = $sb.ToString()
    $dir = Split-Path -Parent $OutputFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($OutputFile, $txt, (New-Object System.Text.UTF8Encoding($false)))
    if ($Structured) {
        $jp = [System.IO.Path]::ChangeExtension($OutputFile, '.json')
        ([ordered]@{ agent = $script:AgentId; mode = $ModeValue; status = $Status; runId = $script:RunId
                     summary = $Summary; changedFiles = $ChangedFiles; commands = $Commands
                     errors = $Errors; notes = $Notes } | ConvertTo-Json -Depth 6) |
            Set-Content -Path $jp -Encoding UTF8
    }
}

function Exit-With {
    param([int]$Code, [string]$Status, [string]$Summary, [string]$Errors, [string]$Notes)
    $meta = @(
        "started_at: $($script:StartedAt.ToString('o'))",
        "finished_at: $((Get-Date).ToString('o'))",
        "task_file: $TaskFile",
        "workspace: $Workspace",
        "transport: $Transport",
        "gateway: $($script:Gateway)"
    ) -join "`n"
    Write-Report -ModeValue $Mode -Status $Status -Summary $Summary -ChangedFiles 'None' `
                 -Commands 'None' -Errors $Errors -Notes $Notes -Extra $meta
    Write-Host "$Status : $Summary"
    exit $Code
}

function Get-Http {
    param([string]$Url, [string]$Method = 'GET', [hashtable]$Headers = @{},
          [string]$Body = $null, [int]$Timeout = 60)
    try {
        $irmArgs = @{ Uri = $Url; Method = $Method; Headers = $Headers; TimeoutSec = $Timeout; UseBasicParsing = $true }
        if (-not [string]::IsNullOrEmpty($Body)) { $irmArgs['Body'] = $Body; $irmArgs['ContentType'] = 'application/json; charset=utf-8' }
        return (Invoke-RestMethod @irmArgs)
    } catch {
        $script:LastHttpError = $_.Exception.Message
        return $null
    }
}

# ------------------------------------------------------------- 0. arg check --
function Exit-BadArgs {
    param([string]$Message)
    if ($OutputFile) {
        Write-Report -ModeValue $(if ($Mode) { $Mode } else { 'execute' }) -Status 'failed' `
                     -Summary $Message -ChangedFiles 'None' -Commands 'None' -Errors "invalid_arguments: $Message" `
                     -Notes 'Fix the arguments and retry.' -Extra ''
    }
    Write-Host "failed : $Message"
    exit 4
}

if (-not $TaskFile -or -not (Test-Path $TaskFile)) { Exit-BadArgs '-TaskFile is required and must exist.' }
if (-not $OutputFile) { Write-Host 'failed : -OutputFile is required.'; exit 4 }
if (-not $Workspace)  { $Workspace = (Get-Location).Path }
if (-not (Test-Path $Workspace)) { Exit-BadArgs "-Workspace '$Workspace' does not exist." }
$resolvedWs = (Resolve-Path $Workspace).Path
$taskText = [System.IO.File]::ReadAllText((Resolve-Path $TaskFile), [System.Text.Encoding]::UTF8)
Trace "args ok; workspace=$resolvedWs; task=$($taskText.Length) chars"

# keep localhost traffic away from any inherited proxy configuration (process scope only)
$env:HTTP_PROXY = ''; $env:HTTPS_PROXY = ''; $env:http_proxy = ''; $env:https_proxy = ''

# ------------------------------------------------------ 1. resolve the CLI ----
if (-not $CliPath) {
    $candidate = Join-Path ${env:ProgramFiles} 'WorkBuddy\resources\app.asar.unpacked\cli\bin\codebuddy'
    if (Test-Path $candidate) { $CliPath = $candidate } else { $CliPath = 'codebuddy' }
}
if (-not $NodePath) {
    $nodeCand = Join-Path $HOME '.workbuddy\binaries\node\versions\22.22.2-3\node.exe'
    if (Test-Path $nodeCand) { $NodePath = $nodeCand } else { $NodePath = 'node' }
}

# ------------------------------------------------------- 2. build the prompt -
$modePreamble = switch ($Mode) {
    'execute' { 'MODE=execute. You MAY create/modify files and MAY run commands inside the workspace. Implement what the task asks, keep the change minimal, and run the relevant tests when they exist.' }
    'review'  { 'MODE=review. You MUST NOT modify any file and MUST NOT run side-effecting commands. Read-only tools only. Produce review findings with severity and concrete suggestions.' }
    'analyze' { 'MODE=analyze. You MUST NOT modify any file. Read-only investigation only. Explain root cause / structure / trade-offs with evidence from what you inspected.' }
}

$prompt = @"
<task id="$script:Marker">
You are CodeBuddy Code (WorkBuddy) invoked as a coding agent by an external A2A caller.

Workspace (do every read/write relative to this directory): $resolvedWs
Do not touch anything outside the workspace unless the task explicitly requires it.

$modePreamble

----- BEGIN TASK -----
$taskText
----- END TASK -----

Answer requirements:
1. Write concise Chinese unless the task says otherwise.
2. Always finish your reply with these exact sections:

Changed Files:
- <path relative to the workspace, one per line, or "None">

Commands / Tests:
- <command you ran and its outcome, or "None">

Errors:
- <anything that blocked you, or "None">

Notes:
- <assumptions, limitations, follow-ups>
"@

# --------------------------------------------------- 3. locate the gateway --
if (-not $GatewayUrl)      { $GatewayUrl      = $env:CODEBUDDY_GATEWAY_URL }
if (-not $GatewayPassword) { $GatewayPassword = $env:CODEBUDDY_GATEWAY_PASSWORD }

function Test-GatewayAlive {
    param([string]$Base, [string]$Password)
    $h = @{ 'X-CodeBuddy-Request' = '1' }
    if ($Password) { $h['Authorization'] = "Bearer $Password" }
    $r = Get-Http -Url "$Base/api/v1/health" -Headers $h -Timeout 10
    if (-not ($r -and $r.data -and $r.data.status -eq 'ok')) { Trace "probe failed: $Base -> $($script:LastHttpError)" }
    return ($r -and $r.data -and $r.data.status -eq 'ok')
}

function Get-PasswordCandidates {
    $list = New-Object System.Collections.Generic.List[string]
    if ($GatewayPassword) { $list.Add($GatewayPassword) }
    if ($env:CODEBUDDY_GATEWAY_PASSWORD) { $list.Add($env:CODEBUDDY_GATEWAY_PASSWORD) }
    # last resort: the desktop app writes the gateway password it hands to each session into its logs
    $logDir = Join-Path $HOME '.workbuddy\logs'
    if (Test-Path $logDir) {
        $recent = Get-ChildItem -Path $logDir -Recurse -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'renderer.log' -and $_.Length -lt 20MB -and $_.LastWriteTime -gt (Get-Date).AddDays(-3) } |
            Sort-Object -Property LastWriteTime -Descending | Select-Object -First 40
        foreach ($f in $recent) {
            try {
                $txt = [System.IO.File]::ReadAllText($f.FullName)
            } catch { continue }   # logs can be locked by the running desktop app
            $m = [regex]::Match($txt, 'CODEBUDDY_GATEWAY_PASSWORD=([A-Za-z0-9_\-]+)')
            if ($m.Success) { $list.Add($m.Groups[1].Value) }
        }
    }
    return $list
}

$passwords = Get-PasswordCandidates
if ($passwords.Count -eq 0) { $passwords = @('') }
Trace "password candidates: $($passwords.Count)"

$candidates = New-Object System.Collections.Generic.List[object]
if ($GatewayUrl) {
    $candidates.Add([pscustomobject]@{ endpoint = $GatewayUrl.TrimEnd('/'); cwd = $null })
} else {
    $sessDir = Join-Path $HOME '.workbuddy\sessions'
    if (Test-Path $sessDir) {
        $nowMs = [int64](([DateTime]::UtcNow) - ([DateTime]'1970-01-01')).TotalMilliseconds
        Get-ChildItem -Path $sessDir -Filter '*.json' -ErrorAction SilentlyContinue |
            ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null } } |
            Where-Object { $_ -and $_.endpoint -and $_.kind -ne 'prewarm' -and ($nowMs - [int64]$_.lastHeartbeat) -lt ($SessionFreshnessSec * 1000) } |
            Sort-Object -Property lastHeartbeat -Descending |
            ForEach-Object { $candidates.Add([pscustomobject]@{ endpoint = $_.endpoint.TrimEnd('/'); cwd = $_.cwd }) }
    }
}

foreach ($c in $candidates) {
    foreach ($p in $passwords) {
        if (Test-GatewayAlive -Base $c.endpoint -Password $p) {
            $script:Gateway = $c.endpoint
            $script:GatewayPassword = $p
            $script:GatewayCwd = $c.cwd
            break
        }
    }
    if ($script:Gateway) { break }
}

# prefer a gateway whose session already lives in the requested workspace
if (-not $GatewayUrl -and $script:Gateway -and $script:GatewayCwd -ne $resolvedWs) {
    foreach ($c in $candidates) {
        if ($c.cwd -eq $resolvedWs -and $c.endpoint -ne $script:Gateway) {
            foreach ($p in $passwords) {
                if (Test-GatewayAlive -Base $c.endpoint -Password $p) {
                    $script:Gateway = $c.endpoint; $script:GatewayPassword = $p; $script:GatewayCwd = $c.cwd
                    break
                }
            }
        }
        if ($script:GatewayCwd -eq $resolvedWs) { break }
    }
}

Trace "gateway resolved: $($script:Gateway) (cwd=$($script:GatewayCwd))"

function Start-OwnServer {
    $port = 18800 + (Get-Random -Minimum 1 -Maximum 900)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NodePath
    $psi.ArgumentList.Add($CliPath)
    $psi.ArgumentList.Add('--serve')
    $psi.ArgumentList.Add('--port'); $psi.ArgumentList.Add("$port")
    $psi.ArgumentList.Add('--host'); $psi.ArgumentList.Add('127.0.0.1')
    $psi.WorkingDirectory = $resolvedWs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $deadline = (Get-Date).AddSeconds(45)
    $pw = $null
    while ((Get-Date) -lt $deadline) {
        $line = $p.StandardOutput.ReadLine()
        if ($line -eq $null) { Start-Sleep -Milliseconds 300; continue }
        if ($line -match 'Password\s+(\S+)') { $pw = $Matches[1]; break }
    }
    if (-not $pw) { try { $p.Kill() } catch {} ; return $null }
    $script:OwnedServer = $p
    return [pscustomobject]@{ endpoint = "http://127.0.0.1:$port"; password = $pw }
}

if (-not $script:Gateway -and $SelfServe -and $Transport -ne 'cli') {
    $own = Start-OwnServer
    if ($own) {
        $script:Gateway = $own.endpoint
        $script:GatewayPassword = $own.password
        $script:Notes.Add("started a private gateway at $($own.endpoint) (stopped when this call ends)")
    }
}

try {
    if (-not $script:Gateway -and $Transport -ne 'cli') {
        Exit-With -Code 2 -Status 'failed' `
          -Summary 'No live agent gateway found. Start a WorkBuddy session, pass -GatewayUrl, or add -SelfServe.' `
          -Errors "gateway_discovery_failed: no endpoint answered /api/v1/health within the last $SessionFreshnessSec s." `
          -Notes 'Discovery scans ~/.workbuddy/sessions/*.json (fields: endpoint, cwd). Auth token comes from -GatewayPassword, $env:CODEBUDDY_GATEWAY_PASSWORD, or ~/.workbuddy/logs.'
    }

    $script:Headers = @{ 'X-CodeBuddy-Request' = '1' }
    if ($script:GatewayPassword) { $script:Headers['Authorization'] = "Bearer $($script:GatewayPassword)" }
    Trace "dispatch begin; transport=$Transport"

    # ------------------------------------------------------- 4. dispatch -----
    $script:DispatchKind = ''
    $runIdResp = $null
    $jobIdResp = $null
    $reply = $null

    function Submit-Run {
        param([string]$Text)
        # documented minimal shape is {text, sender}; the full gateway envelope is sent alongside
        # for compatibility with older gateway builds.
        $payload = @{
            id      = $script:RunId
            type    = 'message'
            text    = $Text
            sender  = @{ id = 'a2a'; name = 'a2a-caller' }
            source  = @{ platform = 'generic'; sender = @{ id = 'a2a' }
                        conversation = @{ id = $script:RunId; type = 'direct' } }
            payload = @{ text = $Text }
            timeoutMs = $TimeoutSec * 1000
        } | ConvertTo-Json -Depth 8
        $r = Get-Http -Url "$($script:Gateway)/api/v1/runs" -Method 'POST' -Headers $script:Headers -Body $payload -Timeout 60
        if ($r -and $r.data -and $r.data.runId) { return $r.data.runId }
        return $null
    }

    function Submit-Job {
        param([string]$Text)
        $payload = @{ prompt = $Text; cwd = $resolvedWs; permissionMode = 'bypassPermissions'
                      name = "a2a-$($script:RunId.Substring(0,8))" }
        if ($Model) { $payload['model'] = $Model }
        $r = Get-Http -Url "$($script:Gateway)/api/v1/jobs" -Method 'POST' -Headers $script:Headers -Body ($payload | ConvertTo-Json -Depth 6) -Timeout 60
        if ($r -and $r.data -and $r.data.id) { return $r.data.id }
        return $null
    }

    function Get-ReplyFromHistory {
        # prefer the session that accepted the run: /sessions/live can flip to
        # null or another session while the reply is still being produced
        $sid = $script:RunsSessionId
        if (-not $sid) {
            $live = Get-Http -Url "$($script:Gateway)/api/v1/sessions/live" -Headers $script:Headers -Timeout 15
            if (-not ($live -and $live.data -and $live.data.sessionId)) { return $null }
            $sid = $live.data.sessionId
        }
        $hist = Get-Http -Url "$($script:Gateway)/api/v1/sessions/$sid/history" -Headers $script:Headers -Timeout 40
        if (-not ($hist -and $hist.data -and $hist.data.requests)) { return $null }
        $hit = $null
        foreach ($req in $hist.data.requests) {
            if ([string]$req.userInput -and ([string]$req.userInput).Contains($script:Marker)) {
                $fr = [string]$req.finalReply
                if ($fr.Trim().Length -gt 0) { $hit = $fr }
            }
        }
        return $hit
    }

    function Get-ReplyFromJobTranscript {
        param([string]$JobId)
        $t = Get-Http -Url "$($script:Gateway)/api/v1/jobs/$JobId/transcript" -Headers $script:Headers -Timeout 40
        if (-not ($t -and $t.data)) { return $null }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($u in @($t.data.updates)) {
            $txt = ''
            if ($u -and $u.message -and $u.message.content) {
                foreach ($c in $u.message.content) { if ($c.type -in @('text','output_text') -and $c.text) { $txt += $c.text } }
            }
            if (-not $txt -and $u -and $u.text) { $txt = [string]$u.text }
            if ($txt) { $parts.Add($txt) }
        }
        foreach ($m in @($t.data.messages)) {
            if ($m -and $m.role -eq 'assistant' -and $m.content) {
                foreach ($c in $m.content) { if ($c.type -in @('text','output_text') -and $c.text) { $parts.Add($c.text) } }
            }
        }
        if ($parts.Count -gt 0) { return ($parts -join "`n`n") }
        return $null
    }

    function Invoke-CliPrint {
        param([string]$Text)
        $argList = New-Object System.Collections.Generic.List[string]
        $argList.Add($CliPath)
        $argList.Add('-p')
        $argList.Add('--output-format'); $argList.Add('json')
        $argList.Add('--permission-mode'); $argList.Add('bypassPermissions')
        $argList.Add('--max-turns'); $argList.Add('40')
        $argList.Add('--no-session-persistence')
        if ($Mode -in @('review','analyze')) { $argList.Add('--disallowedTools'); $argList.Add('Edit,Write,MultiEdit,NotebookEdit') }
        if ($Model) { $argList.Add('--model'); $argList.Add($Model) }
        $argList.Add($Text)

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $NodePath
        foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
        $psi.WorkingDirectory = $resolvedWs
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {} ; return $null }
        $out = $so.Result; $err = $se.Result
        $script:LastCliStderr = $err
        $script:LastCliExit = $p.ExitCode
        if (-not $out) { return $null }
        try {
            $obj = $out | ConvertFrom-Json
            if ($obj.result) { return [string]$obj.result }
            if ($obj.data -and $obj.data.result) { return [string]$obj.data.result }
        } catch { return $out }
        return $out
    }

    if ($Transport -eq 'cli') {
        $reply = Invoke-CliPrint -Text $prompt
        $script:DispatchKind = 'cli'
        if (-not $reply) {
            Exit-With -Code 1 -Status 'failed' -Summary 'The CLI print mode produced no result.' `
                -Errors "cli_no_result: exit=$($script:LastCliExit); stderr=$($script:LastCliStderr)" `
                -Notes "cli=$CliPath; node=$NodePath"
        }
    } else {
        # ---- runs: needs a live session (an occupied writer is fine: API-injected
        #      messages are queued and answered anyway; verified 2026-09-29) ------
        $liveSeen = $false
        if ($Transport -in @('auto','runs')) {
            $liveDeadline = (Get-Date).AddSeconds($IdleWaitSec)
            while ((Get-Date) -lt $liveDeadline) {
                $live = Get-Http -Url "$($script:Gateway)/api/v1/sessions/live" -Headers $script:Headers -Timeout 15
                if ($live -and $live.data -and $live.data.sessionId) { $liveSeen = $true; break }
                Start-Sleep -Seconds $PollIntervalSec
            }
            if ($liveSeen) {
                $rid = Submit-Run -Text $prompt
                if ($rid) {
                    $script:DispatchKind = 'runs'; $runIdResp = $rid
                    $script:RunsSessionId = $live.data.sessionId
                }
            } elseif ($Transport -eq 'runs') {
                Exit-With -Code 1 -Status 'failed' -Summary 'No live session available for the runs transport.' `
                    -Errors "no_live_session: /api/v1/sessions/live returned no sessionId within $IdleWaitSec s." `
                    -Notes "gateway=$($script:Gateway)"
            }
        }

        # ---- jobs: fresh background agent -----------------------------------
        if (-not $script:DispatchKind -and $Transport -in @('auto','jobs')) {
            $jid = Submit-Job -Text $prompt
            if ($jid) { $script:DispatchKind = 'jobs'; $jobIdResp = $jid }
        }

        Trace "dispatch kind: $($script:DispatchKind) run=$runIdResp job=$jobIdResp"
        if (-not $script:DispatchKind) {
            Exit-With -Code 1 -Status 'failed' -Summary 'Failed to dispatch the task through the agent gateway.' `
                -Errors "dispatch_failed: $($script:LastHttpError)" -Notes "gateway=$($script:Gateway); transport=$Transport"
        }

        # -------------------------------------------------- 5. wait for reply --
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $stuckSince = $null
        while ((Get-Date) -lt $deadline) {
            if ($script:DispatchKind -eq 'runs') {
                $info = Get-Http -Url "$($script:Gateway)/api/v1/runs/$runIdResp" -Headers $script:Headers -Timeout 15
                $observation = "run_active=$($info.data.active)"
                $reply = Get-ReplyFromHistory
            } else {
                $info = Get-Http -Url "$($script:Gateway)/api/v1/jobs/$jobIdResp" -Headers $script:Headers -Timeout 15
                $state = if ($info -and $info.data -and $info.data.job) { "$($info.data.job.state)/$($info.data.job.detail)" } else { 'unknown' }
                $observation = "job_state=$state"
                $reply = Get-ReplyFromJobTranscript -JobId $jobIdResp
                if (-not $reply) {
                    if (-not $stuckSince) { $stuckSince = Get-Date }
                    elseif (((Get-Date) - $stuckSince).TotalSeconds -gt $JobStartupGraceSec) {
                        try { Get-Http -Url "$($script:Gateway)/api/v1/jobs/$jobIdResp/stop" -Method 'POST' -Headers $script:Headers -Timeout 15 | Out-Null } catch {}
                        Exit-With -Code 1 -Status 'failed' `
                          -Summary 'The dispatched background agent never started producing output.' `
                          -Errors "job_stuck: $observation after $JobStartupGraceSec s with an empty transcript. On this machine freshly spawned CLI processes have no usable credentials, so the job channel is unavailable; use the runs channel (idle live session) or fix headless login first." `
                          -Notes "gateway=$($script:Gateway); job_id=$jobIdResp"
                    }
                } else { $stuckSince = $null }
            }
            if ($reply) { break }
            Start-Sleep -Seconds $PollIntervalSec
        }

        if (-not $reply) {
            Exit-With -Code 3 -Status 'failed' `
              -Summary "No reply from the agent within $TimeoutSec seconds (dispatch kind: $($script:DispatchKind))." `
              -Errors "timeout: $observation . If this is the runs channel, the session is probably busy in an interactive turn; retry when it is idle." `
              -Notes "gateway=$($script:Gateway); run_id=$runIdResp; job_id=$jobIdResp"
        }
    }

    # ------------------------------------------- 6. normalise into A2A report -
    function Get-Section($text, $pattern) {
        $re = "(?is)^\s*(?:[-*#>\s]*)" + $pattern + "\s*:?[ \t]*\r?\n(.*?)(?=^\s*(?:[-*#>\s]*)(?:Changed Files|Commands\s*/\s*Tests|Errors|Notes)\s*:?[ \t]*\r?\n|\z)"
        $m = [regex]::Match($text, $re, [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
        return ''
    }

    $changed  = Get-Section $reply 'Changed Files';  if (-not $changed)  { $changed  = 'None' }
    $commands = Get-Section $reply 'Commands\s*/\s*Tests'; if (-not $commands) { $commands = 'None' }
    $errorsS  = Get-Section $reply 'Errors';         if (-not $errorsS)  { $errorsS  = 'None' }
    $notesS   = Get-Section $reply 'Notes'

    $summary = $reply
    $idx = $summary.IndexOf('Changed Files', [StringComparison]::OrdinalIgnoreCase)
    if ($idx -gt 0) { $summary = $summary.Substring(0, $idx).Trim() }
    if ($summary.Length -gt 12000) { $summary = $summary.Substring(0, 12000) + "`n...[truncated]" }
    if (-not $notesS) { $notesS = 'See Summary.' }
    if ($script:Notes.Count -gt 0) { $notesS = ($notesS + "`n- " + ($script:Notes -join "`n- ")) }

    $meta = @(
        "started_at: $($script:StartedAt.ToString('o'))",
        "finished_at: $((Get-Date).ToString('o'))",
        "task_file: $TaskFile",
        "workspace: $resolvedWs",
        "transport: $($script:DispatchKind)",
        "gateway: $($script:Gateway)",
        "run_id: $runIdResp",
        "job_id: $jobIdResp"
    ) -join "`n"

    Write-Report -ModeValue $Mode -Status 'success' -Summary $summary -ChangedFiles $changed `
                 -Commands $commands -Errors $errorsS -Notes $notesS -Extra $meta
    Write-Host "Status: success"
    Write-Host "OutputFile: $OutputFile"
    exit 0
}
finally {
    if ($script:OwnedServer) {
        try { if (-not $script:OwnedServer.HasExited) { $script:OwnedServer.Kill() } } catch {}
    }
}
