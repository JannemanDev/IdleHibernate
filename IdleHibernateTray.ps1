# Tray toggle for idle hibernate. Pause is a flag file; timer/AC/network are settings.json.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class UserIdle {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint GetIdleMs() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(info);
        GetLastInputInfo(ref info);
        return unchecked((uint)Environment.TickCount - info.dwTime);
    }
}
public static class TrayNative {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

function Write-TrayCrash($Obj) {
    try {
        $dir = Join-Path $env:LOCALAPPDATA "IdleHibernate"
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $text = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + " " + ([string]$Obj)
        try {
            if ($Obj -and $Obj.Exception) { $text = $text + [Environment]::NewLine + $Obj.Exception.ToString() }
        }
        catch { }
        Add-Content -LiteralPath (Join-Path $dir "crash.log") -Value $text -Encoding UTF8
    }
    catch { }
}

try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
}
catch { }
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-TrayCrash $e
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    Write-TrayCrash $e.ExceptionObject
})

. (Join-Path $PSScriptRoot "Common.ps1")

$mutex = New-Object System.Threading.Mutex($false, "Local\IdleHibernateTray")
$owned = $false
try {
    $owned = $mutex.WaitOne(0, $false)
}
catch [System.Threading.AbandonedMutexException] {
    $owned = $true
}
if (-not $owned) { exit 0 }

$script:flagDir = Join-Path $env:LOCALAPPDATA "IdleHibernate"
$script:flagPath = Join-Path $script:flagDir "paused"
$script:AppVersion = "1.1.1"
$script:keepMenuOpen = $false
$script:PadWide = [string][char]0x00A0
$script:PadThin = [string][char]0x2009
$script:padProbe = $null
$script:padTargets = @{}
$script:padCache = @{}
$script:idleActionArmed = $false
$script:debugSavedThisIdle = $false
$script:uiReady = $false
$script:SourceFileNames = @("Common.ps1", "IdleHibernateTray.ps1", "StartTray.vbs")

$script:state = [ordered]@{
    idleSeconds      = 600
    requireQuiet     = $true
    debugMode        = $false
    debugRetentionHours = 1
    language         = "en"
    powerSources     = @()
    networkProfiles  = @()
    action           = "hibernate"
}

function Test-Paused {
    return (Test-Path -LiteralPath $script:flagPath)
}

function Set-Paused([bool]$paused) {
    if (-not (Test-Path -LiteralPath $script:flagDir)) {
        New-Item -ItemType Directory -Path $script:flagDir -Force | Out-Null
    }
    if ($paused) {
        Set-Content -LiteralPath $script:flagPath -Value "paused" -Encoding ASCII
    }
    else {
        Remove-Item -LiteralPath $script:flagPath -Force -ErrorAction SilentlyContinue
    }
}

function Read-Settings {
    $s = $null
    try { $s = Read-AppSettingsFile } catch { }
    if ($s) {
        $choice = Get-ChosenSettings -Settings $s
        $script:state.idleSeconds = Get-IdleSecondsFromSettings -Settings $choice
        if ($null -ne $choice.requireQuiet) { $script:state.requireQuiet = [bool]$choice.requireQuiet }
        if ($null -ne $choice.debugMode) { $script:state.debugMode = [bool]$choice.debugMode }
        $script:state.debugRetentionHours = Get-DebugRetentionHours -Settings $choice
        $script:state.language = Get-UiLanguageCode -Settings $choice
        $script:UiLanguage = $script:state.language
        $script:state.powerSources = @(Get-SelectedPowerSources -Settings $choice)
        $script:state.networkProfiles = @(Convert-ToStringArray $choice.networkProfiles)
        $script:state.action = Get-NormalizedAction -Settings $choice
    }
    $script:state.idleSeconds = Get-IdleSecondsFromSettings -Settings $script:state
}

function Save-Settings {
    Write-AppSettingsFile -State $script:state
}

