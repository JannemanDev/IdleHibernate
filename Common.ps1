# Shared Home/Work SSID checks. ASCII-only. Dot-source from the tray.

$script:NetworkProfileMap = [ordered]@{
    Home = @("ExampleHomeSSID")
    Work = @("ExampleWorkSSID")
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

if (-not ("IdleDesktopNative" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class IdleDesktopNative {
    const uint WM_SYSCOMMAND = 0x0112;
    static readonly IntPtr SC_MONITORPOWER = (IntPtr)0xF170;
    static readonly IntPtr MONITOR_OFF = (IntPtr)2;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool LockWorkStation();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    static extern IntPtr DefWindowProc(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);

    static void SendOff(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) { return; }
        SendMessage(hwnd, WM_SYSCOMMAND, SC_MONITORPOWER, MONITOR_OFF);
        DefWindowProc(hwnd, WM_SYSCOMMAND, SC_MONITORPOWER, MONITOR_OFF);
    }

    // Do not broadcast WM_SYSCOMMAND: HWND_BROADCAST is handled by winlogon and
    // locks the session, so display-off looked the same as Lock.
    public static void TurnOffDisplay(IntPtr ownedHwnd) {
        SendOff(ownedHwnd);
        SendOff(FindWindow("Progman", null));
        SendOff(FindWindow("Shell_TrayWnd", null));
    }
}
"@
}

function Get-KnownActions {
    return @("hibernate", "sleep", "displayoff", "lock", "shutdown")
}

function Get-NormalizedAction {
    param($Settings)
    $choice = Get-ChosenSettings -Settings $Settings
    $action = ""
    if ($null -ne $choice) { $action = [string](Get-ObjectProperty $choice "action") }
    if (-not $action -and $Settings) { $action = [string](Get-ObjectProperty $Settings "action") }
    $name = $action.ToLowerInvariant()
    foreach ($known in (Get-KnownActions)) {
        if ($name -eq $known) { return $known }
    }
    return "hibernate"
}

function Get-ActionLabel {
    param($Action)
    switch (Get-NormalizedAction -Settings ([pscustomobject]@{ action = $Action })) {
        "sleep" { return Get-UiText Sleep }
        "displayoff" { return Get-UiText DisplayOff }
        "lock" { return Get-UiText Lock }
        "shutdown" { return Get-UiText Shutdown }
        default { return Get-UiText Hibernate }
    }
}

function Invoke-IdlePowerAction {
    param($Action)
    $name = Get-NormalizedAction -Settings ([pscustomobject]@{ action = $Action })
    switch ($name) {
        "sleep" { [void][PowerStateNative]::SetSuspendState($false, $true, $false) }
        "lock" {
            $locked = $false
            try { $locked = [IdleDesktopNative]::LockWorkStation() } catch { }
            if (-not $locked) {
                Start-Process -FilePath "$env:SystemRoot\System32\rundll32.exe" -ArgumentList @("user32.dll,LockWorkStation") -WindowStyle Hidden
            }
        }
        "displayoff" {
            $hwnd = [IntPtr]::Zero
            if ($script:hidden -and $script:hidden.IsHandleCreated) {
                $hwnd = $script:hidden.Handle
            }
            try {
                if ($script:notify -and $script:notify.Visible) {
                    $script:notify.Visible = $false
                    $script:notify.Visible = $true
                }
            }
            catch { }
            Start-Sleep -Milliseconds 500
            [IdleDesktopNative]::TurnOffDisplay($hwnd)
        }
        "shutdown" {
            Start-Process -FilePath "shutdown.exe" -ArgumentList @("/s", "/t", "0") -WindowStyle Hidden
        }
        default { shutdown.exe /h }
    }
}

$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir -and $MyInvocation.MyCommand.Path) {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:DataDir = Join-Path $env:LOCALAPPDATA "IdleHibernate"
$script:SettingsPath = Join-Path $script:ScriptDir "settings.json"
$script:HistoryPath = Join-Path $script:DataDir "history.json"
$script:DebugPath = Join-Path $script:DataDir "debug-last.json"
$script:DebugStatusPath = Join-Path $script:DataDir "debug-status.txt"
$script:DebugStatusJsonPath = Join-Path $script:DataDir "debug-status.json"
$script:IdlePresets = $null
$script:AppSettingsLoaded = $false
# Stamped onto every evaluation so a debug dump names the build that produced it. The tray
# fills these in at startup.
$script:AppVersion = $null
$script:AppSourceHash = $null
$script:JsoncLineComments = [ordered]@{
    powerSources        = "AC, DC"
    debugRetentionHours = "hours of debug log to keep"
    debugFlushSeconds   = "seconds between SQLite debug writes"
    language            = "en, nl"
    selected            = "name of the active chosen config"
    autoSwitch          = "switch config when the current network belongs to another config"
    warnSeconds         = "seconds to warn before the action; 0 = none"
    resetReasons        = "keyboard, mouse"
}
$script:UiLanguage = "en"
$script:UiStrings = @{
    en = @{
        PauseIdle              = "Pause idle action"
        ResumeIdle             = "Resume idle action"
        IdleTimerPaused        = "Idle timer: {0} (paused)"
        IdleTimerRunning       = "Idle timer: {0} ({1})"
        IdleTimerWaiting       = "Idle timer: {0} (0:00 waiting {1})"
        ResetReason            = "Reset reason: {0}"
        ResetReasonNone        = "Reset reason: -"
        IncreaseIdle           = "(+) Increase idle timer"
        DecreaseIdle           = "(-) Decrease idle timer"
        IdlePresets            = "Idle timer presets"
        IdleResetReasons       = "Idle timer reset reasons"
        ResetReasonKeyboard    = "Keyboard"
        ResetReasonMouse       = "Mouse"
        ConfigMenu             = "Config: {0}"
        ConfigMenuAuto         = "Config: {0} (auto)"
        ConfigItemAuto         = "{0} (auto)"
        AutoSwitchConfig       = "Auto-switch config"
        AutoSwitchConflictTitle = "Auto-switch config"
        AutoSwitchConflictBody = "Each network can belong to only one config while auto-switch is on.`n`n{0}"
        AutoSwitchConflictLine = "{0}: {1}"
        Power                  = "Power"
        PowerAc                = "Plugged in"
        PowerDc                = "On battery"
        QuietPc                = "Quiet PC"
        RequireQuiet           = "Require quiet PC"
        CheckCpu               = "Check CPU"
        CheckDisk              = "Check disk"
        CheckNet               = "Check network traffic"
        CpuBusyAbove           = "CPU busy above: {0}% (now {1}%)"
        DiskBusyAbove          = "Disk busy above: {0}% (now {1}%)"
        NetBusyAbove           = "Net busy above: {0} KB/s (now {1} KB/s)"
        QuietSamplesRow        = "Quiet samples: {0}% (min {1}%)"
        QuietWindowRow         = "Quiet window: {0}/{1} sec"
        IncreaseCpu            = "(+) Increase CPU limit"
        DecreaseCpu            = "(-) Decrease CPU limit"
        IncreaseDisk           = "(+) Increase disk limit"
        DecreaseDisk           = "(-) Decrease disk limit"
        IncreaseNet            = "(+) Increase net limit"
        DecreaseNet            = "(-) Decrease net limit"
        Network                = "Network"
        ActionMenu             = "Action: {0}"
        Hibernate              = "Hibernate"
        Sleep                  = "Sleep"
        DisplayOff             = "Turn off display"
        Lock                   = "Lock"
        Shutdown               = "Shut down"
        WarnBefore             = "Warn before: {0}"
        WarnOff                = "off"
        IncreaseWarn           = "(+) Increase warning"
        DecreaseWarn           = "(-) Decrease warning"
        WarnToastTitle         = "Idle action"
        WarnToastBody          = "{0} in {1}. Move the mouse to cancel."
        WarnToastBodyBoth      = "{0} in {1}. Move the mouse or press a key to cancel."
        WarnToastBodyMouse     = "{0} in {1}. Move the mouse to cancel."
        WarnToastBodyKeyboard  = "{0} in {1}. Press a key to cancel."
        WarnToastBodyNone      = "{0} in {1}."
        IdleTimerWarning       = "Idle timer: {0} ({1} in {2})"
        LastActions            = "Last actions"
        NoActionsYet           = "No actions yet"
        ClearEntries           = "Clear entries"
        DebugLastIdle          = "Debug last idle check"
        DebugMode              = "Debug mode"
        OpenDebugLog           = "Open dashboard"
        NoIdleChecksYet        = "No idle checks yet"
        Version                = "Version {0}"
        SourceHash             = "Source hash: {0}"
        SourceHashUnavailable  = "Source hash: unavailable"
        ShowSettings           = "Show settings file"
        OpenFile               = "Open file"
        RestartTray            = "Restart tray icon"
        ExitTray               = "Exit tray icon"
        Language               = "Language"
        LanguageEn             = "English"
        LanguageNl             = "Nederlands"
        StatusPaused           = "PAUSED"
        StatusOn               = "ON"
        Yes                    = "yes"
        No                     = "no"
        WaitPower              = "Power"
        WaitNet                = "Net"
        WaitCpu                = "CPU"
        WaitDisk               = "disk"
        WaitQuiet              = "quiet"
        DurSec                 = "{0} sec"
        DurMin                 = "{0} min"
        DurMinSec              = "{0} min {1} sec"
        Met                    = "MET"
        NotMet                 = "NOT MET"
        NoProfile              = "no profile"
        NoMatchingProfile      = "no matching profile"
        Or                     = "or"
        None                   = "none"
        DebugTitle             = "Idle hibernate debug"
        DebugNone              = "Idle timer has not been reached yet."
        DebugIdleHit           = "Idle timer hit: {0}"
        DebugResult            = "Result: {0}"
        DebugVersion           = "Version {0} ({1})"
        DebugBlocked           = "blocked"
        DebugIdleLine          = "Idle timer ({0}): {1} (actual {2})"
        DebugPausedOn          = "Paused: NOT MET (actual on)"
        DebugPausedOff         = "Paused: MET (actual off)"
        DebugPowerNotRequired  = "Power: not required (actual {0})"
        DebugPowerSource       = "Power {0}: {1} (actual {2})"
        DebugQuietRequired     = "Quiet PC: required, {0}"
        DebugQuietNotRequired  = "Quiet PC: not required"
        DebugCpuActual         = "  CPU: actual {0} (limit {1}%), {2}"
        DebugCpuNotChecked     = "  CPU: not checked"
        DebugDiskActual        = "  Disk: actual {0} (limit {1}%), {2}"
        DebugDiskNotChecked    = "  Disk: not checked"
        DebugNetActual         = "  Net: actual {0} (limit {1} KB/s), {2}"
        DebugNetNotChecked     = "  Net: not checked"
        DebugQuietRatioWindow  = "  Quiet ratio/window: required, {0}"
        DebugQuietSamples      = "    Quiet samples ratio {0}% (minimum {1}%), {2}"
        DebugQuietWindow       = "    Quiet window {0} sec (at least for {1} sec), {2}"
        DebugNetworkNotRequired = "Network: not required (actual {0})"
        DebugNetworkRequired   = "Network: required, {0} (actual {1})"
        DebugNetworkProfile    = "  {0} ({1}): {2}"
        SettingsTitle          = "Idle hibernate settings"
        ResetKeyboard          = "keyboard"
        ResetMouse             = "mouse"
        ResetKeyboardMouse     = "keyboard/mouse"
        ResetCpu               = "CPU {0}% > {1}%"
        ResetDisk              = "disk {0}% > {1}%"
        ResetNet               = "net {0} KB/s > {1} KB/s"
    }
    nl = @{
        PauseIdle              = "Idle-actie pauzeren"
        ResumeIdle             = "Idle-actie hervatten"
        IdleTimerPaused        = "Idle-timer: {0} (gepauzeerd)"
        IdleTimerRunning       = "Idle-timer: {0} ({1})"
        IdleTimerWaiting       = "Idle-timer: {0} (0:00 wacht op {1})"
        ResetReason            = "Resetreden: {0}"
        ResetReasonNone        = "Resetreden: -"
        IncreaseIdle           = "(+) Idle-timer verhogen"
        DecreaseIdle           = "(-) Idle-timer verlagen"
        IdlePresets            = "Idle-timer presets"
        IdleResetReasons       = "Idle-timer resetredenen"
        ResetReasonKeyboard    = "Toetsenbord"
        ResetReasonMouse       = "Muis"
        ConfigMenu             = "Config: {0}"
        ConfigMenuAuto         = "Config: {0} (auto)"
        ConfigItemAuto         = "{0} (auto)"
        AutoSwitchConfig       = "Config automatisch wisselen"
        AutoSwitchConflictTitle = "Config automatisch wisselen"
        AutoSwitchConflictBody = "Elk netwerk mag bij automatisch wisselen maar tot één config behoren.`n`n{0}"
        AutoSwitchConflictLine = "{0}: {1}"
        Power                  = "Voeding"
        PowerAc                = "Ingeplugd"
        PowerDc                = "Op accu"
        QuietPc                = "Stille pc"
        RequireQuiet           = "Stille pc vereisen"
        CheckCpu               = "CPU controleren"
        CheckDisk              = "Schijf controleren"
        CheckNet               = "Netwerkverkeer controleren"
        CpuBusyAbove           = "CPU druk boven: {0}% (nu {1}%)"
        DiskBusyAbove          = "Schijf druk boven: {0}% (nu {1}%)"
        NetBusyAbove           = "Net druk boven: {0} KB/s (nu {1} KB/s)"
        QuietSamplesRow        = "Stille samples: {0}% (min {1}%)"
        QuietWindowRow         = "Stille periode: {0}/{1} sec"
        IncreaseCpu            = "(+) CPU-limiet verhogen"
        DecreaseCpu            = "(-) CPU-limiet verlagen"
        IncreaseDisk           = "(+) Schijflimiet verhogen"
        DecreaseDisk           = "(-) Schijflimiet verlagen"
        IncreaseNet            = "(+) Netlimiet verhogen"
        DecreaseNet            = "(-) Netlimiet verlagen"
        Network                = "Netwerk"
        ActionMenu             = "Actie: {0}"
        Hibernate              = "Slaapstand"
        Sleep                  = "Sluimerstand"
        DisplayOff             = "Beeldscherm uitzetten"
        Lock                   = "Vergrendelen"
        Shutdown               = "Afsluiten"
        WarnBefore             = "Waarschuwen: {0}"
        WarnOff                = "uit"
        IncreaseWarn           = "(+) Waarschuwing verhogen"
        DecreaseWarn           = "(-) Waarschuwing verlagen"
        WarnToastTitle         = "Idle-actie"
        WarnToastBody          = "{0} over {1}. Beweeg de muis om te annuleren."
        WarnToastBodyBoth      = "{0} over {1}. Beweeg de muis of druk op een toets om te annuleren."
        WarnToastBodyMouse     = "{0} over {1}. Beweeg de muis om te annuleren."
        WarnToastBodyKeyboard  = "{0} over {1}. Druk op een toets om te annuleren."
        WarnToastBodyNone      = "{0} over {1}."
        IdleTimerWarning       = "Idle-timer: {0} ({1} over {2})"
        LastActions            = "Laatste acties"
        NoActionsYet           = "Nog geen acties"
        ClearEntries           = "Items wissen"
        DebugLastIdle          = "Debug laatste idle-check"
        DebugMode              = "Debugmodus"
        OpenDebugLog           = "Dashboard openen"
        NoIdleChecksYet        = "Nog geen idle-checks"
        Version                = "Versie {0}"
        SourceHash             = "Bronhash: {0}"
        SourceHashUnavailable  = "Bronhash: niet beschikbaar"
        ShowSettings           = "Instellingenbestand tonen"
        OpenFile               = "Bestand openen"
        RestartTray            = "Tray-pictogram herstarten"
        ExitTray               = "Tray-pictogram afsluiten"
        Language               = "Taal"
        LanguageEn             = "English"
        LanguageNl             = "Nederlands"
        StatusPaused           = "GEPAUZEERD"
        StatusOn               = "AAN"
        Yes                    = "ja"
        No                     = "nee"
        WaitPower              = "Voeding"
        WaitNet                = "Net"
        WaitCpu                = "CPU"
        WaitDisk               = "schijf"
        WaitQuiet              = "stil"
        DurSec                 = "{0} sec"
        DurMin                 = "{0} min"
        DurMinSec              = "{0} min {1} sec"
        Met                    = "WEL"
        NotMet                 = "NIET"
        NoProfile              = "geen profiel"
        NoMatchingProfile      = "geen passend profiel"
        Or                     = "of"
        None                   = "geen"
        DebugTitle             = "Idle-hibernate debug"
        DebugNone              = "Idle-timer is nog niet bereikt."
        DebugIdleHit           = "Idle-timer bereikt: {0}"
        DebugResult            = "Resultaat: {0}"
        DebugVersion           = "Versie {0} ({1})"
        DebugBlocked           = "geblokkeerd"
        DebugIdleLine          = "Idle-timer ({0}): {1} (werkelijk {2})"
        DebugPausedOn          = "Gepauzeerd: NIET (werkelijk aan)"
        DebugPausedOff         = "Gepauzeerd: WEL (werkelijk uit)"
        DebugPowerNotRequired  = "Voeding: niet vereist (werkelijk {0})"
        DebugPowerSource       = "Voeding {0}: {1} (werkelijk {2})"
        DebugQuietRequired     = "Stille pc: vereist, {0}"
        DebugQuietNotRequired  = "Stille pc: niet vereist"
        DebugCpuActual         = "  CPU: werkelijk {0} (limiet {1}%), {2}"
        DebugCpuNotChecked     = "  CPU: niet gecontroleerd"
        DebugDiskActual        = "  Schijf: werkelijk {0} (limiet {1}%), {2}"
        DebugDiskNotChecked    = "  Schijf: niet gecontroleerd"
        DebugNetActual         = "  Net: werkelijk {0} (limiet {1} KB/s), {2}"
        DebugNetNotChecked     = "  Net: niet gecontroleerd"
        DebugQuietRatioWindow  = "  Stille ratio/periode: vereist, {0}"
        DebugQuietSamples      = "    Stille samples-ratio {0}% (minimum {1}%), {2}"
        DebugQuietWindow       = "    Stille periode {0} sec (minstens {1} sec), {2}"
        DebugNetworkNotRequired = "Netwerk: niet vereist (werkelijk {0})"
        DebugNetworkRequired   = "Netwerk: vereist, {0} (werkelijk {1})"
        DebugNetworkProfile    = "  {0} ({1}): {2}"
        SettingsTitle          = "Idle-hibernate instellingen"
        ResetKeyboard          = "toetsenbord"
        ResetMouse             = "muis"
        ResetKeyboardMouse     = "toetsenbord/muis"
        ResetCpu               = "CPU {0}% > {1}%"
        ResetDisk              = "schijf {0}% > {1}%"
        ResetNet               = "net {0} KB/s > {1} KB/s"
    }
}

function Get-UiText {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$FormatArgs
    )
    $lang = $script:UiLanguage
    if (-not $script:UiStrings.ContainsKey($lang)) { $lang = "en" }
    $map = $script:UiStrings[$lang]
    $text = $null
    if ($map.ContainsKey($Key)) { $text = [string]$map[$Key] }
    elseif ($script:UiStrings["en"].ContainsKey($Key)) { $text = [string]$script:UiStrings["en"][$Key] }
    else { $text = $Key }
    if ($null -ne $FormatArgs -and $FormatArgs.Count -gt 0) {
        return [string]::Format($text, [object[]]$FormatArgs)
    }
    return $text
}

