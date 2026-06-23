# Optimization suite — design

Adds a Windows **optimization** engine and a single interactive **menu** front door to the
existing cleanup engine. One command opens a menu; from there the user reaches a detailed
cleanup screen, an optimization screen, undo, restore point, and reports.

## Goals

- One entry point: `.\WinSenior.ps1` → menu → cleanup / optimization / undo / reports.
- Optimization covers four areas: Performance, Privacy/telemetry, Debloat (UWP), Network/games.
- Every tweak is **reversible**: a per-tweak backup manifest is written before applying, and
  `-Undo` restores prior state. A real restore point is created first as a second safety net.
- Same proven architecture as cleanup: declarative registry, real `-WhatIf` via
  `SupportsShouldProcess`, risk tiers, JSON report, standalone-runnable for automation.

## Files

| File | Role |
|------|------|
| `Cleanup-Windows-Senior.ps1` | Existing cleanup engine. Unchanged; already dot-source-safe. |
| `Optimize-Windows-Senior.ps1` | New optimization engine: tweak registry + apply / preview / **undo**. Standalone-runnable. |
| `WinSenior.ps1` | New interactive menu. Borrows both registries for display; runs engines as child invocations. |

The menu reuses each engine by invoking the script file with parameters (`& $engine @params`),
so execution always goes through the engine's own tested parameter binding and scope. An exact
per-task / per-tweak selection is realized with `-Include <on>` + `-Exclude <off>`.

## Optimization engine

Each tweak is one declarative record (`Id, Name, Area, Risk, DefaultOn, Type, Spec`). Types:

- **Registry** — `Path` + one or more `Values` (`Name/Kind/Value`). Generic backup/apply/undo.
- **Service** — `Service` + desired `Startup` (Disabled/Manual). Backup captures StartType+Status.
- **ScheduledTask** — disable a list of tasks. Backup captures each task's State.
- **Custom** — `Test` / `Backup` / `Apply` / `Undo` scriptblocks for Appx removal, power scheme,
  hibernation, and Nagle (multi-interface). Backup output is plain data; undo is looked up by Id
  in the freshly loaded registry, so it round-trips through the JSON manifest.

### Backup & undo

Before each change the engine snapshots current state into
`%ProgramData%\WinSenior\backups\optimize-backup-<timestamp>.json`. `-Undo` reads the newest
(or a named) manifest and reverts each tweak in reverse order. Registry/Service/ScheduledTask
restore generically from the snapshot; Custom tweaks are reverted by their `Undo` scriptblock.
Appx removal is **partially irreversible** — undo re-provisions where the package source is still
present, otherwise the manifest lists what to reinstall from the Store.

### Risk tiers & defaults

Mirror cleanup: Safe + Moderate + Aggressive selectable by default, Dangerous behind
`-IncludeDangerous`, `-Conservative` caps at Moderate. Debatable tweaks (SysMain/Windows Search
off, Ultimate power plan, Xbox/comms debloat, Nagle, NDU) ship `DefaultOn = $false` — allowed by
tier but off until the user toggles or `-Include`s them.

### Safety boundaries

Does not touch Defender real-time protection, does not break Windows Update or the network stack
wholesale, does not remove Edge/Store. A restore point precedes any apply unless `-NoRestorePoint`
or `-WhatIf`.

### Parameters

`-Area`, `-Include`, `-Exclude`, `-IncludeDangerous`, `-Conservative`, `-Undo`,
`-BackupManifest`, `-WhatIf`/`-DryRun`, `-Unattended`/`-Force`, `-NoRestorePoint`, `-BackupDir`,
`-LogPath`, `-ReportPath`, `-ListTweaks`, `-Help`.

## Menu (`WinSenior.ps1`)

Numbered navigation (robust across conhost / Windows Terminal, PS 5.1 and 7). Requires admin;
offers elevation if not. Screens: detailed cleanup (toggle categories/tasks → preview/run),
optimization (pick area → toggle tweaks showing applied/not state → preview/apply/undo), full
run, undo optimizations, create restore point, reports/list.

## Tweak coverage (~28)

- **Performance** — visual effects → best performance, MenuShowDelay 0, startup delay 0,
  High-Performance power plan; (off by default) Ultimate plan, SysMain off, Windows Search off,
  hibernation off, background apps off.
- **Privacy** — telemetry policy 0, advertising ID off, consumer features off, tips/suggestions
  off, activity feed off, web search in Start off, Cortana policy off; DiagTrack + dmwappushservice
  disabled; CEIP/telemetry scheduled tasks disabled.
- **Debloat** — curated junk UWP removal (default on); Xbox apps, comms apps (off by default);
  Start-menu app suggestions off.
- **Network/games** — GameDVR off, Game Mode on, network throttling off / SystemResponsiveness 0;
  (off by default) Nagle off, NDU service off.

## Tests

Pester 5 on pure logic: tweak-registry integrity (unique ids, known areas/risks/types),
`Resolve-TweakSelection` (defaults, tiers, include/exclude), and a registry backup→apply→undo
round-trip against a throwaway `HKCU:\Software\WinSeniorTest` hive. The menu stays thin; logic
lives in tested functions. CI runs on windows-latest.