function Get-AppSourceHash {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($name in ($script:SourceFileNames | Sort-Object)) {
            $path = Join-Path $PSScriptRoot $name
            if (-not (Test-Path -LiteralPath $path)) { return $null }
            $label = [System.Text.Encoding]::UTF8.GetBytes($name + "`n")
            $bytes = [System.IO.File]::ReadAllBytes($path)
            [void]$sha.TransformBlock($label, 0, $label.Length, $null, 0)
            if ($bytes.Length -gt 0) {
                [void]$sha.TransformBlock($bytes, 0, $bytes.Length, $null, 0)
            }
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Update-AppInfoDisplay {
    if ($script:versionItem) {
        $script:versionItem.Text = Get-UiText Version $script:AppVersion
    }
    if ($script:hashItem) {
        $hash = Get-AppSourceHash
        if ($hash) {
            $short = $hash.Substring(0, [math]::Min(7, $hash.Length))
            $script:hashItem.Text = Get-UiText SourceHash $short
        }
        else {
            $script:hashItem.Text = Get-UiText SourceHashUnavailable
        }
    }
}

function Get-TooltipText {
    $lines = New-Object System.Collections.Generic.List[string]
    $idle = Format-IdleDuration -Seconds (Get-IdleSecondsFromSettings -Settings $script:state)
    $action = Get-ActionLabel -Action $script:state.action
    if (Test-Paused) {
        [void]$lines.Add("$(Get-UiText StatusPaused) | $idle | $action")
    }
    else {
        [void]$lines.Add("$(Get-UiText StatusOn) | $idle | $action")
    }
    $conds = New-Object System.Collections.Generic.List[string]
    $power = @(Get-SelectedPowerSources -Settings $script:state)
    if ($power.Count -gt 0) {
        $onAc = Test-OnAc
        if ($power -contains "AC") {
            if ($onAc) { [void]$conds.Add("$(Get-PowerSourceLabel 'AC') $(Get-UiText Yes)") } else { [void]$conds.Add("$(Get-PowerSourceLabel 'AC') $(Get-UiText No)") }
        }
        if ($power -contains "DC") {
            if (-not $onAc) { [void]$conds.Add("$(Get-PowerSourceLabel 'DC') $(Get-UiText Yes)") } else { [void]$conds.Add("$(Get-PowerSourceLabel 'DC') $(Get-UiText No)") }
        }
    }
    if ([bool]$script:state.requireQuiet) {
        $q = Get-QuietStatus
        if ($q.windowMet) { [void]$conds.Add("$(Get-UiText QuietPc) $(Get-UiText Yes)") } else { [void]$conds.Add("$(Get-UiText QuietPc) $(Get-UiText No)") }
    }
    foreach ($label in (Get-NetworkConditionLabels -Settings $script:state)) {
        [void]$conds.Add($label)
    }
    if ($conds.Count -gt 0) {
        [void]$lines.Add(($conds -join " | "))
    }
    $text = $lines -join [Environment]::NewLine
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    return $text
}

function New-StatusIcon([System.Drawing.Color]$color, [bool]$paused) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    if ($paused) {
        $g.FillRectangle($brush, 3, 2, 4, 12)
        $g.FillRectangle($brush, 9, 2, 4, 12)
    }
    else {
        $g.FillEllipse($brush, 1, 1, 14, 14)
    }
    $icon = ([System.Drawing.Icon]::FromHandle($bmp.GetHicon())).Clone()
    $brush.Dispose()
    $g.Dispose()
    $bmp.Dispose()
    return $icon
}

$script:iconOn = New-StatusIcon ([System.Drawing.Color]::FromArgb(46, 204, 64)) $false
$script:iconOff = New-StatusIcon ([System.Drawing.Color]::FromArgb(255, 170, 0)) $true
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = $script:iconOn
$script:notify.Visible = $false

function Update-Tray {
    if (-not $script:pauseItem) { return }
    try {
    if (Test-Paused) {
        $script:notify.Icon = $script:iconOff
        $script:pauseItem.Text = Get-UiText ResumeIdle
    }
    else {
        $script:notify.Icon = $script:iconOn
        $script:pauseItem.Text = Get-UiText PauseIdle
    }
    $script:quietItem.Checked = [bool]$script:state.requireQuiet
    if ($script:debugModeItem) {
        $script:debugModeItem.Checked = [bool]$script:state.debugMode
        $script:debugMenu.Checked = [bool]$script:state.debugMode
    }
    $power = @($script:state.powerSources)
    $script:powerAcItem.Checked = ($power -contains "AC")
    $script:powerDcItem.Checked = ($power -contains "DC")
    $script:powerMenu.Checked = ($power.Count -gt 0)
    $selected = @($script:state.networkProfiles)
    if ($script:netProfileItems) {
        foreach ($name in @($script:netProfileItems.Keys)) {
            $script:netProfileItems[$name].Checked = ($selected -contains $name)
        }
    }
    $script:netMenu.Checked = ($selected.Count -gt 0)
    $isSleep = ((Get-NormalizedAction -Settings $script:state) -eq "sleep")
    $script:actionHibernateItem.Checked = -not $isSleep
    $script:actionSleepItem.Checked = $isSleep
    $script:actionMenu.Text = Get-UiText ActionMenu (Get-ActionLabel -Action $script:state.action)
    if ($script:presetItems) {
        foreach ($item in $script:presetItems) {
            $item.Checked = ([int]$item.Tag -eq [int]$script:state.idleSeconds)
        }
    }
    if ($script:uiReady) {
        Update-RemainingDisplay
    }
    $script:notify.Text = Get-TooltipText
    }
    catch { }
}

function Get-IdleRemainingSeconds {
    $needSec = Get-IdleSecondsFromSettings -Settings $script:state
    $idleSec = [int][math]::Floor(([UserIdle]::GetIdleMs()) / 1000)
    $inputLeft = [math]::Max(0, $needSec - $idleSec)
    $quiet = Update-QuietSample -WindowSeconds $needSec -InputIsIdle ($idleSec -ge 1)
    if (-not [bool]$script:state.requireQuiet) { return $inputLeft }
    if (-not (Test-AnyQuietMetricEnabled)) { return $inputLeft }
    $quietLeft = [math]::Max(0, $needSec - [int]$quiet.consecutiveQuietSec)
    return [math]::Max($inputLeft, $quietLeft)
}

function Format-RemainingClock([int]$left) {
    $mm = [int][math]::Floor($left / 60)
    $ss = $left % 60
    return ("{0}:{1:00}" -f $mm, $ss)
}

function Get-IdleTimerMenuText {
    param([int]$Left = -1)
    $dur = Format-IdleDuration -Seconds (Get-IdleSecondsFromSettings -Settings $script:state)
    if (Test-Paused) { return (Get-UiText IdleTimerPaused $dur) }
    if ($Left -lt 0) { $Left = Get-IdleRemainingSeconds }
    $clock = Format-RemainingClock $Left
    if ($Left -gt 0) { return (Get-UiText IdleTimerRunning $dur $clock) }
    $waiting = New-Object System.Collections.Generic.List[string]
    if (-not (Test-PowerAllowed -Settings $script:state -OnAc (Test-OnAc))) { [void]$waiting.Add((Get-WaitLabel "Power")) }
    if (-not (Test-SelectedNetworksAllowed -Settings $script:state)) { [void]$waiting.Add((Get-WaitLabel "Net")) }
    if ([bool]$script:state.requireQuiet) {
        $q = Get-QuietStatus
        if (-not $q.windowMet -and $q.waiting) { [void]$waiting.Add((Get-WaitLabel $q.waiting)) }
        elseif (-not $q.windowMet) { [void]$waiting.Add((Get-WaitLabel "quiet")) }
    }
    if ($waiting.Count -gt 0) { return (Get-UiText IdleTimerWaiting $dur ($waiting -join ", ")) }
    return (Get-UiText IdleTimerRunning $dur $clock)
}

function Update-ResetReasonDisplay([int]$left) {
    if (-not $script:resetReasonItem) { return }
    if (Test-Paused) {
        Set-StableMenuItemText $script:resetReasonItem "reason" (Get-UiText ResetReasonNone)
        return
    }
    $need = Get-IdleSecondsFromSettings -Settings $script:state
    $reason = Get-IdleResetReason
    $show = $false
    if ($left -ge ($need - 1) -and $reason) {
        $show = $true
    }
    elseif ($null -ne $script:prevRemainingSec -and $left -gt ($script:prevRemainingSec + 1) -and $reason) {
        $show = $true
        $script:resetReasonUntil = [datetime]::UtcNow.AddSeconds(8)
        $script:shownResetReason = $reason
    }
    elseif ($script:shownResetReason -and $null -ne $script:resetReasonUntil -and [datetime]::UtcNow -lt $script:resetReasonUntil) {
        $show = $true
        $reason = $script:shownResetReason
    }
    if ($show -and $reason) {
        Set-StableMenuItemText $script:resetReasonItem "reason" (Get-UiText ResetReason $reason)
    }
    else {
        Set-StableMenuItemText $script:resetReasonItem "reason" (Get-UiText ResetReasonNone)
    }
    $script:prevRemainingSec = $left
}

function Update-QuietLimitLabels {
    if (-not $script:cpuLimitLabel) { return }
    $cfg = Get-QuietConfig
    $q = Get-QuietStatus
    $cpuNow = "--"
    $diskNow = "--"
    $netNow = "--"
    if ($null -ne $q.cpu) { $cpuNow = ([int][math]::Round([double]$q.cpu, 0)).ToString() }
    if ($null -ne $q.disk) { $diskNow = ([int][math]::Round([double]$q.disk, 0)).ToString() }
    if ($null -ne $q.netKBps) { $netNow = Format-KBpsValue ([double]$q.netKBps) }
    Set-StableMenuItemText $script:cpuLimitLabel "cpu" (Get-UiText CpuBusyAbove ([int]$cfg.cpuBusyPercent) $cpuNow)
    Set-StableMenuItemText $script:diskLimitLabel "disk" (Get-UiText DiskBusyAbove ([int]$cfg.diskBusyPercent) $diskNow)
    Set-StableMenuItemText $script:netLimitLabel "net" (Get-UiText NetBusyAbove ([int]$cfg.netBusyKBps) $netNow)
    $script:quietMenu.Checked = [bool]$script:state.requireQuiet
    $script:quietItem.Checked = [bool]$script:state.requireQuiet
    $script:checkCpuItem.Checked = [bool]$cfg.checkCpu
    $script:checkDiskItem.Checked = [bool]$cfg.checkDisk
    $script:checkNetItem.Checked = [bool]$cfg.checkNet
    $cpuOk = $true
    $diskOk = $true
    $netOk = $true
    if ($null -ne $q.cpu) { $cpuOk = ([double]$q.cpu -lt [double]$q.cpuLimit) }
    if ($null -ne $q.disk) { $diskOk = ([double]$q.disk -lt [double]$q.diskLimit) }
    if ($null -ne $q.netKBps) { $netOk = ([double]$q.netKBps -lt [double]$q.netLimitKBps) }
    Set-LiveConditionColor $script:checkCpuItem $cpuOk
    Set-LiveConditionColor $script:checkDiskItem $diskOk
    Set-LiveConditionColor $script:checkNetItem $netOk
    Set-LiveConditionColor $script:cpuLimitLabel $cpuOk
    Set-LiveConditionColor $script:diskLimitLabel $diskOk
    Set-LiveConditionColor $script:netLimitLabel $netOk
    $quietNow = [bool]$q.windowMet
    if (-not (Test-AnyQuietMetricEnabled)) { $quietNow = $true }
    Set-LiveConditionColor $script:quietItem $quietNow
    $gateOk = (-not [bool]$script:state.requireQuiet) -or $quietNow
    Set-LiveConditionColor $script:quietMenu $gateOk
}

function Set-MenuItemText($item, [string]$text) {
    if (-not $item) { return }
    if ($item.Text -ne $text) { $item.Text = $text }
}

# A dropdown sizes itself from the text of its items, and ignores any width we set
# on the items or on the dropdown itself, so live text is padded with blank glyphs
# to keep every variant the same width. Menus may then grow but never shrink.
function Get-MenuTextWidth($item, [string]$text) {
    if (-not $script:padProbe) {
        $script:padProbe = New-Object System.Windows.Forms.ToolStripMenuItem
    }
    if ($item -and $item.Font -and -not $item.Font.Equals($script:padProbe.Font)) {
        $script:padProbe.Font = $item.Font
    }
    $script:padProbe.Text = $text
    return $script:padProbe.GetPreferredSize([System.Drawing.Size]::Empty).Width
}

function Get-PaddedMenuText($item, [string]$text, [int]$target) {
    $natural = Get-MenuTextWidth $item $text
    if ($natural -ge $target) { return $text }
    $cacheKey = "$target|$text"
    if ($script:padCache.ContainsKey($cacheKey)) { return $script:padCache[$cacheKey] }
    $wide = 0
    while ((Get-MenuTextWidth $item ($text + ($script:PadWide * ($wide + 1)))) -le $target) { $wide++ }
    $best = $text
    $bestWidth = $natural
    foreach ($drop in 0, 1) {
        if (($wide - $drop) -lt 0) { continue }
        $candidate = $text + ($script:PadWide * ($wide - $drop))
        $thin = 0
        while ((Get-MenuTextWidth $item ($candidate + ($script:PadThin * ($thin + 1)))) -le $target) { $thin++ }
        $candidate = $candidate + ($script:PadThin * $thin)
        $width = Get-MenuTextWidth $item $candidate
        if ($width -gt $bestWidth) {
            $best = $candidate
            $bestWidth = $width
        }
        if ($bestWidth -eq $target) { break }
    }
    $script:padCache[$cacheKey] = $best
    return $best
}

function Set-StableMenuItemText($item, [string]$key, [string]$text) {
    if (-not $item) { return }
    $target = 0
    if ($script:padTargets.ContainsKey($key)) { $target = [int]$script:padTargets[$key] }
    $natural = Get-MenuTextWidth $item $text
    if ($natural -gt $target) {
        $target = $natural
        $script:padTargets[$key] = $natural
    }
    Set-MenuItemText $item (Get-PaddedMenuText $item $text $target)
}

function Add-MenuTextWidth($item, [string]$key, [string]$text) {
    if (-not $item -or -not $text) { return }
    $width = Get-MenuTextWidth $item $text
    $target = 0
    if ($script:padTargets.ContainsKey($key)) { $target = [int]$script:padTargets[$key] }
    if ($width -gt $target) { $script:padTargets[$key] = $width }
}

function Reset-MenuTextWidths {
    $script:padTargets = @{}
    $script:padCache = @{}
}

# Reserve room for the longest text each live row can realistically show, so the
# menu opens at its final width instead of widening while it is on screen.
function Add-LiveMenuTextWidths {
    $cfg = Get-QuietConfig
    $dur = Format-IdleDuration -Seconds (Get-IdleSecondsFromSettings -Settings $script:state)
    Add-MenuTextWidth $script:idleLabel "idle" (Get-UiText IdleTimerRunning $dur "10:00")
    Add-MenuTextWidth $script:idleLabel "idle" (Get-UiText IdleTimerPaused $dur)
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReasonNone)
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReason (Get-UiText ResetKeyboard))
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReason (Get-UiText ResetCpu "100" ([int]$cfg.cpuBusyPercent)))
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReason (Get-UiText ResetDisk "100" ([int]$cfg.diskBusyPercent)))
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReason (Get-UiText ResetNet "999999" ([int]$cfg.netBusyKBps)))
    Add-MenuTextWidth $script:cpuLimitLabel "cpu" (Get-UiText CpuBusyAbove ([int]$cfg.cpuBusyPercent) "100")
    Add-MenuTextWidth $script:diskLimitLabel "disk" (Get-UiText DiskBusyAbove ([int]$cfg.diskBusyPercent) "100")
    Add-MenuTextWidth $script:netLimitLabel "net" (Get-UiText NetBusyAbove ([int]$cfg.netBusyKBps) "999999")
}

