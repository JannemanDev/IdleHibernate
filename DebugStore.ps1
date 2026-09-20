# SQLite debug sample store. Buffer in memory; flush on a timer and at shutdown.

$script:DebugDbPath = Join-Path $script:DataDir "debug.sqlite"
$script:SqliteDllPath = Join-Path $script:ScriptDir "lib\sqlite3.dll"
$script:DebugSampleBuffer = New-Object System.Collections.Generic.List[object]
$script:DebugDb = $null
$script:DebugDbLock = New-Object object
$script:SqliteLoaded = $false

if (-not ("IdleSqlite" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeLib {
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string lpFileName);
}

public sealed class IdleSqlite : IDisposable {
    const int SQLITE_OK = 0;
    const int SQLITE_ROW = 100;
    const int SQLITE_DONE = 101;
    const int SQLITE_OPEN_READWRITE = 2;
    const int SQLITE_OPEN_CREATE = 4;
    const int SQLITE_OPEN_FULLMUTEX = 0x00010000;
    static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_close_v2(IntPtr db);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, out IntPtr errMsg);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr tail);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_step(IntPtr stmt);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_reset(IntPtr stmt);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_null(IntPtr stmt, int i);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_int(IntPtr stmt, int i, int v);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_int64(IntPtr stmt, int i, long v);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_double(IntPtr stmt, int i, double v);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_text(IntPtr stmt, int i, byte[] v, int n, IntPtr dtor);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_column_int(IntPtr stmt, int i);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern long sqlite3_column_int64(IntPtr stmt, int i);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern double sqlite3_column_double(IntPtr stmt, int i);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_column_type(IntPtr stmt, int i);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_name(IntPtr stmt, int i);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
    static extern void sqlite3_free(IntPtr p);

    IntPtr db;

    static byte[] Utf8z(string s) {
        if (s == null) { s = ""; }
        byte[] bytes = Encoding.UTF8.GetBytes(s);
        byte[] z = new byte[bytes.Length + 1];
        Buffer.BlockCopy(bytes, 0, z, 0, bytes.Length);
        return z;
    }

    static string Utf8Ptr(IntPtr p) {
        if (p == IntPtr.Zero) { return null; }
        int len = 0;
        while (Marshal.ReadByte(p, len) != 0) { len++; }
        if (len == 0) { return ""; }
        byte[] buf = new byte[len];
        Marshal.Copy(p, buf, 0, len);
        return Encoding.UTF8.GetString(buf);
    }

    public static void LoadNative(string dllPath) {
        if (NativeLib.LoadLibrary(dllPath) == IntPtr.Zero) {
            throw new Exception("LoadLibrary sqlite3.dll failed");
        }
    }

    public IdleSqlite(string path) {
        int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
        int rc = sqlite3_open_v2(Utf8z(path), out db, flags, IntPtr.Zero);
        if (rc != SQLITE_OK) { throw new Exception("sqlite open failed: " + Err()); }
        Execute("PRAGMA journal_mode=WAL;");
        Execute("PRAGMA synchronous=NORMAL;");
    }

    string Err() {
        return Utf8Ptr(sqlite3_errmsg(db));
    }

    public void Execute(string sql) {
        IntPtr err;
        int rc = sqlite3_exec(db, Utf8z(sql), IntPtr.Zero, IntPtr.Zero, out err);
        if (rc != SQLITE_OK) {
            string msg = err != IntPtr.Zero ? Utf8Ptr(err) : Err();
            if (err != IntPtr.Zero) { sqlite3_free(err); }
            throw new Exception(msg);
        }
    }

    static void Bind(IntPtr stmt, int i, object v) {
        if (v == null || v is DBNull) { sqlite3_bind_null(stmt, i); return; }
        if (v is bool) { sqlite3_bind_int(stmt, i, ((bool)v) ? 1 : 0); return; }
        if (v is byte || v is short || v is int) { sqlite3_bind_int(stmt, i, Convert.ToInt32(v)); return; }
        if (v is long) { sqlite3_bind_int64(stmt, i, (long)v); return; }
        if (v is float || v is double || v is decimal) { sqlite3_bind_double(stmt, i, Convert.ToDouble(v)); return; }
        byte[] b = Encoding.UTF8.GetBytes(Convert.ToString(v));
        sqlite3_bind_text(stmt, i, b, b.Length, SQLITE_TRANSIENT);
    }

    static object Cell(IntPtr stmt, int i) {
        int t = sqlite3_column_type(stmt, i);
        if (t == 1) { return sqlite3_column_int64(stmt, i); }
        if (t == 2) { return sqlite3_column_double(stmt, i); }
        if (t == 5) { return null; }
        return Utf8Ptr(sqlite3_column_text(stmt, i));
    }

    public void InsertRows(string sql, IList rows) {
        IntPtr stmt;
        int rc = sqlite3_prepare_v2(db, Utf8z(sql), -1, out stmt, IntPtr.Zero);
        if (rc != SQLITE_OK) { throw new Exception(Err()); }
        try {
            Execute("BEGIN IMMEDIATE;");
            try {
                foreach (object rowObj in rows) {
                    IList row = rowObj as IList;
                    if (row == null) { continue; }
                    for (int i = 0; i < row.Count; i++) {
                        Bind(stmt, i + 1, row[i]);
                    }
                    rc = sqlite3_step(stmt);
                    if (rc != SQLITE_DONE) { throw new Exception(Err()); }
                    sqlite3_reset(stmt);
                }
                Execute("COMMIT;");
            }
            catch {
                try { Execute("ROLLBACK;"); } catch { }
                throw;
            }
        }
        finally {
            sqlite3_finalize(stmt);
        }
    }

    public List<Dictionary<string, object>> Query(string sql) {
        IntPtr stmt;
        int rc = sqlite3_prepare_v2(db, Utf8z(sql), -1, out stmt, IntPtr.Zero);
        if (rc != SQLITE_OK) { throw new Exception(Err()); }
        List<Dictionary<string, object>> list = new List<Dictionary<string, object>>();
        try {
            int n = 0;
            while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
                if (n == 0) { n = sqlite3_column_count(stmt); }
                Dictionary<string, object> row = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < n; i++) {
                    row[Utf8Ptr(sqlite3_column_name(stmt, i))] = Cell(stmt, i);
                }
                list.Add(row);
            }
            if (rc != SQLITE_DONE) { throw new Exception(Err()); }
        }
        finally {
            sqlite3_finalize(stmt);
        }
        return list;
    }

    public void Dispose() {
        if (db != IntPtr.Zero) {
            sqlite3_close_v2(db);
            db = IntPtr.Zero;
        }
    }
}
"@
}