function Get-PowerSourceLabel {
    param([string]$Name)
    if ($Name -eq "AC") { return Get-UiText PowerAc }
    if ($Name -eq "DC") { return Get-UiText PowerDc }
    return $Name
}

function Get-WaitLabel {
    param([string]$Name)
    switch ($Name) {
        "Power" { return Get-UiText WaitPower }
        "Net" { return Get-UiText WaitNet }
        "CPU" { return Get-UiText WaitCpu }
        "disk" { return Get-UiText WaitDisk }
        "net" { return Get-UiText WaitNet }
        "quiet" { return Get-UiText WaitQuiet }
        default { return $Name }
    }
}

function Initialize-NewtonsoftJson {
    if ("Newtonsoft.Json.JsonConvert" -as [type]) { return }
    $dll = Join-Path $script:ScriptDir "lib\Newtonsoft.Json.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        throw "Newtonsoft.Json.dll not found at $dll"
    }
    Add-Type -Path $dll
}

Initialize-NewtonsoftJson

function ConvertFrom-JsoncText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $sr = New-Object System.IO.StringReader($Text)
    $reader = New-Object Newtonsoft.Json.JsonTextReader($sr)
    try {
        $token = [Newtonsoft.Json.Linq.JToken]::Load($reader)
        if ($null -eq $token -or $token.Type -eq [Newtonsoft.Json.Linq.JTokenType]::Null) { return $null }
        return ($token.ToString() | ConvertFrom-Json)
    }
    finally {
        $reader.Close()
        $sr.Dispose()
    }
}

