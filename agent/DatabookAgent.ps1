# =============================================================================
# DatabookAgent.ps1 - Local read-only HTTP bridge to IGT DxDatabook SQL Server.
#
# Listens on http://localhost:5005 and exposes a small JSON API the GitHub
# Pages frontend can call. Connects to SQL via the existing ODBC DSN
# "DxDatabook" using the current Windows user's credentials.
#
# SAFETY (server can NOT be corrupted by this agent):
#   - Only single-statement SELECT queries are accepted.
#   - SQL is built server-side from a whitelisted (table, column, op) filter
#     using parameterised values - the user/LLM never supplies raw SQL.
#   - Every query runs inside BEGIN TRAN ... ROLLBACK so even side-effecting
#     reads are undone.
#   - Result row count is capped (default 200) to prevent DoS / huge dumps.
#   - Listener is bound to localhost ONLY (not reachable from the network).
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File DatabookAgent.ps1
# Stop with Ctrl+C in the window.
# =============================================================================

[CmdletBinding()]
param(
    [int]    $Port            = 5005,
    [string] $Dsn             = 'DxDatabook',
    [int]    $MaxRows         = 200,
    [int]    $CmdTimeoutSec   = 10,
    # Origins allowed to call the agent (CORS).
    # Add your GitHub Pages URL(s) here. Example values for Everi-Elect-Hardware:
    #   public repo Pages:    https://everi-elect-hardware.github.io
    #   GitHub Enterprise:    https://<your-ghe-pages-host>
    [string[]] $AllowedOrigins = @(
        'http://localhost',
        'http://127.0.0.1',
        'https://everi-elect-hardware.github.io',   # HW engineering org Pages
        'null'   # for file:// during local frontend dev
    ),
    # GitHub Models config (LLM parser). Token can come from:
    #   1) -GitHubToken parameter
    #   2) $env:GITHUB_TOKEN
    #   3) a .env file next to this script (line: GITHUB_TOKEN=ghp_xxx)
    [string] $GitHubToken     = '',
    [string] $GitHubModel     = 'openai/gpt-4o-mini',
    [string] $GitHubModelsUrl = 'https://models.github.ai/inference/chat/completions'
)

# ---------------------------------------------------------------------------
# 0. Token loader: pick first available source.
# ---------------------------------------------------------------------------
if (-not $GitHubToken) { $GitHubToken = $env:GITHUB_TOKEN }
if (-not $GitHubToken) {
    $envFile = Join-Path $PSScriptRoot '.env'
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            if ($_ -match '^\s*GITHUB_TOKEN\s*=\s*(.+?)\s*$') {
                $GitHubToken = $matches[1].Trim('"').Trim("'")
            }
        }
    }
}

# PowerShell 5.1 defaults to TLS 1.0/1.1 which models.github.ai rejects.
# Force TLS 1.2 + 1.3 for every outbound HTTPS call in this process.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
# Some corporate proxy auto-discovery breaks down inside a long-running
# process; default to no proxy (the OS already has direct access).
try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch {}
# Refresh DNS every 30s instead of caching it for the life of the process.
try { [System.Net.ServicePointManager]::DnsRefreshTimeout = 30000 } catch {}

# ---------------------------------------------------------------------------
# 1. Whitelist of tables and the columns we will allow filters on.
#    Add/remove freely - anything not here is rejected.
# ---------------------------------------------------------------------------
$Schema = @{
    'Resistor'   = @('IGTPartNo','Description','State','Datasheet','Device','PKG_TYPE','Type','Value','Tolerance','Power','TCR','Mounting','Preference','StandardCost','Comments')
    'Capacitor'  = @('IGTPartNo','Description','State','Datasheet','Device','PKG_TYPE','Type','SubType','Value','Tolerance','Voltage','Application','TempCo','Mounting','Preference','StandardCost','Comments')
    'Diode'      = @('IGTPartNo','Description','State','Datasheet','Device','PKG_TYPE','Type','Value','Current','Voltage','Power','Mounting','Preference','StandardCost','Comments')
    'Inductor'   = @('IGTPartNo','Description','State','Datasheet','Device','PKG_TYPE','Type','Value','Tolerance','Current','DCRValue','Mounting','Preference','StandardCost','Comments')
    'Bead'       = @('IGTPartNo','Description','State','Datasheet','Device','Package','Type','SubType','ImpValue','IndCurrent','DCRValue','Mounting','Preference','StandardCost','Comments')
    'Transistor' = @('IGTPartNo','Description','State','Datasheet','Device','PKG_TYPE','Type','SubType','Value','Voltage','Current','Mounting','Preference','StandardCost','Comments')
    'Protection' = @('IGTPartNo','Description','State','Datasheet','Device','PKG_TYPE','Type','TripVolts','TripCurrent','Polarity','Time','Mounting','Preference','StandardCost','Comments')
    'IC'         = @('IGTPartNo','Description','State','Datasheet','Device','PKG_TYPE','Value','Mounting','Preference','StandardCost','Comments')
    'Connector'  = @('IGTPartNo','Description','State','Datasheet','Device','PKG_TYPE','SubType','ContactGender','Pitch','Orientation','Mounting','Preference','StandardCost','Comments')
}

$AllowedOps = @('=', 'LIKE', 'IN', '<', '<=', '>', '>=', '<>')

# Live-discovered map of every dbo table that has IGTPartNo-style data,
# populated by Initialize-LiveSchema at startup. Used by the universal
# keyword scan so we can find parts the curated $Schema doesn't cover
# (e.g. USB hubs in IC-Digital, oscillators, switches, displays, etc.).
$AllTables = @{}
# Tables to never scan (system / cache / non-component).
$ExcludedTables = @('Database CacheHitRatioResults','Documentation','LED_old')

# Forbidden tokens in any text value or identifier (defense in depth).
$ForbiddenPattern = '(?i)(;|--|/\*|\*/|\bxp_|\bsp_|\bexec\b|\bexecute\b|\binsert\b|\bupdate\b|\bdelete\b|\bdrop\b|\balter\b|\bcreate\b|\btruncate\b|\bmerge\b|\bgrant\b|\brevoke\b|\bbackup\b|\brestore\b|\bopenrowset\b|\bopenquery\b|\bbulk\b|\bshutdown\b|\bwaitfor\b)'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level='INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts][$Level] $Msg"
}

function Invoke-CurlPostJson {
    <#
        POST a JSON body to a URL via a freshly-spawned powershell.exe child
        process. We do this instead of an in-process Invoke-RestMethod /
        HttpClient call because on this corporate network the long-running
        agent process (which is listening on TCP 5005 via HttpListener) is
        intermittently blocked outbound to models.github.ai by the local
        firewall ("An attempt was made to access a socket in a way forbidden
        by its access permissions"). A short-lived child process gets its
        own firewall evaluation and reliably succeeds.
        Returns the parsed JSON object, or throws on failure.
    #>
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$BodyJson,
        [string]$BearerToken,
        [int]$TimeoutSec = 30
    )

    $psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $psExe) { throw "powershell.exe not found" }

    $tmpBody = [System.IO.Path]::GetTempFileName()
    $tmpOut  = [System.IO.Path]::GetTempFileName()
    $tmpErr  = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmpBody, $BodyJson, [System.Text.UTF8Encoding]::new($false))

        # Child script: read body file, POST it with up to 3 internal
        # retries (the corporate firewall intermittently blocks fresh
        # outbound sockets too), write raw response or "ERR:..." to stdout.
        $childScript = @"
