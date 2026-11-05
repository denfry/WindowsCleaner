## What and why

<!-- What changes, and what problem it solves. Link the issue: Closes # -->

## Checks

- [ ] New destructive actions go through `ShouldProcess`, and `-WhatIf` changes nothing
- [ ] Deleted paths pass `Test-SafeToDelete` / `Get-WsLeftoverBlocker`
- [ ] Irreversible work is in the Dangerous tier; disputed tweaks default off
- [ ] `Invoke-ScriptAnalyzer -Path . -Severity Error` is clean
- [ ] `Invoke-Pester -Path .\tests` passes; tests added for new behavior
- [ ] `CHANGELOG.md` updated (and README counts, if they changed)

## How I tested it

<!-- Windows build, PowerShell 5.1 and/or 7, what you ran -->
