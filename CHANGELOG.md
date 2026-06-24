# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
