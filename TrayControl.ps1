# IdleHibernate tray helper: start | restart | stop | status
# ASCII-only. Run via Tray.cmd or: powershell -File TrayControl.ps1 <command>

param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "restart", "stop", "status")]
    [string]$Command = "status"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$startVbs = Join-Path $scriptDir "StartTray.vbs"
$logDir = Join-Path $env:LOCALAPPDATA "IdleHibernate"
$logFile = Join-Path $logDir "start-tray.log"
$statusFile = Join-Path $logDir "start-status.txt"

function Get-TrayProcesses {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^(powershell|pwsh)\.exe$' -and
            $_.CommandLine -and
            ($_.CommandLine -like '*IdleHibernateTray.ps1*')
        }
}

function Write-HelperLog([string]$Message) {
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "  TrayControl: " + $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Show-LogPath {
    Write-Host "Log file: $logFile"
}

function Stop-Tray {
    $procs = @(Get-TrayProcesses)
    if ($procs.Count -eq 0) {
        Write-Host "Tray is not running."
        Write-HelperLog "stop: not running"
        return 0
    }
    foreach ($p in $procs) {
        Write-Host "Stopping PID $($p.ProcessId)..."
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    $left = @(Get-TrayProcesses)
    if ($left.Count -gt 0) {
        Write-Host "Failed to stop all tray processes."
        Write-HelperLog "stop: failed, still running"
        Show-LogPath
        return 1
    }
    Write-Host "Tray stopped."
    Write-HelperLog "stop: ok"
    Show-LogPath
    return 0
}

function Start-Tray {
    if (-not (Test-Path -LiteralPath $startVbs)) {
        Write-Host "StartTray.vbs not found: $startVbs"
        return 1
    }
    $existing = @(Get-TrayProcesses)
    if ($existing.Count -gt 0) {
        Write-Host "Tray is already running (PID $($existing[0].ProcessId))."
        Write-HelperLog "start: already running PID $($existing[0].ProcessId)"
        Show-LogPath
        return 0
    }
    if (Test-Path -LiteralPath $statusFile) {
        Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Starting tray..."
    Write-HelperLog "start: launching StartTray.vbs silent"
    Start-Process -FilePath "wscript.exe" -ArgumentList @("`"$startVbs`"", "silent") -WorkingDirectory $scriptDir
    $deadline = (Get-Date).AddSeconds(15)
    $status = ""
    do {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $statusFile) {
            try { $status = (Get-Content -LiteralPath $statusFile -TotalCount 1 -ErrorAction SilentlyContinue).Trim().ToLowerInvariant() } catch { $status = "" }
        }
        if ($status -eq "started" -or $status -eq "already" -or $status.StartsWith("error:")) { break }
        $running = @(Get-TrayProcesses)
        if ($running.Count -gt 0 -and ((Get-Date) -gt $deadline.AddSeconds(-12))) {
            # process up; wait a bit more for ready status
        }
        if ($running.Count -eq 0 -and ((Get-Date) -gt $deadline.AddSeconds(-12)) -and -not $status) {
            # still launching
        }
    } while ((Get-Date) -lt $deadline)

    $running = @(Get-TrayProcesses)
    if ($status -eq "started" -or ($running.Count -gt 0 -and -not $status.StartsWith("error:"))) {
        $pidInfo = if ($running.Count -gt 0) { " (PID $($running[0].ProcessId))" } else { "" }
        Write-Host "Tray started$pidInfo."
        Write-HelperLog "start: ok$status$pidInfo"
        Show-LogPath
        return 0
    }
    if ($status -eq "already") {
        Write-Host "Tray is already running."
        Write-HelperLog "start: already (status file)"
        Show-LogPath
        return 0
    }
    if ($status.StartsWith("error:")) {
        Write-Host "Tray failed to start: $($status.Substring(6))"
    }
    else {
        Write-Host "Tray failed to start."
    }
    Write-HelperLog "start: failed status=$status"
    Show-LogPath
    return 1
}

switch ($Command) {
    "status" {
        $procs = @(Get-TrayProcesses)
        if ($procs.Count -eq 0) {
            Write-Host "Tray is not running."
            Write-HelperLog "status: not running"
            Show-LogPath
            exit 1
        }
        foreach ($p in $procs) {
            Write-Host "Tray is running (PID $($p.ProcessId))."
        }
        Write-HelperLog "status: running count=$($procs.Count)"
        Show-LogPath
        exit 0
    }
    "stop" {
        exit (Stop-Tray)
    }
    "start" {
        exit (Start-Tray)
    }
    "restart" {
        Write-HelperLog "restart: begin"
        [void](Stop-Tray)
        Start-Sleep -Seconds 1
        exit (Start-Tray)
    }
}
