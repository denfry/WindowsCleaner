# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [6.3.0] - 2026-09-23

A correctness and safety release: every engine was audited against Microsoft's
documentation and the common ways cleaners and tweakers break Windows.

### Fixed
- **The desktop app ignored the tick-boxes.** It passed `-Include 'a,b,c'` through `-File`,
  which arrives as one string, so every run used the engine defaults. All engines now split
  comma-joined `-Include` / `-Exclude` (and `-Drives`, `-Area`).
- **No restore point under PowerShell 7** (the app's preferred host): `Checkpoint-Computer`
  does not exist there. Restore points now go through the `SystemRestore` WMI class on both
  hosts, and the 24-hour throttle value is put back afterwards instead of being left at 0.
- **Cleanup dry runs measured nothing for per-user paths**: `ForEach-Object <member>` is
  itself subject to `-WhatIf`, so `<USER>` expanded to nothing in preview mode.
- **Junctions / symlinks**: a link inside a cleaned folder is now removed as a link; its
  target is never enumerated, counted or queued for delete-at-reboot.
- **Age filter** works on files, not folders (a folder's timestamp does not change when a
  file deep inside it does, so fresh files could be deleted with `-MaxAgeDays`).
- Services stopped for a task also restart their **dependents** (`cryptsvc` → AppLocker's
  `AppIDSvc` stayed off until reboot); a task is skipped if its service refuses to stop.
- Native tools (DISM, sfc, powercfg, pnputil, wevtutil) are judged by **exit code**; failures
  were logged as success. 3010 = success, reboot required.
- The engine no longer deletes **its own log / report** or the desktop app's capture files
  out of `%TEMP%` mid-run.
- Browsers are closed **only in the current session**, and never by a silent scheduled run
  (`-CloseApps` makes that explicit; otherwise running browsers' caches are skipped).
- Recycle Bin is emptied for **every user on every disk** with byte accounting
  (`Clear-RecycleBin` only emptied the caller's bin — nothing when running as SYSTEM).
- Event-log archives go to `%ProgramData%\WinSenior\eventlogs` (the temp tasks deleted them)
  and a log is only cleared after a successful export.
- `shadow-old` only prunes system-drive restore-point shadows (it also deleted other
  volumes' and backup software's shadows); `old-drivers` groups by provider + class + inf.
- `gpu-leftovers` only targets installer extraction folders, not any `NVIDIA`/`AMD` folder
  on a data disk; `disk-temp` only removes week-old files.
- `cmd.exe` mis-resolved `call :label` in LF-only batch files (the `.bat` skipped Chrome and
  ran its tail twice); the release build now forces CRLF on scripts.
- Repair: `disk-dirty` flagged every volume (`fsutil dirty query` exits 0 either way),
  `def-signatures` never saw threats, `time-sync` used an invalid `w32tm` switch, ICMP being
  blocked triggered a full network reset, the hosts fix wiped the whole file, the BITS fix
  cancelled healthy jobs, and fixes were reported as *Fixed* without checking — every fix is
  now verified by re-scanning.
- Optimize: `TaskbarDa` (blocked by UCPD on current Windows 11) aborted the whole taskbar
  tweak; `SystemResponsiveness=0` is clamped to 20 by MMCSS; Teredo is disabled through its
  own policy instead of killing every IPv6 tunnel; the Ultimate plan no longer piles up a new
  copy per run; Appx debloat actually works under PowerShell 7; undo manifests are written
  after every tweak (a cancelled run stays undoable) and marked when undone.

### Changed (defaults, per Microsoft guidance)
- Off by default: Prefetch (slows the next boots), standby-memory purge, full
  SoftwareDistribution reset (wipes update history), BITS queue reset, Store reset,
  background-app block, WAP Push service, GameDVR policy, network throttling.
- `DISM /ResetBase` moved to the Dangerous tier (updates become permanently uninstallable);
  `/SPSuperseded` (Windows 7-era) removed. `catroot2` and Defender folders are no longer
  treated as cache. Recent items no longer wipes pinned jump lists / Quick Access pins
  (separate opt-in `jumplists` task). Update caches are skipped while an update waits for a reboot.
- Scheduled runs are installed into `%ProgramFiles%\WinSenior` (admins-only) instead of
  running a user-writable clone as SYSTEM, and keep one report per run.

### Added
- **One-line install** — `irm https://github.com/denfry/WindowsCleaner/releases/latest/download/install.ps1 | iex`
  downloads the latest release, verifies its SHA256, installs to `%LOCALAPPDATA%\WinSenior`,
  adds Start menu / desktop shortcuts and starts the app. Re-run to update; `-Uninstall`,
  `-NoLaunch`, `-Console`, `-NoShortcut` via the scriptblock form. Uses only .NET for
  download / hash / unzip, so it works on any Windows PowerShell 5.1 or PowerShell 7.
- **Cleanup 97 → 106:** Vivaldi, new Teams, WebView2 hosts (new Outlook, Widgets, Copilot),
  Office Click-to-Run update payloads, `Windows\SystemTemp`, upgrade-assistant leftovers,
  Chrome's 4 GB on-device AI model (opt-in), NuGet global packages (opt-in), jump lists
  (opt-in); Chromium shader/component/crash caches, Steam libraries on every disk
  (`libraryfolders.vdf`), nested LiveKernelReports dumps, legacy NVIDIA LocalLow caches;
  Delivery Optimization is emptied through `Delete-DeliveryOptimizationCache`.
- **Optimize 49 → 77:** Recall removal, Copilot app removal, Paint/Notepad AI, Bing search
  suggestions and search highlights, widgets/feeds/Meet Now policies, Edge startup boost /
  background mode / sidebar / shopping, Chrome on-device AI download block, language-list
  and settings-page ads, suggested actions, Sticky Keys prompt, End task in taskbar,
  Home/Gallery in Explorer, HAGS, power throttling, USB selective suspend, reserved storage
  and more (debatable ones off by default). Visual effects keep font smoothing.
- **Troubleshoot 25 → 43:** services disabled by tweak tools, Windows Update blocked by
  policy, update-failure history with per-error-code routing, broken Start/taskbar shell
  packages, WinRE disabled / recovery partition too small (0x80070643), Secure Boot 2023
  certificate status, page file, Winsock LSP, disabled network adapters, BitLocker
  suspended, UAC off, broken PATH/TEMP, Driver Verifier left on, activation, TRIM, root
  certificate updates, Search index health, suspicious Defender exclusions.
- **Desktop app:** Startup apps page (enable/disable exactly like Task Manager, fully
  reversible), History page with all-time total and HTML export, progress bar, filter box
  and sortable columns on every list, tooltips with paths / explanations, confirm dialogs
  before Clean and Apply, drive and Conservative options, single-instance guard, no more
  silent crashes (errors land in the log and `logs\gui-crash.log`), UTF-8 engine output
  (no mojibake on non-English Windows), scrollable pages.
- `WinSenior.cmd` works from folders containing spaces, `)`, `&`, `'` or Cyrillic.

## [6.2.0] - 2026-09-14

### Added
- **Desktop application** (`WinSenior.Gui.ps1`, WPF — ships with Windows, nothing to
  install) with pages for cleanup, optimization, troubleshooting, undo & restore, schedule
  and about. *Scan* fills a per-task "Would free" column from the engine's JSON report;
  optimization rows show their live applied state; troubleshooting shows OK/Warn/Fail with
  detail and lets you tick the problems to fix. Engine output streams into a resizable log
  panel with cancel and save. Selections and options persist in
  `%ProgramData%\WinSenior\gui-settings.json`. The app launches the engine scripts with
  parameters — it never re-implements deletion.
- **One-command launcher** `WinSenior.cmd`: unblocks the scripts, elevates once (UAC),
  starts the app without a console. `WinSenior.cmd console` opens the arrow-key menu;
  `WinSenior.ps1 -Gui` opens the app from PowerShell.
- **Cleanup engine: `-DeferLocked`** schedules locked/in-use files for deletion at the next
  reboot (`MoveFileEx` + `MOVEFILE_DELAY_UNTIL_REBOOT`) instead of counting them as errors;
  the summary and JSON report carry a `TotalDeferred` counter.
- **Cleanup engine: partial-folder accounting** — when a folder is only partly deletable
  the bytes that did go away are still counted; age-filtered runs prune the empty folder
  skeletons they leave behind.
- **Cleanup coverage 63 → 97:** Visual Studio, Python tools (uv/poetry/pipx/pyenv), JVM
  wrappers, .NET SDK, Node toolchain (node-gyp/electron/bun/deno/Cypress), GitHub Desktop,
  Composer, Docker Desktop/WSL logs, ML & browser-automation caches (off by default);
  Telegram, WhatsApp, Zoom/Skype/Signal/Viber, a generic Electron/Chromium cache sweep,
  media players, UWP temp state, notification cache, GPU vendor apps; game launcher logs,
  engine caches (Unreal/Unity/Godot), per-game shader caches on every disk; service-account
  temps, setup/upgrade/servicing logs, Windows misc caches, BITS queue, DNS/ARP/NetBIOS
  flush, silent Store reset, standby-memory purge, Search index rebuild (off); diagnostics
  & telemetry caches, third-party app logs, installer leftovers, empty-folder pruning;
  hibernation off and old shadow-copy pruning (Dangerous, off).
- Automation hooks for smoke tests: `WINSENIOR_GUI_AUTOCLOSE`, `WINSENIOR_GUI_AUTORUN`,
  `WINSENIOR_GUI_SCREENSHOT`. New Pester file `tests/WinSenior.Gui.Tests.ps1` loads the
  embedded XAML into a real WPF window and checks every wired control exists.

### Fixed
- The console menu's status line called an undefined `Test-Admin`; it now uses
  `Test-AdminPrivileges` from the shared library.
- Cleanup engine banner printed a hard-coded `v6.0`; it now reads `Get-WinSeniorVersion`.

## [6.1.0] - 2026-06-24

### Added
- **Shared library `WinSenior.Common.ps1`** dot-sourced by every engine and the menu:
  the admin check, WhatIf probe, byte formatter, canonical logger (`Write-WsLog`), and the
  System Restore routine (`New-WinSeniorRestorePoint`) now live in one place.
- **Unified JSON report** across all three engines. `-ReportPath` writes one envelope
  (`Tool/Version/Engine/Host/Timestamp/Mode/RestorePoint/DurationSec` + `Summary` + `Items`)
  via `Write-WinSeniorReport`, so a single parser reads cleanup, optimize and repair output.
- **Scheduled-task installer** (`WinSenior.Schedule.ps1`). `WinSenior.ps1 -InstallSchedule`
  registers a weekly unattended cleanup and a monthly read-only health scan under `\WinSenior\`
  (reports to `%ProgramData%\WinSenior\reports`); `-RemoveSchedule` removes them.
- **Cleanup coverage 57 → 63:** per-user Windows caches, PowerShell module cache, Remote Desktop
  bitmap cache, live-kernel dumps, the SRUM usage database, and the EventTranscript telemetry DB;
  extended the shader-cache task (NVIDIA OptixCache/NV_Cache) and Windows.old (`$WinREAgent`).
- **Optimization coverage 29 → 49:** modern Windows 11 privacy/debloat — disable Recall &
  Click-to-Do, Copilot, tailored-ad experiences, the Windows Spotlight policy, inking/typing and
  online-speech telemetry, CEIP, the App-Compat appraiser, Windows Error Reporting upload,
  Delivery-Optimization P2P upload, OneDrive pre-sign-in traffic, cloud clipboard (off by
  default); combined taskbar/Start ad-surface debloat, the SCOOBE setup nag, show-file-extensions
  (off), the classic Windows 10 context menu (off), Teredo (off) and Fast Startup (off).
- **Troubleshooting coverage 13 → 25:** System Restore protection, hosts-file integrity,
  proxy/PAC hijack, firewall state, Defender signatures & active threats, SMBv1, critical
  scheduled-task health, BITS queue, print spooler, Microsoft Store health, and report-only
  SSD wear/temperature and crash history.
- `CHANGELOG.md` and `tools/Build-Release.ps1` (zip + SHA256SUMS) and `tools/Sign-Scripts.ps1`.

### Changed
- **Report schema is unified** (breaking for anyone parsing the old `clean.json`/`repair.json`):
  engine-specific counters moved under `Summary`, and `Tasks`/`Results`/`Tweaks` are now `Items`.
- CI parses and analyzes **all** root `*.ps1` (was a hardcoded 4-file list), so the UI, common
  and schedule libraries are linted too.
- Engine loggers and restore-point functions are now thin wrappers over the shared library
  (~175 duplicated lines removed) with identical public signatures.

### Fixed
- `Write-WinSeniorReport` casts `Items` via `[object[]]`: `@()` throws
  `System.ArgumentException` on the `Generic.List[object]` the engines pass.
- The Store-health check wraps `Get-AppxPackage` in try/catch — the Appx module raises a
  terminating load error under PowerShell 7 that `-ErrorAction SilentlyContinue` does not catch.

## [6.0.0] - 2026-06-23

### Added
- Initial v6 release: registry-driven cleanup engine (57 tasks), optimization engine
  (29 reversible tweaks), troubleshooting engine (13 checks), and the `WinSenior.ps1`
  arrow-key TUI menu. Real `-WhatIf` via `SupportsShouldProcess`, a hard `Test-SafeToDelete`
  guard, risk tiers (Safe/Moderate/Aggressive default; Dangerous behind `-IncludeDangerous`),
  real System Restore points, and per-tweak undo.

[6.1.0]: https://github.com/denfry/WindowsCleaner/releases/tag/v6.1.0
[6.0.0]: https://github.com/denfry/WindowsCleaner/releases/tag/v6.0.0
