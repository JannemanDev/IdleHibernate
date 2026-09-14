# Shared Home/Work SSID checks. ASCII-only. Dot-source from the tray.

$script:NetworkProfileMap = [ordered]@{
    Home = @("DeluxeRouter0")
    Work = @("FontysWPA", "Eduroam")
}

if (-not ("PowerStateNative" -as [type])) {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct SystemPowerStatus {
    public byte ACLineStatus;
    public byte BatteryFlag;
    public byte BatteryLifePercent;
    public byte SystemStatusFlag;
    public int BatteryLifeTime;
    public int BatteryFullLifeTime;
}
public static class PowerStateNative {
    [DllImport("powrprof.dll", SetLastError = true)]
    public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemPowerStatus(out SystemPowerStatus lpSystemPowerStatus);
}
"@
}

function Get-NormalizedAction {
    param($Settings)
    $action = [string]$Settings.action
    if ($action.ToLowerInvariant() -eq "sleep") { return "sleep" }
    return "hibernate"
}

function Get-ActionLabel {
    param($Action)
    if (([string]$Action).ToLowerInvariant() -eq "sleep") { return "Sleep" }
    return "Hibernate"
}

function Invoke-IdlePowerAction {
    param($Action)
    $name = Get-NormalizedAction -Settings ([pscustomobject]@{ action = $Action })
    if ($name -eq "sleep") {
        [void][PowerStateNative]::SetSuspendState($false, $true, $false)
    }
    else {
        shutdown.exe /h
    }
}

$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir -and $MyInvocation.MyCommand.Path) {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-IdleSecondsFromSettings {
    param($Settings)
    $sec = 0
    if ($null -ne $Settings.idleSeconds) {
        $sec = [int]$Settings.idleSeconds
    }
    elseif ($null -ne $Settings.idleMinutes) {
        $sec = [int]$Settings.idleMinutes * 60
    }
    else {
        $sec = 600
    }
    if ($sec -lt 10) { $sec = 10 }
    if ($sec -gt 14400) { $sec = 14400 }
    return $sec
}

function Format-IdleDuration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "$Seconds sec" }
    if (($Seconds % 60) -eq 0) { return "$([int]($Seconds / 60)) min" }
    $m = [int][math]::Floor($Seconds / 60)
    $s = $Seconds % 60
    return "$m min $s sec"
}

function Get-IdlePresets {
    $default = @(
        [pscustomobject]@{ label = "10 sec"; seconds = 10 },
        [pscustomobject]@{ label = "1 min"; seconds = 60 },
        [pscustomobject]@{ label = "5 min"; seconds = 300 },
        [pscustomobject]@{ label = "10 min"; seconds = 600 },
        [pscustomobject]@{ label = "15 min"; seconds = 900 },
        [pscustomobject]@{ label = "30 min"; seconds = 1800 },
        [pscustomobject]@{ label = "60 min"; seconds = 3600 }
    )
    $path = Join-Path $script:ScriptDir "idle-presets.json"
    if (-not (Test-Path -LiteralPath $path)) { return $default }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($p in @($doc.presets)) {
            $sec = [int]$p.seconds
            if ($sec -lt 10 -or $sec -gt 14400) { continue }
            $label = [string]$p.label
            if (-not $label) { $label = Format-IdleDuration -Seconds $sec }
            [void]$list.Add([pscustomobject]@{ label = $label; seconds = $sec })
        }
        if ($list.Count -gt 0) { return @($list) }
    }
    catch { }
    return $default
}

$script:QuietConfig = $null
$script:CpuCounter = $null
$script:DiskCounter = $null
$script:NetCounters = $null
$script:LastCpu = $null
$script:LastDisk = $null
$script:LastNetKBps = $null
$script:QuietSamples = New-Object System.Collections.Generic.List[object]
$script:LastQuietSampleUtc = [datetime]::MinValue
$script:LastSampleStampUtc = $null
$script:ConsecutiveQuietSec = 0.0
$script:LastIdleResetReason = $null

