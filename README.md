# IdleHibernate

A Windows tray app that hibernates or sleeps the PC after it has been idle long enough, with optional gates for power source, Wi‑Fi, and a quiet machine (CPU / disk / network).

It is a PowerShell 5.1 WinForms tray icon. Settings live in `settings.json` next to the scripts (that file is gitignored). Runtime logs live under `%LOCALAPPDATA%\IdleHibernate`.

## Requirements

- Windows with PowerShell 5.1
- `lib\Newtonsoft.Json.dll` next to the scripts (used to read JSON with comments)
- `lib\sqlite3.dll` (bundled) for the debug sample database

## Start

Hidden start (no console window):

```text
wscript.exe "C:\Users\Jan\Scripts\IdleHibernate\StartTray.vbs"
```

`StartTray.vbs` hardcodes the path to `IdleHibernateTray.ps1`. Change that path if you move the folder.

Only one tray instance runs at a time. Use **Restart tray icon** in the menu after you edit the scripts.

To run at logon, put a shortcut to `StartTray.vbs` in the Startup folder (`shell:startup`).

## Tray

- **Left-click** pauses or resumes. Pause is a flag file (`%LOCALAPPDATA%\IdleHibernate\paused`), so it survives a tray restart.
- **Right-click** opens the menu. Most toggles keep the menu open; a click outside it closes it.

The icon is green when idle action is armed, orange when paused. The tooltip shows the idle duration, action, and which gates currently pass.

### Menu

| Item | What it does |
| --- | --- |
| Pause / Resume | Same as left-click |
| **Config: …** | Named setting bundles. **Auto-switch config** picks a config when you join a Wi‑Fi that belongs to one. |
| Idle timer | Live remaining time, plus increase / decrease and presets |
| Power | Require plugged in (AC) and/or on battery (DC). None selected = any power source. |
| Quiet PC | Require a quiet machine before the action fires (see below) |
| Network | Require one of the named Wi‑Fi profiles. None selected = any network. Matching **any** selected profile is enough. |
| Action | Hibernate or sleep |
| Last actions | Recent suspends |
| Debug last idle check | Last evaluations; **Debug mode** records samples to SQLite; **Open dashboard** shows them |
| Language | English or Nederlands |
| Version / source hash | Build label and a short hash of the scripts this process loaded |
| Show settings file | Opens `settings.json` |

Idle time is keyboard/mouse idle, clamped across hibernate/sleep so a stale pre-suspend idle clock cannot fire again immediately on wake.

## When the action fires

All of these must be true:

1. Not paused
2. Idle for at least the configured duration
3. Power source allowed (if any are selected)
4. Network allowed (if any profiles are selected)
5. Quiet PC satisfied (if required)

Quiet PC, when required, needs:

- The quiet **window** has lasted at least as long as the idle timer
- At least `minQuietRatio` of samples in that window were under the CPU / disk / net limits (default 90%)
- CPU, disk, and net are not over their limits **right now**

A sampling gap (pause, resume from suspend, a stalled tick) starts the quiet window over.

## Configs

`chosen` is an array of named configs. `definitions.selected` is the one in use. Changing the idle timer, quiet limits, power, network, or action writes to that config only. Language, debug mode, auto-switch, and retention stay in `definitions`.

**Auto-switch config** switches to the config whose `networkProfiles` match the current Wi‑Fi. An unknown network leaves the current config alone.

While auto-switch is on, each network (profile name, and SSID) may belong to only one config. The tray checks that at startup and when you enable the option; overlaps get a warning and auto-switch stays off.

Add or rename configs in `settings.json`. The Config menu only selects among names that are already there.

## Settings

`settings.json` is JSON with `//` comments. The tray rewrites it on save. Shared pieces live under `definitions`; per-config pieces live under `chosen`.

```jsonc
{
  "definitions": {
    "network": { "Home": ["ExampleHomeSSID"], "Work": ["ExampleWorkSSID"] },
    "presets": [ { "label": "5 min", "seconds": 300 } ],
    "quiet": { "cpuStepPercent": 5, "diskStepPercent": 5, "netStepKBps": 10 },
    "language": "en",                 // en, nl
    "debugMode": false,
    "autoSwitch": false,
    "debugRetentionHours": 1,         // 1–168
    "debugFlushSeconds": 30,          // 5–300; how often buffered samples are written
    "selected": "At home"
  },
  "chosen": [
    {
      "name": "At home",
      "idleSeconds": 600,             // 10–14400
      "requireQuiet": true,
      "action": "hibernate",          // hibernate | sleep
      "powerSources": ["AC"],         // AC, DC; empty = any
      "networkProfiles": ["Home"],    // names from definitions.network; empty = any
      "quiet": {
        "minQuietRatio": 0.9,
        "cpuBusyPercent": 35,
        "diskBusyPercent": 25,
        "netBusyKBps": 500,
        "checkCpu": true,
        "checkDisk": true,
        "checkNet": true
      }
    }
  ]
}
```

- `definitions.network` maps a profile name to one or more SSIDs (or connection profile names).
- `definitions.quiet` only holds the +/− step sizes in the menu. Limits and `minQuietRatio` are per config.
- An empty `powerSources` or `networkProfiles` array means “do not require that gate”.

If `settings.json` is missing, the tray starts with defaults and writes the file.

## Debug log

With **Debug mode** on, every ~10 seconds (and at the moment an action fires) the current evaluation is buffered in memory and written to SQLite every `debugFlushSeconds` (default 30). Remaining buffered rows are flushed when the tray exits or debug mode is turned off.

- `%LOCALAPPDATA%\IdleHibernate\debug.sqlite`

Older rows outside `debugRetentionHours` are deleted on each flush. **Open dashboard** starts a localhost page (`http://127.0.0.1:27182/`) that charts idle time, CPU, disk, and network from that database.

Other files in that folder: `history.json` (last actions), `debug-last.json` (last evaluation for the menu), `paused` (pause flag).
