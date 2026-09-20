# Tray toggle for idle hibernate. Pause is a flag file; timer/AC/network are settings.json.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ("IdleWarnToastForm" -as [type])) {
    Add-Type -ReferencedAssemblies @("System.Windows.Forms.dll", "System.Drawing.dll") -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
public class IdleWarnToastForm : Form {
    public Label TitleLabel;
    public Label BodyLabel;
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00000080;
            cp.ExStyle |= 0x00000008;
            cp.ExStyle |= 0x08000000;
            return cp;
        }
    }
    public IdleWarnToastForm() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Width = 360;
        Height = 92;
        BackColor = Color.FromArgb(36, 36, 36);
        TitleLabel = new Label();
        TitleLabel.ForeColor = Color.White;
        TitleLabel.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
        TitleLabel.AutoSize = false;
        TitleLabel.SetBounds(14, 12, 332, 22);
        BodyLabel = new Label();
        BodyLabel.ForeColor = Color.FromArgb(220, 220, 220);
        BodyLabel.Font = new Font("Segoe UI", 9f);
        BodyLabel.AutoSize = false;
        BodyLabel.SetBounds(14, 36, 332, 44);
        Controls.Add(TitleLabel);
        Controls.Add(BodyLabel);
    }
    public void PlaceOnScreen() {
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(wa.Right - Width - 16, wa.Bottom - Height - 16);
    }
}
"@
}

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
public delegate IntPtr IdleHookProc(int nCode, IntPtr wParam, IntPtr lParam);
public static class IdleInputWatch {
    const int WH_KEYBOARD_LL = 13;
    const int WH_MOUSE_LL = 14;
    const int WM_KEYDOWN = 0x0100;
    const int WM_SYSKEYDOWN = 0x0104;
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, IdleHookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string lpModuleName);
    static IdleHookProc kbdProc;
    static IdleHookProc mouseProc;
    static IntPtr kbdHook = IntPtr.Zero;
    static IntPtr mouseHook = IntPtr.Zero;
    public static int LastKeyboardTick = Environment.TickCount - 60000;
    public static int LastMouseTick = Environment.TickCount - 60000;
    public static bool Started;
    public static uint IdleMsFromTick(int tick) {
        return unchecked((uint)(Environment.TickCount - tick));
    }
    public static void Start() {
        if (Started) { return; }
        LastKeyboardTick = Environment.TickCount - 60000;
        LastMouseTick = Environment.TickCount - 60000;
        kbdProc = KeyboardHook;
        mouseProc = MouseHook;
        IntPtr mod = GetModuleHandle(null);
        kbdHook = SetWindowsHookEx(WH_KEYBOARD_LL, kbdProc, mod, 0);
        if (kbdHook == IntPtr.Zero) { kbdHook = SetWindowsHookEx(WH_KEYBOARD_LL, kbdProc, IntPtr.Zero, 0); }
        mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, mod, 0);
        if (mouseHook == IntPtr.Zero) { mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, IntPtr.Zero, 0); }
        Started = (kbdHook != IntPtr.Zero && mouseHook != IntPtr.Zero);
    }
    public static void Stop() {
        if (kbdHook != IntPtr.Zero) { UnhookWindowsHookEx(kbdHook); kbdHook = IntPtr.Zero; }
        if (mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
        Started = false;
    }
    static IntPtr KeyboardHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = (int)wParam.ToInt64();
            if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
                LastKeyboardTick = Environment.TickCount;
            }
        }
        return CallNextHookEx(kbdHook, nCode, wParam, lParam);
    }
    static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            LastMouseTick = Environment.TickCount;
        }
        return CallNextHookEx(mouseHook, nCode, wParam, lParam);
    }
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

function Write-TrayStartStatus([string]$Status) {
    try {
        $dir = Join-Path $env:LOCALAPPDATA "IdleHibernate"
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $path = Join-Path $dir "start-status.txt"
        Set-Content -LiteralPath $path -Value $Status -Encoding ASCII
        $log = Join-Path $dir "start-tray.log"
        $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "  tray: " + $Status
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    }
    catch { }
}

try {
    . (Join-Path $PSScriptRoot "Common.ps1")
    . (Join-Path $PSScriptRoot "DebugStore.ps1")
    . (Join-Path $PSScriptRoot "DashboardServer.ps1")
}
catch {
    $msg = [string]$_
    try { if ($_.Exception) { $msg = [string]$_.Exception.Message } } catch { }
    Write-TrayStartStatus ("error:" + $msg)
    try { Write-TrayCrash $_ } catch { }
    exit 1
}

