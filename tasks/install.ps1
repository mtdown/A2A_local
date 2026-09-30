#!/usr/bin/env pwsh
param(
    [Parameter(Position=0)]
    [string]$Version = "latest"
)

$ErrorActionPreference = "Stop"

# Configuration
$Repository = "https://acc-1258344699.cos.accelerate.myqcloud.com/@tencent-ai/codebuddy-code/releases"
$Package = "codebuddy-code"
$Binary = "codebuddy"

# Detect platform
$OS = "Windows"
$Arch = "x86_64"

$Target = "${OS}_${Arch}"
$Ext = "zip"

# Create temporary directory
$TmpDir = Join-Path $env:TEMP "codebuddy-install-$(Get-Random)"
New-Item -ItemType Directory -Path $TmpDir | Out-Null

try {
    # Always use latest installer
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-WebRequest -Uri "$Repository/latest" -UseBasicParsing
    $Latest = if ($response.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($response.Content).Trim()
    } else {
        $response.Content.Trim()
    }

    # Download archive
    $Archive = "${Package}_${Target}.${Ext}"
    $ArchiveUrl = "$Repository/download/$Latest/$Archive"
    $ArchivePath = Join-Path $TmpDir $Archive

    Invoke-WebRequest -Uri $ArchiveUrl -OutFile $ArchivePath -UseBasicParsing

    # Verify checksum
    $response = Invoke-WebRequest -Uri "$Repository/download/$Latest/checksums.txt" -UseBasicParsing -ErrorAction Stop
    $Checksums = if ($response.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($response.Content)
    } else {
        $response.Content
    }
    $Expected = ($Checksums -split "`n" | Where-Object { $_ -match " $Archive$" } | ForEach-Object { ($_ -split "\s+")[0] })

    if (-not $Expected) {
        Write-Error "Checksum not found for $Archive"
        exit 1
    }

    $hash = Get-FileHash -Path $ArchivePath -Algorithm SHA256
    $Actual = $hash.Hash.ToLower()

    if ($Actual -ne $Expected) {
        Write-Error "Checksum verification failed!`nExpected: $Expected`nActual:   $Actual"
        exit 1
    }

    # Extract archive
    Expand-Archive -Path $ArchivePath -DestinationPath $TmpDir -Force

    # Find binary
    $BinaryName = "$Binary.exe"
    $BinaryPath = Join-Path $TmpDir $BinaryName

    if (-not (Test-Path $BinaryPath)) {
        Write-Error "Binary $BinaryName not found in archive"
        exit 1
    }

    # Delegate installation to the binary itself
    $InstallArgs = @("install")
    if ($Version -ne "latest") {
        $InstallArgs += $Version
    }

    & $BinaryPath $InstallArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

} finally {
    # Cleanup
    if (Test-Path $TmpDir) {
        Remove-Item -Path $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
