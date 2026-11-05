# Contributing

Bug reports, new cleanup targets, tweaks, checks, docs and tests are all welcome. Open an
issue first for anything larger than a single entry, so we can agree on the approach.

## Rules

WinSenior deletes files and changes Windows settings, so every change keeps these:

- Destructive actions go through `ShouldProcess`. `-WhatIf` must stay a real dry run,
  not a separate code path.
- Every path you delete passes `Test-SafeToDelete` in the cleanup engine (or
  `Get-WsLeftoverBlocker` for app leftovers). Don't loosen either check.
- Irreversible work goes in the Dangerous tier. Tweaks that people disagree on ship
  with `DefaultOn $false`.
- Repairs may only improve health. The repair engine turns Defender real-time protection
  on and never off.

## How the code is laid out

Each engine keeps a registry of declarative entries, and a small engine decides what to
run. Adding a target usually means adding one entry. The details are in
[docs/design/architecture.md](docs/design/architecture.md).

| What you add | Where | Notes |
|---|---|---|
| Cleanup task | `New-CleanupTask` entry in `Cleanup-Windows-Senior.ps1` | Id, category, risk tier, paths with `<USER>` / `<DRIVE>` tokens. Check it in `-ListTasks` and under `-WhatIf`. |
| Tweak | `New-RegTweak` / `New-SvcTweak` / `New-CustomTweak` in `Optimize-Windows-Senior.ps1` | Area must be Performance, Privacy, Debloat or Network. `-Undo` must restore it. |
| Health check | `New-DiagnosticCheck` in `Repair-Windows-Senior.ps1` | A read-only scan that returns `OK`, `Warn` or `Fail`, plus an optional fix. |
| Shared helper | `WinSenior.Common.ps1` | Anything two scripts need. |
| UI text | `WinSenior.Gui.ps1` and `WinSenior.Gui.ru.json` | Wrap strings in `T '...'` and add the Russian line. |

Keep the `.ps1` files ASCII. Files with Cyrillic need a UTF-8 BOM, or Windows PowerShell
5.1 misreads them.

## Before you open a pull request

Run what CI runs:

```powershell
Invoke-ScriptAnalyzer -Path . -Severity Error
Invoke-Pester -Path .\tests
```

Add or update a test in `tests\` when you change behavior, and add a line to
`CHANGELOG.md`. Update the counts in `README.md` if you add tasks, tweaks or checks.

Test on Windows PowerShell 5.1 as well as PowerShell 7 when you touch anything that
deletes or elevates.

## Security issues

Don't open a public issue. See [SECURITY.md](SECURITY.md).

## License

Contributions are licensed under the project's [MIT License](LICENSE).