$mutex = New-Object System.Threading.Mutex($false, "Local\IdleHibernateTray")
$owned = $false
try {
    $owned = $mutex.WaitOne(0, $false)
}
catch [System.Threading.AbandonedMutexException] {
    $owned = $true
}
if (-not $owned) {
    Write-TrayStartStatus "already"
    exit 0
}

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
$script:warnDeadlineUtc = $null
$script:warnAction = $null
$script:warnToastLeftShown = $null
$script:warnToastForm = $null
$script:idleBaselineUtc = [datetime]::UtcNow
$script:lastIdleTickUtc = $null
$script:debugSavedThisIdle = $false
$script:uiReady = $false
$script:SourceFileNames = @("Common.ps1", "IdleHibernateTray.ps1", "StartTray.vbs", "DebugStore.ps1", "DashboardServer.ps1")

$script:state = [ordered]@{
    chosenName       = "Default"
    idleSeconds      = 600
    requireQuiet     = $true
    debugMode        = $false
    debugRetentionHours = 1
    language         = "en"
    autoSwitch       = $false
    warnSeconds      = 30
    resetKeyboard    = $true
    resetMouse       = $true
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
        if ($choice) {
            $script:state.idleSeconds = Get-IdleSecondsFromSettings -Settings $choice
            if ($null -ne $choice.requireQuiet) { $script:state.requireQuiet = [bool]$choice.requireQuiet }
            $script:state.powerSources = @(Get-SelectedPowerSources -Settings $choice)
            $script:state.networkProfiles = @(Convert-ToStringArray $choice.networkProfiles)
            $script:state.action = Get-NormalizedAction -Settings $choice
            $reasons = Get-IdleResetReasons -Settings $choice
            $script:state.resetKeyboard = [bool]$reasons.keyboard
            $script:state.resetMouse = [bool]$reasons.mouse
        }
        $script:state.chosenName = Get-SelectedChosenName -Settings $s
        $script:state.debugMode = Get-DebugModeEnabled -Settings $s
        $script:state.debugRetentionHours = Get-DebugRetentionHours -Settings $s
        $script:state.language = Get-UiLanguageCode -Settings $s
        $script:state.autoSwitch = Get-AutoSwitchEnabled -Settings $s
        $script:state.warnSeconds = Get-WarnSeconds -Settings $s
        $script:UiLanguage = $script:state.language
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

# Taken once, here, while the files on disk are still the ones this process loaded. Editing
# the scripts later changes the menu's hash but must not relabel dumps this build wrote.
$script:AppSourceHash = Get-AppSourceHash

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
$script:notify.Add_BalloonTipClicked({
    Clear-IdleActionWarning
    $script:idleActionArmed = $false
})

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
    Update-ResetReasonsMenu
    $currentAction = Get-NormalizedAction -Settings $script:state
    if ($script:actionItems) {
        foreach ($act in @($script:actionItems.Keys)) {
            $script:actionItems[$act].Checked = ($act -eq $currentAction)
        }
    }
    $script:actionMenu.Text = Get-UiText ActionMenu (Get-ActionLabel -Action $script:state.action)
    Update-ActionSleepNote
    Update-WarnMenu
    Update-ConfigMenu
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

function Test-IdleWarningPending {
    return ($null -ne $script:warnDeadlineUtc)
}

function Get-IdleWarningLeftSeconds {
    if (-not (Test-IdleWarningPending)) { return 0 }
    return [math]::Max(0, [int][math]::Ceiling(($script:warnDeadlineUtc - [datetime]::UtcNow).TotalSeconds))
}

function Clear-IdleActionWarning {
    $script:warnDeadlineUtc = $null
    $script:warnAction = $null
    $script:warnToastLeftShown = $null
    Hide-IdleActionWarningToast
}

function Ensure-WarnToastForm {
    if ($script:warnToastForm -and -not $script:warnToastForm.IsDisposed) { return $script:warnToastForm }
    $form = New-Object IdleWarnToastForm
    $cancel = {
        Clear-IdleActionWarning
        $script:idleActionArmed = $false
    }
    $form.Add_Click($cancel)
    $form.TitleLabel.Add_Click($cancel)
    $form.BodyLabel.Add_Click($cancel)
    $script:warnToastForm = $form
    return $form
}

function Hide-IdleActionWarningToast {
    try {
        if ($script:warnToastForm -and -not $script:warnToastForm.IsDisposed) {
            $script:warnToastForm.Hide()
        }
    }
    catch { }
}

function Show-IdleActionWarningToast([string]$Action, [int]$Seconds) {
    if ($Seconds -le 0) { return }
    $label = Get-ActionLabel -Action $Action
    $when = Format-RemainingClock $Seconds
    $reasons = Get-IdleResetReasons -Settings $script:state
    $bodyKey = "WarnToastBodyNone"
    if ([bool]$reasons.keyboard -and [bool]$reasons.mouse) { $bodyKey = "WarnToastBodyBoth" }
    elseif ([bool]$reasons.mouse) { $bodyKey = "WarnToastBodyMouse" }
    elseif ([bool]$reasons.keyboard) { $bodyKey = "WarnToastBodyKeyboard" }
    $title = Get-UiText WarnToastTitle
    $body = Get-UiText $bodyKey $label $when
    try {
        $form = Ensure-WarnToastForm
        $form.TitleLabel.Text = $title
        $form.BodyLabel.Text = $body
        $form.PlaceOnScreen()
        if (-not $form.Visible) { $form.Show() }
    }
    catch { }
}

function Update-IdleActionWarningToast {
    if (-not (Test-IdleWarningPending)) { return }
    if (-not $script:warnAction) { return }
    $left = Get-IdleWarningLeftSeconds
    if ($left -le 0) { return }
    if ($null -ne $script:warnToastLeftShown -and [int]$script:warnToastLeftShown -eq $left) { return }
    $script:warnToastLeftShown = $left
    Show-IdleActionWarningToast -Action $script:warnAction -Seconds $left
}

function Start-IdleActionWarning($Evaluation) {
    $sec = Get-WarnSeconds -Settings $script:state
    $script:warnAction = Get-NormalizedAction -Settings $Evaluation
    $script:warnDeadlineUtc = [datetime]::UtcNow.AddSeconds($sec)
    $script:warnToastLeftShown = $null
    if ([bool]$script:state.debugMode -and $Evaluation) {
        Set-IdleDebugResult $Evaluation "warn"
        Write-IdleDebugStatus -Evaluation $Evaluation -Settings $script:state
    }
    Update-IdleActionWarningToast
}

function Set-IdleDebugResult($Evaluation, [string]$Result) {
    if (-not $Evaluation) { return }
    if ($null -ne $Evaluation.PSObject.Properties["result"]) {
        $Evaluation.result = $Result
    }
    else {
        $Evaluation | Add-Member -NotePropertyName result -NotePropertyValue $Result -Force
    }
}

function Invoke-IdleActionNow($Evaluation) {
    Save-IdleDebug -Evaluation $Evaluation
    $script:debugSavedThisIdle = $true
    $script:idleActionArmed = $false
    Clear-IdleActionWarning
    if ([bool]$script:state.debugMode) {
        Set-IdleDebugResult $Evaluation "fired"
        Write-IdleDebugStatus -Evaluation $Evaluation -Settings $script:state
    }
    Add-HibernateHistory -Evaluation $Evaluation
    Reset-IdleBaseline
    Invoke-IdlePowerAction -Action $Evaluation.action
}

# Windows keeps the last-input clock running across a suspend, so a machine that wakes
# after hibernating reports all of that time as idle and would qualify to hibernate again
# at once. Idle is clamped to the time since the baseline, which is pushed forward
# whenever the tray stops watching.
function Get-InputIdleMs {
    $raw = [int64]::MaxValue
    $reasons = Get-IdleResetReasons -Settings $script:state
    $useKbd = [bool]$reasons.keyboard
    $useMouse = [bool]$reasons.mouse
    $watch = $false
    try { $watch = [bool][IdleInputWatch]::Started } catch { }
    if ($watch -and ($useKbd -or $useMouse)) {
        if ($useKbd) {
            $ms = [int64][IdleInputWatch]::IdleMsFromTick([IdleInputWatch]::LastKeyboardTick)
            if ($ms -lt $raw) { $raw = $ms }
        }
        if ($useMouse) {
            $ms = [int64][IdleInputWatch]::IdleMsFromTick([IdleInputWatch]::LastMouseTick)
            if ($ms -lt $raw) { $raw = $ms }
        }
        return $raw
    }
    if ($useKbd -or $useMouse) {
        return [int64][UserIdle]::GetIdleMs()
    }
    return [int64]::MaxValue
}

function Get-EffectiveIdleMs {
    $raw = Get-InputIdleMs
    $since = [int64][math]::Max(0, ([datetime]::UtcNow - $script:idleBaselineUtc).TotalMilliseconds)
    if ($raw -eq [int64]::MaxValue) { return $since }
    if ($since -lt $raw) { return $since }
    return $raw
}

function Reset-IdleBaseline {
    $script:idleBaselineUtc = [datetime]::UtcNow
}

# A gap between ticks means the machine was suspended (or the tray was stalled), so the
# idle time Windows reports covers a stretch we never observed.
function Update-IdleBaseline {
    $now = [datetime]::UtcNow
    if ($null -ne $script:lastIdleTickUtc -and ($now - $script:lastIdleTickUtc).TotalSeconds -gt 5) {
        $script:idleBaselineUtc = $now
    }
    $script:lastIdleTickUtc = $now
}

function Get-IdleRemainingSeconds {
    $needSec = Get-IdleSecondsFromSettings -Settings $script:state
    $idleSec = [int][math]::Floor((Get-EffectiveIdleMs) / 1000)
    $inputLeft = [math]::Max(0, $needSec - $idleSec)
    $inputIdleSec = [int][math]::Floor((Get-InputIdleMs) / 1000)
    $quiet = Update-QuietSample -WindowSeconds $needSec -InputIsIdle ($inputIdleSec -ge 1)
    if (-not [bool]$script:state.requireQuiet) { return $inputLeft }
    if (-not (Test-AnyQuietMetricEnabled)) { return $inputLeft }
    $quietLeft = [math]::Max(0, $needSec - [int]$quiet.quietWindowSec)
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
    if (Test-IdleWarningPending) {
        $remain = Get-IdleWarningLeftSeconds
        $act = Get-ActionLabel -Action $script:warnAction
        return (Get-UiText IdleTimerWarning $dur $act (Format-RemainingClock $remain))
    }
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
    $reason = $null
    $inputIdleSec = [int][math]::Floor((Get-InputIdleMs) / 1000)
    if ($inputIdleSec -lt 1) {
        $reason = Get-InputResetReasonText
    }
    $show = $false
    if ($reason) {
        $show = $true
        $script:resetReasonUntil = [datetime]::UtcNow.AddSeconds(3)
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
    $ratioNow = [int][math]::Round(100.0 * [double]$q.ratio, 0)
    $ratioMin = [int][math]::Round(100.0 * [double]$q.minRatio, 0)
    Set-StableMenuItemText $script:quietSamplesLabel "samples" (Get-UiText QuietSamplesRow $ratioNow $ratioMin)
    $windowNeed = [int]$q.quietWindowNeedSec
    if ($windowNeed -le 0) { $windowNeed = Get-IdleSecondsFromSettings -Settings $script:state }
    $windowHave = [math]::Min([int]$q.quietWindowSec, $windowNeed)
    Set-StableMenuItemText $script:quietWindowLabel "window" (Get-UiText QuietWindowRow $windowHave $windowNeed)
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
    Set-LiveConditionColor $script:quietSamplesLabel ([bool]$q.windowMet)
    Set-LiveConditionColor $script:quietWindowLabel ([bool]$q.windowFull)
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
    foreach ($act in (Get-KnownActions)) {
        Add-MenuTextWidth $script:idleLabel "idle" (Get-UiText IdleTimerWarning $dur (Get-ActionLabel -Action $act) "10:00")
    }
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReasonNone)
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReason (Get-UiText ResetKeyboard))
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReason (Get-UiText ResetMouse))
    Add-MenuTextWidth $script:resetReasonItem "reason" (Get-UiText ResetReason (Get-UiText ResetKeyboardMouse))
    Add-MenuTextWidth $script:cpuLimitLabel "cpu" (Get-UiText CpuBusyAbove ([int]$cfg.cpuBusyPercent) "100")
    Add-MenuTextWidth $script:diskLimitLabel "disk" (Get-UiText DiskBusyAbove ([int]$cfg.diskBusyPercent) "100")
    Add-MenuTextWidth $script:netLimitLabel "net" (Get-UiText NetBusyAbove ([int]$cfg.netBusyKBps) "999999")
    $needSec = Get-IdleSecondsFromSettings -Settings $script:state
    Add-MenuTextWidth $script:quietSamplesLabel "samples" (Get-UiText QuietSamplesRow 100 ([int][math]::Round(100.0 * [double]$cfg.minQuietRatio, 0)))
    Add-MenuTextWidth $script:quietWindowLabel "window" (Get-UiText QuietWindowRow $needSec $needSec)
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
    Update-IdleBaseline
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
        Clear-IdleActionWarning
        $script:idleActionArmed = $true
        return
    }
    $left = Get-IdleRemainingSeconds
    if ($left -gt 0) {
        Clear-IdleActionWarning
        $script:idleActionArmed = $true
        $script:debugSavedThisIdle = $false
        return
    }

    $idleMs = Get-EffectiveIdleMs
    $eval = Get-IdleEvaluation -Settings $script:state -Paused $false -IdleMs $idleMs -OnAc (Test-OnAc)
    $ready = [bool]($eval.willProceed -or $eval.willHibernate)

    if (Test-IdleWarningPending) {
        if (-not $ready) {
            Clear-IdleActionWarning
            return
        }
        if ([datetime]::UtcNow -ge $script:warnDeadlineUtc) {
            Invoke-IdleActionNow $eval
        }
        else {
            Update-IdleActionWarningToast
        }
        return
    }

    $willFire = $script:idleActionArmed -and $ready
    if ($willFire) {
        $warnSec = Get-WarnSeconds -Settings $script:state
        if ($warnSec -le 0) {
            Invoke-IdleActionNow $eval
        }
        else {
            $script:idleActionArmed = $false
            Start-IdleActionWarning $eval
        }
        return
    }
    if ($script:idleActionArmed -and -not $script:debugSavedThisIdle) {
        Save-IdleDebug -Evaluation $eval
        $script:debugSavedThisIdle = $true
    }
}