# Writes JSONC with a fixed two-space indent, and keeps an object or array on one line when
# it holds nothing but scalars and still fits the line budget. ConvertTo-Json on PS 5.1
# instead aligns every nested value under its key, which runs the indent off to the right.
function ConvertTo-JsoncText {
    param(
        $Value,
        $Comments = $null,
        [int]$MaxWidth = 100,
        [int]$Indent = 0,
        [int]$Column = 0
    )
    $step = 2
    $pad = " " * ($Indent + $step)
    $tail = " " * $Indent

    if ($null -eq $Value) { return "null" }
    if ($Value -is [string]) { return [Newtonsoft.Json.JsonConvert]::ToString([string]$Value) }
    if ($Value -is [bool]) {
        if ($Value) { return "true" }
        return "false"
    }

    $pairs = $null
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($key in $Value.Keys) { $pairs[[string]$key] = $Value[$key] }
    }
    elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($prop in $Value.PSObject.Properties) { $pairs[[string]$prop.Name] = $prop.Value }
    }

    if ($null -ne $pairs) {
        if ($pairs.Count -eq 0) { return "{}" }
        $names = New-Object System.Collections.Generic.List[string]
        $entries = New-Object System.Collections.Generic.List[string]
        $split = $false
        foreach ($name in $pairs.Keys) {
            $key = [Newtonsoft.Json.JsonConvert]::ToString([string]$name)
            $child = ConvertTo-JsoncText -Value $pairs[$name] -Comments $Comments -MaxWidth $MaxWidth -Indent ($Indent + $step) -Column ($Indent + $step + $key.Length + 2)
            if ($child.Contains("`n")) { $split = $true }
            # A documented key has to stay on its own line, otherwise its comment has nowhere to go.
            if ($null -ne $Comments -and $Comments.Contains($name)) { $split = $true }
            [void]$names.Add([string]$name)
            [void]$entries.Add("${key}: $child")
        }
        if (-not $split) {
            $one = "{ " + ($entries -join ", ") + " }"
            if (($Column + $one.Length) -le $MaxWidth) { return $one }
        }
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add("{")
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($null -ne $Comments -and $Comments.Contains($names[$i])) {
                [void]$lines.Add("$pad// $($Comments[$names[$i]])")
            }
            $comma = ","
            if ($i -eq ($entries.Count - 1)) { $comma = "" }
            [void]$lines.Add("$pad$($entries[$i])$comma")
        }
        [void]$lines.Add("$tail}")
        return ($lines -join "`r`n")
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return "[]" }
        $parts = New-Object System.Collections.Generic.List[string]
        $split = $false
        foreach ($item in $items) {
            $child = ConvertTo-JsoncText -Value $item -Comments $Comments -MaxWidth $MaxWidth -Indent ($Indent + $step) -Column ($Indent + $step)
            if ($child.Contains("`n")) { $split = $true }
            [void]$parts.Add($child)
        }
        if (-not $split) {
            $one = "[" + ($parts -join ", ") + "]"
            if (($Column + $one.Length) -le $MaxWidth) { return $one }
        }
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add("[")
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $comma = ","
            if ($i -eq ($parts.Count - 1)) { $comma = "" }
            [void]$lines.Add("$pad$($parts[$i])$comma")
        }
        [void]$lines.Add("$tail]")
        return ($lines -join "`r`n")
    }

    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return [Newtonsoft.Json.JsonConvert]::ToString([double]$Value)
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) {
        return [string][int64]$Value
    }
    return ($Value | ConvertTo-Json -Compress -Depth 8)
}