function Initialize-MenuTextWidths {
    Reset-MenuTextWidths
    Add-LiveMenuTextWidths
}

function Set-SubmenuDropDownDirection($menuItem) {
    if (-not $script:menu -or -not $menuItem) { return }
    $screen = [System.Windows.Forms.Screen]::FromControl($script:menu)
    if (-not $screen) { $screen = [System.Windows.Forms.Screen]::PrimaryScreen }
    $need = $menuItem.DropDown.GetPreferredSize([System.Drawing.Size]::Empty).Width
    $spaceRight = $screen.WorkingArea.Right - $script:menu.Right
    if ($spaceRight -lt ($need + 12)) {
        $menuItem.DropDownDirection = [System.Windows.Forms.ToolStripDropDownDirection]::Left
    }
    else {
        $menuItem.DropDownDirection = [System.Windows.Forms.ToolStripDropDownDirection]::Right
    }
}

function Update-RemainingDisplay {
    try {
    if (Test-Paused) {
        Set-StableMenuItemText $script:idleLabel "idle" (Get-IdleTimerMenuText -Left 0)
        Set-StableMenuItemText $script:resetReasonItem "reason" (Get-UiText ResetReasonNone)
        Update-QuietLimitLabels
        Invoke-IdleTimeoutIfNeeded
        return
    }
    $left = Get-IdleRemainingSeconds
    Set-StableMenuItemText $script:idleLabel "idle" (Get-IdleTimerMenuText -Left $left)
    Update-ResetReasonDisplay $left
    Update-QuietLimitLabels
    Invoke-IdleTimeoutIfNeeded
    }
    catch { }
}