function Get-QuietConfig {
    if ($null -ne $script:QuietConfig) { return $script:QuietConfig }
    $cfg = [pscustomobject]@{
        cpuBusyPercent  = 20.0
        diskBusyPercent = 20.0
        netBusyKBps     = 50.0
        minQuietRatio   = 0.9
        checkCpu        = $true
        checkDisk       = $true
        checkNet        = $true
    }
    $path = Join-Path $script:ScriptDir "quiet.json"
    if (Test-Path -LiteralPath $path) {
        try {
            $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $doc.cpuBusyPercent) { $cfg.cpuBusyPercent = [double]$doc.cpuBusyPercent }
            if ($null -ne $doc.diskBusyPercent) { $cfg.diskBusyPercent = [double]$doc.diskBusyPercent }
            if ($null -ne $doc.netBusyKBps) { $cfg.netBusyKBps = [double]$doc.netBusyKBps }
            if ($null -ne $doc.minQuietRatio) { $cfg.minQuietRatio = [double]$doc.minQuietRatio }
            if ($null -ne $doc.checkCpu) { $cfg.checkCpu = [bool]$doc.checkCpu }
            if ($null -ne $doc.checkDisk) { $cfg.checkDisk = [bool]$doc.checkDisk }
            if ($null -ne $doc.checkNet) { $cfg.checkNet = [bool]$doc.checkNet }
        }
        catch { }
    }
    $script:QuietConfig = $cfg
    return $cfg
}

function Save-QuietConfig {
    $cfg = Get-QuietConfig
    $payload = @{
        cpuBusyPercent  = [int][math]::Round([double]$cfg.cpuBusyPercent, 0)
        diskBusyPercent = [int][math]::Round([double]$cfg.diskBusyPercent, 0)
        netBusyKBps     = [int][math]::Round([double]$cfg.netBusyKBps, 0)
        minQuietRatio   = [double]$cfg.minQuietRatio
        checkCpu        = [bool]$cfg.checkCpu
        checkDisk       = [bool]$cfg.checkDisk
        checkNet        = [bool]$cfg.checkNet
    } | ConvertTo-Json
    $path = Join-Path $script:ScriptDir "quiet.json"
    Set-Content -LiteralPath $path -Value $payload -Encoding UTF8
}

function Set-QuietBusyLimit {
    param(
        [ValidateSet("cpu", "disk", "net")]
        [string]$Kind,
        [int]$Delta
    )
    $cfg = Get-QuietConfig
    if ($Kind -eq "cpu") {
        $cfg.cpuBusyPercent = [math]::Min(90, [math]::Max(5, [int]$cfg.cpuBusyPercent + $Delta))
    }
    elseif ($Kind -eq "disk") {
        $cfg.diskBusyPercent = [math]::Min(90, [math]::Max(5, [int]$cfg.diskBusyPercent + $Delta))
    }
    else {
        $cfg.netBusyKBps = [math]::Min(2000, [math]::Max(5, [int]$cfg.netBusyKBps + $Delta))
    }
    $script:QuietConfig = $cfg
    Save-QuietConfig
}

function Set-QuietCheckEnabled {
    param(
        [ValidateSet("cpu", "disk", "net")]
        [string]$Kind,
        [bool]$Enabled
    )
    $cfg = Get-QuietConfig
    if ($Kind -eq "cpu") { $cfg.checkCpu = $Enabled }
    elseif ($Kind -eq "disk") { $cfg.checkDisk = $Enabled }
    else { $cfg.checkNet = $Enabled }
    $script:QuietConfig = $cfg
    Save-QuietConfig
}

function Test-AnyQuietMetricEnabled {
    $cfg = Get-QuietConfig
    return ([bool]$cfg.checkCpu -or [bool]$cfg.checkDisk -or [bool]$cfg.checkNet)
}

function Format-KBpsValue([double]$Value) {
    return ([int][math]::Round($Value, 0)).ToString()
}

function Get-IdleResetReason {
    return $script:LastIdleResetReason
}

function Initialize-QuietCounters {
    if ($null -ne $script:CpuCounter) { return }
    try {
        $script:CpuCounter = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
        $script:DiskCounter = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk", "% Disk Time", "_Total")
        [void]$script:CpuCounter.NextValue()
        [void]$script:DiskCounter.NextValue()
    }
    catch {
        $script:CpuCounter = $false
        $script:DiskCounter = $false
    }
    $script:NetCounters = New-Object System.Collections.Generic.List[System.Diagnostics.PerformanceCounter]
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory("Network Interface")
        foreach ($name in $cat.GetInstanceNames()) {
            if ($name -match "Loopback|isatap|Teredo|VPN") { continue }
            $counter = New-Object System.Diagnostics.PerformanceCounter("Network Interface", "Bytes Total/sec", $name)
            [void]$counter.NextValue()
            [void]$script:NetCounters.Add($counter)
        }
    }
    catch {
        $script:NetCounters = $false
    }
}

