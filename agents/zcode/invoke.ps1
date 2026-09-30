#Requires -Version 5.1
<#
.SYNOPSIS
    ZCode (Z.AI) A2A unified invocation wrapper.

.DESCRIPTION
    Wraps the ZCode headless CLI so that external callers only need to know the
    unified A2A interface:

        invoke.ps1 -TaskFile <path> -OutputFile <path> -Workspace <path> -Mode <execute|review|analyze>

    Callers do NOT need to know the native CLI (zcode.cjs) arguments.

    Exit codes:
        0 = success
        2 = usage error (missing/invalid parameters, TaskFile/Workspace not found)
        3 = agent not configured for headless runs (no model config / API key)
        4 = agent run failed (CLI returned non-zero or timed out)
        5 = internal error (failed to write OutputFile, etc.)

    An OutputFile is written on EVERY outcome, including failures.

.PARAMETER TaskFile
    UTF-8 text file containing the full task for this agent.

.PARAMETER OutputFile
    Result file to write. Created/overwritten by this script.

.PARAMETER Workspace
    Project directory the agent is allowed to work in. Passed natively to the
    CLI via --cwd.

.PARAMETER Mode
    execute (read-write) | review (read-only) | analyze (read-only).

.PARAMETER TimeoutSeconds
    Hard timeout for the agent run. Default 1800 (30 minutes).

.PARAMETER MaxTurns
    Intentionally not forwarded: the bundled CLI (0.16.5) rejects --max-turns
    even though its help text lists it. Kept for interface stability.

.EXAMPLE
    .\invoke.ps1 -TaskFile "F:\AtoA\tasks\task-001.md" -OutputFile "F:\AtoA\tasks\task-001-result.md" -Workspace "F:\Projects\Demo" -Mode "execute"
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TaskFile,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputFile,

    [Parameter(Mandatory = $false, Position = 2)]
    [string]$Workspace = (Get-Location).Path,

    [Parameter(Mandatory = $false, Position = 3)]
    [ValidateSet('execute', 'review', 'analyze')]
    [string]$Mode = 'execute',

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 1800,

    [Parameter(Mandatory = $false)]
    [int]$MaxTurns = 300   # reserved; not forwarded by this CLI build (see note below)
)

$ErrorActionPreference = 'Stop'
$script:AgentId = 'zcode'

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
$script:AgentDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DefaultCli = 'C:\Program Files\ZCode\resources\glm\zcode.cjs'
$script:NodeExe    = 'node'
$script:SandboxHome = Join-Path $script:AgentDir 'home'          # isolated USERPROFILE for API-key mode
$script:ApiKeyFile  = Join-Path $script:AgentDir 'api-key.txt'   # optional user-provided key (id.secret)

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Utf8File {
    param([string]$Path)
    (New-Object System.IO.StreamReader($Path, [System.Text.Encoding]::UTF8, $true)).ReadToEnd()
}

function Write-ResultFile {
    param(
        [string]$Status,        # success | failed
        [string]$Summary,
        [string]$ChangedFiles,
        [string]$CommandsTests,
        [string]$Errors,
        [string]$Notes,
        [string]$ExitCodeInfo
    )
    $started = if ($script:StartedAt) { $script:StartedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { 'unknown' }
    $ended   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $content = @"
Agent: $script:AgentId
Mode: $Mode
Status: $Status
Started: $started
Finished: $ended
Exit Code: $ExitCodeInfo
Task File: $TaskFile
Workspace: $Workspace

Summary:
$Summary

Changed Files:
$ChangedFiles

Commands / Tests:
$CommandsTests

Errors:
$Errors

Notes:
$Notes
"@
    try {
        Write-Utf8File -Path $OutputFile -Content $content
    } catch {
        Write-Error "Failed to write OutputFile '${OutputFile}': $($_.Exception.Message)"
        exit 5
    }
}

function Exit-Usage   { param([string]$Msg) Write-ResultFile -Status 'failed' -Summary $Msg -Errors $Msg -ExitCodeInfo 2; exit 2 }
function Exit-Unset   { param([string]$Msg) Write-ResultFile -Status 'failed' -Summary $Msg -Errors $Msg -ExitCodeInfo 3; exit 3 }
function Exit-RunFail { param([string]$Msg) Write-ResultFile -Status 'failed' -Summary $Msg -Errors $Msg -ExitCodeInfo 4; exit 4 }

# ---------------------------------------------------------------------------
# 1. Validate parameters
# ---------------------------------------------------------------------------
$script:StartedAt = Get-Date

if ([string]::IsNullOrWhiteSpace($TaskFile))   { Exit-Usage 'Parameter -TaskFile is required.' }
if ([string]::IsNullOrWhiteSpace($OutputFile)) { Exit-Usage 'Parameter -OutputFile is required.' }

$TaskFile   = [System.IO.Path]::GetFullPath($TaskFile)
$OutputFile = [System.IO.Path]::GetFullPath($OutputFile)
$Workspace  = [System.IO.Path]::GetFullPath($Workspace)

if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) { Exit-Usage "TaskFile not found: $TaskFile" }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { Exit-Usage "Workspace directory not found: $Workspace" }