function Invoke-IdleTimeoutIfNeeded {
    if (Test-Paused) {
        $script:idleActionArmed = $true
        return
    }
    $left = Get-IdleRemainingSeconds
    if ($left -gt 0) {
        $script:idleActionArmed = $true
        $script:debugSavedThisIdle = $false
        return
    }

    $idleMs = [int64][UserIdle]::GetIdleMs()
    $eval = Get-IdleEvaluation -Settings $script:state -Paused $false -IdleMs $idleMs -OnAc (Test-OnAc)
    $willFire = $script:idleActionArmed -and ($eval.willProceed -or $eval.willHibernate)
    if ($willFire) {
        Save-IdleDebug -Evaluation $eval
        $script:debugSavedThisIdle = $true
        $script:idleActionArmed = $false
        Add-HibernateHistory -Evaluation $eval
        Invoke-IdlePowerAction -Action $eval.action
        return
    }
    if ($script:idleActionArmed -and -not $script:debugSavedThisIdle) {
        Save-IdleDebug -Evaluation $eval
        $script:debugSavedThisIdle = $true
    }
}

function Toggle-Paused {
    Set-Paused (-not (Test-Paused))
    $script:idleActionArmed = $true
    Update-Tray
}

function Change-Idle([int]$direction) {
    $script:keepMenuOpen = $true
    $current = Get-IdleSecondsFromSettings -Settings $script:state
    $step = 10
    if ($direction -gt 0 -and $current -ge 60) { $step = 60 }
    elseif ($direction -lt 0 -and $current -gt 60) { $step = 60 }
    $next = $current + ($direction * $step)
    $next = Get-IdleSecondsFromSettings -Settings ([pscustomobject]@{ idleSeconds = $next })
    if ($next -eq $current) { return }
    $script:state.idleSeconds = $next
    Save-Settings
    Update-Tray
}

function Enable-KeepSubmenuOpen($menuItem) {
    $dropDown = $menuItem.DropDown
    $dropDown.Add_ItemClicked({
        $script:keepMenuOpen = $true
    })
    $dropDown.Add_Closing({
        param($sender, $e)
        if ($script:keepMenuOpen -and $e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked) {
            $e.Cancel = $true
        }
    })
    $dropDown.Add_Opening({
        param($sender, $e)
        Set-SubmenuDropDownDirection $menuItem
    }.GetNewClosure())
}

function Set-IdleSeconds([int]$seconds) {
    $script:keepMenuOpen = $true
    $next = Get-IdleSecondsFromSettings -Settings ([pscustomobject]@{ idleSeconds = $seconds })
    if ($next -eq [int]$script:state.idleSeconds) { return }
    $script:state.idleSeconds = $next
    $script:idleActionArmed = $true
    Save-Settings
    Update-Tray
}

Read-Settings

$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:pauseItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText PauseIdle)
$script:pauseItem.Add_Click({ Toggle-Paused })

$script:idleLabel = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText IdleTimerRunning (Format-IdleDuration -Seconds 600) "10:00")
$script:idleLabel.Enabled = $false
$script:resetReasonItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ResetReasonNone)
$script:resetReasonItem.Enabled = $false
$script:prevRemainingSec = $null
$script:shownResetReason = $null
$script:resetReasonUntil = [datetime]::MinValue
$script:idleUp = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText IncreaseIdle)
$script:idleDown = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText DecreaseIdle)
$script:idleUp.Add_Click({ Change-Idle 1 })
$script:idleDown.Add_Click({ Change-Idle -1 })

$script:presetMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText IdlePresets)
$script:presetItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ToolStripMenuItem]
foreach ($preset in (Get-IdlePresets)) {
    $sec = [int]$preset.seconds
    $label = [string]$preset.label
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
    $item.Tag = $sec
    $item.Add_Click({
        Set-IdleSeconds $sec
    }.GetNewClosure())
    [void]$script:presetItems.Add($item)
    [void]$script:presetMenu.DropDownItems.Add($item)
}
Enable-KeepSubmenuOpen $script:presetMenu

function Set-NetworkProfileEnabled([string]$name, [bool]$enabled) {
    $current = @($script:state.networkProfiles)
    $has = $current -contains $name
    if ($enabled -and -not $has) {
        $script:state.networkProfiles = @($current + $name)
    }
    elseif (-not $enabled -and $has) {
        $script:state.networkProfiles = @($current | Where-Object { $_ -ne $name })
    }
}

function Set-PowerSourceEnabled([string]$name, [bool]$enabled) {
    $current = @($script:state.powerSources)
    $has = $current -contains $name
    if ($enabled -and -not $has) {
        $script:state.powerSources = @($current + $name)
    }
    elseif (-not $enabled -and $has) {
        $script:state.powerSources = @($current | Where-Object { $_ -ne $name })
    }
}

function Set-LiveConditionColor($item, [bool]$isTrue) {
    if (-not $item) { return }
    if ($isTrue) {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 140, 0)
    }
    else {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(200, 0, 0)
    }
}

function Update-PowerMenuStatus {
    if (-not $script:powerAcItem) { return }
    $onAc = Test-OnAc
    $selected = @($script:state.powerSources)
    $script:powerAcItem.Checked = ($selected -contains "AC")
    $script:powerDcItem.Checked = ($selected -contains "DC")
    $script:powerMenu.Checked = ($selected.Count -gt 0)
    Set-LiveConditionColor $script:powerAcItem $onAc
    Set-LiveConditionColor $script:powerDcItem (-not $onAc)
    Set-LiveConditionColor $script:powerMenu (Test-PowerAllowed -Settings $script:state -OnAc $onAc)
}

