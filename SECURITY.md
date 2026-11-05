# Security policy

WinSenior runs as Administrator, deletes files and runs uninstallers. A bug here can cost
someone their data, so please report security problems privately.

## Supported versions

Only the latest release gets fixes. Update with the install one-liner from the README.

| Version | Supported |
|---------|-----------|
| 6.5.x   | yes       |
| < 6.5   | no        |

## How to report

Open a private advisory on the
[Security tab](https://github.com/denfry/WindowsCleaner/security/advisories/new). Only the
maintainer can see it.

Include:

- the script and version (`Version` in a JSON report, or the number under the app name);
- the exact command line or the steps in the app;
- what happened and what you expected;
- Windows build and `$PSVersionTable.PSVersion`.

You can expect a reply within 5 working days. Confirmed issues get a patch release, and
you get credit in the release notes if you want it.

## In scope

- A path that gets past `Test-SafeToDelete` or `Get-WsLeftoverBlocker` and deletes a
  protected location (drive root, Windows, Program Files, a profile or its known folders).
- A destructive action that runs under `-WhatIf`.
- Data that a non-admin user controls (HKCU, `%LOCALAPPDATA%`, environment variables, files
  in user-writable folders) that makes WinSenior run code or delete files with admin rights.
- A Dangerous operation that runs without `-IncludeDangerous`.
- The installer accepting a release that does not match `SHA256SUMS.txt`.

## Out of scope

- Data lost to the Dangerous tier you turned on yourself.
- Attacks that already need administrator rights.