function Toggle-Paused {
    Set-Paused (-not (Test-Paused))
    Clear-IdleActionWarning
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

function Update-WarnMenu {
    if (-not $script:warnLabel) { return }
    $sec = Get-WarnSeconds -Settings $script:state
    if ($sec -le 0) {
        $script:warnLabel.Text = Get-UiText WarnBefore (Get-UiText WarnOff)
    }
    else {
        $script:warnLabel.Text = Get-UiText WarnBefore (Format-IdleDurationWithSeconds -Seconds $sec)
    }
}

function Update-ActionSleepNote {
    if (-not $script:actionSleepNote) { return }
    $note = $null
    try { $note = Get-SleepCapabilityNote } catch { $note = $null }
    if ($note) {
        $script:actionSleepNote.Text = $note
        $script:actionSleepNote.Visible = $true
    }
    else {
        $script:actionSleepNote.Visible = $false
    }
}

function Change-Warn([int]$direction) {
    $script:keepMenuOpen = $true
    $current = Get-WarnSeconds -Settings $script:state
    $next = Get-WarnSeconds -Settings ([pscustomobject]@{ warnSeconds = ($current + ($direction * 5)) })
    if ($next -eq $current) { return }
    $script:state.warnSeconds = $next
    Save-Settings
    Update-WarnMenu
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

$script:resetReasonsMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText IdleResetReasons)
$script:resetKeyboardItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ResetReasonKeyboard)
$script:resetKeyboardItem.CheckOnClick = $true
$script:resetKeyboardItem.Add_Click({
    $script:keepMenuOpen = $true
    $script:state.resetKeyboard = $script:resetKeyboardItem.Checked
    Save-Settings
    Update-ResetReasonsMenu
})
$script:resetMouseItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ResetReasonMouse)
$script:resetMouseItem.CheckOnClick = $true
$script:resetMouseItem.Add_Click({
    $script:keepMenuOpen = $true
    $script:state.resetMouse = $script:resetMouseItem.Checked
    Save-Settings
    Update-ResetReasonsMenu
})
[void]$script:resetReasonsMenu.DropDownItems.Add($script:resetKeyboardItem)
[void]$script:resetReasonsMenu.DropDownItems.Add($script:resetMouseItem)
Enable-KeepSubmenuOpen $script:resetReasonsMenu