function Get-CurrentBusyPercents {
    Initialize-QuietCounters
    $cpu = $null
    $disk = $null
    $net = $null
    if ($script:CpuCounter -and $script:CpuCounter -ne $false) {
        try {
            $cpu = [double]$script:CpuCounter.NextValue()
            $disk = [double]$script:DiskCounter.NextValue()
        }
        catch { }
    }
    if ($script:NetCounters -and $script:NetCounters -ne $false -and $script:NetCounters.Count -gt 0) {
        try {
            $bytes = 0.0
            foreach ($counter in $script:NetCounters) {
                $bytes += [double]$counter.NextValue()
            }
            $net = $bytes / 1024.0
        }
        catch { }
    }
    if ($null -eq $cpu) {
        try {
            $cpuObj = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
            $diskObj = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
            $cpu = [double]$cpuObj.PercentProcessorTime
            $disk = [double]$diskObj.PercentDiskTime
        }
        catch {
            $cpu = 0.0
            $disk = 0.0
        }
    }
    if ($null -eq $net) {
        try {
            $sum = 0.0
            Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop | ForEach-Object {
                if ($_.Name -notmatch "Loopback|isatap|Teredo") {
                    $sum += [double]$_.BytesTotalPersec
                }
            }
            $net = $sum / 1024.0
        }
        catch {
            $net = 0.0
        }
    }
    if ($cpu -lt 0) { $cpu = 0 }
    if ($cpu -gt 100) { $cpu = 100 }
    if ($disk -lt 0) { $disk = 0 }
    if ($disk -gt 100) { $disk = 100 }
    if ($net -lt 0) { $net = 0 }
    return [pscustomobject]@{ Cpu = $cpu; Disk = $disk; NetKBps = $net }
}

function Get-QuietStatus {
    param([int]$WindowSeconds = 10)
    $cfg = Get-QuietConfig
    $count = $script:QuietSamples.Count
    $quietN = @($script:QuietSamples | Where-Object { $_.Quiet }).Count
    $ratio = 0.0
    if ($count -gt 0) { $ratio = $quietN / $count }
    $minSamples = 4
    $windowMet = ($count -ge $minSamples) -and ($ratio -ge [double]$cfg.minQuietRatio)
    $waiting = $null
    $anyCheck = [bool]$cfg.checkCpu -or [bool]$cfg.checkDisk -or [bool]$cfg.checkNet
    if ($anyCheck) {
        if ([bool]$cfg.checkCpu -and $null -ne $script:LastCpu -and $script:LastCpu -ge $cfg.cpuBusyPercent) { $waiting = "CPU" }
        elseif ([bool]$cfg.checkDisk -and $null -ne $script:LastDisk -and $script:LastDisk -ge $cfg.diskBusyPercent) { $waiting = "disk" }
        elseif ([bool]$cfg.checkNet -and $null -ne $script:LastNetKBps -and $script:LastNetKBps -ge $cfg.netBusyKBps) { $waiting = "net" }
        elseif (-not $windowMet) { $waiting = "quiet" }
    }
    if (-not $anyCheck) { $windowMet = $true }
    return [pscustomobject]@{
        cpu                 = $script:LastCpu
        disk                = $script:LastDisk
        netKBps             = $script:LastNetKBps
        cpuLimit            = [double]$cfg.cpuBusyPercent
        diskLimit           = [double]$cfg.diskBusyPercent
        netLimitKBps        = [double]$cfg.netBusyKBps
        checkCpu            = [bool]$cfg.checkCpu
        checkDisk           = [bool]$cfg.checkDisk
        checkNet            = [bool]$cfg.checkNet
        ratio               = $ratio
        minRatio            = [double]$cfg.minQuietRatio
        sampleCount         = $count
        windowMet           = $windowMet
        consecutiveQuietSec = [int][math]::Floor($script:ConsecutiveQuietSec)
        waiting             = $waiting
    }
}