function Update-NetworkMenuStatus {
    if (-not $script:netMenu) { return }
    Rebuild-NetworkMenu
    $connected = @(Get-ConnectedNetworkNames)
    $selected = @($script:state.networkProfiles)
    $script:netMenu.Checked = ($selected.Count -gt 0)
    if ($script:netProfileItems) {
        foreach ($name in @($script:netProfileItems.Keys)) {
            $item = $script:netProfileItems[$name]
            $item.Checked = ($selected -contains $name)
            $label = Get-NetworkProfileMenuLabel $name
            Set-MenuItemText $item $label
            Set-LiveConditionColor $item (Test-ProfileConnected -ProfileName $name -ConnectedNames $connected)
        }
    }
    Set-LiveConditionColor $script:netMenu (Test-SelectedNetworksAllowed -Settings $script:state)
}

function Rebuild-NetworkMenu {
    if (-not $script:netMenu) { return }
    if (-not $script:netProfileItems) {
        $script:netProfileItems = @{}
    }
    $names = @($script:NetworkProfileMap.Keys)
    $existing = @($script:netProfileItems.Keys)
    $same = ($names.Count -eq $existing.Count -and $script:netMenu.DropDownItems.Count -eq $names.Count)
    if ($same) {
        foreach ($name in $names) {
            if (-not $script:netProfileItems.ContainsKey($name)) { $same = $false; break }
        }
    }
    if ($same) { return }
    $script:netMenu.DropDownItems.Clear()
    $script:netProfileItems.Clear()
    foreach ($name in @($script:NetworkProfileMap.Keys)) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem (Get-NetworkProfileMenuLabel $name)
        $item.CheckOnClick = $true
        $item.Tag = $name
        $item.Add_Click({
            param($sender, $e)
            $script:keepMenuOpen = $true
            $profileName = [string]$sender.Tag
            if (-not $profileName) { $profileName = [string]$this.Tag }
            Set-NetworkProfileEnabled $profileName $sender.Checked
            Save-Settings
            Update-Tray
            Update-NetworkMenuStatus
        })
        $script:netProfileItems[$name] = $item
        [void]$script:netMenu.DropDownItems.Add($item)
    }
}

$script:powerMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText Power)
$script:powerAcItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText PowerAc)
$script:powerAcItem.CheckOnClick = $true
$script:powerAcItem.Add_Click({
    $script:keepMenuOpen = $true
    Set-PowerSourceEnabled "AC" $script:powerAcItem.Checked
    Save-Settings
    Update-Tray
    Update-PowerMenuStatus
})
$script:powerDcItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText PowerDc)
$script:powerDcItem.CheckOnClick = $true
$script:powerDcItem.Add_Click({
    $script:keepMenuOpen = $true
    Set-PowerSourceEnabled "DC" $script:powerDcItem.Checked
    Save-Settings
    Update-Tray
    Update-PowerMenuStatus
})
[void]$script:powerMenu.DropDownItems.Add($script:powerAcItem)
[void]$script:powerMenu.DropDownItems.Add($script:powerDcItem)
Enable-KeepSubmenuOpen $script:powerMenu
$script:powerMenu.DropDown.Add_Opening({ Update-PowerMenuStatus })

$script:quietMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText QuietPc)
$script:quietItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText RequireQuiet)
$script:quietItem.CheckOnClick = $true
$script:quietItem.Add_Click({
    $script:keepMenuOpen = $true
    $script:state.requireQuiet = $script:quietItem.Checked
    Save-Settings
    Update-Tray
})
$script:checkCpuItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText CheckCpu)
$script:checkCpuItem.CheckOnClick = $true
$script:checkCpuItem.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietCheckEnabled -Kind cpu -Enabled $script:checkCpuItem.Checked
    Update-QuietLimitLabels
})
$script:cpuLimitLabel = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText CpuBusyAbove 20 "--")
$script:cpuLimitLabel.Enabled = $false
$script:cpuLimitUp = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText IncreaseCpu)
$script:cpuLimitDown = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText DecreaseCpu)
$script:cpuLimitUp.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietBusyLimit -Kind cpu -Delta 1
    Update-QuietLimitLabels
})
$script:cpuLimitDown.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietBusyLimit -Kind cpu -Delta -1
    Update-QuietLimitLabels
})
$script:checkDiskItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText CheckDisk)
$script:checkDiskItem.CheckOnClick = $true
$script:checkDiskItem.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietCheckEnabled -Kind disk -Enabled $script:checkDiskItem.Checked
    Update-QuietLimitLabels
})
$script:diskLimitLabel = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText DiskBusyAbove 20 "--")
$script:diskLimitLabel.Enabled = $false
$script:diskLimitUp = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText IncreaseDisk)
$script:diskLimitDown = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText DecreaseDisk)
$script:diskLimitUp.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietBusyLimit -Kind disk -Delta 1
    Update-QuietLimitLabels
})
$script:diskLimitDown.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietBusyLimit -Kind disk -Delta -1
    Update-QuietLimitLabels
})
$script:checkNetItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText CheckNet)
$script:checkNetItem.CheckOnClick = $true
$script:checkNetItem.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietCheckEnabled -Kind net -Enabled $script:checkNetItem.Checked
    Update-QuietLimitLabels
})
$script:netLimitLabel = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText NetBusyAbove 50 "--")
$script:netLimitLabel.Enabled = $false
$script:netLimitUp = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText IncreaseNet)
$script:netLimitDown = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText DecreaseNet)
$script:netLimitUp.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietBusyLimit -Kind net -Delta 1
    Update-QuietLimitLabels
})
$script:netLimitDown.Add_Click({
    $script:keepMenuOpen = $true
    Set-QuietBusyLimit -Kind net -Delta -1
    Update-QuietLimitLabels
})
[void]$script:quietMenu.DropDownItems.Add($script:quietItem)
[void]$script:quietMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:quietMenu.DropDownItems.Add($script:checkCpuItem)
[void]$script:quietMenu.DropDownItems.Add($script:cpuLimitLabel)
[void]$script:quietMenu.DropDownItems.Add($script:cpuLimitUp)
[void]$script:quietMenu.DropDownItems.Add($script:cpuLimitDown)
[void]$script:quietMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:quietMenu.DropDownItems.Add($script:checkDiskItem)
[void]$script:quietMenu.DropDownItems.Add($script:diskLimitLabel)
[void]$script:quietMenu.DropDownItems.Add($script:diskLimitUp)
[void]$script:quietMenu.DropDownItems.Add($script:diskLimitDown)
[void]$script:quietMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:quietMenu.DropDownItems.Add($script:checkNetItem)
[void]$script:quietMenu.DropDownItems.Add($script:netLimitLabel)
[void]$script:quietMenu.DropDownItems.Add($script:netLimitUp)
[void]$script:quietMenu.DropDownItems.Add($script:netLimitDown)
Enable-KeepSubmenuOpen $script:quietMenu
$script:quietMenu.DropDown.Add_Opening({
    try {
        $needSec = Get-IdleSecondsFromSettings -Settings $script:state
        [void](Update-QuietSample -WindowSeconds $needSec -InputIsIdle $true)
        Update-QuietLimitLabels
    }
    catch { }
})