$script:configMenu = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ConfigMenu "Default")
$script:configItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ToolStripMenuItem]
$script:autoSwitchItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText AutoSwitchConfig)
$script:autoSwitchItem.CheckOnClick = $true
$script:autoSwitchItem.Add_Click({
    $script:keepMenuOpen = $true
    if ($script:autoSwitchItem.Checked) {
        $conflicts = @(Get-AutoSwitchNetworkConflicts -Doc $script:AppSettingsCache)
        if ($conflicts.Count -gt 0) {
            $script:autoSwitchItem.Checked = $false
            $script:state.autoSwitch = $false
            Show-AutoSwitchConflictDialog $conflicts
            Save-Settings
            return
        }
    }
    $script:state.autoSwitch = [bool]$script:autoSwitchItem.Checked
    Save-Settings
    if ([bool]$script:state.autoSwitch) { Update-AutoSwitchConfig }
    Update-ConfigMenu
})
Enable-KeepSubmenuOpen $script:configMenu
$script:configMenu.DropDown.Add_Opening({ Update-ConfigMenu })

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

function Update-ResetReasonsMenu {
    if (-not $script:resetKeyboardItem) { return }
    $reasons = Get-IdleResetReasons -Settings $script:state
    $script:resetKeyboardItem.Checked = [bool]$reasons.keyboard
    $script:resetMouseItem.Checked = [bool]$reasons.mouse
    $script:resetReasonsMenu.Checked = ([bool]$reasons.keyboard -or [bool]$reasons.mouse)
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
            if ([bool]$script:state.autoSwitch) {
                $conflicts = @(Get-AutoSwitchNetworkConflicts -Doc $script:AppSettingsCache -OverrideName ([string]$script:state.chosenName) -OverrideProfiles @($script:state.networkProfiles))
                if ($conflicts.Count -gt 0) {
                    Set-NetworkProfileEnabled $profileName (-not [bool]$sender.Checked)
                    $sender.Checked = -not [bool]$sender.Checked
                    Show-AutoSwitchConflictDialog $conflicts
                    Update-NetworkMenuStatus
                    return
                }
            }
            Save-Settings
            Update-Tray
            Update-NetworkMenuStatus
        })
        $script:netProfileItems[$name] = $item
        [void]$script:netMenu.DropDownItems.Add($item)
    }
}

