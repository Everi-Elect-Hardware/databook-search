# ============================================================
#  DatabookAgent self-bootstrapping launcher (PowerShell)
# ------------------------------------------------------------
#  Designed to live on a network share, e.g.
#      Z:\LIBRARY\MentorGraphics\DatabookAgent\Start-DatabookAgent.ps1
#
#  On launch it:
#    1. Mirrors DatabookAgent.ps1 + .env.example + README.txt + .env into
#       %LOCALAPPDATA%\DatabookAgent\  (only when the source copy is
#       newer than what's already there).
#       NOTE: .env now mirrors a shared, scoped-down GitHub token so the
#       whole team gets the LLM parser with zero per-user setup. See
#       data/README.md for the token's scope/rotation policy.
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

# Mirror master files only when source is newer. .env is included so the
# shared team token distributes automatically - rotate it by replacing
# the source .env on the share; every launch re-syncs it.
$files = @('DatabookAgent.ps1', '.env.example', 'README.txt', '.env')
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

$envFile = Join-Path $dest '.env'
if (-not (Test-Path $envFile)) {
    Write-Host "  (no .env found - LLM parser disabled; ask Eduard Kliger about the shared token)"
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

# If the agent exited on its own (crash, startup error) rather than the
# window being closed/Ctrl+C'd, pause so "Run with PowerShell" doesn't
# instantly close the window before the error above can be read.
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[ERROR] Agent exited unexpectedly (code $LASTEXITCODE). See messages above." -ForegroundColor Red
    Read-Host "Press Enter to close this window"
}
