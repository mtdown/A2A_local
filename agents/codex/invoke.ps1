[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $true)]
    [ValidateSet('execute', 'review', 'analyze')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$outputPath = $null
$rawPath = $null
$stdoutPath = $null
$stderrPath = $null

function Write-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Summary,
        [string]$ChangedFiles = 'None reported.',
        [string]$CommandsTests = 'None reported.',
        [string]$Errors = 'None.',
        [string]$Notes = 'None.'
    )

    if (-not $script:outputPath) {
        return
    }

    $parent = Split-Path -Parent $script:outputPath
    if ($parent) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    $content = @"
Agent: codex
Mode: $Mode
Status: $Status

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

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:outputPath, $content.TrimEnd() + [Environment]::NewLine, $utf8NoBom)
}

try {
    $script:outputPath = [System.IO.Path]::GetFullPath($OutputFile)
    $taskPath = [System.IO.Path]::GetFullPath($TaskFile)
    $workspacePath = [System.IO.Path]::GetFullPath($Workspace)

    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        throw "TaskFile does not exist: $taskPath"
    }
    if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) {
        throw "Workspace does not exist: $workspacePath"
    }

    $codex = Get-Command codex -ErrorAction Stop
    $task = [System.IO.File]::ReadAllText($taskPath, [System.Text.Encoding]::UTF8)
    $sandbox = if ($Mode -eq 'execute') { 'workspace-write' } else { 'read-only' }

    $modeInstruction = switch ($Mode) {
        'execute' { 'Execute the task. You may modify files inside Workspace when the task requires it.' }
        'review' { 'Review only. Do not create, modify, delete, or format files. Report findings and evidence.' }
        'analyze' { 'Analyze only. Do not create, modify, delete, or format files. Report conclusions and evidence.' }
    }

    $prompt = @"
You are Codex being called through a local A2A adapter.
Mode: $Mode
Workspace: $workspacePath
$modeInstruction

Follow the task below as the complete user request. At the end, provide a concise final report containing:
- Summary
- Changed Files
- Commands / Tests
- Errors
- Notes

TaskFile contents:
---
$task
---
"@

    $tempId = [Guid]::NewGuid().ToString('N')
    $rawPath = Join-Path ([System.IO.Path]::GetTempPath()) "codex-a2a-$tempId-final.txt"
    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) "codex-a2a-$tempId-stdout.txt"
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) "codex-a2a-$tempId-stderr.txt"

    & $codex.Source exec --ephemeral --skip-git-repo-check --sandbox $sandbox --cd $workspacePath --output-last-message $rawPath --color never -- $prompt 1> $stdoutPath 2> $stderrPath
    $nativeExitCode = $LASTEXITCODE

    $finalMessage = if (Test-Path -LiteralPath $rawPath) { [System.IO.File]::ReadAllText($rawPath, [System.Text.Encoding]::UTF8).Trim() } else { '' }
    if (-not $finalMessage) {
        $finalMessage = 'No final agent message was produced.'
    }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.Encoding]::UTF8).Trim() } else { '' }

    if ($nativeExitCode -eq 0) {
        Write-Result -Status 'success' -Summary $finalMessage -Notes 'Codex exec returned exit code 0.'
        exit 0
    }

    $errorText = if ($stderr) { $stderr } else { 'Codex exec returned a non-zero exit code without stderr output.' }
    Write-Result -Status 'failed' -Summary $finalMessage -Errors $errorText -Notes "Native exit code: $nativeExitCode"
    exit $nativeExitCode
}
catch {
    $message = $_.Exception.Message
    Write-Result -Status 'failed' -Summary 'Codex invocation could not be started or completed.' -Errors $message -Notes 'The adapter returned a non-zero exit code.'
    exit 1
}
finally {
    foreach ($temporaryPath in @($rawPath, $stdoutPath, $stderrPath)) {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}
