<!-- Thanks for contributing to WinSenior! Please fill this out. -->

## Summary

<!-- What does this PR change and why? -->

## Type of change

- [ ] Bug fix
- [ ] New cleanup task / optimization tweak / health check
- [ ] Behavior change to an existing engine
- [ ] Documentation only
- [ ] CI / tooling

## Safety review

<!-- This tool deletes files and changes Windows settings. Confirm the invariants: -->

- [ ] Every new destructive action runs through `ShouldProcess` (real `-WhatIf`)
- [ ] New paths pass through `Test-SafeToDelete`
- [ ] Irreversible work is in the **Dangerous** tier; debatable tweaks default **off**
- [ ] Repairs only improve health (e.g. never disable Defender)

## Testing

<!-- How did you verify this? -->

- [ ] `-WhatIf` preview reviewed on a real machine
- [ ] `Invoke-ScriptAnalyzer -Path . -Severity Error` is clean
- [ ] `Invoke-Pester -Path .\tests` passes
- [ ] Added/updated tests for this change

## Checklist

- [ ] `CHANGELOG.md` updated
- [ ] `README.md` updated if user-facing behavior or counts changed
- [ ] Linked the related issue (if any): closes #