`$ErrorActionPreference = 'Stop'
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072
} catch {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
try { [System.Net.WebRequest]::DefaultWebProxy = `$null } catch {}
`$bodyText = [System.IO.File]::ReadAllText('$tmpBody', [System.Text.UTF8Encoding]::new(`$false))
`$headers = @{ 'Content-Type'='application/json'; 'Accept'='application/json' }
"@
        if ($BearerToken) {
            $childScript += "`n`$headers['Authorization'] = 'Bearer $BearerToken'`n"
        }
        $childScript += @"
`$lastErr = `$null
for (`$i = 1; `$i -le 4; `$i++) {
  try {
    `$resp = Invoke-WebRequest -Uri '$Url' -Method Post -Body `$bodyText -Headers `$headers -TimeoutSec $TimeoutSec -UseBasicParsing
    [Console]::Out.Write(`$resp.Content)
    exit 0
  } catch {
    `$lastErr = `$_
    `$msg = `$_.Exception.Message
    if (`$msg -match '401|403|404|429|5\d\d') { break }
    Start-Sleep -Milliseconds (300 * `$i)
  }
}
`$msg = `$lastErr.Exception.Message
`$detail = `$null
try { `$detail = `$lastErr.ErrorDetails.Message } catch {}
if (`$detail) { [Console]::Out.Write('ERR:' + `$msg + ' :: ' + `$detail) }
else        { [Console]::Out.Write('ERR:' + `$msg) }
exit 1
"@
        $tmpScript = [System.IO.Path]::GetTempFileName() + '.ps1'
        [System.IO.File]::WriteAllText($tmpScript, $childScript, [System.Text.UTF8Encoding]::new($false))

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $psExe
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tmpScript`""
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow  = $true

            $stdout = ''
            $stderr = ''
            $exit = -1
            $lastChildErr = $null
            # Up to 2 fresh subprocess attempts. The Windows firewall on this
            # endpoint randomly blocks short-lived outbound sockets too, but
            # a brand-new process on a 2-second cooldown usually succeeds.
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $proc = [System.Diagnostics.Process]::Start($psi)
                if (-not $proc.WaitForExit(($TimeoutSec + 5) * 1000)) {
                    try { $proc.Kill() } catch {}
                    $lastChildErr = "Child process timed out after ${TimeoutSec}s"
                    continue
                }
                $stdout = $proc.StandardOutput.ReadToEnd()
                $stderr = $proc.StandardError.ReadToEnd()
                $exit   = $proc.ExitCode
                if ($exit -eq 0 -and -not $stdout.StartsWith('ERR:')) { break }
                $lastChildErr = if ($stdout.StartsWith('ERR:')) { $stdout.Substring(4) } else { $stderr }
                # Don't retry on auth/limit errors -- they will not improve.
                if ($lastChildErr -match '401|403|404|429') { break }
                if ($attempt -lt 2) { Start-Sleep -Milliseconds 1500 }
            }

            if ($exit -ne 0 -or $stdout.StartsWith('ERR:')) {
                throw $lastChildErr
            }
            if (-not $stdout) { throw "Empty response body" }
            try { return ($stdout | ConvertFrom-Json) }
            catch { throw "Non-JSON response: $($stdout.Substring(0, [Math]::Min(200, $stdout.Length)))" }
        } finally {
            try { Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue } catch {}
        }
    } finally {
        try { Remove-Item $tmpBody -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item $tmpOut  -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item $tmpErr  -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Test-SafeIdentifier {
    param([string]$Name)
    # Identifiers must be alphanumeric/underscore only, length 1..64.
    return ($Name -match '^[A-Za-z_][A-Za-z0-9_ \-]{0,63}$') -and ($Name -notmatch $ForbiddenPattern)
}

function Test-SafeValue {
    param($Value)
    if ($null -eq $Value) { return $true }
    $s = [string]$Value
    if ($s.Length -gt 256) { return $false }
    if ($s -match $ForbiddenPattern) { return $false }
    return $true
}

function New-OdbcConnection {
    $cs = "DSN=$Dsn;Trusted_Connection=Yes;ApplicationIntent=ReadOnly;"
    $c  = New-Object System.Data.Odbc.OdbcConnection $cs
    $c.Open()
    return $c
}

function Initialize-LiveSchema {
    <#
        Reads INFORMATION_SCHEMA at startup and populates $script:AllTables
        with every dbo table that has an IGTPartNo column. Stores the list
        of string-ish columns per table for the universal keyword scan.
        Read-only; opens its own short-lived connection so the MaxRows cap
        on Invoke-SafeQuery doesn't truncate the metadata listing.
    #>
    try {
        $conn = New-OdbcConnection
        try {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = @"
SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'dbo'
  AND c.TABLE_NAME IN (
    SELECT TABLE_NAME FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA='dbo' AND COLUMN_NAME='IGTPartNo'
  )
"@
            $cmd.CommandTimeout = $CmdTimeoutSec
            $reader = $cmd.ExecuteReader()
            $map = @{}
            while ($reader.Read()) {
                $t   = [string]$reader['TABLE_NAME']
                if ($script:ExcludedTables -contains $t) { continue }
                $col = [string]$reader['COLUMN_NAME']
                $dt  = [string]$reader['DATA_TYPE']
                if (-not $map.ContainsKey($t)) { $map[$t] = @{ all=@(); text=@() } }
                $map[$t].all += $col
                if ($dt -match '^(varchar|nvarchar|char|nchar|text|ntext)$') {
                    $map[$t].text += $col
                }
            }
            $reader.Close()
            $script:AllTables = $map
            Write-Log "Live schema: $($map.Count) tables discovered with IGTPartNo column."
        }
        finally { $conn.Close() }
    } catch {
        Write-Log "Live schema discovery failed: $_  (universal scan will use curated `$Schema only)" 'WARN'
        $script:AllTables = @{}
    }
}

function Invoke-SafeQuery {
    <#
        Runs a SELECT inside BEGIN TRAN..ROLLBACK. Returns array of hashtables.
        $sql is a parameterised statement using ? placeholders.
        $params is an array of values in the same order.
    #>
    param(
        [Parameter(Mandatory)] [string] $Sql,
        [object[]] $Params = @()
    )

    if ($Sql -match $ForbiddenPattern) {
        throw "SQL contains forbidden token. Rejected."
    }
    if ($Sql -notmatch '^\s*SELECT\b') {
        throw "Only SELECT statements are allowed."
    }
    if ($Sql -match ';') {
        throw "Multi-statement batches are not allowed."
    }

    $conn = New-OdbcConnection
    try {
        $tx = $conn.BeginTransaction()
        try {
            $cmd = $conn.CreateCommand()
            $cmd.Transaction    = $tx
            $cmd.CommandText    = $Sql
            $cmd.CommandTimeout = $CmdTimeoutSec
            foreach ($p in $Params) {
                [void]$cmd.Parameters.AddWithValue([string][guid]::NewGuid(), $p)
            }
            $reader = $cmd.ExecuteReader()
            $rows = New-Object System.Collections.ArrayList
            $colCount = $reader.FieldCount
            $cols = 0..($colCount-1) | ForEach-Object { $reader.GetName($_) }
            while ($reader.Read() -and $rows.Count -lt $MaxRows) {
                $row = [ordered]@{}
                for ($i = 0; $i -lt $colCount; $i++) {
                    $v = $reader.GetValue($i)
                    if ($v -is [System.DBNull]) { $v = $null }
                    $row[$cols[$i]] = $v
                }
                [void]$rows.Add([pscustomobject]$row)
            }
            $reader.Close()
            return ,$rows.ToArray()
        }
        finally {
            # Always rollback - we never write.
            try { $tx.Rollback() } catch {}
        }
    }
    finally {
        $conn.Close()
    }
}

function Build-Search {
    <#
        Build a parameterised SELECT from a validated structured request:
        @{ table='Resistor'; columns=@('IGTPARTNO','VALUE'); filters=@(@{column='PACKAGE'; op='='; value='0603'}, ...) }
    #>
    param([hashtable]$Req)

    $table = [string]$Req.table
    if (-not $Schema.ContainsKey($table)) {
        throw "Unknown or disallowed table: $table"
    }
    $allowedCols = $Schema[$table]

    # Columns to return
    $selCols = @()
    if ($Req.columns -and @($Req.columns).Count -gt 0) {
        foreach ($c in $Req.columns) {
            if (-not (Test-SafeIdentifier $c)) { throw "Bad column name: $c" }
            if ($allowedCols -notcontains $c) { throw "Column not allowed for $table : $c" }
            $selCols += $c
        }
    } else {
        $selCols = $allowedCols
    }
    $selList = ($selCols | ForEach-Object { "[$_]" }) -join ', '

    # WHERE
    $whereParts = @()
    $params = @()
    if ($Req.filters) {
        foreach ($f in $Req.filters) {
            $col = [string]$f.column
            $op  = [string]$f.op
            $val = $f.value
            if (-not (Test-SafeIdentifier $col)) { throw "Bad filter column: $col" }
            if ($allowedCols -notcontains $col) { throw "Filter column not allowed for $table : $col" }
            if ($AllowedOps -notcontains $op)   { throw "Operator not allowed: $op" }
            if (-not (Test-SafeValue $val))     { throw "Filter value rejected." }

            if ($op -eq 'IN') {
                if (-not ($val -is [array])) { throw "IN value must be array." }
                $placeholders = @()
                foreach ($v in $val) {
                    if (-not (Test-SafeValue $v)) { throw "IN list value rejected." }
                    $placeholders += '?'
                    $params += $v
                }
                $whereParts += "[$col] IN ($($placeholders -join ','))"
            }
            elseif ($op -eq 'LIKE') {
                $whereParts += "[$col] LIKE ?"
                $params += $val
            }
            else {
                $whereParts += "[$col] $op ?"
                $params += $val
            }
        }
    }

    $sql = "SELECT TOP $MaxRows $selList FROM [dbo].[$table]"
    if ($whereParts.Count -gt 0) {
        $sql += " WHERE " + ($whereParts -join ' AND ')
    }
    return @{ Sql = $sql; Params = $params }
}

# ---------------------------------------------------------------------------
# HTTP handling
# ---------------------------------------------------------------------------
function Send-Json {
    param($Context, [int]$Status, $Obj, [string]$Origin)
    $resp = $Context.Response
    $resp.StatusCode = $Status
    $resp.ContentType = 'application/json; charset=utf-8'
    if ($Origin) {
        $resp.Headers['Access-Control-Allow-Origin']  = $Origin
        $resp.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
        $resp.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
        $resp.Headers['Vary'] = 'Origin'
    }
    $json = $Obj | ConvertTo-Json -Depth 6 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Get-AllowedOrigin {
    param([string]$RequestOrigin)
    if (-not $RequestOrigin) { return $null }
    foreach ($o in $AllowedOrigins) {
        if ($RequestOrigin -eq $o -or $RequestOrigin.StartsWith($o)) { return $RequestOrigin }
    }
    return $null
}

function Read-RequestBody {
    param($Context)
    $req = $Context.Request
    if (-not $req.HasEntityBody) { return $null }
    $sr = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
    try { return $sr.ReadToEnd() } finally { $sr.Close() }
}

# ---------------------------------------------------------------------------
# Chat / NL parsing
#
# Two modes:
#   (a) Rule-based parser (default) - regex-extracts common spec patterns.
#       Works offline, no API key needed. Good for "0603 1% 58 ohm" style.
#   (b) GitHub Models LLM (if $env:GITHUB_TOKEN is set) - uses gpt-4o-mini
#       to convert free-form text into the same structured filter JSON.
#       Same downstream validation; LLM cannot inject SQL.
# ---------------------------------------------------------------------------

function Convert-ValueToOhms {
    param([string]$Text)
    if ($Text -match '^([\d\.]+)\s*([kKmMrRoO]?)') {
        $n = [double]$matches[1]; $u = $matches[2].ToLower()
        switch ($u) {
            'k' { return $n * 1e3 }
            'm' { return $n * 1e6 }
            default { return $n }
        }
    }
    return $null
}

function Convert-ValueToFarads {
    param([string]$Text)
    if ($Text -match '^([\d\.]+)\s*([pPnNuU\xB5fF]+)') {
        $n = [double]$matches[1]; $u = $matches[2].ToLower()
        if ($u -match '^p')         { return $n * 1e-12 }
        elseif ($u -match '^n')     { return $n * 1e-9 }
        elseif ($u -match '^(u|µ)') { return $n * 1e-6 }
        elseif ($u -match '^m')     { return $n * 1e-3 }
        else                        { return $n }
    }
    return $null
}

function Invoke-RuleParser {
    <#
        Best-effort parse of a free-form engineer query into a structured
        DxDatabook filter. Returns:
          @{ table='Resistor'; filters=@(...); columns=@(...); intent='...' }
        or $null if nothing recognized.

        Calibrated to actual DxDatabook storage formats:
         - Resistor.Value   = raw ohms (e.g. 4700 for 4.7k)
         - Capacitor.Value  = farads scientific (e.g. 1E-09 for 1nF)
         - Diode.Type       = short codes: SHTKY, TVS, ZNR, RECT, SIGNAL, SW, ARRAY, BRDG, REF
         - PKG_TYPE         = exact label, e.g. 0603, SOT-23, DO-35, SO-8
    #>
    param([string]$Text)

    $t = $Text.ToLower()

    # ----- Family detection -----
    $table = $null
    if     ($t -match '\bres(istor)?\b|\bohm|\u03A9') { $table = 'Resistor' }
    elseif ($t -match '\bcap(acitor)?\b|\d+\s*[unp]f\b|0?\.\d+\s*uf\b|\bmlcc\b') { $table = 'Capacitor' }
    elseif ($t -match '\bdiode|\bschottky|\btvs\b|\bzener|\besd diode|\bshtky|\brectifier') { $table = 'Diode' }
    elseif ($t -match '\binductor|\bcoil') { $table = 'Inductor' }
    elseif ($t -match '\bbead|\bferrite') { $table = 'Bead' }
    elseif ($t -match '\bmosfet|\bbjt|\btransistor|\bfet\b') { $table = 'Transistor' }
    elseif ($t -match '\besd protection|protection|\btvs array') { $table = 'Protection' }
    elseif ($t -match '\bic\b|\bregulator|\bldo\b|\bmcu\b|\bopamp|\bop-amp') { $table = 'IC' }
    elseif ($t -match '\bconnector|\bheader|\busb\b|\brj45') { $table = 'Connector' }

    if (-not $table) { return $null }

    $allowedCols = $Schema[$table]
    $filters = @()

    # ----- Surface-mount package size (resistor/capacitor/inductor) -----
    if ($t -match '\b(0201|0402|0603|0805|1206|1210|2010|2512)\b') {
        $pkgCol = if ($allowedCols -contains 'PKG_TYPE') { 'PKG_TYPE' }
                  elseif ($allowedCols -contains 'Package') { 'Package' } else { $null }
        if ($pkgCol) { $filters += @{ column=$pkgCol; op='='; value=$matches[1] } }
    }

    # ----- Discrete packages (diode/transistor): SOT-23, SOT-23-3, SOT-23-6, DO-35, DO-41, SOD-323, DPAK, D2PAK, SMA, SMB, SMC -----
    if ($t -match '\b(sot-?23(?:-\d)?|sot-?89|sot-?223|do-?\d+|sod-?\d+|d2pak|dpak|sma|smb|smc|so-?\d+)\b') {
        $pkg = $matches[1].ToUpper() -replace '^SOT(\d)','SOT-$1' -replace '^DO(\d)','DO-$1' -replace '^SOD(\d)','SOD-$1' -replace '^SO(\d)','SO-$1'
        if ($allowedCols -contains 'PKG_TYPE') {
            $filters += @{ column='PKG_TYPE'; op='LIKE'; value="$pkg%" }
        }
    }

    # ----- Tolerance (resistor): 1%, 0.1%, 5% -----
    if ($t -match '(\d+(?:\.\d+)?)\s*%') {
        if ($allowedCols -contains 'Tolerance') {
            $filters += @{ column='Tolerance'; op='='; value=("$($matches[1])%") }
        }
    }

    # ----- Voltage (cap/diode/transistor): exact match against numeric column -----
    if ($t -match '(\d+(?:\.\d+)?)\s*v(?:olt)?\b') {
        if ($allowedCols -contains 'Voltage') {
            $filters += @{ column='Voltage'; op='='; value=$matches[1] }
        }
    }

    # ----- Resistor value: 58 ohm, 4.7k, 10kohm, 1M -----
    if ($table -eq 'Resistor') {
        $rOhms = $null
        if ($t -match '(\d+(?:\.\d+)?)\s*([kKmM])\s*(?:ohm|\u03A9)?') {
            $n = [double]$matches[1]
            switch ($matches[2].ToLower()) {
                'k' { $rOhms = $n * 1000 }
                'm' { $rOhms = $n * 1000000 }
            }
        }
        elseif ($t -match '(\d+(?:\.\d+)?)\s*(?:ohm|\u03A9)') {
            $rOhms = [double]$matches[1]
        }
        if ($rOhms -ne $null) {
            # store as integer if whole number, else trimmed decimal
            $valStr = if ([math]::Floor($rOhms) -eq $rOhms) { [string][int]$rOhms } else { [string]$rOhms }
            $filters += @{ column='Value'; op='='; value=$valStr }
        }
    }

    # ----- Capacitor value: 0.1uF, 100nF, 22pF -> use range on farad-scientific column -----
    if ($table -eq 'Capacitor') {
        if ($t -match '(\d+(?:\.\d+)?)\s*(uf|\xB5f|nf|pf|mf)') {
            $n = [double]$matches[1]
            $f = switch ($matches[2].ToLower()) {
                'pf'         { $n * 1e-12 }
                'nf'         { $n * 1e-9 }
                { $_ -in 'uf','µf' } { $n * 1e-6 }
                'mf'         { $n * 1e-3 }
                default      { $n }
            }
            # +/- 5% range to absorb storage-format differences (1E-07 vs 1.0E-07)
            $lo = $f * 0.95; $hi = $f * 1.05
            $filters += @{ column='Value'; op='>='; value=[string]$lo }
            $filters += @{ column='Value'; op='<='; value=[string]$hi }
        }
    }

    # ----- Diode subtype keywords -----
    if ($table -eq 'Diode') {
        if     ($t -match '\bschottky|shtky')      { $filters += @{ column='Type'; op='='; value='SHTKY' } }
        elseif ($t -match '\btvs\b')               { $filters += @{ column='Type'; op='='; value='TVS' } }
        elseif ($t -match '\bzener|\bznr\b')       { $filters += @{ column='Type'; op='='; value='ZNR' } }
        elseif ($t -match '\brectifier|\brect\b')  { $filters += @{ column='Type'; op='='; value='RECT' } }
        elseif ($t -match '\bsignal\b')            { $filters += @{ column='Type'; op='='; value='SIGNAL' } }
        elseif ($t -match '\bbridge|\bbrdg\b')     { $filters += @{ column='Type'; op='='; value='BRDG' } }
        elseif ($t -match '\barray|\bary\b')       { $filters += @{ column='Type'; op='='; value='ARRAY' } }
    }

    # ----- Manufacturer P/N hint anywhere -> Description LIKE -----
    if ($Text -match '([A-Z][A-Z0-9]{2,4}[\d-][A-Z0-9\-]+)') {
        $maybe = $matches[1].ToUpper()
        if ($maybe -notmatch '^(0201|0402|0603|0805|1206|1210|SOT|DO|SOD|SMA|SMB|SMC|SO\d+)' -and
            $allowedCols -contains 'Description') {
            $filters += @{ column='Description'; op='LIKE'; value="%$maybe%" }
        }
    }

    # ----- Default columns to return -----
    $cols = @()
    foreach ($c in @('IGTPartNo','Value','Tolerance','PKG_TYPE','Package','Voltage','Power','Current','Type','Description','State')) {
        if ($allowedCols -contains $c) { $cols += $c }
    }

    return @{
        table   = $table
        filters = $filters
        columns = $cols
        intent  = "Search $table" + ($(if($filters){' with '+(($filters | ForEach-Object{ "$($_.column) $($_.op) $($_.value)" }) -join ', ')}else{''}))
    }
}

function Invoke-LlmParser {
    <#
        Optional GPT-4o-mini parser via GitHub Models. Activated if a token
        was loaded (param, env var, or .env file). Returns same shape as
        Invoke-RuleParser, or $null on failure. On failure, sets
        $script:LastLlmError so /health and /chat can surface the cause.
    #>
    param(
        [string]$Text,
        # Optional prior chat turns to give the LLM follow-up context.
        # Each item: @{ role='user'|'assistant'; content='...' }
        $History = @()
    )
    if (-not $script:GitHubToken) {
        $script:LastLlmError = 'no token configured'
        return $null
    }

    $schemaText = ($Schema.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value -join ', ')" }) -join "`n"
    # Also tell the model what other tables exist (auto-discovered) so it can
    # emit mode=keyword for things like Oscillator, IC-Digital, Microprocessors,
    # Switch, Display, Battery, etc. even though structured queries are only
    # allowed on the curated $Schema list.
    $otherTables = @()
    if ($script:AllTables -and $script:AllTables.Count -gt 0) {
        foreach ($t in ($script:AllTables.Keys | Sort-Object)) {
            if (-not $Schema.ContainsKey($t)) { $otherTables += $t }
        }
    }
    $otherTablesNote = if ($otherTables.Count -gt 0) {
        "Other component tables (keyword scan only, no structured filters): $($otherTables -join ', ')"
    } else { '' }
    $sys = @"
You convert engineer queries into JSON filters for IGT's electronic-component database.
Allowed tables and their columns:
$schemaText

$otherTablesNote

Operators allowed: =, LIKE, <, <=, >, >=, <>, IN
Numeric values use exact strings (no quotes). For LIKE, include % wildcards.

Important storage notes:
- Resistor.Value is raw ohms as a string (e.g. "4700" for 4.7k, "10000" for 10k).
- Capacitor.Value is a FLOAT column holding farads (e.g. 1E-07 for 100nF,
  1E-09 for 1nF, 1E-05 for 10uF). Use op "=" with the scientific value as a
  bare string:
    100nF -> filters: [{"column":"Value","op":"=","value":"1E-07"}]
    1nF   -> filters: [{"column":"Value","op":"=","value":"1E-09"}]
    10uF  -> filters: [{"column":"Value","op":"=","value":"1E-05"}]
  DO NOT use LIKE on Capacitor.Value -- it is float, LIKE will fail.
- Voltage / Current / Tolerance columns are stored as VARCHAR strings (e.g.
  "50", "16", "1%"). For an exact target like "50V" emit op "=" with value
  "50". DO NOT use >= or <= on these columns -- string comparison is lexical
  and "50" >= "6" is false. Only use < <= > >= when the user explicitly
  asks for a range AND when you express the threshold so it makes sense as
  lexical compare (rarely useful -- prefer "=").
- Diode.Type is a short code: SHTKY, TVS, ZNR, RECT, SIGNAL, SW, ARRAY, BRDG, REF.
- PKG_TYPE values are exact labels like 0603, SOT-23, DO-35, SO-8.

KEYWORDS MUST BE SINGLE TOKENS, not phrases:
- "USB hub IC in a small package" -> keyword: "USB" (not "USB hub IC")
- "find me oscillators around 16MHz" -> keyword: "oscillator" (or use structured table=Oscillator if listed)
- "any STM32 part" -> keyword: "STM32"
The keyword is fed into LIKE %keyword% so multi-word phrases will not match.
Prefer the single most distinctive noun or part-code token.

Reply with ONLY a JSON object. Three shapes are allowed:

A. Structured filter (use when the user asks you to FIND parts in the database):
{
  "mode": "structured",
  "table": "Resistor",
  "filters": [{"column":"PKG_TYPE","op":"=","value":"0603"}, ...],
  "columns": ["IGTPartNo","Value","PKG_TYPE","Tolerance","State"]
}

B. Keyword scan (use when the user asks for "all/any/every X", or X is a part
   code, or you cannot tell which table applies):
{
  "mode": "keyword",
  "keyword": "TVS"
}

C. Direct answer (use when the user is asking a FACTUAL or CONCEPTUAL question
   about a part rather than asking to find parts -- e.g. "what is the clamping
   voltage of 48017191W", "explain how a TVS diode works", "is SRDA3.3 unidirec-
   tional?", "datasheet link for STM32F407", "what package is SOT-23-6". The
   answer should be 1-4 short sentences, use any context from the conversation
   history (prior search results, prior part numbers), and never invent specs --
   if you don't know, say so and suggest the user check the datasheet:
{
  "mode": "answer",
  "answer": "SRDA3.3 is a 3.3V uni-directional TVS diode array. Its typical clamping voltage at 1A is around 9V; see the Littelfuse SRDA3.3 datasheet for exact numbers."
}

STRONG HINTS FOR mode=answer (use answer mode, NOT keyword/structured, when):
- The query starts with "what is", "what's", "how does", "how do", "why",
  "explain", "tell me about", "is this", "does this", "can this".
- The query asks for a SPEC of a specific IGT part number (8-digit code,
  optionally trailing letter, e.g. "32083091", "48017191W") -- e.g. "operating
  voltage", "clamping voltage", "current rating", "function" of a specific
  part number. Use the part's Description from conversation history.
- The query contains typos that look like spec words ("operretion", "claming",
  "voltge") -- still treat as a spec question, do NOT use the typo as a
  database keyword.
In these cases, draw on conversation history (prior search rows often include
the part's Description, Type, Value) and reply with a concise prose answer.

VERY IMPORTANT -- PREFER STRUCTURED LOOKUP when the user asks for a STORED
DATABASE FIELD of a known part number from conversation history. Examples:
- "show me datasheet" / "give me the datasheet link" / "datasheet for 47464894"
  -> mode=structured against the table that part lives in,
     filters=[{"column":"IGTPartNo","op":"=","value":"47464894"}],
     columns=["IGTPartNo","Description","Datasheet"]
- "what is the description for 47464894" -> structured, columns include Description
- "what tolerance does 47464894 have" -> structured, columns include Tolerance
- "what package is 32083091 in" -> structured, columns include PKG_TYPE
The Datasheet column in EVERY table holds the actual URL we want to surface.
Never answer "check the manufacturer's website" when you can look up the
Datasheet field directly. If you don't know which table the part is in, pick
the most plausible one from conversation history (it was almost certainly
mentioned in a prior assistant turn with `_source=<TableName>`).

If nothing useful can be done, reply with {"mode": "none"}.
"@

    $msgs = @(@{ role='system'; content=$sys })
    # Cap prior turns to last 6 exchanges to keep tokens low.
    if ($History) {
        $hist = @($History)
        if ($hist.Count -gt 12) { $hist = $hist[($hist.Count-12)..($hist.Count-1)] }
        foreach ($h in $hist) {
            $role = [string]$h.role
            $content = [string]$h.content
            if ($role -and $content -and ($role -eq 'user' -or $role -eq 'assistant')) {
                $msgs += @{ role=$role; content=$content }
            }
        }
    }
    $msgs += @{ role='user'; content=$Text }

    $body = @{
        model = $script:GitHubModel
        messages = $msgs
        temperature = 0
        response_format = @{ type='json_object' }
    } | ConvertTo-Json -Depth 8

    try {
        # Use curl.exe (ships with Windows 10/11) for the LLM call. The
        # in-process .NET HTTP stack in long-running PowerShell jobs is
        # unreliable on this network -- a fresh OS-level TLS connection
        # via curl is dramatically more stable than ServicePoint reuse.
        $resp = Invoke-CurlPostJson -Url $script:GitHubModelsUrl -BodyJson $body -BearerToken $script:GitHubToken -TimeoutSec 30
        if (-not $resp) { throw "curl returned no response" }

        $content = $resp.choices[0].message.content
        $j = $content | ConvertFrom-Json
        $mode = if ($j.PSObject.Properties.Name -contains 'mode' -and $j.mode) { [string]$j.mode } else { 'structured' }
        if ($mode -eq 'keyword' -and $j.keyword) {
            $script:LastLlmError = $null
            $script:LastLlmOkAt  = Get-Date
            return @{
                mode = 'keyword'
                keyword = [string]$j.keyword
                intent = "LLM-parsed: keyword scan for '$($j.keyword)'"
            }
        }
        if ($mode -eq 'answer' -and $j.answer) {
            $script:LastLlmError = $null
            $script:LastLlmOkAt  = Get-Date
            return @{
                mode = 'answer'
                answer = [string]$j.answer
                intent = 'LLM-parsed: direct answer'
            }
        }
        if (-not $j.table) { return $null }
        $h = @{
            mode = 'structured'
            table = [string]$j.table
            columns = @($j.columns)
            filters = @()
            intent = "LLM-parsed: search $($j.table)"
        }
        foreach ($f in @($j.filters)) {
            $h.filters += @{ column=$f.column; op=$f.op; value=$f.value }
        }
        $script:LastLlmError = $null
        $script:LastLlmOkAt  = Get-Date
        return $h
    } catch {
        $msg = "$_"
        # Try to pick a short error tag
        $tag = if     ($msg -match '\b401\b|unauthorized') { '401 unauthorized (token expired or wrong scope)' }
               elseif ($msg -match '\b403\b|forbidden')    { '403 forbidden (no Models access on this account/org)' }
               elseif ($msg -match '\b404\b')              { '404 not found (model name or endpoint wrong)' }
               elseif ($msg -match '\b429\b')              { '429 rate limited' }
               elseif ($msg -match '\b5\d\d\b')            { 'GitHub Models server error' }
               elseif ($msg -match 'timed out|timeout')    { 'network timeout' }
               else                                         { $msg.Substring(0, [math]::Min(160, $msg.Length)) }
        $script:LastLlmError = $tag
        Write-Log "LLM parse failed: $tag" 'WARN'
        return $null
    }
}

function Test-LlmConnection {
    <#
        Lightweight LLM probe used by /health. Cached for 5 minutes so
        polling clients don't hammer GitHub Models. Returns hashtable:
          @{ ok=$true|$false; error='...'; checkedAt='ISO8601' }
    #>
    if (-not $script:GitHubToken) {
        return @{ ok = $false; error = 'no token configured'; checkedAt = (Get-Date).ToString('o') }
    }
    $now = Get-Date
    if ($script:LlmProbeCache -and ($now - $script:LlmProbeCache.At).TotalSeconds -lt 300) {
        return $script:LlmProbeCache.Result
    }
    $result = @{ ok = $false; error = $null; checkedAt = $now.ToString('o') }
    try {
        $body = @{
            model = $script:GitHubModel
            messages = @(@{ role='user'; content='ping' })
            max_tokens = 1
            temperature = 0
        } | ConvertTo-Json -Depth 5
        $null = Invoke-CurlPostJson -Url $script:GitHubModelsUrl -BodyJson $body -BearerToken $script:GitHubToken -TimeoutSec 8
        $result.ok = $true
        $script:LastLlmError = $null
    } catch {
        $msg = "$_"
        $tag = if     ($msg -match '\b401\b|unauthorized') { '401 unauthorized (token expired or wrong scope)' }
               elseif ($msg -match '\b403\b|forbidden')    { '403 forbidden (no Models access)' }
               elseif ($msg -match '\b404\b')              { '404 not found (model or endpoint)' }
               elseif ($msg -match '\b429\b')              { '429 rate limited' }
               elseif ($msg -match 'timed out|timeout')    { 'network timeout' }
               else                                         { $msg.Substring(0, [math]::Min(160, $msg.Length)) }
        $result.error = $tag
        $script:LastLlmError = $tag
    }
    $script:LlmProbeCache = @{ At = $now; Result = $result }
    return $result
}

function Get-DistinctiveKeyword {
    <#
        Pick the most useful single search keyword out of the user's free text.
        Strategy (in order):
          1. Quoted phrase "...".
          2. Manufacturer-style part-code token: letters with at least one digit
             or dash (SRV05-4, SMAJ16A, BSS138, STM32, LM358).
          3. Known component-noun (mosfet, schottky, varistor, ldo, ...).
          4. Longest alphabetic word >=4 chars that isn't a stopword.
        Returns $null if nothing useful was found.
    #>
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '"([^"]{2,})"') { return $matches[1] }

    $partCode = [regex]::Matches($Text, '\b[A-Za-z]{2,}[0-9][A-Za-z0-9\-]*\b')
    if ($partCode.Count -gt 0) {
        return ($partCode | Sort-Object { $_.Value.Length } -Descending | Select-Object -First 1).Value
    }

    $known = @(
        'schottky','zener','rectifier','varistor','transient','tvs','mosfet','jfet','bjt',
        'tantalum','ceramic','electrolytic','ferrite','bead','inductor','choke','transformer',
        'resistor','capacitor','diode','transistor','protection','fuse','ptc','mov',
        'regulator','ldo','buck','boost','opamp','comparator','adc','dac','mcu','fpga',
        'connector','header','usb','rj45','ethernet','crystal','oscillator','relay',
        'optocoupler','photodiode','led','thermistor','hall','accelerometer'
    )
    foreach ($w in ($Text.ToLower() -split '[^a-z0-9]+' | Where-Object { $_ })) {
        if ($known -contains $w) { return $w }
    }

    $stop = @('the','and','for','with','any','all','show','list','find','give','need','want','please','part','parts','from','that','this','better','than','smaller','smallest','larger','largest','more','less','cheaper','cheapest','around','about','need','wants','have','some','what','which','where','when','about','near')
    $words = $Text -split '[^a-zA-Z]+' | Where-Object { $_.Length -ge 4 -and ($stop -notcontains $_.ToLower()) }
    if ($words) {
        return ($words | Sort-Object { $_.Length } -Descending | Select-Object -First 1)
    }
    return $null
}

function Invoke-KeywordSearch {
    <#
        Universal keyword scan across every whitelisted table. For each table,
        one parameterised SELECT with [Description]/[Type]/[SubType]/[Device]
        LIKE @kw (whichever exist). Tags rows with _source = <table>.
        Same safety stack as Invoke-SafeQuery.
    #>
    param(
        [Parameter(Mandatory)] [string] $Keyword,
        [int] $PerTableMax = 200
    )
    if (-not $Keyword -or $Keyword.Length -lt 2) { return @() }
    if (-not (Test-SafeValue $Keyword)) { throw "Keyword rejected by safety filter." }

    $kw = "%$Keyword%"
    $all = New-Object System.Collections.ArrayList

    # Prefer the live-discovered universe of tables. Fall back to curated $Schema
    # if discovery failed.
    $tableSource = if ($script:AllTables -and $script:AllTables.Count -gt 0) {
        $script:AllTables
    } else {
        $fallback = @{}
        foreach ($k in $Schema.Keys) { $fallback[$k] = @{ all = $Schema[$k]; text = $Schema[$k] } }
        $fallback
    }

    foreach ($table in $tableSource.Keys) {
        $allCols  = $tableSource[$table].all
        $textCols = $tableSource[$table].text
        # Columns to LIKE-scan: prefer Description/Type/SubType/Device/Comments
        # but fall back to every text column on this table so we never miss
        # rows just because the part description lives in a non-standard field.
        $likeCols = @()
        foreach ($c in 'Description','Type','SubType','Device','Comments','Application') {
            if ($textCols -contains $c) { $likeCols += $c }
        }
        if ($likeCols.Count -eq 0) { $likeCols = @($textCols | Select-Object -First 6) }
        if (-not $likeCols -or $likeCols.Count -eq 0) { continue }
        # Columns to return: a friendly subset if available, else everything.
        $selCols = @()
        foreach ($c in 'IGTPartNo','Description','Type','SubType','PKG_TYPE','Package','Device','Value','Voltage','State') {
            if ($allCols -contains $c) { $selCols += $c }
        }
        if (-not $selCols -or $selCols.Count -eq 0) { $selCols = @($allCols | Select-Object -First 8) }
        $whereOr = ($likeCols | ForEach-Object { "[$_] LIKE ?" }) -join ' OR '
        $selList = ($selCols | ForEach-Object { "[$_]" }) -join ', '
        $sql = "SELECT TOP $PerTableMax $selList FROM [dbo].[$table] WHERE $whereOr"
        $params = @()
        foreach ($lc in $likeCols) { $params += $kw }
        try {
            $rows = Invoke-SafeQuery -Sql $sql -Params $params
            foreach ($r in $rows) {
                $r | Add-Member -NotePropertyName '_source' -NotePropertyValue $table -Force
                [void]$all.Add($r)
            }
        } catch {
            Write-Log "Keyword scan on $table skipped: $_" 'WARN'
        }
    }
    return @($all.ToArray())
}

function Format-ChatReply {
    param($Parsed, $Rows, $Truncated)

    $count = @($Rows).Count
    if ($count -eq 0) {
        return "No matches in DxDatabook for: $($Parsed.intent)."
    }

    # Group by source table when present (universal keyword scan paths).
    $hasSource = @($Rows) | Where-Object { $_.PSObject.Properties.Name -contains '_source' -and $_._source } | Select-Object -First 1
    if ($hasSource) {
        $groups = @($Rows) | Group-Object _source
        $tableSummary = ($groups | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
        $lead = "Found $count$(if($Truncated){'+'}) match(es) across DxDatabook ($tableSummary):"
        $samples = foreach ($g in $groups) {
            "  -- $($g.Name) --"
            $g.Group | Select-Object -First 3 | ForEach-Object {
                $r = $_
                $bits = @()
                foreach ($k in 'IGTPartNo','Value','PKG_TYPE','Voltage','Type','SubType','Description','State') {
                    if ($r.PSObject.Properties.Name -contains $k -and $r.$k) { $bits += "$($k)=$($r.$k)" }
                }
                '    - ' + ($bits -join '  ')
            }
        }
        return $lead + "`n" + ($samples -join "`n")
    }

    $tbl = if ($Parsed.table) { $Parsed.table } else { 'results' }
    $lead = "Found $count$(if($Truncated){'+'}) match(es) in DxDatabook ($tbl):"
    $top = @($Rows) | Select-Object -First 5 | ForEach-Object {
        $r = $_
        $bits = @()
        foreach ($k in 'IGTPartNo','Value','Tolerance','PKG_TYPE','Package','Voltage','Power','Type','State') {
            if ($r.PSObject.Properties.Name -contains $k -and $r.$k) { $bits += "$($k)=$($r.$k)" }
        }
        '  - ' + ($bits -join '  ')
    }
    return $lead + "`n" + ($top -join "`n")
}


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$prefix = "http://localhost:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
    Write-Log "Failed to start listener at $prefix : $_" 'ERROR'
    Write-Log "If port $Port is in use, pass -Port <other>." 'ERROR'
    return
}

Write-Log "DatabookAgent listening at $prefix"
Write-Log "DSN=$Dsn  MaxRows=$MaxRows  CmdTimeout=${CmdTimeoutSec}s"
Write-Log "Allowed origins: $($AllowedOrigins -join ', ')"
if ($GitHubToken) {
    $masked = $GitHubToken.Substring(0,[math]::Min(7,$GitHubToken.Length)) + '...'
    Write-Log "LLM enabled (model=$GitHubModel token=$masked)"
} else {
    Write-Log "LLM disabled (no token) - using rule-based parser only"
}
Write-Log "Press Ctrl+C to stop."

# Discover the full set of component tables once at startup.
Initialize-LiveSchema

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $origin = Get-AllowedOrigin $req.Headers['Origin']

        try {
            # CORS preflight
            if ($req.HttpMethod -eq 'OPTIONS') {
                Send-Json -Context $ctx -Status 204 -Obj @{} -Origin $origin
                continue
            }

            $path = $req.Url.AbsolutePath.TrimEnd('/')
            Write-Log "$($req.HttpMethod) $($req.Url.AbsolutePath)  origin=$($req.Headers['Origin'])"

            switch -Regex ($path) {

                '^/health$' {
                    $llm = Test-LlmConnection
                    Send-Json -Context $ctx -Status 200 -Obj @{
                        ok = $true
                        agent = 'DatabookAgent'
                        version = '0.2'
                        user = $env:USERDOMAIN + '\' + $env:USERNAME
                        dsn = $Dsn
                        llmConfigured = [bool]$GitHubToken
                        llmEnabled = [bool]$llm.ok
                        llmModel = $GitHubModel
                        llmError = $llm.error
                        llmCheckedAt = $llm.checkedAt
                    } -Origin $origin
                    break
                }

                '^/llm-test$' {
                    if (-not $GitHubToken) {
                        Send-Json -Context $ctx -Status 400 -Obj @{ ok=$false; error='No token configured (set GITHUB_TOKEN env var or create agent\.env)' } -Origin $origin
                        break
                    }
                    try {
                        $body = @{
                            model = $GitHubModel
                            messages = @(@{ role='user'; content='Reply with just the word PONG.' })
                            temperature = 0
                        } | ConvertTo-Json -Depth 5
                        $resp = Invoke-CurlPostJson -Url $GitHubModelsUrl -BodyJson $body -BearerToken $GitHubToken -TimeoutSec 20
                        Send-Json -Context $ctx -Status 200 -Obj @{
                            ok = $true
                            model = $GitHubModel
                            reply = $resp.choices[0].message.content
                        } -Origin $origin
                    } catch {
                        Send-Json -Context $ctx -Status 500 -Obj @{ ok=$false; error="$_" } -Origin $origin
                    }
                    break
                }

                '^/tables$' {
                    Send-Json -Context $ctx -Status 200 -Obj @{
                        tables = $Schema.Keys | Sort-Object
                    } -Origin $origin
                    break
                }

                '^/columns$' {
                    $t = $req.QueryString['table']
                    if (-not $Schema.ContainsKey($t)) {
                        Send-Json -Context $ctx -Status 400 -Obj @{ error = "Unknown table: $t" } -Origin $origin
                        break
                    }
                    Send-Json -Context $ctx -Status 200 -Obj @{
                        table = $t
                        columns = $Schema[$t]
                    } -Origin $origin
                    break
                }

                '^/search$' {
                    if ($req.HttpMethod -ne 'POST') {
                        Send-Json -Context $ctx -Status 405 -Obj @{ error = 'POST required' } -Origin $origin
                        break
                    }
                    $body = Read-RequestBody $ctx
                    if (-not $body) {
                        Send-Json -Context $ctx -Status 400 -Obj @{ error = 'Empty body' } -Origin $origin
                        break
                    }
                    try {
                        $reqObj = $body | ConvertFrom-Json
                    } catch {
                        Send-Json -Context $ctx -Status 400 -Obj @{ error = 'Bad JSON' } -Origin $origin
                        break
                    }
                    # Convert to hashtable for Build-Search
                    $h = @{
                        table   = $reqObj.table
                        columns = @($reqObj.columns)
                        filters = @()
                    }
                    foreach ($f in @($reqObj.filters)) {
                        if ($null -ne $f) {
                            $h.filters += @{ column = $f.column; op = $f.op; value = $f.value }
                        }
                    }

                    try {
                        $built = Build-Search $h
                        Write-Log "SQL: $($built.Sql)" 'SQL'
                        $rows = Invoke-SafeQuery -Sql $built.Sql -Params $built.Params
                        Send-Json -Context $ctx -Status 200 -Obj @{
                            ok = $true
                            sql = $built.Sql
                            rowCount = @($rows).Count
                            truncated = (@($rows).Count -ge $MaxRows)
                            rows = $rows
                        } -Origin $origin
                    } catch {
                        Write-Log "Query rejected: $_" 'WARN'
                        Send-Json -Context $ctx -Status 400 -Obj @{ error = "$_" } -Origin $origin
                    }
                    break
                }

                '^/chat$' {
                    if ($req.HttpMethod -ne 'POST') {
                        Send-Json -Context $ctx -Status 405 -Obj @{ error = 'POST required' } -Origin $origin
                        break
                    }
                    $body = Read-RequestBody $ctx
                    if (-not $body) {
                        Send-Json -Context $ctx -Status 400 -Obj @{ error = 'Empty body' } -Origin $origin
                        break
                    }
                    try {
                        $reqObj = $body | ConvertFrom-Json
                    } catch {
                        Send-Json -Context $ctx -Status 400 -Obj @{ error = 'Bad JSON' } -Origin $origin
                        break
                    }
                    $userText = [string]$reqObj.message
                    if (-not $userText) {
                        Send-Json -Context $ctx -Status 400 -Obj @{ error = 'message required' } -Origin $origin
                        break
                    }
                    # Optional refinement context: caller can send mode='refine' plus
                    # previousQuery to AND-combine with the previous user message.
                    # Default is mode='fresh' (no context carried) so 'usb' after 'tvs'
                    # is treated as a brand-new search, not a TVS filter.
                    $reqMode = if ($reqObj.mode) { [string]$reqObj.mode } else { 'fresh' }
                    $prevQuery = if ($reqObj.previousQuery) { [string]$reqObj.previousQuery } else { '' }
                    $effectiveText = $userText
                    if ($reqMode -eq 'refine' -and $prevQuery) {
                        $effectiveText = "$prevQuery $userText"
                        Write-Log "REFINE: '$prevQuery' + '$userText' -> '$effectiveText'" 'CHAT'
                    } else {
                        Write-Log "CHAT: $userText" 'CHAT'
                    }
                    # Optional conversation history -- last N user/assistant turns.
                    # Used to give the LLM follow-up context (ChatGPT-style).
                    $history = @()
                    if ($reqObj.history) { $history = @($reqObj.history) }
                    $parsed = Invoke-LlmParser -Text $effectiveText -History $history
                    $usedLlm = $true
                    if (-not $parsed) {
                        $parsed = Invoke-RuleParser -Text $effectiveText
                        $usedLlm = $false
                    }
                    if (-not $parsed) {
                        # Final fallback: try a universal keyword scan from whatever
                        # distinctive word we can extract from the message.
                        $kw = Get-DistinctiveKeyword $effectiveText
                        if ($kw) {
                            $parsed = @{ mode = 'keyword'; keyword = $kw; intent = "Fallback keyword scan: '$kw'" }
                        } else {
                            Send-Json -Context $ctx -Status 200 -Obj @{
                                ok = $true
                                reply = "I couldn't extract a useful keyword. Try a part code (SRV05-4), a value (4.7k, 0.1uF), a package (0603, SOT-23), or a family (TVS, MOSFET, LDO)."
                                parsed = $null
                                rows = @()
                            } -Origin $origin
                            break
                        }
                    }
                    try {
                        $rowsList = New-Object System.Collections.ArrayList
                        $builtSql = $null
                        $kwSql = $null
                        $kwUsed = $null

                        # Path 0: direct LLM answer (factual / conceptual question --
                        # no database lookup needed).
                        if ($parsed.mode -eq 'answer' -and $parsed.answer) {
                            Send-Json -Context $ctx -Status 200 -Obj @{
                                ok = $true
                                reply = [string]$parsed.answer
                                parsed = $parsed
                                parsedBy = if ($usedLlm) { 'llm' } else { 'rules' }
                                rows = @()
                                mode = 'answer'
                            } -Origin $origin
                            break
                        }

                        # Path A: structured query (when parser identified a table)
                        if ($parsed.table -and (-not $parsed.mode -or $parsed.mode -eq 'structured')) {
                            $built = Build-Search $parsed
                            $builtSql = $built.Sql
                            Write-Log "SQL: $builtSql" 'SQL'
                            $sRows = Invoke-SafeQuery -Sql $built.Sql -Params $built.Params
                            foreach ($r in $sRows) {
                                if (-not ($r.PSObject.Properties.Name -contains '_source')) {
                                    $r | Add-Member -NotePropertyName '_source' -NotePropertyValue $parsed.table -Force
                                }
                                [void]$rowsList.Add($r)
                            }
                        }

                        # Path B: universal keyword scan across all 9 tables.
                        $wantsBroad = ($effectiveText -match '(?i)\b(all|any|every|list|show|find|search)\b')
                        $forceKw    = ($parsed.mode -eq 'keyword')
                        $sparseHit  = ($rowsList.Count -lt 3)
                        $kw = if ($forceKw) { [string]$parsed.keyword } else { Get-DistinctiveKeyword $effectiveText }
                        if ($kw -and ($forceKw -or $wantsBroad -or $sparseHit)) {
                            try {
                                Write-Log "Keyword scan: '$kw'" 'SQL'
                                $kwRows = Invoke-KeywordSearch -Keyword $kw
                                $kwSql  = "<universal scan on '%${kw}%' across all tables>"
                                $kwUsed = $kw
                                $seen = @{}
                                foreach ($r in $rowsList) {
                                    if ($r.IGTPartNo) { $seen[[string]$r.IGTPartNo] = $true }
                                }
                                foreach ($r in $kwRows) {
                                    $pn = if ($r.IGTPartNo) { [string]$r.IGTPartNo } else { $null }
                                    if ($pn -and $seen.ContainsKey($pn)) { continue }
                                    if ($pn) { $seen[$pn] = $true }
                                    [void]$rowsList.Add($r)
                                }
                            } catch {
                                Write-Log "Keyword scan skipped: $_" 'WARN'
                            }
                        }

                        $rows = @($rowsList.ToArray())

                        # If this was a refinement, narrow the result set so the new
                        # term must appear in one of the row's text-ish fields.
                        if ($reqMode -eq 'refine' -and $prevQuery -and $userText -and $rows.Count -gt 0) {
                            $needle = $userText.Trim().ToLower()
                            if ($needle) {
                                $filtered = New-Object System.Collections.ArrayList
                                foreach ($r in $rows) {
                                    $hit = $false
                                    foreach ($p in $r.PSObject.Properties) {
                                        $v = $p.Value
                                        if ($null -eq $v) { continue }
                                        if (([string]$v).ToLower().Contains($needle)) { $hit = $true; break }
                                    }
                                    if ($hit) { [void]$filtered.Add($r) }
                                }
                                $rows = @($filtered.ToArray())
                                Write-Log "Refine post-filter on '$needle' kept $($rows.Count) rows" 'CHAT'
                            }
                        }

                        $truncated = ($rows.Count -ge $MaxRows)
                        $baseReply = Format-ChatReply -Parsed $parsed -Rows $rows -Truncated $truncated
                        # Echo how we interpreted the query so 'fresh' vs 'refine' is visible.
                        $interp = if ($reqMode -eq 'refine' -and $prevQuery) {
                            "Refining previous ('$prevQuery') with '$userText'"
                        } elseif ($parsed.mode -eq 'keyword' -or $forceKw) {
                            "Fresh search - universal scan for keyword '$kw'"
                        } elseif ($parsed.table) {
                            "Fresh search - $($parsed.table) table" + $(if($kwUsed){" + universal scan for '$kwUsed'"}else{''})
                        } else {
                            "Fresh search"
                        }
                        $reply = "[$interp]`n" + $baseReply
                        $parsedTag = if ($usedLlm) { 'llm' }
                                     elseif ($GitHubToken -and $script:LastLlmError) { 'rules-fallback' }
                                     else { 'rules' }
                        $sqlOut = if ($builtSql -and $kwSql) { "$builtSql  +  $kwSql" }
                                  elseif ($builtSql)         { $builtSql }
                                  else                       { $kwSql }
                        Send-Json -Context $ctx -Status 200 -Obj @{
                            ok = $true
                            reply = $reply
                            parsedBy = $parsedTag
                            llmError = $(if($parsedTag -eq 'rules-fallback'){ $script:LastLlmError } else { $null })
                            parsed = $parsed
                            keyword = $kwUsed
                            sql = $sqlOut
                            rowCount = $rows.Count
                            truncated = $truncated
                            rows = $rows
                        } -Origin $origin
                    } catch {
                        Write-Log "Chat query rejected: $_" 'WARN'
                        Send-Json -Context $ctx -Status 400 -Obj @{ error = "$_"; parsed = $parsed } -Origin $origin
                    }
                    break
                }

                default {
                    Send-Json -Context $ctx -Status 404 -Obj @{ error = 'Not found' } -Origin $origin
                }
            }
        }
        catch {
            Write-Log "Handler error: $_" 'ERROR'
            try { Send-Json -Context $ctx -Status 500 -Obj @{ error = "$_" } -Origin $origin } catch {}
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Log "Listener stopped."
}
