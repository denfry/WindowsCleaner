# Architecture

The tool is a single-file PowerShell engine driven by a declarative task registry, plus a
batch script that mirrors the same defaults for dependency-free environments.

## Task registry + engine

Every cleanup operation is one record in `Get-CleanupTaskRegistry` (Id, Category, Risk,
DefaultOn, AgeDays, Paths or Action, StopServices). A small engine resolves which tasks to
run, measures reclaimed space, and deletes through PowerShell's `ShouldProcess`. Adding a
target is one registry entry.

### Risk tiers
- `Safe` — regenerated caches (browsers, temp, thumbnails, dev/app/messenger/game caches).
- `Moderate` — recycle bin, crash dumps, font cache, WU download cache, DISM cleanup, drive temp.
- `Aggressive` — full SoftwareDistribution wipe, catroot2, DISM `/ResetBase` + `/SPSuperseded`, SFC.
- `Dangerous` — irreversible: event-log clearing, `$PatchCache$`, `Windows.old`, superseded driver removal.

Default: Safe + Moderate + Aggressive run. Dangerous requires `-IncludeDangerous`. A real
restore point (`Checkpoint-Computer`) is created by default unless `-NoRestorePoint` / `-WhatIf`.

### Engine functions (single-responsibility)
`Get-CleanupTaskRegistry`, `Resolve-CleanupSelection`, `Invoke-PathCleanup`
(ShouldProcess + honest byte/file accounting), `Use-StoppedService`,
`New-CleanupRestorePoint`, `Invoke-CleanupTask`, `Write-CleanupLog`,
`Write-CleanupReport` (JSON), `Show-CleanupSummary`.

### Path tokens
- `<USER>` expands per user profile (`Get-UserProfiles`; all users unless `-CurrentUserOnly`).
- `<DRIVE>` expands per local fixed disk (`Get-LocalDrives`, DriveType=3), filtered by `-Drives`.
- `%VAR%` environment variables are expanded normally.

### Safety guard
`Test-SafeToDelete` refuses drive roots, `%WINDIR%`, `%USERPROFILE%`, `C:\Users`,
`System32`, `%ProgramData%`, the Program Files roots, and any path shallower than two
levels — a backstop against a malformed registry entry or an unexpanded variable.

## Parameters (~15, with aliases)
`-Category`, `-Include`, `-Exclude`, `-IncludeDangerous`, `-Conservative`,
`-CurrentUserOnly`, `-Drives`, `-WhatIf` / `-DryRun`, `-Unattended` / `-Force`,
`-NoRestorePoint`, `-SkipOptimization`, `-MaxAgeDays`, `-LogPath`, `-ReportPath`,
`-ListTasks`, `-Help`.

## Categories
Browsers, DevTools, Apps, Games, System, Disks, Logs, Updates, Optimization
(57 tasks total; `-ListTasks` prints the live list).

## Batch script
`Cleanup-Windows-Senior.bat` is the dependency-free alternative. It mirrors the engine's
defaults via a per-profile helper, independent per-browser flags, ordered Windows Update
service stops, all-local-disk cleanup, a Dangerous tier behind `/IncludeDangerous`, and an
optional real restore point via `/RestorePoint`.

## Tests
Pester 5 tests (`tests/`) cover the pure logic — selection, the safety guard, `<DRIVE>`
expansion, age filtering, formatting, and `-WhatIf` accounting — with destructive paths
validated through `-WhatIf`. CI runs them on `windows-latest`.