function Get-ObjectProperty {
    param($Obj, [string]$Name)
    if ($null -eq $Obj -or -not $Name) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-NameEquals {
    param([string]$Left, [string]$Right)
    return [string]::Equals([string]$Left, [string]$Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DefinitionSettings {
    param($Doc)
    if ($null -eq $Doc) { return $null }
    return (Get-ObjectProperty $Doc "definitions")
}

function Get-ChosenList {
    param($Doc)
    if ($null -eq $Doc) { return @() }
    $raw = Get-ObjectProperty $Doc "chosen"
    if ($null -eq $raw) { return @() }
    return @($raw)
}

function Get-ChosenName {
    param($Choice, [int]$Index = 0)
    $name = [string](Get-ObjectProperty $Choice "name")
    if ($name) { return $name }
    if ($Index -le 0) { return "Default" }
    return "Profile $($Index + 1)"
}

function Get-SelectedChosenName {
    param($Settings)
    $name = [string](Get-ObjectProperty $Settings "chosenName")
    if (-not $name) {
        $defs = Get-DefinitionSettings -Doc $Settings
        $name = [string](Get-ObjectProperty $defs "selected")
    }
    if (-not $name) {
        $name = [string](Get-ObjectProperty $Settings "selected")
    }
    if (-not $name -and $null -eq (Get-ObjectProperty $Settings "chosen")) {
        $defs = Get-DefinitionSettings -Doc $script:AppSettingsCache
        $name = [string](Get-ObjectProperty $defs "selected")
    }
    $doc = $Settings
    if ($null -eq (Get-ObjectProperty $doc "chosen")) { $doc = $script:AppSettingsCache }
    $list = @(Get-ChosenList -Doc $doc)
    if ($list.Count -eq 0) {
        if ($name) { return $name }
        return "Default"
    }
    if ($name) {
        $i = 0
        foreach ($item in $list) {
            $itemName = Get-ChosenName -Choice $item -Index $i
            if (Test-NameEquals $itemName $name) { return $itemName }
            $i++
        }
    }
    return (Get-ChosenName -Choice $list[0] -Index 0)
}

function Find-ChosenByName {
    param($List, [string]$Name)
    $items = @($List)
    $i = 0
    foreach ($item in $items) {
        if (Test-NameEquals (Get-ChosenName -Choice $item -Index $i) $Name) { return $item }
        $i++
    }
    if ($items.Count -gt 0) { return $items[0] }
    return $null
}

function Get-ChosenSettings {
    param($Settings)
    if ($null -eq $Settings) { return $null }
    if ($null -ne (Get-ObjectProperty $Settings "chosen")) {
        $list = @(Get-ChosenList -Doc $Settings)
        if ($list.Count -eq 0) { return $null }
        return (Find-ChosenByName -List $list -Name (Get-SelectedChosenName -Settings $Settings))
    }
    return $Settings
}

function Get-DefinitionField {
    param($Settings, [string]$Name)
    foreach ($root in @($Settings, $script:AppSettingsCache)) {
        if ($null -eq $root) { continue }
        $defs = Get-DefinitionSettings -Doc $root
        $val = Get-ObjectProperty $defs $Name
        if ($null -ne $val) { return $val }
        $val = Get-ObjectProperty $root $Name
        if ($null -ne $val) { return $val }
        if ($null -ne (Get-ObjectProperty $root "chosen")) {
            $choice = Get-ChosenSettings -Settings $root
            $val = Get-ObjectProperty $choice $Name
            if ($null -ne $val) { return $val }
        }
    }
    return $null
}

function Get-IdleSecondsFromSettings {
    param($Settings)
    $choice = Get-ChosenSettings -Settings $Settings
    $sec = 600
    if ($null -ne $choice -and $null -ne $choice.idleSeconds) {
        $sec = [int]$choice.idleSeconds
    }
    if ($sec -lt 10) { $sec = 10 }
    if ($sec -gt 14400) { $sec = 14400 }
    return $sec
}

function Get-WarnSeconds {
    param($Settings)
    $sec = 30
    $raw = Get-DefinitionField -Settings $Settings -Name "warnSeconds"
    if ($null -ne $raw) {
        try { $sec = [int]$raw } catch { $sec = 30 }
    }
    if ($sec -lt 0) { $sec = 0 }
    if ($sec -gt 300) { $sec = 300 }
    return $sec
}

function Apply-IdleResetReasonsDoc {
    param($Doc, $Cfg)
    if (-not $Doc) { return $Cfg }
    $nested = Get-ObjectProperty $Doc "resetReasons"
    if ($nested) {
        $k = Get-ObjectProperty $nested "keyboard"
        $m = Get-ObjectProperty $nested "mouse"
        if ($null -ne $k) { $Cfg.keyboard = [bool]$k }
        if ($null -ne $m) { $Cfg.mouse = [bool]$m }
    }
    $k2 = Get-ObjectProperty $Doc "resetKeyboard"
    $m2 = Get-ObjectProperty $Doc "resetMouse"
    if ($null -ne $k2) { $Cfg.keyboard = [bool]$k2 }
    if ($null -ne $m2) { $Cfg.mouse = [bool]$m2 }
    return $Cfg
}

function Get-IdleResetReasons {
    param($Settings)
    $cfg = [pscustomobject]@{ keyboard = $true; mouse = $true }
    if ($Settings) {
        $choice = Get-ChosenSettings -Settings $Settings
        if ($choice) { $cfg = Apply-IdleResetReasonsDoc -Doc $choice -Cfg $cfg }
        $cfg = Apply-IdleResetReasonsDoc -Doc $Settings -Cfg $cfg
    }
    return $cfg
}

function Get-InputResetReasonText {
    $reasons = Get-IdleResetReasons -Settings $script:state
    $useKbd = [bool]$reasons.keyboard
    $useMouse = [bool]$reasons.mouse
    if (-not $useKbd -and -not $useMouse) { return $null }
    $watch = $false
    try { $watch = [bool][IdleInputWatch]::Started } catch { }
    if (-not $watch) { return (Get-UiText ResetKeyboardMouse) }
    $kbdMs = [int64]::MaxValue
    $mouseMs = [int64]::MaxValue
    if ($useKbd) { $kbdMs = [int64][IdleInputWatch]::IdleMsFromTick([IdleInputWatch]::LastKeyboardTick) }
    if ($useMouse) { $mouseMs = [int64][IdleInputWatch]::IdleMsFromTick([IdleInputWatch]::LastMouseTick) }
    if ($kbdMs -le $mouseMs) { return (Get-UiText ResetKeyboard) }
    return (Get-UiText ResetMouse)
}

function Get-DebugRetentionHours {
    param($Settings)
    $hours = 1
    $raw = Get-DefinitionField -Settings $Settings -Name "debugRetentionHours"
    if ($null -ne $raw) {
        try { $hours = [int]$raw } catch { $hours = 1 }
    }
    if ($hours -lt 1) { $hours = 1 }
    if ($hours -gt 168) { $hours = 168 }
    return $hours
}

function Get-DebugFlushSeconds {
    param($Settings)
    $sec = 30
    $raw = Get-DefinitionField -Settings $Settings -Name "debugFlushSeconds"
    if ($null -ne $raw) {
        try { $sec = [int]$raw } catch { $sec = 30 }
    }
    if ($sec -lt 5) { $sec = 5 }
    if ($sec -gt 300) { $sec = 300 }
    return $sec
}

function Get-DebugModeEnabled {
    param($Settings)
    $raw = Get-DefinitionField -Settings $Settings -Name "debugMode"
    if ($null -eq $raw) { return $false }
    return [bool]$raw
}

function Get-AutoSwitchEnabled {
    param($Settings)
    $raw = Get-DefinitionField -Settings $Settings -Name "autoSwitch"
    if ($null -eq $raw) { return $false }
    return [bool]$raw
}

function Add-ConfigNameToMap {
    param($Map, [string]$Key, [string]$ConfigName)
    if (-not $Key -or -not $ConfigName) { return }
    $existingKey = $null
    foreach ($k in @($Map.Keys)) {
        if (Test-NameEquals $k $Key) { $existingKey = $k; break }
    }
    if ($null -eq $existingKey) {
        $Map[$Key] = New-Object System.Collections.Generic.List[string]
        $existingKey = $Key
    }
    foreach ($n in $Map[$existingKey]) {
        if (Test-NameEquals $n $ConfigName) { return }
    }
    [void]$Map[$existingKey].Add($ConfigName)
}

function Get-ChosenNetworkProfileNames {
    param($Choice)
    $raw = @(Convert-ToStringArray (Get-ObjectProperty $Choice "networkProfiles"))
    return @($raw | Where-Object { $script:NetworkProfileMap.Keys -contains $_ })
}

function Get-AutoSwitchNetworkConflicts {
    param(
        $Doc,
        [string]$OverrideName = $null,
        [string[]]$OverrideProfiles = $null
    )
    if ($null -eq $Doc) { $Doc = $script:AppSettingsCache }
    $byProfile = @{}
    $bySsid = @{}
    $list = @(Get-ChosenList -Doc $Doc)
    $i = 0
    foreach ($choice in $list) {
        $cname = Get-ChosenName -Choice $choice -Index $i
        $profiles = @(Get-ChosenNetworkProfileNames -Choice $choice)
        if ($OverrideName -and (Test-NameEquals $cname $OverrideName)) {
            $profiles = @($OverrideProfiles | Where-Object { $script:NetworkProfileMap.Keys -contains $_ })
        }
        foreach ($profile in $profiles) {
            Add-ConfigNameToMap -Map $byProfile -Key $profile -ConfigName $cname
            foreach ($ssid in @($script:NetworkProfileMap[$profile])) {
                Add-ConfigNameToMap -Map $bySsid -Key ([string]$ssid) -ConfigName $cname
            }
        }
        $i++
    }
    $conflicts = New-Object System.Collections.Generic.List[object]
    foreach ($profile in @($byProfile.Keys)) {
        if ($byProfile[$profile].Count -gt 1) {
            [void]$conflicts.Add([pscustomobject]@{
                network = $profile
                configs = @($byProfile[$profile])
            })
        }
    }
    foreach ($ssid in @($bySsid.Keys)) {
        if ($bySsid[$ssid].Count -le 1) { continue }
        $already = $false
        foreach ($row in $conflicts) {
            $ssids = @($script:NetworkProfileMap[$row.network])
            if ($ssids.Count -gt 0 -and (Test-NameInList -Name $ssid -List $ssids)) {
                $already = $true
                break
            }
        }
        if ($already) { continue }
        [void]$conflicts.Add([pscustomobject]@{
            network = "$ssid (SSID)"
            configs = @($bySsid[$ssid])
        })
    }
    if ($conflicts.Count -eq 0) { return @() }
    return $conflicts.ToArray()
}

function Format-AutoSwitchConflictText {
    param($Conflicts)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($row in @($Conflicts)) {
        [void]$lines.Add((Get-UiText AutoSwitchConflictLine $row.network ($row.configs -join ", ")))
    }
    return ($lines -join [Environment]::NewLine)
}

function Find-AutoSwitchConfigName {
    param(
        $Doc,
        [string[]]$ConnectedNames = $null
    )
    if ($null -eq $Doc) { $Doc = $script:AppSettingsCache }
    if ($null -eq $ConnectedNames) { $ConnectedNames = @(Get-ConnectedNetworkNames) }
    $matched = @(Get-MatchedNetworkProfiles -ConnectedNames $ConnectedNames)
    if ($matched.Count -eq 0) { return $null }
    $hits = New-Object System.Collections.Generic.List[string]
    $list = @(Get-ChosenList -Doc $Doc)
    $i = 0
    foreach ($choice in $list) {
        $cname = Get-ChosenName -Choice $choice -Index $i
        foreach ($profile in @(Get-ChosenNetworkProfileNames -Choice $choice)) {
            if (Test-NameInList -Name $profile -List $matched) {
                $seen = $false
                foreach ($h in $hits) {
                    if (Test-NameEquals $h $cname) { $seen = $true; break }
                }
                if (-not $seen) { [void]$hits.Add($cname) }
                break
            }
        }
        $i++
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

function Get-UiLanguageCode {
    param($Settings)
    $lang = "en"
    $raw = Get-DefinitionField -Settings $Settings -Name "language"
    if ($null -ne $raw) {
        $text = ([string]$raw).ToLowerInvariant()
        if ($text -eq "nl" -or $text -eq "nederlands" -or $text -eq "dutch") { $lang = "nl" }
    }
    return $lang
}

function Format-IdleDuration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return (Get-UiText DurSec $Seconds) }
    if (($Seconds % 60) -eq 0) { return (Get-UiText DurMin ([int]($Seconds / 60))) }
    $m = [int][math]::Floor($Seconds / 60)
    $s = $Seconds % 60
    return (Get-UiText DurMinSec $m $s)
}

function Format-IdleDurationWithSeconds {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return (Get-UiText DurSec $Seconds) }
    $m = [int][math]::Floor($Seconds / 60)
    $s = $Seconds % 60
    return (Get-UiText DurMinSec $m $s)
}

function Get-DefaultIdlePresets {
    return @(
        [pscustomobject]@{ label = "10 sec"; seconds = 10 },
        [pscustomobject]@{ label = "1 min"; seconds = 60 },
        [pscustomobject]@{ label = "5 min"; seconds = 300 },
        [pscustomobject]@{ label = "10 min"; seconds = 600 },
        [pscustomobject]@{ label = "15 min"; seconds = 900 },
        [pscustomobject]@{ label = "30 min"; seconds = 1800 },
        [pscustomobject]@{ label = "60 min"; seconds = 3600 }
    )
}

function Get-IdlePresets {
    if ($null -eq $script:IdlePresets) { [void](Read-AppSettingsFile) }
    if ($script:IdlePresets -and $script:IdlePresets.Count -gt 0) { return @($script:IdlePresets) }
    return Get-DefaultIdlePresets
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
$script:QuietWindowStartUtc = [datetime]::MinValue
$script:QuietWindowSeconds = 0
$script:LastIdleResetReason = $null

function Get-DefaultQuietConfig {
    return [pscustomobject]@{
        cpuBusyPercent  = 20.0
        diskBusyPercent = 20.0
        netBusyKBps     = 50.0
        minQuietRatio   = 0.9
        checkCpu        = $true
        checkDisk       = $true
        checkNet        = $true
        cpuStepPercent  = 5
        diskStepPercent = 5
        netStepKBps     = 10
    }
}

function Apply-QuietDoc {
    param($Doc, $Cfg)
    if (-not $Doc) { return $Cfg }
    if ($null -ne $Doc.cpuBusyPercent) { $Cfg.cpuBusyPercent = [double]$Doc.cpuBusyPercent }
    if ($null -ne $Doc.diskBusyPercent) { $Cfg.diskBusyPercent = [double]$Doc.diskBusyPercent }
    if ($null -ne $Doc.netBusyKBps) { $Cfg.netBusyKBps = [double]$Doc.netBusyKBps }
    if ($null -ne $Doc.minQuietRatio) { $Cfg.minQuietRatio = [double]$Doc.minQuietRatio }
    if ($null -ne $Doc.checkCpu) { $Cfg.checkCpu = [bool]$Doc.checkCpu }
    if ($null -ne $Doc.checkDisk) { $Cfg.checkDisk = [bool]$Doc.checkDisk }
    if ($null -ne $Doc.checkNet) { $Cfg.checkNet = [bool]$Doc.checkNet }
    if ($null -ne $Doc.cpuStepPercent) { $Cfg.cpuStepPercent = [int]$Doc.cpuStepPercent }
    if ($null -ne $Doc.diskStepPercent) { $Cfg.diskStepPercent = [int]$Doc.diskStepPercent }
    if ($null -ne $Doc.netStepKBps) { $Cfg.netStepKBps = [int]$Doc.netStepKBps }
    if ($Cfg.cpuStepPercent -lt 1) { $Cfg.cpuStepPercent = 1 }
    if ($Cfg.cpuStepPercent -gt 50) { $Cfg.cpuStepPercent = 50 }
    if ($Cfg.diskStepPercent -lt 1) { $Cfg.diskStepPercent = 1 }
    if ($Cfg.diskStepPercent -gt 50) { $Cfg.diskStepPercent = 50 }
    if ($Cfg.netStepKBps -lt 1) { $Cfg.netStepKBps = 1 }
    if ($Cfg.netStepKBps -gt 200) { $Cfg.netStepKBps = 200 }
    return $Cfg
}

function Get-QuietConfig {
    if ($null -ne $script:QuietConfig) { return $script:QuietConfig }
    [void](Read-AppSettingsFile)
    return $script:QuietConfig
}

function Save-QuietConfig {
    if (-not $script:AppSettingsLoaded) { [void](Read-AppSettingsFile) }
    if ($script:state) {
        Write-AppSettingsFile -State $script:state
    }
    else {
        Write-AppSettingsFile
    }
}

function Get-QuietStep {
    param(
        [ValidateSet("cpu", "disk", "net")]
        [string]$Kind
    )
    $cfg = Get-QuietConfig
    if ($Kind -eq "cpu") { return [int]$cfg.cpuStepPercent }
    if ($Kind -eq "disk") { return [int]$cfg.diskStepPercent }
    return [int]$cfg.netStepKBps
}

function Set-QuietBusyLimit {
    param(
        [ValidateSet("cpu", "disk", "net")]
        [string]$Kind,
        [int]$Delta
    )
    $cfg = Get-QuietConfig
    $step = Get-QuietStep -Kind $Kind
    if ($Delta -lt 0) { $step = -$step }
    if ($Kind -eq "cpu") {
        $cfg.cpuBusyPercent = [math]::Min(90, [math]::Max(5, [int]$cfg.cpuBusyPercent + $step))
    }
    elseif ($Kind -eq "disk") {
        $cfg.diskBusyPercent = [math]::Min(90, [math]::Max(5, [int]$cfg.diskBusyPercent + $step))
    }
    else {
        $cfg.netBusyKBps = [math]::Min(2000, [math]::Max(5, [int]$cfg.netBusyKBps + $step))
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
    # Seconds we have been watching an idle machine without a break in sampling. Read
    # from a timestamp so a slow tick can never make it lag behind the clock.
    $windowSec = 0
    $windowFull = $false
    if ($script:QuietWindowStartUtc -ne [datetime]::MinValue) {
        $windowSec = [int][math]::Floor(([datetime]::UtcNow - $script:QuietWindowStartUtc).TotalSeconds)
        $windowFull = ($windowSec -ge [int]$script:QuietWindowSeconds)
    }
    $waiting = $null
    $busyNow = $false
    $anyCheck = [bool]$cfg.checkCpu -or [bool]$cfg.checkDisk -or [bool]$cfg.checkNet
    if ($anyCheck) {
        if ([bool]$cfg.checkCpu -and $null -ne $script:LastCpu -and $script:LastCpu -ge $cfg.cpuBusyPercent) { $waiting = "CPU"; $busyNow = $true }
        elseif ([bool]$cfg.checkDisk -and $null -ne $script:LastDisk -and $script:LastDisk -ge $cfg.diskBusyPercent) { $waiting = "disk"; $busyNow = $true }
        elseif ([bool]$cfg.checkNet -and $null -ne $script:LastNetKBps -and $script:LastNetKBps -ge $cfg.netBusyKBps) { $waiting = "net"; $busyNow = $true }
        elseif (-not $windowMet -or -not $windowFull) { $waiting = "quiet" }
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
        windowFull          = $windowFull
        busyNow             = $busyNow
        quietWindowSec      = $windowSec
        quietWindowNeedSec  = [int]$script:QuietWindowSeconds
        waiting             = $waiting
    }
}

function Update-QuietSample {
    param(
        [int]$WindowSeconds = 10,
        [bool]$InputIsIdle = $true
    )
    $script:QuietWindowSeconds = [math]::Max(5, $WindowSeconds)
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
    if (-not $InputIsIdle) {
        $script:LastIdleResetReason = Get-InputResetReasonText
        $script:QuietSamples.Clear()
        $script:QuietWindowStartUtc = $now
        $script:LastSampleStampUtc = $now
        return Get-QuietStatus -WindowSeconds $WindowSeconds
    }
    # A break in sampling (pause, resume from suspend, a stalled tick) leaves no evidence
    # for that stretch, so drop the stale samples and start the window over.
    if ($null -ne $script:LastSampleStampUtc -and ($now - $script:LastSampleStampUtc).TotalSeconds -gt 5) {
        $script:QuietSamples.Clear()
        $script:QuietWindowStartUtc = $now
    }
    if ($script:QuietWindowStartUtc -eq [datetime]::MinValue) { $script:QuietWindowStartUtc = $now }
    $script:LastSampleStampUtc = $now
    [void]$script:QuietSamples.Add([pscustomobject]@{
        Utc   = $now
        Cpu   = $busy.Cpu
        Disk  = $busy.Disk
        Quiet = $sampleQuiet
    })
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
    $choice = Get-ChosenSettings -Settings $Settings
    if ($null -ne $choice -and $null -ne $choice.powerSources) {
        $raw = @(Convert-ToStringArray $choice.powerSources)
        return @($raw | Where-Object { $_ -eq "AC" -or $_ -eq "DC" })
    }
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
    $choice = Get-ChosenSettings -Settings $Settings
    $selected = Convert-ToStringArray $choice.networkProfiles
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
            [void]$labels.Add("$profile $(Get-UiText Yes)")
        }
        else {
            [void]$labels.Add("$profile $(Get-UiText No)")
        }
    }
    return @($labels)
}

function Convert-NetworkMapFromDoc {
    param($Doc)
    $map = [ordered]@{}
    $defs = Get-DefinitionSettings -Doc $Doc
    if (-not $defs) { $defs = $Doc }
    $src = $null
    if ($defs -and $defs.network) { $src = $defs.network }
    if ($src) {
        foreach ($prop in $src.PSObject.Properties) {
            $ssids = @($prop.Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
            if ($ssids.Count -gt 0) { $map[$prop.Name] = @($ssids) }
        }
    }
    if ($map.Count -eq 0) {
        return [ordered]@{
            Home = @("ExampleHomeSSID")
            Work = @("ExampleWorkSSID")
        }
    }
    return $map
}

function Convert-PresetsFromDoc {
    param($Doc)
    $list = New-Object System.Collections.Generic.List[object]
    $defs = Get-DefinitionSettings -Doc $Doc
    if (-not $defs) { $defs = $Doc }
    $raw = $null
    if ($defs -and $defs.presets) { $raw = $defs.presets }
    foreach ($p in @($raw)) {
        if ($null -eq $p) { continue }
        $sec = [int]$p.seconds
        if ($sec -lt 10 -or $sec -gt 14400) { continue }
        $label = [string]$p.label
        if (-not $label) { $label = Format-IdleDuration -Seconds $sec }
        [void]$list.Add([pscustomobject]@{ label = $label; seconds = $sec })
    }
    if ($list.Count -gt 0) { return $list.ToArray() }
    return $null
}

function Read-AppSettingsFile {
    $cfg = Get-DefaultQuietConfig
    $presets = $null
    $doc = $null
    if (Test-Path -LiteralPath $script:SettingsPath) {
        $doc = Read-JsonFile -Path $script:SettingsPath
    }
    $defs = Get-DefinitionSettings -Doc $doc
    $choice = Get-ChosenSettings -Settings $doc
    if ($defs -and (Get-ObjectProperty $defs "quiet")) {
        $cfg = Apply-QuietDoc -Doc $defs.quiet -Cfg $cfg
    }
    if ($choice) {
        $cfg = Apply-QuietDoc -Doc $choice -Cfg $cfg
    }
    if ($choice -and (Get-ObjectProperty $choice "quiet")) {
        $cfg = Apply-QuietDoc -Doc $choice.quiet -Cfg $cfg
    }
    $presets = Convert-PresetsFromDoc -Doc $doc
    if (-not $presets) { $presets = Get-DefaultIdlePresets }
    $script:QuietConfig = $cfg
    $script:IdlePresets = @($presets)
    $script:NetworkProfileMap = Convert-NetworkMapFromDoc -Doc $doc
    $script:AppSettingsCache = $doc
    $script:AppSettingsLoaded = $true
    return $doc
}

function New-ChosenWriteObject {
    param(
        $Source,
        [string]$Name,
        $Cfg
    )
    $quietFromCaller = $null -ne $Cfg
    if ($null -eq $Cfg) { $Cfg = Get-DefaultQuietConfig }
    $idleSec = 600
    $requireQuiet = $true
    $power = @()
    $profiles = @()
    $action = "hibernate"
    if ($Source) {
        $idleSec = Get-IdleSecondsFromSettings -Settings $Source
        $rq = Get-ObjectProperty $Source "requireQuiet"
        if ($null -ne $rq) { $requireQuiet = [bool]$rq }
        $power = @(Get-SelectedPowerSources -Settings $Source)
        $profiles = @(Convert-ToStringArray (Get-ObjectProperty $Source "networkProfiles"))
        $action = Get-NormalizedAction -Settings $Source
        if (-not $quietFromCaller) {
            $quietDoc = Get-ObjectProperty $Source "quiet"
            if ($quietDoc) { $Cfg = Apply-QuietDoc -Doc $quietDoc -Cfg $Cfg }
            $Cfg = Apply-QuietDoc -Doc $Source -Cfg $Cfg
        }
    }
    $reasons = Get-IdleResetReasons -Settings $Source
    $quiet = [ordered]@{
        minQuietRatio   = [double]$Cfg.minQuietRatio
        cpuBusyPercent  = [int][math]::Round([double]$Cfg.cpuBusyPercent, 0)
        diskBusyPercent = [int][math]::Round([double]$Cfg.diskBusyPercent, 0)
        netBusyKBps     = [int][math]::Round([double]$Cfg.netBusyKBps, 0)
        checkCpu        = [bool]$Cfg.checkCpu
        checkDisk       = [bool]$Cfg.checkDisk
        checkNet        = [bool]$Cfg.checkNet
    }
    return [ordered]@{
        name            = $Name
        idleSeconds     = $idleSec
        requireQuiet    = [bool]$requireQuiet
        action          = $action
        powerSources    = @($power)
        networkProfiles = @($profiles)
        resetReasons    = [ordered]@{
            keyboard = [bool]$reasons.keyboard
            mouse    = [bool]$reasons.mouse
        }
        quiet           = $quiet
    }
}

function Write-AppSettingsFile {
    param($State)
    $cfg = $script:QuietConfig
    if ($null -eq $cfg) { $cfg = Get-DefaultQuietConfig }
    $presets = @($script:IdlePresets)
    if ($presets.Count -eq 0) { $presets = Get-DefaultIdlePresets }
    $network = [ordered]@{}
    foreach ($name in $script:NetworkProfileMap.Keys) {
        $network[$name] = @($script:NetworkProfileMap[$name])
    }
    $presetObjs = @()
    foreach ($p in $presets) {
        $presetObjs += [pscustomobject]@{
            label   = [string]$p.label
            seconds = [int]$p.seconds
        }
    }
    $doc = $script:AppSettingsCache
    $existing = @(Get-ChosenList -Doc $doc)
    $selectedName = Get-SelectedChosenName -Settings $(if ($State) { $State } else { $doc })
    $activeSource = $State
    if (-not $activeSource) { $activeSource = Get-ChosenSettings -Settings $doc }
    $active = New-ChosenWriteObject -Source $activeSource -Name $selectedName -Cfg $cfg

    $chosenOut = New-Object System.Collections.Generic.List[object]
    $replaced = $false
    $i = 0
    foreach ($item in $existing) {
        $itemName = Get-ChosenName -Choice $item -Index $i
        if (-not $replaced -and (Test-NameEquals $itemName $selectedName)) {
            [void]$chosenOut.Add($active)
            $replaced = $true
        }
        else {
            $itemCfg = Get-DefaultQuietConfig
            $itemCfg = Apply-QuietDoc -Doc $item -Cfg $itemCfg
            $itemQuiet = Get-ObjectProperty $item "quiet"
            if ($itemQuiet) { $itemCfg = Apply-QuietDoc -Doc $itemQuiet -Cfg $itemCfg }
            [void]$chosenOut.Add((New-ChosenWriteObject -Source $item -Name $itemName -Cfg $itemCfg))
        }
        $i++
    }
    if (-not $replaced -and $chosenOut.Count -eq 0) {
        [void]$chosenOut.Add($active)
    }

    $debugMode = Get-DebugModeEnabled -Settings $(if ($State) { $State } else { $doc })
    $autoSwitch = Get-AutoSwitchEnabled -Settings $(if ($State) { $State } else { $doc })
    $warnSeconds = Get-WarnSeconds -Settings $(if ($State) { $State } else { $doc })
    $debugRetentionHours = Get-DebugRetentionHours -Settings $(if ($State) { $State } else { $doc })
    $debugFlushSeconds = Get-DebugFlushSeconds -Settings $(if ($State) { $State } else { $doc })
    $language = Get-UiLanguageCode -Settings $(if ($State) { $State } else { $doc })

    $defQuiet = [ordered]@{
        cpuStepPercent  = [int]$cfg.cpuStepPercent
        diskStepPercent = [int]$cfg.diskStepPercent
        netStepKBps     = [int]$cfg.netStepKBps
    }
    $definitions = [ordered]@{
        network             = [pscustomobject]$network
        presets             = @($presetObjs)
        quiet               = $defQuiet
        language            = $language
        debugMode           = [bool]$debugMode
        autoSwitch          = [bool]$autoSwitch
        warnSeconds         = [int]$warnSeconds
        debugRetentionHours = [int]$debugRetentionHours
        debugFlushSeconds   = [int]$debugFlushSeconds
        selected            = $selectedName
    }
    $payload = [ordered]@{
        definitions = $definitions
        chosen      = @($chosenOut.ToArray())
    }
    (ConvertTo-JsoncText -Value $payload -Comments $script:JsoncLineComments) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    $script:AppSettingsCache = Read-JsonFile -Path $script:SettingsPath
}

function Get-NetworkProfileMenuLabel {
    param([string]$Name)
    $ssids = @($script:NetworkProfileMap[$Name])
    if ($ssids.Count -eq 0) { return $Name }
    return "$Name ($($ssids -join " $(Get-UiText Or) "))"
}

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
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return ConvertFrom-JsoncText -Text $raw
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
        return (Get-UiText NoMatchingProfile)
    }
    if ($matched.Count -gt 0) { return ($matched -join ", ") }
    if ($ConnectedNames.Count -gt 0) { return $ConnectedNames[0] }
    return (Get-UiText NoProfile)
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
    $choice = Get-ChosenSettings -Settings $Settings
    $quietRequired = $true
    if ($null -ne $choice -and $null -ne $choice.requireQuiet) { $quietRequired = [bool]$choice.requireQuiet }
    if (-not (Test-AnyQuietMetricEnabled)) { $quietRequired = $false }
    # Tolerate brief spikes over the window (minQuietRatio), but never suspend while a
    # metric is over its limit right now, and not before the window has actually elapsed.
    $quietMet = (-not $quietRequired) -or ([bool]$quiet.windowMet -and [bool]$quiet.windowFull -and -not [bool]$quiet.busyNow)
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
        appVersion       = $script:AppVersion
        appHash          = $script:AppSourceHash
        idleSeconds      = $needSec
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
        quietWindowSec   = $quiet.quietWindowSec
        quietWindowNeed  = $quiet.quietWindowNeedSec
        quietWindowMet   = [bool]$quiet.windowMet
        quietWindowFull  = [bool]$quiet.windowFull
        quietBusyNow     = [bool]$quiet.busyNow
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

function Get-IdleDebugStatusLog {
    $doc = Read-JsonFile -Path $script:DebugStatusJsonPath
    if (-not $doc) { return @() }
    if ($doc.items) { return @(Convert-ToObjectArray $doc.items) }
    if ($doc.at) { return @($doc) }
    return @()
}

function Write-IdleDebugStatus {
    param($Evaluation, $Settings)
    if (Get-Command Add-DebugSample -ErrorAction SilentlyContinue) {
        Add-DebugSample -Evaluation $Evaluation
        if ($Evaluation -and ($Evaluation.willProceed -or $Evaluation.willHibernate)) {
            if (Get-Command Save-DebugSampleBuffer -ErrorAction SilentlyContinue) {
                Save-DebugSampleBuffer -Settings $Settings
            }
        }
    }
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
    if (-not $profile) { $profile = Get-UiText NoProfile }
    $action = Get-ActionLabel -Action $Entry.action
    return "$when  $action  $profile"
}

function Format-MetLabel {
    param([bool]$Met)
    if ($Met) { return Get-UiText Met }
    return Get-UiText NotMet
}

function Test-DebugMetricUnderLimit {
    param($Actual, $Limit)
    if ($null -eq $Actual -or $null -eq $Limit) { return $false }
    return ([double]$Actual -lt [double]$Limit)
}

function Format-DebugText {
    param($Evaluation)
    if (-not $Evaluation) {
        return Get-UiText DebugNone
    }
    $when = Format-LocalWhen -Value $Evaluation.at -Pattern "dd-MM-yyyy HH:mm:ss"
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add((Get-UiText DebugIdleHit $when))
    if ($Evaluation.willProceed -or $Evaluation.willHibernate) {
        [void]$lines.Add((Get-UiText DebugResult (Get-ActionLabel -Action $Evaluation.action)))
    }
    else {
        [void]$lines.Add((Get-UiText DebugResult (Get-UiText DebugBlocked)))
    }
    if ($Evaluation.appVersion -or $Evaluation.appHash) {
        $ver = [string]$Evaluation.appVersion
        if (-not $ver) { $ver = "?" }
        $hash = [string]$Evaluation.appHash
        if ($hash) {
            [void]$lines.Add((Get-UiText DebugVersion $ver ($hash.Substring(0, [math]::Min(7, $hash.Length)))))
        }
        else {
            [void]$lines.Add((Get-UiText Version $ver))
        }
    }
    [void]$lines.Add("")
    $actual = "?"
    if ($null -ne $Evaluation.idleMs) {
        $actual = Format-IdleDurationWithSeconds -Seconds ([int][math]::Floor(([double]$Evaluation.idleMs) / 1000.0))
    }
    $idleLabel = $null
    if ($null -ne $Evaluation.idleSeconds) {
        $idleLabel = Format-IdleDurationWithSeconds -Seconds ([int]$Evaluation.idleSeconds)
    }
    elseif ($Evaluation.idleLabel) {
        $idleLabel = [string]$Evaluation.idleLabel
    }
    else {
        $idleLabel = Format-IdleDurationWithSeconds -Seconds (Get-IdleSecondsFromSettings -Settings $Evaluation)
    }
    [void]$lines.Add((Get-UiText DebugIdleLine $idleLabel (Format-MetLabel ([bool]$Evaluation.idleHit)) $actual))
    if ($Evaluation.paused) {
        [void]$lines.Add((Get-UiText DebugPausedOn))
    }
    else {
        [void]$lines.Add((Get-UiText DebugPausedOff))
    }
    $actualPower = "?"
    if ($null -ne $Evaluation.acMet) {
        if ([bool]$Evaluation.acMet) { $actualPower = Get-PowerSourceLabel "AC" } else { $actualPower = Get-PowerSourceLabel "DC" }
    }
    if ($null -ne $Evaluation.powerRequired -or $null -ne $Evaluation.powerSources) {
        $powerSources = @(Convert-ToStringArray $Evaluation.powerSources)
        if (-not [bool]$Evaluation.powerRequired -and $powerSources.Count -eq 0) {
            [void]$lines.Add((Get-UiText DebugPowerNotRequired $actualPower))
        }
        else {
            if ($powerSources -contains "AC") {
                [void]$lines.Add((Get-UiText DebugPowerSource (Get-PowerSourceLabel "AC") (Format-MetLabel ([bool]$Evaluation.acMet)) $actualPower))
            }
            if ($powerSources -contains "DC") {
                [void]$lines.Add((Get-UiText DebugPowerSource (Get-PowerSourceLabel "DC") (Format-MetLabel (-not [bool]$Evaluation.acMet)) $actualPower))
            }
        }
    }
    elseif ($Evaluation.acRequired) {
        [void]$lines.Add((Get-UiText DebugPowerSource (Get-PowerSourceLabel "AC") (Format-MetLabel ([bool]$Evaluation.acMet)) $actualPower))
    }
    else {
        [void]$lines.Add((Get-UiText DebugPowerNotRequired $actualPower))
    }
    if ($Evaluation.quietRequired) {
        [void]$lines.Add((Get-UiText DebugQuietRequired (Format-MetLabel ([bool]$Evaluation.quietMet))))
        if ($Evaluation.checkCpu) {
            $cpu = "?"
            if ($null -ne $Evaluation.cpuPercent) { $cpu = [math]::Round([double]$Evaluation.cpuPercent, 0).ToString() + "%" }
            [void]$lines.Add((Get-UiText DebugCpuActual $cpu $Evaluation.cpuLimit (Format-MetLabel (Test-DebugMetricUnderLimit $Evaluation.cpuPercent $Evaluation.cpuLimit))))
        }
        else {
            [void]$lines.Add((Get-UiText DebugCpuNotChecked))
        }
        if ($Evaluation.checkDisk) {
            $disk = "?"
            if ($null -ne $Evaluation.diskPercent) { $disk = [math]::Round([double]$Evaluation.diskPercent, 0).ToString() + "%" }
            [void]$lines.Add((Get-UiText DebugDiskActual $disk $Evaluation.diskLimit (Format-MetLabel (Test-DebugMetricUnderLimit $Evaluation.diskPercent $Evaluation.diskLimit))))
        }
        else {
            [void]$lines.Add((Get-UiText DebugDiskNotChecked))
        }
        if ($Evaluation.checkNet) {
            $net = "?"
            if ($null -ne $Evaluation.netKBps) { $net = (Format-KBpsValue ([double]$Evaluation.netKBps)) + " KB/s" }
            [void]$lines.Add((Get-UiText DebugNetActual $net $Evaluation.netLimitKBps (Format-MetLabel (Test-DebugMetricUnderLimit $Evaluation.netKBps $Evaluation.netLimitKBps))))
        }
        else {
            [void]$lines.Add((Get-UiText DebugNetNotChecked))
        }
        $ratioPct = 0
        $minPct = 0
        if ($null -ne $Evaluation.quietRatio) { $ratioPct = [int][math]::Round(100.0 * [double]$Evaluation.quietRatio, 0) }
        if ($null -ne $Evaluation.quietMinRatio) { $minPct = [int][math]::Round(100.0 * [double]$Evaluation.quietMinRatio, 0) }
        $samplesMet = $false
        if ($null -ne $Evaluation.quietWindowMet) {
            $samplesMet = [bool]$Evaluation.quietWindowMet
        }
        elseif ($null -ne $Evaluation.quietRatio -and $null -ne $Evaluation.quietMinRatio) {
            $samplesMet = ([double]$Evaluation.quietRatio -ge [double]$Evaluation.quietMinRatio)
        }
        $needSec = 0
        $haveSec = 0
        if ($null -ne $Evaluation.quietWindowNeed) { $needSec = [int]$Evaluation.quietWindowNeed }
        if ($null -ne $Evaluation.quietWindowSec) { $haveSec = [int]$Evaluation.quietWindowSec }
        $windowMet = $false
        if ($null -ne $Evaluation.quietWindowFull) {
            $windowMet = [bool]$Evaluation.quietWindowFull
        }
        elseif ($needSec -gt 0) {
            $windowMet = ($haveSec -ge $needSec)
        }
        [void]$lines.Add((Get-UiText DebugQuietRatioWindow (Format-MetLabel ($samplesMet -and $windowMet))))
        [void]$lines.Add((Get-UiText DebugQuietSamples $ratioPct $minPct (Format-MetLabel $samplesMet)))
        [void]$lines.Add((Get-UiText DebugQuietWindow $haveSec $needSec (Format-MetLabel $windowMet)))
    }
    else {
        [void]$lines.Add((Get-UiText DebugQuietNotRequired))
    }
    $selected = @(Convert-ToStringArray $Evaluation.selectedProfiles)
    $matched = @(Convert-ToStringArray $Evaluation.matchedProfiles)
    $connected = @(Convert-ToStringArray $Evaluation.connected)
    $actualNet = Get-UiText None
    if ($connected.Count -gt 0) { $actualNet = ($connected -join ", ") }
    if ($selected.Count -eq 0) {
        [void]$lines.Add((Get-UiText DebugNetworkNotRequired $actualNet))
    }
    else {
        # Any one selected profile matching is enough, so the group line carries the verdict
        # while the rows below show which profile supplied it.
        [void]$lines.Add((Get-UiText DebugNetworkRequired (Format-MetLabel ([bool]$Evaluation.networkMet)) $actualNet))
        foreach ($profile in $selected) {
            $ssids = @($script:NetworkProfileMap[$profile]) -join " $(Get-UiText Or) "
            [void]$lines.Add((Get-UiText DebugNetworkProfile $profile $ssids (Format-MetLabel ($matched -contains $profile))))
        }
    }
    return ($lines -join [Environment]::NewLine)
}