function Convert-DebugBool($Value) {
    if ($null -eq $Value) { return 0 }
    if ([bool]$Value) { return 1 }
    return 0
}

function Convert-DebugNum($Value) {
    if ($null -eq $Value) { return $null }
    try { return [double]$Value } catch { return $null }
}

function Convert-DebugInt($Value) {
    if ($null -eq $Value) { return $null }
    try { return [int64]$Value } catch { return $null }
}

function Enter-DebugDbLock {
    [void][System.Threading.Monitor]::Enter($script:DebugDbLock)
}

function Exit-DebugDbLock {
    [System.Threading.Monitor]::Exit($script:DebugDbLock)
}

function Initialize-DebugStore {
    if ($script:DebugDb) { return }
    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
    if (-not $script:SqliteLoaded) {
        if (-not (Test-Path -LiteralPath $script:SqliteDllPath)) {
            throw "sqlite3.dll not found at $($script:SqliteDllPath)"
        }
        [IdleSqlite]::LoadNative($script:SqliteDllPath)
        $script:SqliteLoaded = $true
    }
    $script:DebugDb = New-Object IdleSqlite $script:DebugDbPath
    $script:DebugDb.Execute(@"
CREATE TABLE IF NOT EXISTS samples (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at TEXT NOT NULL,
  at_unix REAL NOT NULL,
  app_version TEXT,
  app_hash TEXT,
  chosen_name TEXT,
  idle_seconds INTEGER,
  idle_ms INTEGER,
  idle_hit INTEGER,
  paused INTEGER,
  power_required INTEGER,
  power_met INTEGER,
  ac_met INTEGER,
  network_required INTEGER,
  network_met INTEGER,
  quiet_required INTEGER,
  quiet_met INTEGER,
  cpu_percent REAL,
  disk_percent REAL,
  net_kbps REAL,
  cpu_limit REAL,
  disk_limit REAL,
  net_limit_kbps REAL,
  check_cpu INTEGER,
  check_disk INTEGER,
  check_net INTEGER,
  quiet_ratio REAL,
  quiet_min_ratio REAL,
  quiet_window_sec INTEGER,
  quiet_window_need INTEGER,
  quiet_window_met INTEGER,
  quiet_window_full INTEGER,
  quiet_busy_now INTEGER,
  action TEXT,
  will_proceed INTEGER,
  connected TEXT,
  payload TEXT
);
CREATE INDEX IF NOT EXISTS idx_samples_at_unix ON samples(at_unix);
"@)
    foreach ($old in @($script:DebugStatusPath, $script:DebugStatusJsonPath)) {
        if ($old -and (Test-Path -LiteralPath $old)) {
            try { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Convert-EvaluationToSampleRow($Evaluation) {
    $at = [string]$Evaluation.at
    $unix = 0.0
    try { $unix = [datetimeoffset]::Parse($at).ToUnixTimeMilliseconds() / 1000.0 } catch {
        $unix = [datetimeoffset]::Now.ToUnixTimeMilliseconds() / 1000.0
    }
    $chosen = $null
    if ($script:state) { $chosen = [string]$script:state.chosenName }
    $connected = @($Evaluation.connected) -join ", "
    $payload = $null
    try { $payload = ($Evaluation | ConvertTo-Json -Compress -Depth 8) } catch { }
    $row = New-Object System.Collections.Generic.List[object]
    foreach ($v in @(
        $at,
        $unix,
        [string]$Evaluation.appVersion,
        [string]$Evaluation.appHash,
        $chosen,
        (Convert-DebugInt $Evaluation.idleSeconds),
        (Convert-DebugInt $Evaluation.idleMs),
        (Convert-DebugBool $Evaluation.idleHit),
        (Convert-DebugBool $Evaluation.paused),
        (Convert-DebugBool $Evaluation.powerRequired),
        (Convert-DebugBool $Evaluation.powerMet),
        (Convert-DebugBool $Evaluation.acMet),
        (Convert-DebugBool $Evaluation.networkRequired),
        (Convert-DebugBool $Evaluation.networkMet),
        (Convert-DebugBool $Evaluation.quietRequired),
        (Convert-DebugBool $Evaluation.quietMet),
        (Convert-DebugNum $Evaluation.cpuPercent),
        (Convert-DebugNum $Evaluation.diskPercent),
        (Convert-DebugNum $Evaluation.netKBps),
        (Convert-DebugNum $Evaluation.cpuLimit),
        (Convert-DebugNum $Evaluation.diskLimit),
        (Convert-DebugNum $Evaluation.netLimitKBps),
        (Convert-DebugBool $Evaluation.checkCpu),
        (Convert-DebugBool $Evaluation.checkDisk),
        (Convert-DebugBool $Evaluation.checkNet),
        (Convert-DebugNum $Evaluation.quietRatio),
        (Convert-DebugNum $Evaluation.quietMinRatio),
        (Convert-DebugInt $Evaluation.quietWindowSec),
        (Convert-DebugInt $Evaluation.quietWindowNeed),
        (Convert-DebugBool $Evaluation.quietWindowMet),
        (Convert-DebugBool $Evaluation.quietWindowFull),
        (Convert-DebugBool $Evaluation.quietBusyNow),
        [string]$Evaluation.action,
        (Convert-DebugBool ($Evaluation.willProceed -or $Evaluation.willHibernate)),
        $connected,
        $payload
    )) { [void]$row.Add($v) }
    return $row
}

function Add-DebugSample {
    param($Evaluation)
    if (-not $Evaluation) { return }
    Enter-DebugDbLock
    try {
        [void]$script:DebugSampleBuffer.Add($Evaluation)
    }
    finally { Exit-DebugDbLock }
}

function Save-DebugSampleBuffer {
    param($Settings)
    $rows = @()
    Enter-DebugDbLock
    try {
        if ($script:DebugSampleBuffer.Count -eq 0 -and -not $script:DebugDb) { return }
        $rows = @($script:DebugSampleBuffer.ToArray())
        $script:DebugSampleBuffer.Clear()
    }
    finally { Exit-DebugDbLock }
    try {
        Initialize-DebugStore
        $insertSql = @"
INSERT INTO samples (
  at, at_unix, app_version, app_hash, chosen_name,
  idle_seconds, idle_ms, idle_hit, paused,
  power_required, power_met, ac_met,
  network_required, network_met,
  quiet_required, quiet_met,
  cpu_percent, disk_percent, net_kbps,
  cpu_limit, disk_limit, net_limit_kbps,
  check_cpu, check_disk, check_net,
  quiet_ratio, quiet_min_ratio,
  quiet_window_sec, quiet_window_need,
  quiet_window_met, quiet_window_full, quiet_busy_now,
  action, will_proceed, connected, payload
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
"@
        $bindRows = New-Object System.Collections.Generic.List[object]
        foreach ($item in $rows) {
            [void]$bindRows.Add((Convert-EvaluationToSampleRow $item))
        }
        $hours = Get-DebugRetentionHours -Settings $Settings
        $cutoff = [datetimeoffset]::UtcNow.AddHours(-$hours).ToUnixTimeMilliseconds() / 1000.0
        $del = "DELETE FROM samples WHERE at_unix < " + $cutoff.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        Enter-DebugDbLock
        try {
            if ($bindRows.Count -gt 0) {
                $script:DebugDb.InsertRows($insertSql, $bindRows)
            }
            $script:DebugDb.Execute($del)
        }
        finally { Exit-DebugDbLock }
    }
    catch {
        Enter-DebugDbLock
        try {
            $i = 0
            foreach ($item in $rows) {
                $script:DebugSampleBuffer.Insert($i, $item)
                $i++
            }
        }
        finally { Exit-DebugDbLock }
    }
}

function Get-DebugSamples {
    param(
        [double]$Hours = 1,
        [int]$Limit = 2000
    )
    if ($Hours -lt 0.05) { $Hours = 0.05 }
    if ($Hours -gt 168) { $Hours = 168 }
    if ($Limit -lt 1) { $Limit = 1 }
    if ($Limit -gt 20000) { $Limit = 20000 }
    try { Initialize-DebugStore } catch { return @() }
    $cutoff = [datetimeoffset]::UtcNow.AddHours(-$Hours).ToUnixTimeMilliseconds() / 1000.0
    $sql = @"
SELECT at, at_unix, app_version, app_hash, chosen_name,
       idle_seconds, idle_ms, idle_hit, paused,
       power_required, power_met, ac_met,
       network_required, network_met,
       quiet_required, quiet_met,
       cpu_percent, disk_percent, net_kbps,
       cpu_limit, disk_limit, net_limit_kbps,
       check_cpu, check_disk, check_net,
       quiet_ratio, quiet_min_ratio,
       quiet_window_sec, quiet_window_need,
       quiet_window_met, quiet_window_full, quiet_busy_now,
       action, will_proceed, connected
FROM samples
WHERE at_unix >= $($cutoff.ToString([System.Globalization.CultureInfo]::InvariantCulture))
ORDER BY at_unix ASC
LIMIT $Limit
"@
    Enter-DebugDbLock
    try {
        return @($script:DebugDb.Query($sql))
    }
    finally { Exit-DebugDbLock }
}

function Get-DebugSampleSummary {
    param([double]$Hours = 1)
    $rows = @(Get-DebugSamples -Hours $Hours -Limit 20000)
    $n = $rows.Count
    $proceed = 0
    $idleHit = 0
    $quietMet = 0
    $paused = 0
    foreach ($row in $rows) {
        if ([int]$row.will_proceed -ne 0) { $proceed++ }
        if ([int]$row.idle_hit -ne 0) { $idleHit++ }
        if ([int]$row.quiet_met -ne 0) { $quietMet++ }
        if ([int]$row.paused -ne 0) { $paused++ }
    }
    $last = $null
    if ($n -gt 0) { $last = $rows[$n - 1] }
    return [pscustomobject]@{
        count     = $n
        proceed   = $proceed
        idleHit   = $idleHit
        quietMet  = $quietMet
        paused    = $paused
        last      = $last
        hours     = $Hours
        dbPath    = $script:DebugDbPath
        buffered  = $script:DebugSampleBuffer.Count
    }
}

function Clear-DebugSamples {
    Enter-DebugDbLock
    try { $script:DebugSampleBuffer.Clear() }
    finally { Exit-DebugDbLock }
    try { Initialize-DebugStore } catch { return }
    Enter-DebugDbLock
    try { $script:DebugDb.Execute("DELETE FROM samples;") }
    finally { Exit-DebugDbLock }
}

function Close-DebugStore {
    param($Settings)
    try { Save-DebugSampleBuffer -Settings $Settings } catch { }
    Enter-DebugDbLock
    try {
        if ($script:DebugDb) {
            try { $script:DebugDb.Dispose() } catch { }
            $script:DebugDb = $null
        }
    }
    finally { Exit-DebugDbLock }
}
