$ErrorActionPreference = 'Continue'
$node = 'C:\Users\origin\.workbuddy\binaries\node\versions\22.22.2-3\node.exe'
$out  = 'F:\AtoA\tasks\_ab.txt'
$lines = @()

function Try-Spawn {
    param([string]$Tag, [bool]$TouchEnv)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = '-e "console.log(''NODE_OK '' + process.version)"'
    $psi.WorkingDirectory = 'F:\AtoA\tasks'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($TouchEnv) {
        # 触发 EnvironmentVariables 实体化，并移除一个变量
        $null = $psi.EnvironmentVariables.Count
        [void]$psi.EnvironmentVariables.Remove('SERVER__PORT')
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        $o = $p.StandardOutput.ReadToEnd()
        $e = $p.StandardError.ReadToEnd()
        $p.WaitForExit(30000) | Out-Null
        $code = -1; try { $code = $p.ExitCode } catch {}
        $script:lines += "[" + $Tag + "] touchEnv=" + $TouchEnv + " exit=" + $code
        $script:lines += "    stdout: " + ($o -replace '\r?\n',' | ').Trim()
        if ($e) { $script:lines += "    stderr: " + ($e.Substring(0,[Math]::Min(300,$e.Length)) -replace '\r?\n',' | ') }
    } catch {
        $script:lines += "[" + $Tag + "] touchEnv=" + $TouchEnv + " EXCEPTION: " + $_.Exception.Message
    }
}

Try-Spawn -Tag 'A-no-touch' -TouchEnv $false
Try-Spawn -Tag 'B-touch'    -TouchEnv $true

[System.IO.File]::WriteAllText($out, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
