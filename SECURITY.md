# Security Policy

WinSenior runs with administrator rights and deletes files and changes Windows
settings, so its security properties matter. Thank you for helping keep it safe.

## Supported versions

Security fixes are applied to the latest release line.

| Version | Supported          |
| ------- | ------------------ |
| 6.1.x   | :white_check_mark: |
| < 6.1   | :x:                |

## Reporting a vulnerability

**Please do not report security issues in public GitHub issues, discussions, or
pull requests.**

Report privately through GitHub's built-in private vulnerability reporting:

1. Go to the repository's **[Security](https://github.com/denfry/WindowsCleaner/security)** tab.
2. Click **Report a vulnerability** to open a private advisory only the maintainers can see.

Please include:

- The script and version (`-Help` / the `Version` field in a JSON report).
- The exact command line you ran.
- What happened versus what you expected, and why it is a security concern.
- Your OS build and PowerShell version (`$PSVersionTable`).

### What to expect

- An acknowledgement, normally within **5 business days**.
- An assessment and, for confirmed issues, a fix in a patch release.
- Credit in the release notes if you would like it (let us know).

## What counts as a security issue here

Because this is a privileged system-maintenance tool, examples of in-scope
issues include:

- A path that bypasses the `Test-SafeToDelete` guard and could delete protected
  locations (drive roots, `%WINDIR%`, `%USERPROFILE%`, `System32`, etc.).
- A destructive action that runs even under `-WhatIf` / `-DryRun`.
- Privilege-escalation, untrusted-input, or path-injection paths via
  parameters, registry values, or environment variables.
- An "Aggressive"/"Dangerous" operation that is reachable without its tier flag.

## Out of scope

- Expected data loss from intentionally running the **Dangerous** tier
  (`-IncludeDangerous`) — this is documented behavior; always preview with
  `-WhatIf` and keep backups.
- Issues that require an attacker who already has administrator access.
