# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