function Update-ConfigMenu {
    if (-not $script:configMenu) { return }
    Rebuild-ConfigMenu
    $current = [string]$script:state.chosenName
    $autoOn = [bool]$script:state.autoSwitch
    if ($autoOn) {
        $script:configMenu.Text = Get-UiText ConfigMenuAuto $current
    }
    else {
        $script:configMenu.Text = Get-UiText ConfigMenu $current
    }
    if ($script:autoSwitchItem) {
        $script:autoSwitchItem.Checked = $autoOn
        $script:autoSwitchItem.Text = Get-UiText AutoSwitchConfig
    }
    if ($script:configItems) {
        foreach ($item in $script:configItems) {
            $name = [string]$item.Tag
            $isCurrent = Test-NameEquals $name $current
            $item.Checked = $isCurrent
            $item.Enabled = -not $autoOn
            if ($autoOn -and $isCurrent) {
                $item.Text = Get-UiText ConfigItemAuto $name
            }
            else {
                $item.Text = $name
            }
        }
    }
}

function Rebuild-ConfigMenu {
    if (-not $script:configMenu) { return }
    if (-not $script:configItems) {
        $script:configItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ToolStripMenuItem]
    }
    $list = @(Get-ChosenList -Doc $script:AppSettingsCache)
    $names = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($choice in $list) {
        [void]$names.Add((Get-ChosenName -Choice $choice -Index $i))
        $i++
    }
    if ($names.Count -eq 0) { [void]$names.Add((Get-SelectedChosenName -Settings $script:state)) }
    $same = ($script:configItems.Count -eq $names.Count)
    if ($same) {
        for ($n = 0; $n -lt $names.Count; $n++) {
            if ([string]$script:configItems[$n].Tag -ne $names[$n]) { $same = $false; break }
        }
    }
    if ($same) { return }
    $script:configMenu.DropDownItems.Clear()
    $script:configItems.Clear()
    if ($script:autoSwitchItem) {
        [void]$script:configMenu.DropDownItems.Add($script:autoSwitchItem)
        [void]$script:configMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }
    foreach ($name in $names) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $name
        $item.Tag = $name
        $item.Add_Click({
            param($sender, $e)
            $script:keepMenuOpen = $true
            $picked = [string]$sender.Tag
            if (-not $picked) { $picked = [string]$this.Tag }
            Select-ChosenConfig $picked
        })
        [void]$script:configItems.Add($item)
        [void]$script:configMenu.DropDownItems.Add($item)
    }
}