$script:netMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText Network)
$script:netProfileItems = @{}
Rebuild-NetworkMenu
Enable-KeepSubmenuOpen $script:netMenu
$script:netMenu.DropDown.Add_Opening({ Update-NetworkMenuStatus })

$script:actionMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ActionMenu (Get-UiText Hibernate))
$script:actionHibernateItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText Hibernate)
$script:actionSleepItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText Sleep)
$script:actionHibernateItem.Add_Click({
    $script:keepMenuOpen = $true
    $script:state.action = "hibernate"
    Save-Settings
    Update-Tray
})
$script:actionSleepItem.Add_Click({
    $script:keepMenuOpen = $true
    $script:state.action = "sleep"
    Save-Settings
    Update-Tray
})
[void]$script:actionMenu.DropDownItems.Add($script:actionHibernateItem)
[void]$script:actionMenu.DropDownItems.Add($script:actionSleepItem)
Enable-KeepSubmenuOpen $script:actionMenu

$script:historyMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText LastActions)
$script:historyItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ToolStripMenuItem]
for ($i = 0; $i -lt 5; $i++) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText NoActionsYet)
    $item.Enabled = $false
    [void]$script:historyItems.Add($item)
    [void]$script:historyMenu.DropDownItems.Add($item)
}
[void]$script:historyMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$script:historyClearItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ClearEntries)
$script:historyClearItem.Add_Click({
    $script:keepMenuOpen = $true
    Clear-HibernateHistory
    Update-HistoryMenu
})
[void]$script:historyMenu.DropDownItems.Add($script:historyClearItem)
Enable-KeepSubmenuOpen $script:historyMenu

function Update-HistoryMenu {
    $entries = @(Get-HibernateHistory)
    for ($i = 0; $i -lt 5; $i++) {
        if ($i -lt $entries.Count) {
            $script:historyItems[$i].Text = Format-HistoryItem -Entry $entries[$i]
            $script:historyItems[$i].Visible = $true
        }
        elseif ($i -eq 0) {
            $script:historyItems[$i].Text = Get-UiText NoActionsYet
            $script:historyItems[$i].Visible = $true
        }
        else {
            $script:historyItems[$i].Visible = $false
        }
    }
    if ($script:historyClearItem) {
        $script:historyClearItem.Enabled = ($entries.Count -gt 0)
    }
}

function Show-IdleDebugWindow($Evaluation) {
    $text = Format-DebugText -Evaluation $Evaluation
    $form = New-Object System.Windows.Forms.Form
    $form.Text = Get-UiText DebugTitle
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Size = New-Object System.Drawing.Size(540, 520)
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowInTaskbar = $false
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "OK"
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $ok.Height = 36

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.ReadOnly = $true
    $box.DetectUrls = $false
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $box.Dock = [System.Windows.Forms.DockStyle]::Fill
    $box.Font = New-Object System.Drawing.Font("Consolas", 10)
    $box.BackColor = [System.Drawing.SystemColors]::Window
    $box.HideSelection = $true
    $box.TabStop = $false

    $form.Controls.Add($ok)
    $form.Controls.Add($box)
    $form.AcceptButton = $ok

    $green = [System.Drawing.Color]::FromArgb(0, 140, 0)
    $red = [System.Drawing.Color]::FromArgb(200, 0, 0)
    $normal = $box.ForeColor
    foreach ($part in [regex]::Split([string]$text, '(NOT MET|NIET|MET|WEL)')) {
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        if ($part -eq "MET" -or $part -eq "WEL") { $box.SelectionColor = $green }
        elseif ($part -eq "NOT MET" -or $part -eq "NIET") { $box.SelectionColor = $red }
        else { $box.SelectionColor = $normal }
        [void]$box.AppendText($part)
    }
    $box.SelectionStart = 0
    $box.ScrollToCaret()

    [void]$form.ShowDialog()
    $form.Dispose()
}

function Write-CurrentDebugStatus {
    if (-not [bool]$script:state.debugMode) { return }
    $idleMs = [int64][UserIdle]::GetIdleMs()
    $eval = Get-IdleEvaluation -Settings $script:state -Paused (Test-Paused) -IdleMs $idleMs -OnAc (Test-OnAc)
    Write-IdleDebugStatus -Evaluation $eval -Settings $script:state
    Update-DebugLogItem
}

function Update-DebugLogItem {
    if (-not $script:debugLogItem) { return }
    $script:debugLogItem.Enabled = (Test-Path -LiteralPath $script:DebugStatusPath)
}

function Update-DebugMode {
    if ($script:debugModeItem) {
        $script:debugModeItem.Checked = [bool]$script:state.debugMode
    }
    if ($script:debugMenu) {
        $script:debugMenu.Checked = [bool]$script:state.debugMode
    }
    if (-not $script:debugStatusTimer) { return }
    if ([bool]$script:state.debugMode) {
        if (-not $script:debugStatusTimer.Enabled) {
            Write-CurrentDebugStatus
            $script:debugStatusTimer.Start()
        }
    }
    else {
        $script:debugStatusTimer.Stop()
    }
    Update-DebugLogItem
}

