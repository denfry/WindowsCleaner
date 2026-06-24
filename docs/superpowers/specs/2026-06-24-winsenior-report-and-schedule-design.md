# WinSenior #2 — Unified report + scheduled-task installer

**Date:** 2026-06-24
**Status:** Approved
**Branch:** tui-menu

## Goal

Two maintenance-suite improvements that build on the new `WinSenior.Common.ps1`
shared library:

1. **Unified JSON report** across all three engines (cleanup / optimize / repair).
   All three already accept `-ReportPath`, but each emits a differently shaped
   document. Converge them on one envelope so a parser, dashboard, or fleet tool
   reads every engine the same way.
2. **Scheduled-task installer** so recurring maintenance can be set up with one
   command instead of hand-written `schtasks` / Task Scheduler clicks.

## Part A — Unified report

### Shared helper (in `WinSenior.Common.ps1`)

```powershell
function Get-WinSeniorVersion { '6.0.0' }   # single source of the version string

function Write-WinSeniorReport {
    param(
        [string]$ReportPath,
        [ValidateSet('Cleanup','Optimize','Repair')][string]$Engine,
        [hashtable]$Summary = @{},
        $Items = @(),
        [bool]$RestorePoint,
        [datetime]$StartTime,
        [scriptblock]$LogAction
    )
    if (-not $ReportPath) { return }
    $report = [ordered]@{
        Tool         = 'WinSenior'
        Version      = (Get-WinSeniorVersion)
        Engine       = $Engine
        Host         = $env:COMPUTERNAME
        Timestamp    = (Get-Date).ToString('s')
        Mode         = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
        RestorePoint = [bool]$RestorePoint
        DurationSec  = if ($StartTime) { [math]::Round(((Get-Date) - $StartTime).TotalSeconds, 1) } else { $null }
        Summary      = $Summary
        Items        = @($Items)
    }
    try {
        ($report | ConvertTo-Json -Depth 6) | Set-Content -Path $ReportPath -Encoding UTF8 -WhatIf:$false
        if ($LogAction) { & $LogAction "JSON report written: $ReportPath" 'Info' }
    } catch {
        if ($LogAction) { & $LogAction "Could not write report: $($_.Exception.Message)" 'Warning' }
    }
}
```

### Envelope

Common top level for every engine: `Tool, Version, Engine, Host, Timestamp,
Mode, RestorePoint, DurationSec`, then engine-specific `Summary` (counters) and
`Items` (per-unit list).

| Engine | `Summary` keys | `Items` |
|--------|----------------|---------|
| Cleanup | `TotalBytes, TotalFreed, TotalFiles, TotalErrors` | `$script:Stats` |
| Optimize | `Applied, Skipped, Errors, Manifest` | `$script:Stats` |
| Repair | `Fixed, FixErrors, Reboot` | `$script:Results` |

Each engine's `Write-*Report` shrinks to a single call to the helper, passing its
`$script:RestorePointMade`, `$script:StartTime`, and a `-LogAction` that forwards
to its own logger. The `if (-not $ReportPath) { return }` guard moves into the
helper.

**Breaking change (accepted):** the old top-level fields of `clean.json` /
`repair.json` / the optimize report move under `Summary`, and `Tasks` / `Results`
/ `Tweaks` are renamed to `Items`. Chosen deliberately for cross-engine
consistency.

## Part B — Scheduled-task installer

New dot-sourced library `WinSenior.Schedule.ps1`, following the UI library's
pure-core + thin-wrapper pattern.

- **`Get-WinSeniorScheduleSpec -Root <repoDir> -ReportDir <dir>`** — pure function
  returning an array of task specs. Each spec: `Name, TaskPath, Execute,
  Argument, Cadence ('Weekly'|'Monthly'), Day, Time`. Unit-testable with no
  registration side effect.
- **`Install-WinSeniorSchedule`** — turns each spec into a `Register-ScheduledTask`
  (action + trigger + SYSTEM principal at RunLevel Highest), `-Force` to replace.
  Weekly trigger via `New-ScheduledTaskTrigger -Weekly`; monthly trigger via the
  CIM class `MSFT_TaskMonthlyTrigger` (no `-Monthly` on the cmdlet).
- **`Remove-WinSeniorSchedule`** — `Unregister-ScheduledTask` for each spec name.

### Tasks (folder `\WinSenior\`, principal SYSTEM, RunLevel Highest)

| Task | Cadence | Command |
|------|---------|---------|
| `WinSenior Weekly Cleanup` | Weekly, Sun 03:00 | `Cleanup-Windows-Senior.ps1 -Unattended -NoRestorePoint -SkipOptimization -ReportPath <ReportDir>\cleanup.json` |
| `WinSenior Monthly Health Scan` | Monthly, day 1 03:30 | `Repair-Windows-Senior.ps1 -ScanOnly -Unattended -ReportPath <ReportDir>\repair.json` |

`ReportDir` defaults to `%ProgramData%\WinSenior\reports`. The scheduled run
overwrites a stable filename (the engines already timestamp inside the report);
this avoids unbounded report accumulation.

### WinSenior.ps1 wiring

New switches `-InstallSchedule` and `-RemoveSchedule`. Both self-elevate (already
done), dot-source `WinSenior.Schedule.ps1`, perform the action, print a summary,
and exit before the menu loop. A menu entry can come later; the CLI switch is the
automation-friendly surface now.

## Testing

- `tests/WinSenior.Common.Tests.ps1` — add a `Write-WinSeniorReport` block:
  writes to a temp file, round-trips the JSON, asserts envelope fields and that
  no file is written without `-ReportPath`.
- `tests/WinSenior.Schedule.Tests.ps1` — new: asserts `Get-WinSeniorScheduleSpec`
  returns two specs, names/cadences are correct, every `Argument` contains
  `-Unattended`, the report path sits under the given `ReportDir`, and the repair
  task is scan-only.
- CI already globs root `*.ps1` and `./tests`, so the new library and test are
  picked up automatically.

## Verification limits

`Register-ScheduledTask` / `Unregister-ScheduledTask` mutate the live system and
cannot be exercised safely in the dev sandbox. Part B is verified by parse-check
plus the pure-spec unit test; functional install/remove is left to a real machine.
Part A is fully verifiable locally by dot-sourcing and writing to a temp file.

## Out of scope

- Russian UI localization (separate item).
- A TUI menu entry for scheduling (CLI switch only for now).
- Distribution / signing / git hygiene (item #4).