function Select-ChosenConfig([string]$name) {
    if (-not $name) { return }
    Save-Settings
    $list = @(Get-ChosenList -Doc $script:AppSettingsCache)
    $target = $null
    $resolved = $null
    $i = 0
    foreach ($item in $list) {
        $itemName = Get-ChosenName -Choice $item -Index $i
        if (Test-NameEquals $itemName $name) {
            $target = $item
            $resolved = $itemName
            break
        }
        $i++
    }
    if (-not $target) { return }
    $script:state.chosenName = $resolved
    $script:state.idleSeconds = Get-IdleSecondsFromSettings -Settings $target
    if ($null -ne $target.requireQuiet) { $script:state.requireQuiet = [bool]$target.requireQuiet }
    $script:state.powerSources = @(Get-SelectedPowerSources -Settings $target)
    $script:state.networkProfiles = @(Convert-ToStringArray $target.networkProfiles)
    $script:state.action = Get-NormalizedAction -Settings $target
    $reasons = Get-IdleResetReasons -Settings $target
    $script:state.resetKeyboard = [bool]$reasons.keyboard
    $script:state.resetMouse = [bool]$reasons.mouse
    $cfg = Get-DefaultQuietConfig
    $defs = Get-DefinitionSettings -Doc $script:AppSettingsCache
    if ($defs -and $defs.quiet) { $cfg = Apply-QuietDoc -Doc $defs.quiet -Cfg $cfg }
    $cfg = Apply-QuietDoc -Doc $target -Cfg $cfg
    if ($target.quiet) { $cfg = Apply-QuietDoc -Doc $target.quiet -Cfg $cfg }
    $script:QuietConfig = $cfg
    Save-Settings
    Update-UiLanguage
}