$script:debugMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText DebugLastIdle)
$script:debugModeItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText DebugMode)
$script:debugModeItem.CheckOnClick = $true
$script:debugModeItem.Add_Click({
    $script:keepMenuOpen = $true
    $script:state.debugMode = $script:debugModeItem.Checked
    Save-Settings
    Update-DebugMode
})
[void]$script:debugMenu.DropDownItems.Add($script:debugModeItem)
$script:debugLogItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText OpenDebugLog)
$script:debugLogItem.Enabled = $false
$script:debugLogItem.Add_Click({
    $script:keepMenuOpen = $true
    if (-not (Test-Path -LiteralPath $script:DebugStatusPath)) { return }
    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$($script:DebugStatusPath)`""
})
[void]$script:debugMenu.DropDownItems.Add($script:debugLogItem)
[void]$script:debugMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$script:debugItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ToolStripMenuItem]
for ($i = 0; $i -lt 5; $i++) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText NoIdleChecksYet)
    $item.Enabled = $false
    $item.Add_Click({
        param($sender, $e)
        $script:keepMenuOpen = $true
        $eval = $null
        if ($sender -and $sender.Tag) { $eval = $sender.Tag }
        elseif ($this -and $this.Tag) { $eval = $this.Tag }
        if (-not $eval) { return }
        Show-IdleDebugWindow $eval
    })
    [void]$script:debugItems.Add($item)
    [void]$script:debugMenu.DropDownItems.Add($item)
}
[void]$script:debugMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$script:debugClearItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ClearEntries)
$script:debugClearItem.Add_Click({
    $script:keepMenuOpen = $true
    Clear-IdleDebugLog
    Update-DebugMenu
})
[void]$script:debugMenu.DropDownItems.Add($script:debugClearItem)
Enable-KeepSubmenuOpen $script:debugMenu

function Update-DebugMenu {
    $entries = @(Get-IdleDebugLog)
    $defaultColor = [System.Drawing.SystemColors]::ControlText
    for ($i = 0; $i -lt 5; $i++) {
        if ($i -lt $entries.Count) {
            $script:debugItems[$i].Text = Format-LocalWhen -Value $entries[$i].at -Pattern "dd-MM-yyyy HH:mm:ss"
            $script:debugItems[$i].Tag = $entries[$i]
            $script:debugItems[$i].Enabled = $true
            $script:debugItems[$i].Visible = $true
            $proceed = [bool]($entries[$i].willProceed -or $entries[$i].willHibernate)
            Set-LiveConditionColor $script:debugItems[$i] $proceed
        }
        elseif ($i -eq 0) {
            $script:debugItems[$i].Text = Get-UiText NoIdleChecksYet
            $script:debugItems[$i].Tag = $null
            $script:debugItems[$i].Enabled = $false
            $script:debugItems[$i].Visible = $true
            $script:debugItems[$i].ForeColor = $defaultColor
        }
        else {
            $script:debugItems[$i].Visible = $false
            $script:debugItems[$i].ForeColor = $defaultColor
        }
    }
    if ($script:debugClearItem) {
        $script:debugClearItem.Enabled = ($entries.Count -gt 0)
    }
    Update-DebugLogItem
}

function Show-SettingsFileWindow {
    Save-Settings
    $path = $script:SettingsPath
    $text = ""
    if (Test-Path -LiteralPath $path) {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    }
    if (-not $text) { $text = "(empty)" }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = Get-UiText SettingsTitle
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Size = New-Object System.Drawing.Size(560, 580)
    $form.MinimizeBox = $false
    $form.MaximizeBox = $true
    $form.ShowInTaskbar = $false

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text = $path
    $pathLabel.Dock = [System.Windows.Forms.DockStyle]::Top
    $pathLabel.Height = 28
    $pathLabel.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)

    $buttons = New-Object System.Windows.Forms.Panel
    $buttons.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttons.Height = 44

    $openBtn = New-Object System.Windows.Forms.Button
    $openBtn.Text = Get-UiText OpenFile
    $openBtn.Width = 100
    $openBtn.Height = 28
    $openBtn.Location = New-Object System.Drawing.Point(12, 8)
    $openBtn.Add_Click({
        Start-Process -FilePath "notepad.exe" -ArgumentList "`"$($script:SettingsPath)`""
    })

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "OK"
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Width = 88
    $ok.Height = 28
    $ok.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $buttons.Controls.Add($openBtn)
    $buttons.Controls.Add($ok)
    $form.Add_Shown({
        $ok.Location = New-Object System.Drawing.Point(($buttons.ClientSize.Width - 100), 8)
    })

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $box.WordWrap = $false
    $box.Dock = [System.Windows.Forms.DockStyle]::Fill
    $box.Font = New-Object System.Drawing.Font("Consolas", 10)
    $box.Text = $text

    $form.Controls.Add($box)
    $form.Controls.Add($buttons)
    $form.Controls.Add($pathLabel)
    $form.AcceptButton = $ok
    [void]$form.ShowDialog()
    $form.Dispose()
    Read-Settings
    Rebuild-NetworkMenu
    Update-UiLanguage
    Update-Tray
}

function Set-UiLanguage([string]$lang) {
    $script:keepMenuOpen = $true
    $next = Get-UiLanguageCode -Settings ([pscustomobject]@{ language = $lang })
    $script:state.language = $next
    $script:UiLanguage = $next
    Save-Settings
    Update-UiLanguage
    Add-LiveMenuTextWidths
    Update-RemainingDisplay
}

function Update-UiLanguage {
    $script:UiLanguage = Get-UiLanguageCode -Settings $script:state
    if ($script:idleUp) { $script:idleUp.Text = Get-UiText IncreaseIdle }
    if ($script:idleDown) { $script:idleDown.Text = Get-UiText DecreaseIdle }
    if ($script:presetMenu) { $script:presetMenu.Text = Get-UiText IdlePresets }
    if ($script:powerMenu) { $script:powerMenu.Text = Get-UiText Power }
    if ($script:powerAcItem) { $script:powerAcItem.Text = Get-UiText PowerAc }
    if ($script:powerDcItem) { $script:powerDcItem.Text = Get-UiText PowerDc }
    if ($script:quietMenu) { $script:quietMenu.Text = Get-UiText QuietPc }
    if ($script:quietItem) { $script:quietItem.Text = Get-UiText RequireQuiet }
    if ($script:checkCpuItem) { $script:checkCpuItem.Text = Get-UiText CheckCpu }
    if ($script:cpuLimitUp) { $script:cpuLimitUp.Text = Get-UiText IncreaseCpu }
    if ($script:cpuLimitDown) { $script:cpuLimitDown.Text = Get-UiText DecreaseCpu }
    if ($script:checkDiskItem) { $script:checkDiskItem.Text = Get-UiText CheckDisk }
    if ($script:diskLimitUp) { $script:diskLimitUp.Text = Get-UiText IncreaseDisk }
    if ($script:diskLimitDown) { $script:diskLimitDown.Text = Get-UiText DecreaseDisk }
    if ($script:checkNetItem) { $script:checkNetItem.Text = Get-UiText CheckNet }
    if ($script:netLimitUp) { $script:netLimitUp.Text = Get-UiText IncreaseNet }
    if ($script:netLimitDown) { $script:netLimitDown.Text = Get-UiText DecreaseNet }
    if ($script:netMenu) { $script:netMenu.Text = Get-UiText Network }
    if ($script:actionHibernateItem) { $script:actionHibernateItem.Text = Get-UiText Hibernate }
    if ($script:actionSleepItem) { $script:actionSleepItem.Text = Get-UiText Sleep }
    if ($script:historyMenu) { $script:historyMenu.Text = Get-UiText LastActions }
    if ($script:historyClearItem) { $script:historyClearItem.Text = Get-UiText ClearEntries }
    if ($script:debugMenu) { $script:debugMenu.Text = Get-UiText DebugLastIdle }
    if ($script:debugModeItem) { $script:debugModeItem.Text = Get-UiText DebugMode }
    if ($script:debugLogItem) { $script:debugLogItem.Text = Get-UiText OpenDebugLog }
    if ($script:debugClearItem) { $script:debugClearItem.Text = Get-UiText ClearEntries }
    if ($script:settingsFileItem) { $script:settingsFileItem.Text = Get-UiText ShowSettings }
    if ($script:restartItem) { $script:restartItem.Text = Get-UiText RestartTray }
    if ($script:exitItem) { $script:exitItem.Text = Get-UiText ExitTray }
    if ($script:languageMenu) { $script:languageMenu.Text = Get-UiText Language }
    if ($script:languageEnItem) {
        $script:languageEnItem.Text = Get-UiText LanguageEn
        $script:languageEnItem.Checked = ($script:UiLanguage -eq "en")
    }
    if ($script:languageNlItem) {
        $script:languageNlItem.Text = Get-UiText LanguageNl
        $script:languageNlItem.Checked = ($script:UiLanguage -eq "nl")
    }
    Rebuild-NetworkMenu
    Update-PowerMenuStatus
    Update-NetworkMenuStatus
    Update-QuietLimitLabels
    Update-HistoryMenu
    Update-DebugMenu
    Update-AppInfoDisplay
    Update-Tray
}

