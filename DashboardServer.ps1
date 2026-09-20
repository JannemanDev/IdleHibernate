# Localhost dashboard for debug samples in SQLite.

$script:DashboardPort = 27182
$script:DashboardUrl = "http://127.0.0.1:$($script:DashboardPort)/"
$script:DashboardRoot = Join-Path $script:ScriptDir "dashboard"
$script:DashboardListener = $null
$script:DashboardRunspace = $null
$script:DashboardPower = $null
$script:DashboardHandle = $null
$script:DashboardLive = [hashtable]::Synchronized(@{
    debugMode = $false
})

function Update-DashboardLiveStatus {
    if (-not $script:DashboardLive) { return }
    $on = $false
    if ($script:state) { $on = [bool]$script:state.debugMode }
    $script:DashboardLive["debugMode"] = $on
}

function Get-DashboardMime([string]$Path) {
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        ".html" { return "text/html; charset=utf-8" }
        ".css"  { return "text/css; charset=utf-8" }
        ".js"   { return "application/javascript; charset=utf-8" }
        ".svg"  { return "image/svg+xml" }
        ".json" { return "application/json; charset=utf-8" }
        default { return "application/octet-stream" }
    }
}

function Start-DebugDashboard {
    try { Save-DebugSampleBuffer -Settings $script:state } catch { }
    Update-DashboardLiveStatus
    if ($script:DashboardListener -and $script:DashboardListener.IsListening) { return $script:DashboardUrl }
    try { Initialize-DebugStore } catch { }
    $prefix = $script:DashboardUrl
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    $script:DashboardListener = $listener
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Listener, $Root, $DbPath, $DllPath, $Live)
        if (-not ("IdleSqlite" -as [type])) { return }
        $db = $null
        try {
            if ($DllPath -and (Test-Path -LiteralPath $DllPath)) {
                try { [IdleSqlite]::LoadNative($DllPath) } catch { }
            }
            $db = New-Object IdleSqlite $DbPath
        }
        catch { }
        function Send-DashResponse($Response, [int]$Status, [string]$Type, [byte[]]$Bytes) {
            $Response.StatusCode = $Status
            $Response.ContentType = $Type
            $Response.Headers["Cache-Control"] = "no-store"
            $Response.ContentLength64 = $Bytes.Length
            $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
            $Response.OutputStream.Close()
        }
        function Get-DashHours($Query) {
            $hours = 1.0
            if ($Query["hours"]) {
                try { $hours = [double]$Query["hours"] } catch { $hours = 1.0 }
            }
            if ($hours -lt 0.05) { $hours = 0.05 }
            if ($hours -gt 168) { $hours = 168 }
            return $hours
        }
        while ($Listener.IsListening) {
            $ctx = $null
            try { $ctx = $Listener.GetContext() }
            catch { break }
            if (-not $ctx) { break }
            $req = $ctx.Request
            $res = $ctx.Response
            try {
                $path = [string]$req.Url.AbsolutePath
                if (-not $path -or $path -eq "/") { $path = "/index.html" }
                if ($path -eq "/api/status") {
                    $on = $false
                    if ($Live) { $on = [bool]$Live["debugMode"] }
                    $json = (@{ debugMode = $on; dbPath = [string]$DbPath } | ConvertTo-Json -Compress)
                    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
                    Send-DashResponse $res 200 "application/json; charset=utf-8" $bytes
                    continue
                }
                if ($path -eq "/api/samples") {
                    $hours = Get-DashHours $req.QueryString
                    $limit = 2000
                    if ($req.QueryString["limit"]) {
                        try { $limit = [int]$req.QueryString["limit"] } catch { $limit = 2000 }
                    }
                    if ($limit -lt 1) { $limit = 1 }
                    if ($limit -gt 20000) { $limit = 20000 }
                    $cutoff = [datetimeoffset]::UtcNow.AddHours(-$hours).ToUnixTimeMilliseconds() / 1000.0
                    $sql = "SELECT at, at_unix, app_version, app_hash, chosen_name, idle_seconds, idle_ms, idle_hit, paused, power_required, power_met, ac_met, network_required, network_met, quiet_required, quiet_met, cpu_percent, disk_percent, net_kbps, cpu_limit, disk_limit, net_limit_kbps, check_cpu, check_disk, check_net, quiet_ratio, quiet_min_ratio, quiet_window_sec, quiet_window_need, quiet_window_met, quiet_window_full, quiet_busy_now, action, will_proceed, connected FROM samples WHERE at_unix >= " + $cutoff.ToString([System.Globalization.CultureInfo]::InvariantCulture) + " ORDER BY at_unix ASC LIMIT " + $limit
                    $rows = @()
                    if ($db) { $rows = @($db.Query($sql)) }
                    $json = $rows | ConvertTo-Json -Compress -Depth 6
                    if (-not $json) { $json = "[]" }
                    if ($rows.Count -eq 1 -and $json.StartsWith("{")) { $json = "[$json]" }
                    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
                    Send-DashResponse $res 200 "application/json; charset=utf-8" $bytes
                    continue
                }
                if ($path -eq "/api/summary") {
                    $hours = Get-DashHours $req.QueryString
                    $cutoff = [datetimeoffset]::UtcNow.AddHours(-$hours).ToUnixTimeMilliseconds() / 1000.0
                    $sql = "SELECT COUNT(*) AS count, SUM(will_proceed) AS proceed, SUM(idle_hit) AS idleHit, SUM(quiet_met) AS quietMet, SUM(paused) AS paused FROM samples WHERE at_unix >= " + $cutoff.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                    $row = $null
                    if ($db) {
                        $found = @($db.Query($sql))
                        if ($found.Count -gt 0) { $row = $found[0] }
                    }
                    $summary = [pscustomobject]@{
                        count    = 0
                        proceed  = 0
                        idleHit  = 0
                        quietMet = 0
                        paused   = 0
                        hours    = $hours
                        dbPath   = $DbPath
                    }
                    if ($row) {
                        if ($null -ne $row.count) { $summary.count = [int64]$row.count }
                        if ($null -ne $row.proceed) { $summary.proceed = [int64]$row.proceed }
                        if ($null -ne $row.idleHit) { $summary.idleHit = [int64]$row.idleHit }
                        if ($null -ne $row.quietMet) { $summary.quietMet = [int64]$row.quietMet }
                        if ($null -ne $row.paused) { $summary.paused = [int64]$row.paused }
                    }
                    $json = $summary | ConvertTo-Json -Compress -Depth 4
                    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
                    Send-DashResponse $res 200 "application/json; charset=utf-8" $bytes
                    continue
                }
                $safe = $path.TrimStart("/").Replace("/", [IO.Path]::DirectorySeparatorChar)
                if ($safe.Contains("..")) {
                    Send-DashResponse $res 400 "text/plain; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes("bad path"))
                    continue
                }
                $file = Join-Path $Root $safe
                if (-not (Test-Path -LiteralPath $file)) {
                    Send-DashResponse $res 404 "text/plain; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes("not found"))
                    continue
                }
                $bytes = [IO.File]::ReadAllBytes($file)
                $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
                $type = "application/octet-stream"
                if ($ext -eq ".html") { $type = "text/html; charset=utf-8" }
                elseif ($ext -eq ".css") { $type = "text/css; charset=utf-8" }
                elseif ($ext -eq ".js") { $type = "application/javascript; charset=utf-8" }
                elseif ($ext -eq ".json") { $type = "application/json; charset=utf-8" }
                Send-DashResponse $res 200 $type $bytes
            }
            catch {
                try {
                    $msg = [Text.Encoding]::UTF8.GetBytes([string]$_)
                    Send-DashResponse $res 500 "text/plain; charset=utf-8" $msg
                }
                catch { }
            }
        }
        if ($db) { try { $db.Dispose() } catch { } }
    }).AddArgument($listener).AddArgument($script:DashboardRoot).AddArgument($script:DebugDbPath).AddArgument($script:SqliteDllPath).AddArgument($script:DashboardLive)
    $script:DashboardRunspace = $rs
    $script:DashboardPower = $ps
    $script:DashboardHandle = $ps.BeginInvoke()
    return $script:DashboardUrl
}

function Stop-DebugDashboard {
    try {
        if ($script:DashboardListener) {
            $script:DashboardListener.Stop()
            $script:DashboardListener.Close()
        }
    }
    catch { }
    $script:DashboardListener = $null
    try {
        if ($script:DashboardPower) {
            $script:DashboardPower.Dispose()
        }
    }
    catch { }
    $script:DashboardPower = $null
    $script:DashboardHandle = $null
    try {
        if ($script:DashboardRunspace) {
            $script:DashboardRunspace.Close()
            $script:DashboardRunspace.Dispose()
        }
    }
    catch { }
    $script:DashboardRunspace = $null
}

function Show-DebugDashboard {
    $url = Start-DebugDashboard
    Start-Process $url
}
