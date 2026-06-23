# Architecture

The tool is a pair of single-file PowerShell engines driven by declarative registries — one
for cleanup, one for optimization — plus an interactive menu that ties them together and a
batch script that mirrors the cleanup defaults for dependency-free environments.

## Menu front door

`WinSenior.ps1` is the single entry point. It self-elevates, dot-sources both engines as
libraries (their `InvocationName -ne '.'` entry guards keep them from auto-running), and
presents numbered screens for cleanup, optimization, undo, restore point and listings. It
executes by invoking each engine as a child call (`& $engine @params`); an exact toggled
selection is reproduced with `-Include <on>` + `-Exclude <off>`.

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

## Optimization engine
`Optimize-Windows-Senior.ps1` changes Windows settings instead of deleting files. Each tweak
is one record (`Id, Name, Area, Risk, DefaultOn, Type, Spec`). Types: `Registry` (path + one or
more values), `Service` (desired startup type), `ScheduledTask` (disable a list), and `Custom`
(Test/Backup/Apply/Undo scriptblocks for Appx removal, power scheme, hibernation, Nagle).

Before each change the engine snapshots prior state and, after the run, writes a JSON backup
manifest to `%ProgramData%\WinSenior\backups`. `-Undo` reads the newest (or a named) manifest
and reverts each tweak in reverse order — generically for Registry/Service/ScheduledTask, and via
the tweak's own `Undo` scriptblock (looked up by Id in the live registry) for Custom. Selection
(`Resolve-TweakSelection`) and tiers mirror cleanup; debatable tweaks ship `DefaultOn = $false`.
Areas: Performance, Privacy, Debloat, Network (29 tweaks; `-ListTweaks` prints the live list).
It never touches Defender real-time protection, Windows Update, the network stack wholesale, or
Edge/Store.

## Batch script
`Cleanup-Windows-Senior.bat` is the dependency-free alternative. It mirrors the engine's
defaults via a per-profile helper, independent per-browser flags, ordered Windows Update
service stops, all-local-disk cleanup, a Dangerous tier behind `/IncludeDangerous`, and an
optional real restore point via `/RestorePoint`.

## Tests
Pester 5 tests (`tests/`) cover the pure logic of both engines — cleanup selection, the safety
guard, `<DRIVE>` expansion, age filtering, formatting and `-WhatIf` accounting; plus the tweak
registry integrity, `Resolve-TweakSelection`, and a registry backup→apply→undo round-trip against
a throwaway `HKCU:\Software\WinSeniorTest` hive. Destructive paths are validated through `-WhatIf`.
CI runs them on `windows-latest`.