# ---------------------------------------------------------------------------
# 2. Locate the CLI
# ---------------------------------------------------------------------------
$cliPath = if ($env:ZCODE_CLI_PATH) { $env:ZCODE_CLI_PATH } else { $script:DefaultCli }
if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    Exit-RunFail "ZCode CLI not found at: $cliPath (install ZCode desktop, or set ZCODE_CLI_PATH)."
}

# ---------------------------------------------------------------------------
# 3. Determine headless configuration source
#
#    Mode A: user already completed `zcode login` (global config has model.main)
#            -> run CLI against the real user profile, no overrides.
#    Mode B: api-key.txt exists in this agent directory
#            -> generate an isolated config under .\home and run with
#               USERPROFILE redirected there (global files are not touched).
#    Neither: fail with actionable setup instructions.
# ---------------------------------------------------------------------------
$realConfigPath = Join-Path $env:USERPROFILE '.zcode\cli\config.json'
$useSandbox = $false

$realConfigHasModel = $false
if (Test-Path -LiteralPath $realConfigPath -PathType Leaf) {
    try {
        $realCfg = Get-Content -LiteralPath $realConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($realCfg.model -and $realCfg.model.main) { $realConfigHasModel = $true }
    } catch { $realConfigHasModel = $false }
}

$apiKey = $null
if (-not $realConfigHasModel -and (Test-Path -LiteralPath $script:ApiKeyFile -PathType Leaf)) {
    $apiKey = (Read-Utf8File -Path $script:ApiKeyFile).Trim()
    if ($apiKey) { $useSandbox = $true }
}

if (-not $realConfigHasModel -and -not $useSandbox) {
    $setupMsg = @"
ZCode headless mode is not configured on this machine (no model provider in '$realConfigPath').

Run ONE of the following one-time setup steps, then retry:
  1. Open a terminal and run:  node "$cliPath" login
     (complete Z.AI OAuth in the browser once; this writes the global config)
  2. Or save a Z.AI Coding Plan API key (format: id.secret) to:
     $script:ApiKeyFile
"@
    Exit-Unset ($setupMsg -replace "`r`n", "`n")
}

# ---------------------------------------------------------------------------
# 4. Prepare sandbox config (Mode B only)
# ---------------------------------------------------------------------------
$modelId = if ($env:ZCODE_A2A_MODEL) { $env:ZCODE_A2A_MODEL } else { 'GLM-5.3-Flash' }

if ($useSandbox) {
    $sandboxCliConfigDir = Join-Path $script:SandboxHome '.zcode\cli'
    if (-not (Test-Path -LiteralPath $sandboxCliConfigDir)) {
        New-Item -ItemType Directory -Path $sandboxCliConfigDir -Force | Out-Null
    }
    $cfg = [ordered]@{
        provider = [ordered]@{
            'zai' = [ordered]@{
                kind = 'anthropic'
                name = 'Z.AI Coding Plan'
                options = [ordered]@{
                    apiKeyRequired = $true
                    baseURL = 'https://api.z.ai/api/anthropic'
                    apiKey = $apiKey
                }
            }
        }
        model = [ordered]@{
            main = "zai/$modelId"
        }
    }
    $cfgJson = $cfg | ConvertTo-Json -Depth 10
    Write-Utf8File -Path (Join-Path $sandboxCliConfigDir 'config.json') -Content $cfgJson
}

# ---------------------------------------------------------------------------
# 5. Build the prompt according to Mode
# ---------------------------------------------------------------------------
$taskText = Read-Utf8File -Path $TaskFile
$prompt = $null
$attachArgs = @()

# Windows CreateProcess command-line limit is ~32k chars; longer tasks go via --attach.
$inlineLimit = 26000

$modeHeader = switch ($Mode) {
    'execute' {
        @"
[Mode: execute] Complete the task below. You may read, modify, create and delete files inside the workspace, and run shell/git commands as needed.
When finished, your final reply MUST end with a report using exactly these headings:

Summary:
Changed Files:
Commands / Tests:
Errors:
Notes:

--- TASK ---
"@
    }
    'review' {
        @"
[Mode: review] You are responsible for REVIEW ONLY. Do NOT modify, create or delete any file. Do NOT run state-changing commands. Read the code, audit it, and report findings.
When finished, your final reply MUST end with a report using exactly these headings:

Summary:
Changed Files: (for review mode, state "None (read-only mode)")
Commands / Tests: (commands you ran that are read-only, e.g. tests in dry-run)
Errors:
Notes:

--- TASK ---
"@
    }
    'analyze' {
        @"
[Mode: analyze] You are responsible for ANALYSIS ONLY. Do NOT modify, create or delete any file. Gather information, reason about it, and report conclusions and evidence.
When finished, your final reply MUST end with a report using exactly these headings:

Summary:
Changed Files: (for analyze mode, state "None (read-only mode)")
Commands / Tests:
Errors:
Notes:

--- TASK ---
"@
    }
}

