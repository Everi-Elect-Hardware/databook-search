# ============================================================
#  DatabookAgent self-bootstrapping launcher (PowerShell)
# ------------------------------------------------------------
#  Designed to live on a network share, e.g.
#      Z:\LIBRARY\MentorGraphics\DatabookAgent\Start-DatabookAgent.ps1
#
#  On launch it:
#    1. Mirrors DatabookAgent.ps1 + .env.example + README.txt into
#       %LOCALAPPDATA%\DatabookAgent\  (only when the source copy is
#       newer than what's already there).
#    2. Runs the LOCAL copy with PowerShell.
#
#  Why .ps1 and not .cmd?
#    AppLocker / Threat Locker policies on IGT laptops block .cmd / .bat
#    execution from user-writable paths.  PowerShell scripts run via
#    powershell.exe (System32, Microsoft-signed) which is allowed.
#
#  How to launch:
#    - Double-click:    Right-click -> "Run with PowerShell"
#    - From a prompt:   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path>\Start-DatabookAgent.ps1"
#
#  No new binaries are introduced.
# ============================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:LOCALAPPDATA 'DatabookAgent'

Write-Host "DatabookAgent launcher" -ForegroundColor Cyan
Write-Host "  Source : $src"
Write-Host "  Local  : $dest"
Write-Host ""

if (-not (Test-Path $dest)) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}

# Mirror master files only when source is newer.  Skip .env (user-private).
$files = @('DatabookAgent.ps1', '.env.example', 'README.txt')
foreach ($f in $files) {
    $s = Join-Path $src $f
    $d = Join-Path $dest $f
    if (-not (Test-Path $s)) { continue }
    $copy = $true
    if (Test-Path $d) {
        $sItem = Get-Item $s
        $dItem = Get-Item $d
        if ($dItem.LastWriteTime -ge $sItem.LastWriteTime) { $copy = $false }
    }
    if ($copy) {
        Copy-Item -Force $s $d
        Write-Host "  updated: $f"
    }
}

# Do NOT auto-seed .env from .env.example - the example contains a placeholder
# token that would make the agent report "LLM: error" instead of "LLM: off".
# Users opt-in to LLM by creating .env themselves (see README).
$envFile = Join-Path $dest '.env'
if (-not (Test-Path $envFile)) {
    Write-Host "  (no .env found - LLM parser disabled; copy .env.example to .env and add a token to enable it)"
}

$agent = Join-Path $dest 'DatabookAgent.ps1'
if (-not (Test-Path $agent)) {
    Write-Host ""
    Write-Host "[ERROR] DatabookAgent.ps1 not found at $agent" -ForegroundColor Red
    Write-Host "        Source folder $src does not contain it either." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "Starting agent ... (close this window to stop)" -ForegroundColor Green
Write-Host ""

# Run in-process so the user sees the agent log live.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agent