function Update-QuietSample {
    param(
        [int]$WindowSeconds = 10,
        [bool]$InputIsIdle = $true
    )
    $now = [datetime]::UtcNow
    if ($script:LastQuietSampleUtc -ne [datetime]::MinValue -and ($now - $script:LastQuietSampleUtc).TotalMilliseconds -lt 350) {
        return Get-QuietStatus -WindowSeconds $WindowSeconds
    }
    $cfg = Get-QuietConfig
    $busy = Get-CurrentBusyPercents
    $script:LastCpu = $busy.Cpu
    $script:LastDisk = $busy.Disk
    $script:LastNetKBps = $busy.NetKBps
    $cpuBusy = [bool]$cfg.checkCpu -and ($busy.Cpu -ge [double]$cfg.cpuBusyPercent)
    $diskBusy = [bool]$cfg.checkDisk -and ($busy.Disk -ge [double]$cfg.diskBusyPercent)
    $netBusy = [bool]$cfg.checkNet -and ($busy.NetKBps -ge [double]$cfg.netBusyKBps)
    $anyCheck = [bool]$cfg.checkCpu -or [bool]$cfg.checkDisk -or [bool]$cfg.checkNet
    $sampleQuiet = -not $anyCheck -or (-not $cpuBusy -and -not $diskBusy -and -not $netBusy)
    $script:LastQuietSampleUtc = $now
    $cpuTxt = [int][math]::Round($busy.Cpu, 0)
    $diskTxt = [int][math]::Round($busy.Disk, 0)
    $netTxt = Format-KBpsValue $busy.NetKBps
    $cpuLim = [int][math]::Round([double]$cfg.cpuBusyPercent, 0)
    $diskLim = [int][math]::Round([double]$cfg.diskBusyPercent, 0)
    $netLim = [int][math]::Round([double]$cfg.netBusyKBps, 0)
    if (-not $InputIsIdle) {
        $script:LastIdleResetReason = "keyboard/mouse"
        $script:QuietSamples.Clear()
        $script:ConsecutiveQuietSec = 0.0
        $script:LastSampleStampUtc = $now
        return Get-QuietStatus -WindowSeconds $WindowSeconds
    }
    if (-not $sampleQuiet) {
        if ($cpuBusy) {
            $script:LastIdleResetReason = "CPU $cpuTxt% > $cpuLim%"
        }
        elseif ($diskBusy) {
            $script:LastIdleResetReason = "disk $diskTxt% > $diskLim%"
        }
        else {
            $script:LastIdleResetReason = "net $netTxt KB/s > $netLim KB/s"
        }
    }
    $intervalSec = 0.5
    if ($null -ne $script:LastSampleStampUtc) {
        $intervalSec = [math]::Min(2.0, [math]::Max(0.3, ($now - $script:LastSampleStampUtc).TotalSeconds))
    }
    $script:LastSampleStampUtc = $now
    [void]$script:QuietSamples.Add([pscustomobject]@{
        Utc   = $now
        Cpu   = $busy.Cpu
        Disk  = $busy.Disk
        Quiet = $sampleQuiet
    })
    if ($sampleQuiet) { $script:ConsecutiveQuietSec += $intervalSec }
    else { $script:ConsecutiveQuietSec = 0.0 }
    $cut = $now.AddSeconds(-[math]::Max(5, $WindowSeconds))
    while ($script:QuietSamples.Count -gt 0 -and $script:QuietSamples[0].Utc -lt $cut) {
        $script:QuietSamples.RemoveAt(0)
    }
    return Get-QuietStatus -WindowSeconds $WindowSeconds
}

function Convert-ToStringArray {
    param($Value)
    if ($null -eq $Value -or $Value -eq "") { return @() }
    if ($Value -is [string]) { return @($Value) }
    return @($Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function Get-ConnectedNetworkNames {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        $lines = @(netsh wlan show interfaces 2>$null)
        foreach ($line in $lines) {
            if ($line -match '^\s+SSID\s+:\s+(.+)$') {
                $ssid = $Matches[1].Trim()
                if ($ssid) { [void]$names.Add($ssid) }
            }
            elseif ($line -match '^\s+Profile\s+:\s+(.+)$') {
                $profile = $Matches[1].Trim()
                if ($profile) { [void]$names.Add($profile) }
            }
        }
    }
    catch { }
    try {
        Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name) { [void]$names.Add([string]$_.Name) }
        }
    }
    catch { }
    return @($names | Select-Object -Unique)
}

