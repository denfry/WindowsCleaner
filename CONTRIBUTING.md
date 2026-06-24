# Contributing to WinSenior

Thanks for taking the time to contribute! This project is a set of PowerShell
engines for cleaning, optimizing, and repairing Windows. Contributions of all
sizes are welcome — bug reports, new cleanup/optimization/repair entries, docs,
and tests.

## Ground rules

This tool deletes files and changes Windows settings. The whole design exists to
make those operations **safe and reversible**. Please keep that bar:

- **Never bypass `ShouldProcess`.** Every destructive action must run through
  `SupportsShouldProcess` so `-WhatIf` / `-DryRun` is real, not a parallel path.
- **Never weaken the safety guard.** `Test-SafeToDelete` refuses to touch drive
  roots, `%WINDIR%`, `%USERPROFILE%`, `System32`, or any path shallower than two
  levels. New tasks must pass through it.
- **Irreversible operations go in the Dangerous tier**, gated behind
  `-IncludeDangerous`. Debatable optimization tweaks ship **off by default**.
- **Repairs only ever improve health** — for example, the repair engine *enables*
  Defender real-time protection; it never disables it.

## The architecture in one sentence

Every cleanup target, optimization tweak, and health check is a **single
declarative entry in a registry**; a small engine resolves what to run. Adding a
target is usually one entry — you rarely touch the engine. See
[`docs/design/architecture.md`](docs/design/architecture.md) for the full design.

### Adding a cleanup task

Add one entry to the task registry in `Cleanup-Windows-Senior.ps1` with its id,
category, risk tier, and the path(s) to clean (using `<USER>` / `<DRIVE>`
placeholders where needed). Confirm it shows up in `-ListTasks` and behaves under
`-WhatIf` before anything else.

### Adding an optimization tweak

Add one entry to the tweak registry in `Optimize-Windows-Senior.ps1`. The engine
snapshots prior state into the backup manifest automatically, so make sure your
tweak is captured by `-Undo`. Debatable tweaks must default to off.

### Adding a health check

Add one entry to the check registry in `Repair-Windows-Senior.ps1`: a read-only
scan returning `OK` / `Warn` / `Fail`, and an optional fix that runs through
`ShouldProcess`.

## Development setup

- **PowerShell 5.1+** (7+ recommended). Most changes can be developed on any
  Windows 10/11 machine.
- Always start by previewing with `-WhatIf` against your own machine.

## Before you open a pull request

Run the same checks CI runs (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)):

```powershell
# 1. Syntax parses cleanly (CI fails on parse errors)
Get-ChildItem -Filter *.ps1 -File | ForEach-Object {
  $errs = $null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs) | Out-Null
  if ($errs) { $errs }
}

# 2. Static analysis (CI fails on Error-severity findings)
Invoke-ScriptAnalyzer -Path . -Severity Error

# 3. Tests (Pester 5+)
Invoke-Pester -Path .\tests
```

If you change behavior, **add or update a test** in `tests\*.Tests.ps1`. The
suites cover selection, the safety guard, age filtering, formatting, `-WhatIf`
accounting, the backup→apply→undo round-trip, and the scan/fix dispatch.

## Pull request checklist

- [ ] `-WhatIf` is honored for every new destructive action
- [ ] New paths pass through `Test-SafeToDelete`
- [ ] Irreversible work is in the Dangerous tier; debatable tweaks default off
- [ ] Syntax parse, PSScriptAnalyzer (Error), and Pester all pass locally
- [ ] Tests added/updated for the change
- [ ] `CHANGELOG.md` updated under the unreleased/next version
- [ ] `README.md` updated if user-facing behavior or counts changed

## Reporting bugs & requesting features

Use the issue templates (bug report / feature request). For anything that looks
like a **security vulnerability**, do not open a public issue — see
[`SECURITY.md`](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