$script:languageMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText Language)
$script:languageEnItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText LanguageEn)
$script:languageNlItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText LanguageNl)
$script:languageEnItem.Add_Click({ Set-UiLanguage "en" })
$script:languageNlItem.Add_Click({ Set-UiLanguage "nl" })
[void]$script:languageMenu.DropDownItems.Add($script:languageEnItem)
[void]$script:languageMenu.DropDownItems.Add($script:languageNlItem)
Enable-KeepSubmenuOpen $script:languageMenu

$script:versionItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText Version $script:AppVersion)
$script:versionItem.Enabled = $false
$script:hashItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText SourceHash "--")
$script:hashItem.Enabled = $false
$script:settingsFileItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ShowSettings)
$script:settingsFileItem.Add_Click({ Show-SettingsFileWindow })

$script:restartItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText RestartTray)
$script:restartItem.Add_Click({
    $script:uiReady = $false
    try { $script:notify.Visible = $false } catch { }
    try { $script:notify.Dispose() } catch { }
    try { [void]$mutex.ReleaseMutex() } catch { }
    Start-Process -FilePath "wscript.exe" -ArgumentList @("`"$PSScriptRoot\StartTray.vbs`"", "delay")
    [System.Windows.Forms.Application]::Exit()
})
$script:exitItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ExitTray)
$script:exitItem.Add_Click({
    $script:notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

[void]$script:menu.Items.Add($script:pauseItem)
[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:menu.Items.Add($script:idleLabel)
[void]$script:menu.Items.Add($script:resetReasonItem)
[void]$script:menu.Items.Add($script:idleUp)
[void]$script:menu.Items.Add($script:idleDown)
[void]$script:menu.Items.Add($script:presetMenu)
[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:menu.Items.Add($script:powerMenu)
[void]$script:menu.Items.Add($script:quietMenu)
[void]$script:menu.Items.Add($script:netMenu)
[void]$script:menu.Items.Add($script:actionMenu)
[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:menu.Items.Add($script:historyMenu)
[void]$script:menu.Items.Add($script:debugMenu)
[void]$script:menu.Items.Add($script:languageMenu)
[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:menu.Items.Add($script:versionItem)
[void]$script:menu.Items.Add($script:hashItem)
[void]$script:menu.Items.Add($script:settingsFileItem)
[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:menu.Items.Add($script:restartItem)
[void]$script:menu.Items.Add($script:exitItem)
Update-UiLanguage

$script:countdownTimer = New-Object System.Windows.Forms.Timer
$script:countdownTimer.Interval = 250
$script:countdownTimer.Add_Tick({ Update-RemainingDisplay })

$script:debugStatusTimer = New-Object System.Windows.Forms.Timer
$script:debugStatusTimer.Interval = 10000
$script:debugStatusTimer.Add_Tick({
    try { Write-CurrentDebugStatus } catch { }
})
Update-DebugMode

$script:menu.AutoClose = $true
$script:menu.Add_Opening({
    param($sender, $e)
    if (-not $script:uiReady) {
        $e.Cancel = $true
        return
    }
    try {
        Read-Settings
        Update-UiLanguage
        Update-DebugMode
        Initialize-MenuTextWidths
        Update-RemainingDisplay
        $script:countdownTimer.Start()
        if ($script:hidden -and $script:hidden.IsHandleCreated) {
            [void][TrayNative]::SetForegroundWindow($script:hidden.Handle)
        }
    }
    catch { }
})

$script:menu.Add_Closing({
    param($sender, $e)
    $outside = (
        $e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::AppFocusChange -or
        $e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::AppClicked
    )
    if ($outside) {
        $e.Cancel = $false
        $script:keepMenuOpen = $false
        return
    }
    if ($script:keepMenuOpen -and $e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked) {
        $e.Cancel = $true
        $script:keepMenuOpen = $false
    }
})

$script:menu.Add_Closed({
    $script:countdownTimer.Stop()
    Reset-MenuTextWidths
})

$script:notify.Add_MouseUp({
    param($sender, $e)
    if (-not $script:uiReady) { return }
    try {
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Toggle-Paused
            return
        }
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        if ($script:hidden -and $script:hidden.IsHandleCreated) {
            [void][TrayNative]::SetForegroundWindow($script:hidden.Handle)
        }
        $script:menu.Show([System.Windows.Forms.Control]::MousePosition)
    }
    catch { }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try { Update-Tray } catch { }
})

$script:readyTimer = New-Object System.Windows.Forms.Timer
$script:readyTimer.Interval = 800
$script:readyTimer.Add_Tick({
    $script:readyTimer.Stop()
    try {
        [void]$script:menu.Handle
        try { Initialize-QuietCounters } catch { }
        $script:uiReady = $true
        $script:notify.Visible = $true
        $timer.Start()
    }
    catch { }
})

$script:hidden = New-Object System.Windows.Forms.Form
$script:hidden.ShowInTaskbar = $false
$script:hidden.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
$script:hidden.Size = New-Object System.Drawing.Size(1, 1)
$script:hidden.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:hidden.Location = New-Object System.Drawing.Point(-4000, -4000)
$script:hidden.Opacity = 0
[void]$script:hidden.Handle

Update-Tray
Save-Settings
$script:hidden.Add_Shown({
    if ($script:readyTimer.Enabled) { return }
    if ($script:uiReady) { return }
    $script:readyTimer.Start()
})
[System.Windows.Forms.Application]::Run($script:hidden)
try { $script:readyTimer.Stop(); $script:readyTimer.Dispose() } catch { }
$timer.Stop()
$timer.Dispose()
$script:countdownTimer.Stop()
$script:countdownTimer.Dispose()
try { $script:debugStatusTimer.Stop(); $script:debugStatusTimer.Dispose() } catch { }
try { $script:notify.Dispose() } catch { }
$script:iconOn.Dispose()
$script:iconOff.Dispose()
try { [void]$mutex.ReleaseMutex() } catch { }
$mutex.Dispose()
