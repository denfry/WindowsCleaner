# Architecture

WinSenior is a set of PowerShell scripts. Three engines do the real work; the desktop app,
the console menu and the scheduled tasks only start them with parameters.

```
WinSenior.cmd ─┬─ WinSenior.Gui.ps1  (WPF window)
               └─ WinSenior.ps1      (console menu, -InstallSchedule)
                        │  child process, same parameters a user would type
        ┌───────────────┼────────────────┬──────────────────────────┐
Cleanup-Windows-  Optimize-Windows-  Repair-Windows-   WinSenior.Drivers / Apps /
Senior.ps1        Senior.ps1         Senior.ps1        Memory / Insights / Startup
        └───────────────┴────────────────┴──── WinSenior.Common.ps1 (shared helpers)
```

## Engines

Each engine holds a registry: a list of declarative entries built by one constructor.
The engine selects entries, runs them through `ShouldProcess` and writes a JSON report.

| Engine | Registry | Entry fields |
|---|---|---|
| Cleanup | `New-CleanupTask` × 110 | Id, Category, Risk, DefaultOn, Paths or Action, AgeDays, StopServices, Processes |
| Optimize | `New-RegTweak` / `New-SvcTweak` / `New-TaskTweak` / `New-CustomTweak` × 77 | Id, Area, Risk, DefaultOn, Spec (or Test/Backup/Apply/Undo blocks) |
| Repair | `New-DiagnosticCheck` × 43 | Id, Category, Scan, Fix, FixRisk, Reboot |

**Selection** is the same everywhere: the risk tier sets the ceiling (`-Conservative`,
`-IncludeDangerous`), `DefaultOn` picks the defaults, `-Include` forces entries on,
`-Exclude` wins over everything.

**Cleanup paths** use tokens: `<USER>` expands to every profile (or the current one with
`-CurrentUserOnly`), `<DRIVE>` to every local fixed disk, `<STEAM>` / `<STEAMLIB>` to Steam
folders. Every item passes `Test-SafeToDelete` before deletion. It refuses paths shallower
than `X:\a\b`, and any path that is, or contains, a protected folder: Windows, Program
Files, ProgramData, the Users folder, each profile and its known folders. Reparse points
are deleted as links and never followed. Locked files can be queued for deletion at reboot
(`-DeferLocked`, `MoveFileEx`).

**Optimize** snapshots the old value of every tweak into a manifest in
`%ProgramData%\WinSenior\backups` before applying it. `-Undo` replays a manifest in reverse.
Custom tweaks restore through their own `Undo` block, looked up by Id.

**Repair** scans first and changes nothing. `-FixAll` applies Safe and Moderate fixes;
`-IncludeHeavy` adds SFC, DISM RestoreHealth and the Windows Update and network resets.

## Tools

| Script | What it does | Source of truth |
|---|---|---|
| `WinSenior.Drivers.ps1` | GPU status, devices with errors, driver updates, backup | Microsoft Update API, `pnputil` |
| `WinSenior.Apps.ps1` | Inventory, uninstall, leftovers, updates, installs | Uninstall registry keys, Appx, `winget` |
| `WinSenior.Memory.ps1` | Finds idle processes that hold RAM and stops them | process tree, CPU over a sample window |
| `WinSenior.Insights.ps1` | Boot-time comparison, disk forecast, cleanup planning | event 100, recorded disk samples, `WinSenior.Stats.ps1` |
| `WinSenior.Startup.ps1` | Startup entries on/off | `Explorer\StartupApproved`, like Task Manager |

App leftovers have their own checks (`Get-WsLeftoverBlocker`) and go to a 30-day
quarantine. Uninstallers from HKCU entries run without elevation, because any program of
that user can write those keys.

## Desktop app

`WinSenior.Gui.ps1` is WPF: XAML in a here-string, code-behind in PowerShell. It
dot-sources the engines only to read their registries and the current tweak state. Every
action starts the engine as a child process with `-Include`/`-Exclude`, tails its output
into the log panel and reads the JSON report when the process exits. UI strings go through
`T '...'`; translations live in `WinSenior.Gui.<lang>.json`.

## Scheduled runs

`WinSenior.Schedule.ps1` copies the scripts to `%ProgramFiles%\WinSenior` (admins only) and
registers two tasks under `\WinSenior\` that run as SYSTEM from that copy. Running from the
user's own folder would let a non-admin process replace a script that SYSTEM executes.

## Tests

`tests\` holds Pester 5 suites for each script. They exercise selection, the safety
checks, `-WhatIf` accounting, a backup → apply → undo round-trip on a throwaway HKCU key,
scan and fix dispatch with synthetic checks, and the installer against a fake local
release. CI runs them with PSScriptAnalyzer on `windows-latest`.
