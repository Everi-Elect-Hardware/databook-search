#Requires -Version 5.1
<#
    Re-copies the Altium/DxDatabook CSV snapshots this tool uses for
    501-xxxxx-xx matching from the source 75809910 CCB project export
    folder. Run this whenever that project re-exports its library data.
#>
$srcDir = "C:\Users\eduard.kliger\OneDrive - IGT\Eduard's Files\75809910 CCB\databook-export"
$dstDir = Join-Path $PSScriptRoot 'data'

$files = @('Altium_Combined.csv', 'Unified_Library.csv')
foreach ($f in $files) {
    $src = Join-Path $srcDir $f
    $dst = Join-Path $dstDir $f
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "Updated $f" -ForegroundColor Green
    } else {
        Write-Warning "Source file not found: $src"
    }
}
Write-Host "Done. Restart the agent to pick up the refreshed data." -ForegroundColor Cyan