function Show-AutoSwitchConflictDialog($Conflicts) {
    $detail = Format-AutoSwitchConflictText -Conflicts $Conflicts
    [void][System.Windows.Forms.MessageBox]::Show(
        (Get-UiText AutoSwitchConflictBody $detail),
        (Get-UiText AutoSwitchConflictTitle),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
}

function Confirm-AutoSwitchNetworks {
    if (-not [bool]$script:state.autoSwitch) { return $true }
    $conflicts = @(Get-AutoSwitchNetworkConflicts -Doc $script:AppSettingsCache)
    if ($conflicts.Count -eq 0) { return $true }
    $script:state.autoSwitch = $false
    if ($script:autoSwitchItem) { $script:autoSwitchItem.Checked = $false }
    Show-AutoSwitchConflictDialog $conflicts
    return $false
}

function Update-AutoSwitchConfig {
    if (-not [bool]$script:state.autoSwitch) { return }
    $name = Find-AutoSwitchConfigName -Doc $script:AppSettingsCache
    if (-not $name) { return }
    if (Test-NameEquals $name ([string]$script:state.chosenName)) { return }
    Select-ChosenConfig $name
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
$script:quietSamplesLabel = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText QuietSamplesRow "--" 90)
$script:quietSamplesLabel.Enabled = $false
$script:quietWindowLabel = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText QuietWindowRow 0 0)
$script:quietWindowLabel.Enabled = $false
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
[void]$script:quietMenu.DropDownItems.Add($script:quietSamplesLabel)
[void]$script:quietMenu.DropDownItems.Add($script:quietWindowLabel)
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
$script:actionItems = @{}
foreach ($act in (Get-KnownActions)) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem (Get-ActionLabel -Action $act)
    $item.Tag = $act
    $item.Add_Click({
        param($sender, $e)
        $script:keepMenuOpen = $true
        $picked = [string]$sender.Tag
        if (-not $picked) { $picked = [string]$this.Tag }
        $script:state.action = Get-NormalizedAction -Settings ([pscustomobject]@{ action = $picked })
        Save-Settings
        Update-Tray
    }.GetNewClosure())
    $script:actionItems[$act] = $item
    [void]$script:actionMenu.DropDownItems.Add($item)
}
$script:actionSleepNote = New-Object System.Windows.Forms.ToolStripMenuItem ""
$script:actionSleepNote.Enabled = $false
$script:actionSleepNote.Visible = $false
[void]$script:actionMenu.DropDownItems.Add($script:actionSleepNote)
[void]$script:actionMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$script:warnLabel = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText WarnBefore (Get-UiText WarnOff))
$script:warnLabel.Enabled = $false
$script:warnUp = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText IncreaseWarn)
$script:warnDown = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText DecreaseWarn)
$script:warnUp.Add_Click({ Change-Warn 1 })
$script:warnDown.Add_Click({ Change-Warn -1 })
[void]$script:actionMenu.DropDownItems.Add($script:warnLabel)
[void]$script:actionMenu.DropDownItems.Add($script:warnUp)
[void]$script:actionMenu.DropDownItems.Add($script:warnDown)
Enable-KeepSubmenuOpen $script:actionMenu
$script:actionMenu.DropDown.Add_Opening({ Update-ActionSleepNote; Update-WarnMenu })
Update-ActionSleepNote
Update-WarnMenu

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
    Update-IdleBaseline
    $idleMs = Get-EffectiveIdleMs
    $eval = Get-IdleEvaluation -Settings $script:state -Paused (Test-Paused) -IdleMs $idleMs -OnAc (Test-OnAc)
    $result = "block"
    if ([bool]$eval.paused) {
        $result = "paused"
    }
    elseif ((Test-IdleWarningPending) -and ($eval.willProceed -or $eval.willHibernate)) {
        $result = "warn"
    }
    Set-IdleDebugResult $eval $result
    Write-IdleDebugStatus -Evaluation $eval -Settings $script:state
    Update-DebugLogItem
}

function Update-DebugLogItem {
    if (-not $script:debugLogItem) { return }
    $script:debugLogItem.Enabled = $true
}

