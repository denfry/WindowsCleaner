# WinSenior TUI — design spec

**Date:** 2026-06-24
**Status:** Approved (brainstorming)
**Scope:** Replace the presentation layer of `WinSenior.ps1` with an arrow-key driven
text UI. No change to the cleanup/optimize/repair engines or to the selection/dispatch
logic in `WinSenior.ps1`.

## Goal

The current menu is a "type a number, press Enter" loop (`Write-Banner` / `Read-Key` /
`Invoke-ToggleScreen`). Make it a real TUI: a highlighted selection bar driven by the
arrow keys, `Space` to toggle checkboxes, `Enter` to confirm, `Esc` to go back — for
**both** the top-level menus and the detailed task/tweak selection screens.

## Decisions (locked in brainstorming)

- **Interaction:** arrow keys + `Enter`/`Space`, pure PowerShell, **no module
  dependencies** (PSGallery is blocked here and the tool ships publicly — it must run
  out of the box on PS 5.1+).
- **UI language:** English (unchanged). Avoids the Cyrillic-mojibake-on-PS5.1 problem.
- **Coverage:** everything — top menus *and* the checkbox selection screens.
- **Structure:** a new dot-sourced library `WinSenior.UI.ps1`, mirroring how the engines
  are already separate dot-sourced files (approach A).

## Architecture

```
WinSenior.ps1   (entry point — unchanged responsibilities: self-elevate, dot-source
  │              engines, hold selection state, dispatch flow)
  ├─ dot-source WinSenior.UI.ps1   <- NEW: TUI primitives library
  └─ dot-source Cleanup/Optimize/Repair engines   <- unchanged
```

Only the presentation layer changes. `Get-SelectionParams`, `Invoke-Cleanup`,
`Invoke-Optimize`, `Get-AppliedMap`, and every `& $engine @params` call stay as they are,
so all runs still go through the engines' tested logic, real `-WhatIf`, safety guard and
per-tweak undo.

## `WinSenior.UI.ps1` — components

### Initialization
- `Initialize-UiTheme [-Plain]` — builds a script-scoped `$Glyph` hashtable from code
  points (`[char]0x250C` …) for the box frame, cursor `>`/`▶`, and check mark, plus a
  color theme (highlight bg/fg, dim, accent, danger). `-Plain` (or a non-unicode console)
  swaps to an ASCII-only glyph set (`+ - | >`, `[x]`/`[ ]`). Building glyphs from code
  points at runtime keeps the **source file pure ASCII** — zero encoding risk, same
  reasoning that keeps the UI English.

### Input
- `Read-MenuKey` — wraps `[Console]::ReadKey($true)`; returns a normalized token:
  `Up`, `Down`, `Left`, `Right`, `Enter`, `Space`, `Esc`, `Home`, `End`, `PageUp`,
  `PageDown`, or the literal character (digit/letter). When `[Console]::IsInputRedirected`
  is true it returns a `Redirected` sentinel so callers can degrade.

### Single-select — `Show-Menu`
- **Params:** `-Title`, `-Items` (objects with `.Label`, optional `.Hint`, `.Disabled`),
  `-StatusLines` (string[] shown under the title: admin status, selection counts),
  `-Footer` (key-hint line).
- Renders a boxed frame, header, status lines, the list with a **highlight bar** on the
  cursor row, item numbers always visible, and a footer hint line.
- **Keys:** `Up`/`Down` move (wrap, skip `Disabled`); a digit jumps the highlight to that
  item; `Enter` returns the highlighted index; `Esc`/`0`/`q` return `$null` (back).
- **Returns:** selected index, or `$null` for back/cancel.

### Multi-select — `Show-Checklist`
- **Params:** `-Title`, `-Items` (objects with `.Id`, `.Name`, `.Group`, optional
  `.Risk`, `.Applied`), `-OnSet` (a `HashSet[string]` mutated in place), `-StatusLines`.
- Renders the list grouped by `.Group` (one header per group), `[x]`/`[ ]`, risk tag, and
  an `(applied)`/`(not set)` suffix when `.Applied` is set, with the highlight bar.
- **Keys:** `Up`/`Down` move; `Space` toggles the current item; `a`/`A` select all;
  `n`/`N` clear all; `PageUp`/`PageDown`/`Home`/`End` for long lists; `Enter` confirms
  (returns); `Esc` exits the screen. Toggles mutate `-OnSet` live — same contract as the
  current `Invoke-ToggleScreen`, so the caller's selection state stays the source of truth.
- **Returns:** nothing (mutates `-OnSet`).

### Rendering (the testable seam)
- `Get-MenuFrame` / `Get-ChecklistFrame` — **pure** functions. Given state (items, cursor
  index, selected set, title, status lines, width, glyph set) they return an ordered array
  of line records `@{ Text; Fg; Bg }`. No console access.
- `Write-Frame` — the painter. Moves the cursor home
  (`[Console]::SetCursorPosition(0,0)`), writes each line padded to the frame width
  (erasing leftovers), clears any extra rows left by a taller previous frame, and avoids
  `Clear-Host` so there is no flicker. Falls back to `Clear-Host` + plain `Write-Host`
  if cursor positioning throws (e.g. redirected output).

## Data flow

`WinSenior.ps1` already owns the registries and selection sets
(`$script:CleanReg`, `$script:OptReg`, `$script:CleanOn`, `$script:OptOn`).

- **Main / sub menus:** build a small array of label objects → `Show-Menu` → index →
  dispatch to the same targets as today's `switch`.
- **Detailed selection:** map `$script:CleanReg` / `$script:OptReg` to checklist items
  (`Group` = `Category`/`Area`, plus `Risk`, and `Applied` from `Get-AppliedMap` for
  tweaks) → `Show-Checklist -OnSet $script:CleanOn` / `-OnSet $script:OptOn`.
- Engine invocation is unchanged.

## Error handling / degradation

- **Non-interactive** (`[Console]::IsInputRedirected`): `Show-Menu` / `Show-Checklist`
  fall back to a one-shot numbered `Read-Host` prompt (reusing the always-visible numbers)
  so piped/CI runs neither hang nor crash.
- **Cursor positioning failure:** `Write-Frame` falls back to `Clear-Host` rendering.
- **Narrow window:** frame width is clamped to `[Console]::WindowWidth`; long labels are
  truncated.
- **Old terminals / encoding:** `-Plain` forces the ASCII glyph set.

## Testing

`tests/WinSenior.UI.Tests.ps1` (Pester 5), dot-sourcing the UI library and exercising the
**pure** `Get-MenuFrame` / `Get-ChecklistFrame` with synthetic data:

- highlight bar lands on the cursor index;
- `[x]`/`[ ]` reflect the `OnSet` contents;
- each group header appears exactly once;
- item numbers and labels are present;
- `-Plain` output contains only ASCII (no code point > 0x7E);
- `Read-MenuKey` token normalization (table-driven over synthetic `ConsoleKeyInfo`),
  where feasible without a live console.

CI already parse-checks/analyzes every `.ps1` and globs `./tests`, so the new library and
test file are picked up automatically. PSScriptAnalyzer/Pester5 can't be installed in this
environment (PSGallery not allowlisted) — verify logic locally by dot-sourcing; rely on CI
for the analyzer/Pester pass.

## Out of scope (YAGNI)

Mouse support, live resize reflow, scrollbars, theme configuration, persisting selections
to disk.
