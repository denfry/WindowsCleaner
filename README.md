# Windows System Cleaner and Optimizer 🧹

[![CI](https://github.com/denfry/WindowsCleaner/actions/workflows/ci.yml/badge.svg)](https://github.com/denfry/WindowsCleaner/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-6.0.0-blue.svg)](https://github.com/denfry/WindowsCleaner)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B%20%7C%207%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue.svg)](https://www.microsoft.com/windows/)

> A registry-driven Windows cleanup engine. Every operation is one declarative task;
> a small engine resolves what to run, reclaims disk space, and deletes through
> PowerShell's `ShouldProcess` — so **`-WhatIf` is real**, not a parallel code path.

It cleans 57 targets across browsers, developer tools, apps, games, system caches, every
local disk, logs, Windows Update, and driver leftovers — all from one declarative registry
with a real dry-run mode and a hard safety guard. A companion optimization engine applies
29 reversible system tweaks, a troubleshooting engine scans for 13 common problems and
repairs them, and a single menu ties everything together.

## One command — the menu

`WinSenior.ps1` is the single entry point. Run it (it self-elevates) and an interactive
menu opens with detailed screens for cleanup, optimization, troubleshooting, undo, a
restore point and a task/tweak/check listing. It drives all three engines, so every action
keeps real `-WhatIf`, the safety guard and per-tweak undo.

The menu is **arrow-key driven**: <kbd>↑</kbd>/<kbd>↓</kbd> move the highlight,
<kbd>Enter</kbd> selects, <kbd>Space</kbd> toggles a task/tweak on the detailed screens,
and <kbd>Esc</kbd> goes back. Add `-Plain` for terminals that can't render box-drawing
characters (ASCII `+ - |` borders instead).

```powershell
.\WinSenior.ps1
.\WinSenior.ps1 -Plain   # ASCII-only borders
```

## Highlights

- **One source of truth.** Every cleanup target is a single entry in a task registry
  (`-ListTasks` prints it). Adding a target is one line; nothing else to wire up.
- **Real `-WhatIf` / `-DryRun`.** Implemented through `SupportsShouldProcess`. Preview
  shows exactly what would be removed and reports honest would-free totals.
- **Real restore point.** `Checkpoint-Computer` actually creates a System Restore point
  (and clears the 24-hour throttle first) — non-interactive, safe for automation.
- **Honest accounting.** Reclaimed bytes are summed from items that were actually
  removed, not estimated and not counted from log lines.
- **A safety guard that can't be argued with.** `Test-SafeToDelete` refuses to operate on
  drive roots, `%WINDIR%`, `%USERPROFILE%`, `C:\Users`, `System32`, or any path shallower
  than two levels — defends against a bad registry entry or an unexpanded variable.
- **Risk tiers.** Safe / Moderate / Aggressive run by default; irreversible operations
  live in a Dangerous tier behind `-IncludeDangerous`.
- **~15 parameters** with short aliases, plus per-user (`<USER>`) and per-disk (`<DRIVE>`)
  path expansion.

## Quick start

```powershell
# Preview everything (no changes, real ShouldProcess)
.\Cleanup-Windows-Senior.ps1 -WhatIf

# Default aggressive cleanup, all users, with a real restore point first
.\Cleanup-Windows-Senior.ps1

# Just browser + developer-tool caches
.\Cleanup-Windows-Senior.ps1 -Category Browsers,DevTools

# Clean drive-level junk on specific local disks only
.\Cleanup-Windows-Senior.ps1 -Category Disks -Drives C,D

# Non-interactive for scheduled tasks / GPO / SCCM / Intune
.\Cleanup-Windows-Senior.ps1 -Unattended -NoRestorePoint -SkipOptimization

# Everything, including the irreversible tier, with a JSON report
.\Cleanup-Windows-Senior.ps1 -IncludeDangerous -ReportPath C:\Logs\clean.json

# One-time execution-policy bypass
powershell.exe -ExecutionPolicy Bypass -File .\Cleanup-Windows-Senior.ps1 -WhatIf
```

Run as Administrator. PowerShell 5.1+ (7+ recommended).

## Parameters

| Parameter | Alias | Effect |
|-----------|-------|--------|
| `-Category <names>` | | Limit to: Browsers, DevTools, Apps, Games, System, Disks, Logs, Updates, Optimization |
| `-Include <ids>` | | Force tasks on (ids from `-ListTasks`) — overrides category and risk cap |
| `-Exclude <ids>` | | Force tasks off — wins over everything |
| `-IncludeDangerous` | | Also run the irreversible tier (event logs, patch cache, Windows.old, old drivers) |
| `-Conservative` | `-SafeMode` | Cap at Safe + Moderate (skip Aggressive) |
| `-CurrentUserOnly` | `-cu` | Clean only the current profile (default: all users) |
| `-Drives <letters>` | | Local disks for drive-level cleanup, e.g. `-Drives C,D` (default: all local disks) |
| `-WhatIf` / `-DryRun` | `-dr` | Preview only, change nothing |
| `-Unattended` | `-Force`, `-f` | No prompts, no GUI — for automation |
| `-NoRestorePoint` | `-nrp` | Skip the restore point that is otherwise created first |
| `-SkipOptimization` | `-so` | Skip the slow SFC / DISM category |
| `-MaxAgeDays <n>` | | Only delete files older than n days |
| `-LogPath <path>` | | Text log (default `%TEMP%\WindowsCleanup.log`) |
| `-ReportPath <path>` | | Write a machine-readable JSON report |
| `-ListTasks` | | Print the task registry and exit |
| `-Help` | | Show usage |

## Risk tiers

| Tier | Runs by default? | Examples |
|------|------------------|----------|
| **Safe** | yes | browser caches, temp, thumbnails, dev/app/messenger caches, shader cache |
| **Moderate** | yes | recycle bin, crash dumps, font cache, WU download cache, DISM cleanup |
| **Aggressive** | yes | full SoftwareDistribution reset, prefetch, DISM `/ResetBase`, SFC |
| **Dangerous** | only with `-IncludeDangerous` | clear event logs, `$PatchCache$`, Windows.old, remove superseded drivers |

`-Conservative` lowers the default ceiling to Moderate. `-Include` can force any single
task on regardless of tier.

## What gets cleaned

`-ListTasks` shows the live list. Categories:

- **Browsers** — Chrome, Edge, Firefox, Opera, Yandex, Brave (all profiles, cache /
  code cache / GPU cache / service-worker cache).
- **DevTools** — npm, pip, Yarn, NuGet http cache, Gradle, VS Code, JetBrains
  (caches/logs/temp), Nuitka build cache, Go build cache, Dart/Flutter Pub cache,
  package-manager caches (winget, Chocolatey, Scoop, conda, cargo, Go module cache),
  `pnpm store prune`, and `docker system prune` (each skipped if the tool isn't installed).
- **Apps** — Windows app/UWP caches, Microsoft Teams (classic + new), Discord, Slack,
  Spotify, Office document/web cache, OneDrive logs, Adobe media & Camera Raw cache.
- **Games** — launcher caches for Steam (shader/http/html), Epic, Battle.net, GOG.
- **System** — user/Windows temp, WinINet cache, thumbnail & icon cache, GPU/D3D shader
  cache, GPU driver installer leftovers (NVIDIA/AMD), WebCache, Delivery Optimization,
  recent items, font cache, Windows logs, prefetch, and removal of superseded driver
  packages via pnputil (Dangerous; boot-critical and in-use drivers are never touched).
- **Logs** additions — setup logs (Panther/setupapi) and Defender scan history.
- **Disks** — drive-level cleanup across **every local disk** (C:, D:, E: …): per-drive
  `Temp`/`tmp` scratch folders and CHKDSK `FOUND.*` fragments. Recycle Bins on all drives
  are emptied by the Logs task. Restrict with `-Drives C,D`.
- **Logs** — Windows Error Reporting, crash & memory dumps, old IIS logs (>14 days),
  Recycle Bin (all drives), event-log clearing (Dangerous).
- **Updates** — Windows Update download cache (services stopped correctly), full
  SoftwareDistribution reset, patch cache (Dangerous), Windows.old & upgrade leftovers (Dangerous).
- **Optimization** — DISM analyze / component cleanup / reset base, StartComponentCleanup
  task, SFC. Skipped entirely with `-SkipOptimization`.

## Optimization

`Optimize-Windows-Senior.ps1` is a second registry-driven engine that changes Windows
settings instead of deleting files. Every tweak is one declarative entry; the engine
snapshots prior state into a backup manifest before applying, so `-Undo` reverts an entire
run. A real restore point is created first as a second safety net.

```powershell
# Preview every tweak (no changes, real ShouldProcess)
.\Optimize-Windows-Senior.ps1 -WhatIf

# Apply the default privacy + performance set
.\Optimize-Windows-Senior.ps1 -Area Privacy,Performance

# Revert the most recent run
.\Optimize-Windows-Senior.ps1 -Undo
```

It covers 29 tweaks across four areas:

- **Performance** — visual effects to best performance, zero menu/startup delay,
  High-Performance power plan, background apps off; (off by default) Ultimate plan,
  SysMain / Windows Search off, hibernation off.
- **Privacy** — telemetry policy, advertising ID, consumer features, tips/spotlight,
  activity feed, Start web search and Cortana off; DiagTrack and dmwappushservice disabled;
  CEIP / telemetry scheduled tasks off.
- **Debloat** — curated junk UWP removal (default on); Xbox and comms apps (off by default);
  Start-menu app suggestions off.
- **Network** — GameDVR off, Game Mode on, network-throttling and multimedia reservation off;
  (off by default) Nagle off, NDU service off.

Debatable tweaks ship off by default — allowed by their tier but only applied when you toggle
them on or `-Include` them. The engine never disables Defender real-time protection, never
breaks Windows Update or the network stack wholesale, and never removes Edge or the Store.
Removing UWP apps is partially irreversible; the manifest lists what to reinstall from the
Store. `-ListTweaks` prints the live list, and `-Undo` reverts a run from its backup manifest
(newest in `%ProgramData%\WinSenior\backups`, or a specific one with `-BackupManifest`).

## Troubleshooting

`Repair-Windows-Senior.ps1` is a third engine that diagnoses and repairs system health.
Every check is one declarative entry: a read-only scan that returns OK / Warn / Fail, and an
optional fix. The default flow is scan-then-choose — it scans (changing nothing), prints a
health report, and lets you pick which detected issues to repair. Fixes run through
`ShouldProcess` after a real restore point.

```powershell
# Scan, show the report, then choose what to repair
.\Repair-Windows-Senior.ps1

# Diagnose only - never change anything
.\Repair-Windows-Senior.ps1 -ScanOnly

# Non-interactive: auto-apply every fixable issue, including heavy repairs
.\Repair-Windows-Senior.ps1 -FixAll -IncludeHeavy -Unattended
```

It runs 13 checks across eight categories: system image health (DISM), physical disk SMART
health, low free space, volumes flagged for chkdsk, pending reboot, Windows Update components,
internet & DNS, devices with driver errors, stopped critical services, Microsoft Defender
health, WMI repository consistency, time synchronization, and recent critical/error events.

Heavy repairs (SFC, DISM RestoreHealth, Windows Update reset, network stack reset) are included
but only run when you select them, or pass `-FixAll -IncludeHeavy`. Repairs only ever improve
health — the engine *enables* Defender real-time protection, it never disables it. `-ListChecks`
prints the live list.

## Batch version

`Cleanup-Windows-Senior.bat` is the simple, dependency-free alternative. v6 brings it to
parity with the engine's defaults and fixes the old bugs (each browser flag is now
independent; real all-users iteration; Windows Update services stopped in the right order).
The Dangerous tier is behind `/IncludeDangerous`; a real restore point is opt-in via
`/RestorePoint`. Run `Cleanup-Windows-Senior.bat /?` for options. The PowerShell version is
recommended — it has real `-WhatIf`, finer control, and the safety guard.

```cmd
Cleanup-Windows-Senior.bat /DryRun
Cleanup-Windows-Senior.bat /CurrentUserOnly /nch /nff
Cleanup-Windows-Senior.bat /IncludeDangerous /RestorePoint
```

## Automation (GPO / SCCM / Intune / Task Scheduler)

The `-Unattended` switch makes the run fully non-interactive (no prompts, no GUI) — the
restore point is created programmatically with `Checkpoint-Computer`, so nothing blocks.

```powershell
# Startup script / scheduled task
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden `
  -File "C:\Scripts\Cleanup-Windows-Senior.ps1" -Unattended -SkipOptimization `
  -LogPath "C:\Logs\cleanup.log" -ReportPath "C:\Logs\cleanup.json"
```

Exit codes: `0` success, `2` administrator privileges required.

## Tests

The `tests\*.Tests.ps1` files cover the pure logic of all three engines — selection, the
safety guard, age filtering, formatting, `-WhatIf` accounting, a registry backup→apply→undo
round-trip against a throwaway hive, and the troubleshooter's scan/fix dispatch. Requires
Pester 5+:

```powershell
Invoke-Pester -Path .\tests
```

## Troubleshooting

- **"running scripts is disabled"** — `powershell.exe -ExecutionPolicy Bypass -File ...`
  or `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- **Restore point not created** — System Protection is off for the system drive. Enable it
  (`Enable-ComputerRestore -Drive "C:\"`) or run with `-NoRestorePoint`.
- **Some items report errors** — they were locked/in use (e.g. an open browser). Close the
  app and re-run; the engine counts these and continues.
- **Nothing happens** — check you ran as Administrator (exit code 2 otherwise).

## License

MIT © 2026 denfry. See [LICENSE](LICENSE).

## Author

**denfry** — [github.com/denfry](https://github.com/denfry)

---

### 🔒 Safety note

This tool deletes files and, in the Dangerous tier, makes irreversible changes. Always
start with `-WhatIf`. Keep the default restore point on for important systems. The authors
are not responsible for data loss from improper use — ensure you have backups.