function Update-DebugMode {
    if ($script:debugModeItem) {
        $script:debugModeItem.Checked = [bool]$script:state.debugMode
    }
    if ($script:debugMenu) {
        $script:debugMenu.Checked = [bool]$script:state.debugMode
    }
    try { Update-DashboardLiveStatus } catch { }
    if (-not $script:debugStatusTimer) { return }
    if ([bool]$script:state.debugMode) {
        if ($script:debugFlushTimer) {
            $script:debugFlushTimer.Interval = [math]::Max(1000, (Get-DebugFlushSeconds -Settings $script:state) * 1000)
            if (-not $script:debugFlushTimer.Enabled) { $script:debugFlushTimer.Start() }
        }
        if (-not $script:debugStatusTimer.Enabled) {
            Write-CurrentDebugStatus
            $script:debugStatusTimer.Start()
        }
    }
    else {
        $script:debugStatusTimer.Stop()
        if ($script:debugFlushTimer) { $script:debugFlushTimer.Stop() }
        try { Save-DebugSampleBuffer -Settings $script:state } catch { }
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
    try { Show-DebugDashboard } catch { }
})
[void]$script:debugMenu.DropDownItems.Add($script:debugLogItem)
$script:debugClearDbItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-UiText ClearDebugDatabase 0)
$script:debugClearDbItem.Add_Click({
    $script:keepMenuOpen = $true
    try { Clear-DebugSamples } catch { }
    Update-DebugMenu
})
[void]$script:debugMenu.DropDownItems.Add($script:debugClearDbItem)
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
$script:debugMenu.DropDown.Add_Opening({ Update-DebugMenu })

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
    if ($script:debugClearDbItem) {
        $count = 0
        try { $count = Get-DebugSampleCount } catch { $count = 0 }
        $script:debugClearDbItem.Text = Get-UiText ClearDebugDatabase $count
        $script:debugClearDbItem.Enabled = ($count -gt 0)
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
    if ($script:resetReasonsMenu) { $script:resetReasonsMenu.Text = Get-UiText IdleResetReasons }
    if ($script:resetKeyboardItem) { $script:resetKeyboardItem.Text = Get-UiText ResetReasonKeyboard }
    if ($script:resetMouseItem) { $script:resetMouseItem.Text = Get-UiText ResetReasonMouse }
    Update-ConfigMenu
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
    if ($script:actionItems) {
        foreach ($act in @($script:actionItems.Keys)) {
            $script:actionItems[$act].Text = Get-ActionLabel -Action $act
        }
    }
    if ($script:warnUp) { $script:warnUp.Text = Get-UiText IncreaseWarn }
    if ($script:warnDown) { $script:warnDown.Text = Get-UiText DecreaseWarn }
    Update-WarnMenu
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
    Update-ResetReasonsMenu
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
    try { Save-DebugSampleBuffer -Settings $script:state } catch { }
    try { Stop-DebugDashboard } catch { }
    try { Close-DebugStore -Settings $script:state } catch { }
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
[void]$script:menu.Items.Add($script:configMenu)
[void]$script:menu.Items.Add($script:idleLabel)
[void]$script:menu.Items.Add($script:resetReasonItem)
[void]$script:menu.Items.Add($script:idleUp)
[void]$script:menu.Items.Add($script:idleDown)
[void]$script:menu.Items.Add($script:presetMenu)
[void]$script:menu.Items.Add($script:resetReasonsMenu)
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
$script:debugFlushTimer = New-Object System.Windows.Forms.Timer
$script:debugFlushTimer.Interval = 30000
$script:debugFlushTimer.Add_Tick({
    try { Save-DebugSampleBuffer -Settings $script:state } catch { }
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
    try { Update-AutoSwitchConfig } catch { }
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
        Write-TrayStartStatus "started"
        $timer.Start()
        try { [void](Start-DebugDashboard) } catch { Write-TrayCrash $_ }
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
try { [IdleInputWatch]::Start() } catch { }

Update-Tray
[void](Confirm-AutoSwitchNetworks)
Update-AutoSwitchConfig
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
try { $script:debugFlushTimer.Stop(); $script:debugFlushTimer.Dispose() } catch { }
try { Save-DebugSampleBuffer -Settings $script:state } catch { }
try { Stop-DebugDashboard } catch { }
try { Close-DebugStore -Settings $script:state } catch { }
try { $script:notify.Dispose() } catch { }
$script:iconOn.Dispose()
$script:iconOff.Dispose()
try { [IdleInputWatch]::Stop() } catch { }
try { [void]$mutex.ReleaseMutex() } catch { }
$mutex.Dispose()