function Test-NameInList {
    param(
        [string]$Name,
        [string[]]$List
    )
    foreach ($item in $List) {
        if ([string]::Equals($Name, $item, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-ProfileConnected {
    param(
        [string]$ProfileName,
        [string[]]$ConnectedNames
    )
    $ssids = @($script:NetworkProfileMap[$ProfileName])
    if ($ssids.Count -eq 0) { return $false }
    foreach ($ssid in $ssids) {
        if (Test-NameInList -Name $ssid -List $ConnectedNames) {
            return $true
        }
    }
    return $false
}

function Get-SelectedPowerSources {
    param($Settings)
    if ($null -ne $Settings.powerSources) {
        $raw = @(Convert-ToStringArray $Settings.powerSources)
        return @($raw | Where-Object { $_ -eq "AC" -or $_ -eq "DC" })
    }
    if ([bool]$Settings.requireAc) { return @("AC") }
    return @()
}

function Test-PowerAllowed {
    param(
        $Settings,
        [bool]$OnAc
    )
    $selected = @(Get-SelectedPowerSources -Settings $Settings)
    if ($selected.Count -eq 0) { return $true }
    if ($OnAc) { return ($selected -contains "AC") }
    return ($selected -contains "DC")
}

function Get-SelectedNetworkProfiles {
    param($Settings)
    $selected = Convert-ToStringArray $Settings.networkProfiles
    return @($selected | Where-Object { $script:NetworkProfileMap.Keys -contains $_ })
}

function Test-SelectedNetworksAllowed {
    param($Settings)
    $selected = Get-SelectedNetworkProfiles -Settings $Settings
    if ($selected.Count -eq 0) { return $true }
    $connected = Get-ConnectedNetworkNames
    foreach ($profile in $selected) {
        if (Test-ProfileConnected -ProfileName $profile -ConnectedNames $connected) {
            return $true
        }
    }
    return $false
}

function Get-NetworkConditionLabels {
    param($Settings)
    $selected = Get-SelectedNetworkProfiles -Settings $Settings
    $labels = New-Object System.Collections.Generic.List[string]
    if ($selected.Count -eq 0) { return @() }
    $connected = Get-ConnectedNetworkNames
    foreach ($profile in $selected) {
        if (Test-ProfileConnected -ProfileName $profile -ConnectedNames $connected) {
            [void]$labels.Add("$profile yes")
        }
        else {
            [void]$labels.Add("$profile no")
        }
    }
    return @($labels)
}

$script:DataDir = "C:\Users\Jan\AppData\Local\IdleHibernate"
$script:HistoryPath = Join-Path $script:DataDir "history.json"
$script:DebugPath = Join-Path $script:DataDir "debug-last.json"

function Test-OnAc {
    try {
        $rows = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop)
        if ($rows.Count -gt 0) {
            $charging = $false
            $discharging = $false
            $online = $false
            $offline = $false
            foreach ($row in $rows) {
                if ([bool]$row.Charging) { $charging = $true }
                if ([bool]$row.Discharging) { $discharging = $true }
                if ([bool]$row.PowerOnline) { $online = $true } else { $offline = $true }
            }
            if ($discharging -and -not $charging) { return $false }
            if ($charging -and -not $discharging) { return $true }
            if ($online -and -not $offline) { return $true }
            if ($offline -and -not $online) { return $false }
        }
    }
    catch { }

    $acLine = 255
    $batteryFlag = 0
    try {
        $status = New-Object SystemPowerStatus
        if ([PowerStateNative]::GetSystemPowerStatus([ref]$status)) {
            $acLine = [int]$status.ACLineStatus
            $batteryFlag = [int]$status.BatteryFlag
        }
    }
    catch { }
    if (($batteryFlag -band 8) -eq 8) { return $true }
    if ($acLine -eq 0) { return $false }
    if ($acLine -eq 1) { return $true }
    if (($batteryFlag -band 128) -eq 128) { return $true }

    try {
        $batt = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        if ($batt.Count -eq 0) { return $true }
        foreach ($b in $batt) {
            $st = [int]$b.BatteryStatus
            if ($st -ge 6 -and $st -le 9) { return $true }
            if ($st -in 4, 5) { return $false }
        }
    }
    catch { }
    return ($acLine -ne 0)
}

function Get-MatchedNetworkProfiles {
    param([string[]]$ConnectedNames)
    $matched = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:NetworkProfileMap.Keys) {
        if (Test-ProfileConnected -ProfileName $name -ConnectedNames $ConnectedNames) {
            [void]$matched.Add($name)
        }
    }
    return @($matched)
}

function Convert-ToObjectArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        $Value
    )
    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
    ($Value | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-HistoryProfileLabel {
    param($Settings, [string[]]$ConnectedNames)
    $selected = Get-SelectedNetworkProfiles -Settings $Settings
    $matched = Get-MatchedNetworkProfiles -ConnectedNames $ConnectedNames
    if ($selected.Count -gt 0) {
        $hit = @($selected | Where-Object { $matched -contains $_ })
        if ($hit.Count -gt 0) { return ($hit -join ", ") }
        return "no matching profile"
    }
    if ($matched.Count -gt 0) { return ($matched -join ", ") }
    if ($ConnectedNames.Count -gt 0) { return $ConnectedNames[0] }
    return "no profile"
}

function Get-IdleEvaluation {
    param(
        $Settings,
        [bool]$Paused,
        $IdleMs,
        [bool]$OnAc
    )
    $needSec = Get-IdleSecondsFromSettings -Settings $Settings
    $needMs = [int64]$needSec * 1000
    $idleHit = ($null -ne $IdleMs -and [int64]$IdleMs -ge $needMs)
    $inputIsIdle = ($null -ne $IdleMs -and [int64]$IdleMs -ge 400)
    $quiet = Update-QuietSample -WindowSeconds $needSec -InputIsIdle $inputIsIdle
    $quietRequired = $true
    if ($null -ne $Settings.requireQuiet) { $quietRequired = [bool]$Settings.requireQuiet }
    if (-not (Test-AnyQuietMetricEnabled)) { $quietRequired = $false }
    $quietMet = (-not $quietRequired) -or [bool]$quiet.windowMet
    $connected = @(Get-ConnectedNetworkNames)
    $selected = @(Get-SelectedNetworkProfiles -Settings $Settings)
    $matched = @(Get-MatchedNetworkProfiles -ConnectedNames $connected)
    $networkRequired = $selected.Count -gt 0
    $networkMet = $true
    if ($networkRequired) {
        $networkMet = $false
        foreach ($profile in $selected) {
            if ($matched -contains $profile) { $networkMet = $true; break }
        }
    }
    $powerSources = @(Get-SelectedPowerSources -Settings $Settings)
    $powerRequired = $powerSources.Count -gt 0
    $powerMet = Test-PowerAllowed -Settings $Settings -OnAc $OnAc
    $acRequired = $powerRequired -and ($powerSources.Count -eq 1) -and ($powerSources -contains "AC")
    $action = Get-NormalizedAction -Settings $Settings
    $willProceed = (-not $Paused) -and $idleHit -and $powerMet -and $networkMet -and $quietMet
    return [pscustomobject]@{
        at               = [datetimeoffset]::Now.ToString("o")
        idleSeconds      = $needSec
        idleMinutes      = [math]::Max(1, [int][math]::Ceiling($needSec / 60.0))
        idleLabel        = Format-IdleDuration -Seconds $needSec
        idleMs           = $IdleMs
        idleHit          = $idleHit
        paused           = $Paused
        powerSources     = @($powerSources)
        powerRequired    = $powerRequired
        powerMet         = $powerMet
        acRequired       = $acRequired
        acMet            = $OnAc
        networkRequired  = $networkRequired
        networkMet       = $networkMet
        quietRequired    = $quietRequired
        quietMet         = $quietMet
        cpuPercent       = $quiet.cpu
        diskPercent      = $quiet.disk
        netKBps          = $quiet.netKBps
        cpuLimit         = $quiet.cpuLimit
        diskLimit        = $quiet.diskLimit
        netLimitKBps     = $quiet.netLimitKBps
        checkCpu         = $quiet.checkCpu
        checkDisk        = $quiet.checkDisk
        checkNet         = $quiet.checkNet
        quietRatio       = $quiet.ratio
        quietMinRatio    = $quiet.minRatio
        quietWaiting     = $quiet.waiting
        selectedProfiles = @($selected)
        matchedProfiles  = @($matched)
        connected        = @($connected)
        action           = $action
        willProceed      = $willProceed
        willHibernate    = $willProceed
        historyProfile   = Get-HistoryProfileLabel -Settings $Settings -ConnectedNames $connected
    }
}

function Get-IdleDebugLog {
    $doc = Read-JsonFile -Path $script:DebugPath
    if (-not $doc) { return @() }
    if ($doc.items) { return @(Convert-ToObjectArray $doc.items) }
    if ($doc.at) { return @($doc) }
    return @()
}

function Save-IdleDebug {
    param($Evaluation)
    try {
        $items = @(Get-IdleDebugLog)
        $items = @($Evaluation) + $items
        if ($items.Count -gt 5) { $items = $items[0..4] }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $items) {
            [void]$parts.Add(($item | ConvertTo-Json -Compress -Depth 8))
        }
        $json = '{ "items": [' + ($parts -join ',') + '] }'
        if (-not (Test-Path -LiteralPath $script:DataDir)) {
            New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:DebugPath -Value $json -Encoding UTF8
    }
    catch { }
}

function Add-HibernateHistory {
    param($Evaluation)
    try {
        $doc = Read-JsonFile -Path $script:HistoryPath
        $items = @()
        if ($doc -and $doc.items) { $items = @(Convert-ToObjectArray $doc.items) }
        $entry = [pscustomobject]@{
            at        = $Evaluation.at
            profile   = $Evaluation.historyProfile
            action    = Get-ActionLabel -Action $Evaluation.action
            connected = @($Evaluation.connected)
        }
        $items = @($entry) + $items
        if ($items.Count -gt 5) { $items = $items[0..4] }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $items) {
            [void]$parts.Add(($item | ConvertTo-Json -Compress -Depth 8))
        }
        $json = '{ "items": [' + ($parts -join ',') + '] }'
        if (-not (Test-Path -LiteralPath $script:DataDir)) {
            New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:HistoryPath -Value $json -Encoding UTF8
    }
    catch { }
}

function Get-HibernateHistory {
    $doc = Read-JsonFile -Path $script:HistoryPath
    if (-not $doc) { return @() }
    return @(Convert-ToObjectArray $doc.items)
}

function Clear-HibernateHistory {
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) {
            New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:HistoryPath -Value '{ "items": [] }' -Encoding UTF8
    }
    catch { }
}

function Clear-IdleDebugLog {
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) {
            New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:DebugPath -Value '{ "items": [] }' -Encoding UTF8
    }
    catch { }
}