if ($taskText.Length -le $inlineLimit) {
    $prompt = "$modeHeader`n$taskText`n`n--- END TASK ---"
} else {
    # Deliver the long task via --attach; keep --prompt short.
    $prompt = "$modeHeader`nThe full task text is provided in the attached file: $TaskFile`nRead it first, then complete it.`n`n--- END TASK ---"
    $attachArgs += @('--attach', $TaskFile)
}

# ---------------------------------------------------------------------------
# 6. Assemble CLI arguments
# ---------------------------------------------------------------------------
$permissionMode = if ($Mode -eq 'execute') { 'yolo' } else { 'plan' }

$cliArgs = @(
    $cliPath,
    '--prompt', $prompt,
    '--cwd', $Workspace,
    '--mode', $permissionMode,
    '--no-color'
) + $attachArgs

# NOTE: this CLI build (0.16.5) rejects --max-turns / --allowed-tools / --permission-mode
# despite listing them in --help (verified empirically), so they are intentionally not passed.

# ---------------------------------------------------------------------------
# 7. Quote args manually (PowerShell 5.1 mangles embedded quotes) and run
# ---------------------------------------------------------------------------
function ConvertTo-NativeArg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\', (2 * $backslashes + 1))
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append('\', $backslashes); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\', (2 * $backslashes)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

$argString = ($cliArgs | ForEach-Object { ConvertTo-NativeArg $_ }) -join ' '

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $script:NodeExe
$psi.Arguments              = $argString
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$psi.WorkingDirectory       = $Workspace
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

if ($useSandbox) {
    $psi.EnvironmentVariables['USERPROFILE'] = $script:SandboxHome
}

$cliDisplay = "node $argString"

try {
    $proc = [System.Diagnostics.Process]::Start($psi)
} catch {
    Exit-RunFail "Failed to start ZCode CLI: $($_.Exception.Message)"
}

# Async reads avoid pipe-buffer deadlock; WaitForExit enforces the timeout.
$outTask = $proc.StandardOutput.ReadToEndAsync()
$errTask = $proc.StandardError.ReadToEndAsync()

$timedOut = $false
if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    $timedOut = $true
    try { & cmd /c "taskkill /PID $($proc.Id) /T /F" 2>$null | Out-Null } catch { }
    $proc.WaitForExit(10000) | Out-Null
}

$cliExit   = if ($timedOut) { -1 } else { $proc.ExitCode }
$cliStdout = ''
$cliStderr = ''
try { if ($outTask.Wait(5000)) { $cliStdout = $outTask.Result } } catch { }
try { if ($errTask.Wait(5000)) { $cliStderr = $errTask.Result } } catch { }

# ---------------------------------------------------------------------------
# 8. Write the unified OutputFile
# ---------------------------------------------------------------------------
if ($timedOut) {
    Write-ResultFile -Status 'failed' `
        -Summary "Agent run exceeded the ${TimeoutSeconds}s timeout and was terminated." `
        -ChangedFiles 'unknown (run terminated)' `
        -CommandsTests $cliDisplay `
        -Errors "Timeout after ${TimeoutSeconds}s.`nPartial stdout:`n$($cliStdout.Substring(0, [Math]::Min(4000, $cliStdout.Length)))" `
        -Notes "Consider increasing -TimeoutSeconds for large tasks." `
        -ExitCodeInfo 'timeout (-1)'
    exit 4
}

if ($cliExit -eq 0) {
    Write-ResultFile -Status 'success' `
        -Summary $cliStdout `
        -ChangedFiles '(parsed from agent output above; agent lists changed files under "Changed Files:")' `
        -CommandsTests '(see agent output above)' `
        -Errors 'None' `
        -Notes "Agent raw output is embedded verbatim in the Summary section." `
        -ExitCodeInfo "0 (cli exit $cliExit)"
    exit 0
} else {
    $errTail = $cliStderr
    if ($errTail.Length -gt 4000) { $errTail = $errTail.Substring($errTail.Length - 4000) }
    Write-ResultFile -Status 'failed' `
        -Summary "ZCode CLI exited with code $cliExit. Partial stdout:`n$($cliStdout.Substring(0, [Math]::Min(4000, $cliStdout.Length)))" `
        -ChangedFiles 'unknown (run failed)' `
        -CommandsTests $cliDisplay `
        -Errors $errTail `
        -Notes 'See AGENT.md section 14 for common errors.' `
        -ExitCodeInfo "$cliExit (cli exit $cliExit)"
    exit 4
}