function Format-LocalWhen {
    param($Value, [string]$Pattern = "dd-MM HH:mm")
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        if ($Value -is [datetimeoffset]) {
            return $Value.ToLocalTime().DateTime.ToString($Pattern, $culture)
        }
        if ($Value -is [datetime]) {
            $dt = [datetime]$Value
            if ($dt.Kind -eq [System.DateTimeKind]::Utc) { $dt = $dt.ToLocalTime() }
            return $dt.ToString($Pattern, $culture)
        }
        return [datetimeoffset]::Parse([string]$Value).ToLocalTime().DateTime.ToString($Pattern, $culture)
    }
    catch {
        return [string]$Value
    }
}

function Format-HistoryItem {
    param($Entry)
    if (-not $Entry) { return "-" }
    $when = Format-LocalWhen -Value $Entry.at -Pattern "dd-MM HH:mm:ss"
    $profile = [string]$Entry.profile
    if (-not $profile) { $profile = "no profile" }
    $action = Get-ActionLabel -Action $Entry.action
    return "$when  $action  $profile"
}

function Format-MetLabel {
    param([bool]$Met)
    if ($Met) { return "MET" }
    return "NOT MET"
}

function Format-DebugText {
    param($Evaluation)
    if (-not $Evaluation) {
        return "Idle timer has not been reached yet."
    }
    $when = Format-LocalWhen -Value $Evaluation.at -Pattern "dd-MM-yyyy HH:mm:ss"
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Idle timer hit: $when")
    if ($Evaluation.willProceed -or $Evaluation.willHibernate) {
        [void]$lines.Add("Result: $(Get-ActionLabel -Action $Evaluation.action)")
    }
    else {
        [void]$lines.Add("Result: blocked")
    }
    [void]$lines.Add("")
    $actual = "?"
    if ($null -ne $Evaluation.idleMs) {
        $actualSec = ([double]$Evaluation.idleMs) / 1000.0
        if ($actualSec -lt 90) {
            $actual = ([math]::Round($actualSec, 1)).ToString() + " sec"
        }
        else {
            $actual = ([math]::Round($actualSec / 60.0, 1)).ToString() + " min"
        }
    }
    $idleLabel = [string]$Evaluation.idleLabel
    if (-not $idleLabel) { $idleLabel = Format-IdleDuration -Seconds (Get-IdleSecondsFromSettings -Settings $Evaluation) }
    [void]$lines.Add("Idle timer ($idleLabel): $(Format-MetLabel ([bool]$Evaluation.idleHit)) (actual $actual)")
    if ($Evaluation.paused) {
        [void]$lines.Add("Paused: NOT MET (actual on)")
    }
    else {
        [void]$lines.Add("Paused: MET (actual off)")
    }
    $actualPower = "?"
    if ($null -ne $Evaluation.acMet) {
        if ([bool]$Evaluation.acMet) { $actualPower = "AC" } else { $actualPower = "DC" }
    }
    if ($null -ne $Evaluation.powerRequired -or $null -ne $Evaluation.powerSources) {
        $powerSources = @(Convert-ToStringArray $Evaluation.powerSources)
        if (-not [bool]$Evaluation.powerRequired -and $powerSources.Count -eq 0) {
            [void]$lines.Add("Power: not required (actual $actualPower)")
        }
        else {
            if ($powerSources -contains "AC") {
                [void]$lines.Add("Power AC: $(Format-MetLabel ([bool]$Evaluation.acMet)) (actual $actualPower)")
            }
            if ($powerSources -contains "DC") {
                [void]$lines.Add("Power DC: $(Format-MetLabel (-not [bool]$Evaluation.acMet)) (actual $actualPower)")
            }
        }
    }
    elseif ($Evaluation.acRequired) {
        [void]$lines.Add("AC power: required, $(Format-MetLabel ([bool]$Evaluation.acMet)) (actual $actualPower)")
    }
    else {
        [void]$lines.Add("Power: not required (actual $actualPower)")
    }
    if ($Evaluation.quietRequired) {
        [void]$lines.Add("Quiet PC: required, $(Format-MetLabel ([bool]$Evaluation.quietMet))")
        if ($Evaluation.checkCpu) {
            $cpu = "?"
            if ($null -ne $Evaluation.cpuPercent) { $cpu = [math]::Round([double]$Evaluation.cpuPercent, 0).ToString() + "%" }
            [void]$lines.Add("  CPU: actual $cpu (limit $($Evaluation.cpuLimit)%)")
        }
        else {
            [void]$lines.Add("  CPU: not checked")
        }
        if ($Evaluation.checkDisk) {
            $disk = "?"
            if ($null -ne $Evaluation.diskPercent) { $disk = [math]::Round([double]$Evaluation.diskPercent, 0).ToString() + "%" }
            [void]$lines.Add("  Disk: actual $disk (limit $($Evaluation.diskLimit)%)")
        }
        else {
            [void]$lines.Add("  Disk: not checked")
        }
        if ($Evaluation.checkNet) {
            $net = "?"
            if ($null -ne $Evaluation.netKBps) { $net = (Format-KBpsValue ([double]$Evaluation.netKBps)) + " KB/s" }
            [void]$lines.Add("  Net: actual $net (limit $($Evaluation.netLimitKBps) KB/s)")
        }
        else {
            [void]$lines.Add("  Net: not checked")
        }
        $ratio = "?"
        if ($null -ne $Evaluation.quietRatio) { $ratio = [math]::Round(100.0 * [double]$Evaluation.quietRatio, 0).ToString() + "%" }
        [void]$lines.Add("  Quiet samples $ratio")
    }
    else {
        [void]$lines.Add("Quiet PC: not required")
    }
    $selected = @(Convert-ToStringArray $Evaluation.selectedProfiles)
    $matched = @(Convert-ToStringArray $Evaluation.matchedProfiles)
    $connected = @(Convert-ToStringArray $Evaluation.connected)
    $actualNet = "none"
    if ($connected.Count -gt 0) { $actualNet = ($connected -join ", ") }
    if ($selected.Count -eq 0) {
        [void]$lines.Add("Network: not required (actual $actualNet)")
    }
    else {
        foreach ($profile in $selected) {
            $ssids = @($script:NetworkProfileMap[$profile]) -join " or "
            [void]$lines.Add("Network $profile ($ssids): $(Format-MetLabel ($matched -contains $profile)) (actual $actualNet)")
        }
    }
    return ($lines -join [Environment]::NewLine)
}
