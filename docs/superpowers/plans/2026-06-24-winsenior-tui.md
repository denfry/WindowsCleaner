# WinSenior Arrow-Key TUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the number-entry menu in `WinSenior.ps1` with an arrow-key driven TUI (highlight bar, `Space` to toggle checkboxes, `Enter`/`Esc`) for both the top menus and the detailed task/tweak selection screens.

**Architecture:** A new dot-sourced library `WinSenior.UI.ps1` provides the TUI primitives. The interactive loops are thin wrappers over **pure** functions — a key→action reducer (`Resolve-MenuAction` / `Resolve-ChecklistAction`) and a state→lines renderer (`Get-MenuFrame` / `Get-ChecklistFrame`) — which are the unit-tested seam. `WinSenior.ps1` keeps all engine-invocation and selection logic; only its presentation calls change.

**Tech Stack:** Windows PowerShell 5.1, `[System.Console]` for raw key input and cursor positioning, Pester 5 for tests.

## Global Constraints

- Target **Windows PowerShell 5.1+**; no syntax requiring 7.x.
- **No external module dependencies** — pure PowerShell only (PSGallery is blocked here and the tool ships publicly; it must run out of the box).
- **UI text is English.** Do not introduce Cyrillic literals.
- **Source files stay pure ASCII** — build box-drawing glyphs from code points (`[char]0x250C`), never paste literal box characters into the `.ps1`.
- **Do not modify** the cleanup/optimize/repair engines, nor the selection/dispatch helpers in `WinSenior.ps1` (`Get-SelectionParams`, `Invoke-Cleanup`, `Invoke-Optimize`, `Get-AppliedMap`, `& $engine @params`). Only the presentation layer changes.
- Tests use **Pester 5** (`Describe`/`It`/`Should`), dot-sourcing the SUT in `BeforeAll`, matching the existing `tests/*.Tests.ps1` files.
- CI already globs `./tests` and parse-checks every `.ps1`; new files are picked up automatically. PSScriptAnalyzer/Pester can't be installed locally — verify by dot-sourcing; rely on CI for the full pass.
- Keep the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` commit trailer. Attribution is **denfry** only.
- Work happens on branch `tui-menu`.

---

### Task 1: UI library scaffold — theme & glyphs

**Files:**
- Create: `WinSenior.UI.ps1`
- Test: `tests/WinSenior.UI.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-UiGlyphSet([switch]$Plain) -> hashtable` with keys `TL,TR,BL,BR,H,V,Cursor` (single-char strings).
  - `Initialize-UiTheme([switch]$Plain) -> void` — sets `$script:UiGlyph` (from `Get-UiGlyphSet`), `$script:UiColor` (hashtable: `Frame,Title,Dim,Accent,Danger,Normal,HighlightFg,HighlightBg`), and `$script:UiLastHeight = 0`.

- [ ] **Step 1: Write the failing tests**

Create `tests/WinSenior.UI.Tests.ps1`:

```powershell
# Pester tests for the pure logic of WinSenior.UI.ps1 (no live console needed).
# Run:  Invoke-Pester -Path .\tests

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\WinSenior.UI.ps1'
    . $script:Sut
    Initialize-UiTheme
}

Describe 'Get-UiGlyphSet' {
    It 'plain set is pure ASCII' {
        foreach ($v in (Get-UiGlyphSet -Plain).Values) {
            [int][char]$v | Should -BeLessOrEqual 126
        }
    }
    It 'unicode set uses box-drawing corner' {
        [int][char](Get-UiGlyphSet).TL | Should -Be ([int]0x250C)
    }
    It 'every glyph key is present' {
        $g = Get-UiGlyphSet
        foreach ($k in 'TL','TR','BL','BR','H','V','Cursor') { $g.ContainsKey($k) | Should -BeTrue }
    }
}

Describe 'Initialize-UiTheme' {
    It 'populates the color theme' {
        Initialize-UiTheme
        $script:UiColor.HighlightBg | Should -Not -BeNullOrEmpty
        $script:UiLastHeight | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: FAIL — `WinSenior.UI.ps1` does not exist / `Get-UiGlyphSet` not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `WinSenior.UI.ps1`:

```powershell
<#
.SYNOPSIS
    Arrow-key TUI primitives for WinSenior (pure-PowerShell, no dependencies).
.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Glyphs are built from code points so this source stays pure ASCII.
#>

function Get-UiGlyphSet {
    param([switch]$Plain)
    if ($Plain) {
        return @{ TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|'; Cursor = '>' }
    }
    @{
        TL = [string][char]0x250C; TR = [string][char]0x2510
        BL = [string][char]0x2514; BR = [string][char]0x2518
        H  = [string][char]0x2500; V  = [string][char]0x2502
        Cursor = [string][char]0x25B6
    }
}

function Initialize-UiTheme {
    param([switch]$Plain)
    $script:UiGlyph = Get-UiGlyphSet -Plain:$Plain
    $script:UiColor = @{
        Frame       = 'DarkCyan'
        Title       = 'Cyan'
        Dim         = 'DarkGray'
        Accent      = 'Yellow'
        Danger      = 'Magenta'
        Normal      = 'White'
        HighlightFg = 'Black'
        HighlightBg = 'Cyan'
    }
    $script:UiLastHeight = 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add WinSenior.UI.ps1 tests/WinSenior.UI.Tests.ps1
git commit -m "feat(ui): add WinSenior.UI theme and code-point glyph set"
```

---

### Task 2: Single-select reducer & renderer

**Files:**
- Modify: `WinSenior.UI.ps1`
- Test: `tests/WinSenior.UI.Tests.ps1`

**Interfaces:**
- Consumes: `$script:UiColor` (Task 1), `Get-UiGlyphSet` (Task 1).
- Produces:
  - `Resolve-MenuAction(-Token [string], -Cursor [int], -Count [int]) -> hashtable` with keys `Cursor [int]`, `Result [string]` (`move|select|back|none`), `Index [int|$null]`.
  - `Get-MenuFrame(-Title [string], -Items [object[]], -Cursor [int], -StatusLines [string[]], -Footer [string], -Width [int], -Glyph [hashtable]) -> object[]`. Each `Items[i]` has `.Label [string]`. Returns line records `[pscustomobject]@{ Left; Text; Right; Fg; Highlight }`; exactly one record has `Highlight=$true` (the cursor row).

- [ ] **Step 1: Write the failing tests**

Append to `tests/WinSenior.UI.Tests.ps1`:

```powershell
Describe 'Resolve-MenuAction' {
    It 'Down moves down and wraps to top' {
        (Resolve-MenuAction -Token 'Down' -Cursor 2 -Count 3).Cursor | Should -Be 0
    }
    It 'Up moves up and wraps to bottom' {
        (Resolve-MenuAction -Token 'Up' -Cursor 0 -Count 3).Cursor | Should -Be 2
    }
    It 'Enter selects the current cursor' {
        $a = Resolve-MenuAction -Token 'Enter' -Cursor 1 -Count 3
        $a.Result | Should -Be 'select'
        $a.Index  | Should -Be 1
    }
    It 'a digit selects that 1-based item' {
        $a = Resolve-MenuAction -Token '3' -Cursor 0 -Count 5
        $a.Result | Should -Be 'select'
        $a.Index  | Should -Be 2
    }
    It 'Esc, 0 and q go back' {
        (Resolve-MenuAction -Token 'Esc' -Cursor 0 -Count 3).Result | Should -Be 'back'
        (Resolve-MenuAction -Token '0'   -Cursor 0 -Count 3).Result | Should -Be 'back'
        (Resolve-MenuAction -Token 'q'   -Cursor 0 -Count 3).Result | Should -Be 'back'
    }
    It 'an out-of-range digit does nothing' {
        (Resolve-MenuAction -Token '9' -Cursor 1 -Count 3).Result | Should -Be 'none'
    }
}

Describe 'Get-MenuFrame' {
    BeforeAll {
        Initialize-UiTheme
        $script:menuItems = 1..3 | ForEach-Object { [pscustomobject]@{ Label = "Item $_" } }
        $script:menuFrame = Get-MenuFrame -Title 'Title' -Items $script:menuItems -Cursor 1 `
            -StatusLines @('status A') -Footer 'hint' -Width 40
    }
    It 'highlights exactly one row, the cursor row' {
        @($script:menuFrame | Where-Object Highlight).Count | Should -Be 1
        ($script:menuFrame | Where-Object Highlight).Text   | Should -Match 'Item 2'
    }
    It 'shows the item number next to each label' {
        ($script:menuFrame | Where-Object { $_.Text -match 'Item 1' }).Text | Should -Match '1'
    }
    It 'includes the status line' {
        @($script:menuFrame | Where-Object { $_.Text -match 'status A' }).Count | Should -Be 1
    }
    It 'plain glyphs render pure-ASCII lines' {
        $pf = Get-MenuFrame -Title 'Title' -Items $script:menuItems -Cursor 0 -Width 40 -Glyph (Get-UiGlyphSet -Plain)
        foreach ($ln in $pf) {
            foreach ($ch in ("$($ln.Left)$($ln.Text)$($ln.Right)").ToCharArray()) {
                [int]$ch | Should -BeLessOrEqual 126
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: FAIL — `Resolve-MenuAction` / `Get-MenuFrame` not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `WinSenior.UI.ps1`:

```powershell
function Resolve-MenuAction {
    param([string]$Token, [int]$Cursor, [int]$Count)
    switch ($Token) {
        'Up'    { return @{ Cursor = (($Cursor - 1 + $Count) % $Count); Result = 'move';   Index = $null } }
        'Down'  { return @{ Cursor = (($Cursor + 1) % $Count);         Result = 'move';   Index = $null } }
        'Home'  { return @{ Cursor = 0;                                Result = 'move';   Index = $null } }
        'End'   { return @{ Cursor = ($Count - 1);                     Result = 'move';   Index = $null } }
        'Enter' { return @{ Cursor = $Cursor;                          Result = 'select'; Index = $Cursor } }
        'Esc'   { return @{ Cursor = $Cursor;                          Result = 'back';   Index = $null } }
        'q'     { return @{ Cursor = $Cursor;                          Result = 'back';   Index = $null } }
        default {
            if ($Token -match '^[0-9]$') {
                $d = [int]$Token
                if ($d -eq 0) { return @{ Cursor = $Cursor; Result = 'back'; Index = $null } }
                if ($d -ge 1 -and $d -le $Count) { return @{ Cursor = ($d - 1); Result = 'select'; Index = ($d - 1) } }
            }
            return @{ Cursor = $Cursor; Result = 'none'; Index = $null }
        }
    }
}

# Internal: one bordered content row, padded/truncated to the inner width.
function New-UiRow {
    param([string]$Text, [string]$Fg, [bool]$Highlight, [int]$Inner)
    $body = (' ' + $Text)
    if ($body.Length -lt $Inner) { $body = $body.PadRight($Inner) } else { $body = $body.Substring(0, $Inner) }
    [pscustomobject]@{ Left = $script:UiGlyph.V; Text = $body; Right = $script:UiGlyph.V; Fg = $Fg; Highlight = $Highlight }
}

function Get-MenuFrame {
    param(
        [string]$Title,
        [object[]]$Items,
        [int]$Cursor,
        [string[]]$StatusLines = @(),
        [string]$Footer = '',
        [int]$Width = 60,
        [hashtable]$Glyph
    )
    if ($Glyph) { $script:UiGlyph = $Glyph }
    $g = $script:UiGlyph
    $inner = $Width - 2
    $rule  = { param($l, $r) [pscustomobject]@{ Left = $l; Text = ($g.H * $inner); Right = $r; Fg = $script:UiColor.Frame; Highlight = $false } }
    $out = New-Object 'System.Collections.Generic.List[object]'
    $out.Add((& $rule $g.TL $g.TR))
    $out.Add((New-UiRow -Text $Title -Fg $script:UiColor.Title -Highlight $false -Inner $inner))
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    foreach ($s in $StatusLines) { $out.Add((New-UiRow -Text $s -Fg $script:UiColor.Dim -Highlight $false -Inner $inner)) }
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $cur = if ($i -eq $Cursor) { $g.Cursor } else { ' ' }
        $txt = '{0} {1,2}  {2}' -f $cur, ($i + 1), $Items[$i].Label
        $out.Add((New-UiRow -Text $txt -Fg $script:UiColor.Normal -Highlight ($i -eq $Cursor) -Inner $inner))
    }
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    $out.Add((& $rule $g.BL $g.BR))
    if ($Footer) { $out.Add([pscustomobject]@{ Left = ''; Text = " $Footer"; Right = ''; Fg = $script:UiColor.Dim; Highlight = $false }) }
    , $out.ToArray()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: PASS (all Task 1 + Task 2 tests).

- [ ] **Step 5: Commit**

```bash
git add WinSenior.UI.ps1 tests/WinSenior.UI.Tests.ps1
git commit -m "feat(ui): add single-select reducer and frame renderer"
```

---

### Task 3: Multi-select reducer & renderer

**Files:**
- Modify: `WinSenior.UI.ps1`
- Test: `tests/WinSenior.UI.Tests.ps1`

**Interfaces:**
- Consumes: `New-UiRow`, `$script:UiColor`, `$script:UiGlyph` (Task 2), `Get-UiGlyphSet` (Task 1).
- Produces:
  - `Resolve-ChecklistAction(-Token [string], -Cursor [int], -Count [int], -Page [int]=10) -> hashtable` with keys `Cursor [int]`, `Action [string]` (`move|toggle|all|none|done|cancel|none`), `Index [int|$null]`.
  - `Get-ChecklistFrame(-Title [string], -Items [object[]], -Cursor [int], -OnSet [HashSet], -StatusLines [string[]], -Footer [string], -Width [int], -Glyph [hashtable]) -> object[]`. Each `Items[i]` has `.Id,.Name,.Group`, optional `.Risk,.Applied`. Group headers appear once per group; item rows show `[x]`/`[ ]` from `$OnSet.Contains($Id)`; exactly one item row has `Highlight=$true`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/WinSenior.UI.Tests.ps1`:

```powershell
Describe 'Resolve-ChecklistAction' {
    It 'Space toggles the current item' {
        $a = Resolve-ChecklistAction -Token 'Space' -Cursor 2 -Count 5
        $a.Action | Should -Be 'toggle'
        $a.Index  | Should -Be 2
    }
    It 'a selects all and n clears all' {
        (Resolve-ChecklistAction -Token 'a' -Cursor 0 -Count 5).Action | Should -Be 'all'
        (Resolve-ChecklistAction -Token 'n' -Cursor 0 -Count 5).Action | Should -Be 'none'
    }
    It 'Enter is done and Esc is cancel' {
        (Resolve-ChecklistAction -Token 'Enter' -Cursor 0 -Count 5).Action | Should -Be 'done'
        (Resolve-ChecklistAction -Token 'Esc'   -Cursor 0 -Count 5).Action | Should -Be 'cancel'
    }
    It 'a digit just moves the cursor (selection is via Space)' {
        $a = Resolve-ChecklistAction -Token '4' -Cursor 0 -Count 5
        $a.Action | Should -Be 'move'
        $a.Cursor | Should -Be 3
    }
}

Describe 'Get-ChecklistFrame' {
    BeforeAll {
        Initialize-UiTheme
        $script:cItems = @(
            [pscustomobject]@{ Id = 'a'; Name = 'Alpha'; Group = 'G1'; Risk = 'Safe' }
            [pscustomobject]@{ Id = 'b'; Name = 'Bravo'; Group = 'G1'; Risk = 'Safe' }
            [pscustomobject]@{ Id = 'c'; Name = 'Cee';   Group = 'G2'; Risk = 'Dangerous' }
        )
        $script:cOn = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$script:cOn.Add('a')
        $script:cFrame = Get-ChecklistFrame -Title 'Pick' -Items $script:cItems -Cursor 0 -OnSet $script:cOn -Width 50
    }
    It 'marks selected ids [x] and unselected [ ]' {
        ($script:cFrame | Where-Object { $_.Text -match 'Alpha' }).Text | Should -Match '\[x\]'
        ($script:cFrame | Where-Object { $_.Text -match 'Bravo' }).Text | Should -Match '\[ \]'
    }
    It 'renders each group header exactly once' {
        @($script:cFrame | Where-Object { $_.Text -match '^\s*G1\s*$' }).Count | Should -Be 1
        @($script:cFrame | Where-Object { $_.Text -match '^\s*G2\s*$' }).Count | Should -Be 1
    }
    It 'highlights exactly the cursor item' {
        @($script:cFrame | Where-Object Highlight).Count | Should -Be 1
        ($script:cFrame | Where-Object Highlight).Text   | Should -Match 'Alpha'
    }
    It 'shows the applied suffix when Applied is set' {
        $items = @([pscustomobject]@{ Id = 'x'; Name = 'Xeq'; Group = 'G'; Risk = 'Safe'; Applied = $true })
        $on = New-Object 'System.Collections.Generic.HashSet[string]'
        $f = Get-ChecklistFrame -Title 'P' -Items $items -Cursor 0 -OnSet $on -Width 50
        ($f | Where-Object { $_.Text -match 'Xeq' }).Text | Should -Match '\(applied\)'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: FAIL — `Resolve-ChecklistAction` / `Get-ChecklistFrame` not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `WinSenior.UI.ps1`:

```powershell
function Resolve-ChecklistAction {
    param([string]$Token, [int]$Cursor, [int]$Count, [int]$Page = 10)
    switch ($Token) {
        'Up'       { return @{ Cursor = (($Cursor - 1 + $Count) % $Count);   Action = 'move';   Index = $null } }
        'Down'     { return @{ Cursor = (($Cursor + 1) % $Count);           Action = 'move';   Index = $null } }
        'Home'     { return @{ Cursor = 0;                                  Action = 'move';   Index = $null } }
        'End'      { return @{ Cursor = ($Count - 1);                       Action = 'move';   Index = $null } }
        'PageUp'   { return @{ Cursor = [Math]::Max(0, $Cursor - $Page);    Action = 'move';   Index = $null } }
        'PageDown' { return @{ Cursor = [Math]::Min($Count - 1, $Cursor + $Page); Action = 'move'; Index = $null } }
        'Space'    { return @{ Cursor = $Cursor;                            Action = 'toggle'; Index = $Cursor } }
        'Enter'    { return @{ Cursor = $Cursor;                            Action = 'done';   Index = $null } }
        'Esc'      { return @{ Cursor = $Cursor;                            Action = 'cancel'; Index = $null } }
        default {
            if ($Token -eq 'a' -or $Token -eq 'A') { return @{ Cursor = $Cursor; Action = 'all';  Index = $null } }
            if ($Token -eq 'n' -or $Token -eq 'N') { return @{ Cursor = $Cursor; Action = 'none'; Index = $null } }
            if ($Token -match '^[0-9]$') {
                $d = [int]$Token
                if ($d -ge 1 -and $d -le $Count) { return @{ Cursor = ($d - 1); Action = 'move'; Index = $null } }
            }
            return @{ Cursor = $Cursor; Action = 'none'; Index = $null }
        }
    }
}

function Get-ChecklistFrame {
    param(
        [string]$Title,
        [object[]]$Items,
        [int]$Cursor,
        $OnSet,
        [string[]]$StatusLines = @(),
        [string]$Footer = '',
        [int]$Width = 70,
        [hashtable]$Glyph
    )
    if ($Glyph) { $script:UiGlyph = $Glyph }
    $g = $script:UiGlyph
    $inner = $Width - 2
    $rule  = { param($l, $r) [pscustomobject]@{ Left = $l; Text = ($g.H * $inner); Right = $r; Fg = $script:UiColor.Frame; Highlight = $false } }
    $out = New-Object 'System.Collections.Generic.List[object]'
    $out.Add((& $rule $g.TL $g.TR))
    $out.Add((New-UiRow -Text $Title -Fg $script:UiColor.Title -Highlight $false -Inner $inner))
    foreach ($s in $StatusLines) { $out.Add((New-UiRow -Text $s -Fg $script:UiColor.Dim -Highlight $false -Inner $inner)) }
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    $lastGroup = [object]$null
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $it = $Items[$i]
        if ($it.Group -ne $lastGroup) {
            $out.Add((New-UiRow -Text $it.Group -Fg $script:UiColor.Accent -Highlight $false -Inner $inner))
            $lastGroup = $it.Group
        }
        $box = if ($OnSet.Contains($it.Id)) { '[x]' } else { '[ ]' }
        $cur = if ($i -eq $Cursor) { $g.Cursor } else { ' ' }
        $risk = if ($it.Risk) { [string]$it.Risk } else { '' }
        $suffix = ''
        if ($null -ne $it.Applied) { $suffix = if ($it.Applied) { '  (applied)' } else { '  (not set)' } }
        $txt = '{0} {1} {2,-11}{3}{4}' -f $cur, $box, $risk, $it.Name, $suffix
        $fg = if ($risk -eq 'Dangerous') { $script:UiColor.Danger } else { $script:UiColor.Normal }
        $out.Add((New-UiRow -Text $txt -Fg $fg -Highlight ($i -eq $Cursor) -Inner $inner))
    }
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    $out.Add((& $rule $g.BL $g.BR))
    if ($Footer) { $out.Add([pscustomobject]@{ Left = ''; Text = " $Footer"; Right = ''; Fg = $script:UiColor.Dim; Highlight = $false }) }
    , $out.ToArray()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: PASS (Task 1–3 tests).

- [ ] **Step 5: Commit**

```bash
git add WinSenior.UI.ps1 tests/WinSenior.UI.Tests.ps1
git commit -m "feat(ui): add multi-select reducer and checklist renderer"
```

---

### Task 4: Console input & frame painter

**Files:**
- Modify: `WinSenior.UI.ps1`
- Test: `tests/WinSenior.UI.Tests.ps1`

**Interfaces:**
- Consumes: `$script:UiColor`, `$script:UiLastHeight` (Task 1).
- Produces:
  - `Read-MenuKey() -> string` — normalized token (`Up,Down,Left,Right,Enter,Esc,Space,Home,End,PageUp,PageDown`, a single literal char, or `none`); returns `Redirected` when `[Console]::IsInputRedirected`.
  - `Get-FrameWidth() -> int` — frame width clamped to the window (`[Math]::Min(76, [Console]::WindowWidth - 1)`, default 76 on failure).
  - `Write-Frame(-Lines [object[]]) -> void` — paints line records at the cursor home, padding to clear leftovers; falls back to `Clear-Host` if cursor positioning is unavailable. Updates `$script:UiLastHeight`.

- [ ] **Step 1: Write the failing test**

Append to `tests/WinSenior.UI.Tests.ps1`:

```powershell
Describe 'Read-MenuKey' {
    It 'returns Redirected when there is no interactive console' {
        # Pester runs non-interactively, so input is redirected here.
        Read-MenuKey | Should -Be 'Redirected'
    }
}

Describe 'Get-FrameWidth' {
    It 'returns a positive width' {
        Get-FrameWidth | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: FAIL — `Read-MenuKey` / `Get-FrameWidth` not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `WinSenior.UI.ps1`:

```powershell
function Read-MenuKey {
    if ([Console]::IsInputRedirected) { return 'Redirected' }
    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
        'UpArrow'    { return 'Up' }
        'DownArrow'  { return 'Down' }
        'LeftArrow'  { return 'Left' }
        'RightArrow' { return 'Right' }
        'Enter'      { return 'Enter' }
        'Escape'     { return 'Esc' }
        'Spacebar'   { return 'Space' }
        'Home'       { return 'Home' }
        'End'        { return 'End' }
        'PageUp'     { return 'PageUp' }
        'PageDown'   { return 'PageDown' }
        default {
            $c = $k.KeyChar
            if ($c -and -not [char]::IsControl($c)) { return [string]$c }
            return 'none'
        }
    }
}

function Get-FrameWidth {
    try { return [Math]::Min(76, [Console]::WindowWidth - 1) } catch { return 76 }
}

function Write-FrameLine {
    param($Line, [int]$Width)
    if ($Line.Left)  { Write-Host $Line.Left -ForegroundColor $script:UiColor.Frame -NoNewline }
    if ($Line.Highlight) {
        Write-Host $Line.Text -ForegroundColor $script:UiColor.HighlightFg -BackgroundColor $script:UiColor.HighlightBg -NoNewline
    } else {
        Write-Host $Line.Text -ForegroundColor $Line.Fg -NoNewline
    }
    if ($Line.Right) { Write-Host $Line.Right -ForegroundColor $script:UiColor.Frame -NoNewline }
    $used = ("$($Line.Left)$($Line.Text)$($Line.Right)").Length
    if ($used -lt $Width) { Write-Host (' ' * ($Width - $used)) -NoNewline }
    Write-Host ''
}

function Write-Frame {
    param([object[]]$Lines)
    $w = try { [Console]::WindowWidth } catch { 80 }
    $home = $true
    try { [Console]::SetCursorPosition(0, 0) } catch { $home = $false; Clear-Host }
    foreach ($ln in $Lines) { Write-FrameLine -Line $ln -Width ($w - 1) }
    if ($home) {
        $extra = $script:UiLastHeight - $Lines.Count
        for ($j = 0; $j -lt $extra; $j++) { Write-Host (' ' * ($w - 1)) }
        try { [Console]::SetCursorPosition(0, $Lines.Count) } catch { }
    }
    $script:UiLastHeight = $Lines.Count
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: PASS (Task 1–4 tests).

- [ ] **Step 5: Commit**

```bash
git add WinSenior.UI.ps1 tests/WinSenior.UI.Tests.ps1
git commit -m "feat(ui): add key normalizer, frame width and painter"
```

---

### Task 5: Interactive Show-Menu / Show-Checklist with non-interactive fallback

**Files:**
- Modify: `WinSenior.UI.ps1`
- Test: `tests/WinSenior.UI.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MenuFrame`, `Resolve-MenuAction`, `Get-ChecklistFrame`, `Resolve-ChecklistAction`, `Read-MenuKey`, `Get-FrameWidth`, `Write-Frame`.
- Produces:
  - `Show-Menu(-Title [string], -Items [object[]], -StatusLines [string[]], -Footer [string]) -> int|$null` — returns the selected 0-based index, or `$null` for back. When input is redirected, reads one line via `[Console]::In.ReadLine()`; a valid 1-based number returns its index, anything else (incl. EOF/`$null`) returns `$null` (so CI never hangs).
  - `Show-Checklist(-Title [string], -Items [object[]], -OnSet [HashSet], -StatusLines [string[]], -Footer [string]) -> void` — mutates `$OnSet`. When input is redirected it returns immediately (no toggles), so CI never hangs.

- [ ] **Step 1: Write the failing tests**

Append to `tests/WinSenior.UI.Tests.ps1`:

```powershell
Describe 'Show-Menu (non-interactive fallback)' {
    It 'returns $null at end-of-input instead of hanging' {
        $items = 1..2 | ForEach-Object { [pscustomobject]@{ Label = "Opt $_" } }
        Show-Menu -Title 'T' -Items $items | Should -Be $null
    }
}

Describe 'Show-Checklist (non-interactive fallback)' {
    It 'returns without hanging and leaves the set unchanged' {
        $items = @([pscustomobject]@{ Id = 'a'; Name = 'A'; Group = 'G'; Risk = 'Safe' })
        $on = New-Object 'System.Collections.Generic.HashSet[string]'
        { Show-Checklist -Title 'T' -Items $items -OnSet $on } | Should -Not -Throw
        $on.Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: FAIL — `Show-Menu` / `Show-Checklist` not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `WinSenior.UI.ps1`:

```powershell
function Show-Menu {
    param(
        [string]$Title,
        [object[]]$Items,
        [string[]]$StatusLines = @(),
        [string]$Footer = 'Up/Down move   Enter select   Esc back'
    )
    if ([Console]::IsInputRedirected) {
        $line = [Console]::In.ReadLine()
        if ($line -match '^[0-9]+$') {
            $d = [int]$line
            if ($d -ge 1 -and $d -le $Items.Count) { return ($d - 1) }
        }
        return $null
    }
    $cursor = 0
    $w = Get-FrameWidth
    while ($true) {
        $frame = Get-MenuFrame -Title $Title -Items $Items -Cursor $cursor -StatusLines $StatusLines -Footer $Footer -Width $w -Glyph $script:UiGlyph
        Write-Frame -Lines $frame
        $act = Resolve-MenuAction -Token (Read-MenuKey) -Cursor $cursor -Count $Items.Count
        $cursor = $act.Cursor
        switch ($act.Result) {
            'select' { return $act.Index }
            'back'   { return $null }
        }
    }
}

function Show-Checklist {
    param(
        [string]$Title,
        [object[]]$Items,
        $OnSet,
        [string[]]$StatusLines = @(),
        [string]$Footer = 'Up/Down move   Space toggle   a all   n none   Enter done   Esc back'
    )
    if ([Console]::IsInputRedirected) { return }
    $cursor = 0
    $w = Get-FrameWidth
    while ($true) {
        $frame = Get-ChecklistFrame -Title $Title -Items $Items -Cursor $cursor -OnSet $OnSet -StatusLines $StatusLines -Footer $Footer -Width $w -Glyph $script:UiGlyph
        Write-Frame -Lines $frame
        $act = Resolve-ChecklistAction -Token (Read-MenuKey) -Cursor $cursor -Count $Items.Count
        $cursor = $act.Cursor
        switch ($act.Action) {
            'toggle' {
                $id = $Items[$act.Index].Id
                if ($OnSet.Contains($id)) { [void]$OnSet.Remove($id) } else { [void]$OnSet.Add($id) }
            }
            'all'    { foreach ($it in $Items) { [void]$OnSet.Add($it.Id) } }
            'none'   { $OnSet.Clear() }
            'done'   { return }
            'cancel' { return }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Invoke-Pester -Path .\tests\WinSenior.UI.Tests.ps1`
Expected: PASS (Task 1–5 tests; the fallback tests complete without hanging).

- [ ] **Step 5: Commit**

```bash
git add WinSenior.UI.ps1 tests/WinSenior.UI.Tests.ps1
git commit -m "feat(ui): add Show-Menu and Show-Checklist interactive loops"
```

---

### Task 6: Wire the TUI into WinSenior.ps1

**Files:**
- Modify: `WinSenior.ps1` (param block ~24-28; engine checks ~35-54; dot-source ~73-76; UI helpers + screens ~95-321)

**Interfaces:**
- Consumes: `Initialize-UiTheme`, `Show-Menu`, `Show-Checklist` (Tasks 1–5).
- Produces: `Get-CleanupItems() -> object[]`, `Get-OptimizeItems(-Applied [hashtable]) -> object[]` (each item: `Id,Name,Group,Risk,Applied`).
- Unchanged: `Get-SelectionParams`, `Invoke-Cleanup`, `Invoke-Optimize`, `Get-AppliedMap`, `Invoke-FullRun`, `Write-Banner`, `Wait-Enter`, and every `& $engine` call.

- [ ] **Step 1: Add the `-Plain` switch to the param block**

In `WinSenior.ps1`, replace the param block (lines ~24-28):

```powershell
[CmdletBinding()]
param(
    # Do not try to relaunch elevated; run with whatever rights we have.
    [switch]$NoElevate,
    # Force ASCII-only glyphs (for terminals that can't render box-drawing chars).
    [switch]$Plain
)
```

- [ ] **Step 2: Locate and dot-source the UI library**

After the existing engine path variables (after line ~38 `$script:RepairScript = ...`), add:

```powershell
$script:UiScript = Join-Path $script:Root 'WinSenior.UI.ps1'
```

In the engine-existence `foreach` (line ~48), include the UI script:

```powershell
foreach ($s in @($script:CleanupScript, $script:OptimizeScript, $script:RepairScript, $script:UiScript)) {
```

After the three engine dot-sources (after line ~76 `. $script:RepairScript`), add:

```powershell
. $script:UiScript
Initialize-UiTheme -Plain:$Plain
```

- [ ] **Step 3: Add item-builder helpers**

After `Get-SelectionParams` (after line ~156), add:

```powershell
# Map the cleanup registry into checklist items (Group = Category).
function Get-CleanupItems {
    $script:CleanReg | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Group = $_.Category; Risk = $_.Risk; Applied = $null }
    }
}

# Map the optimization registry into checklist items (Group = Area), with live applied-state.
function Get-OptimizeItems {
    param([hashtable]$Applied)
    $script:OptReg | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Group = $_.Area; Risk = $_.Risk; Applied = $Applied[$_.Id] }
    }
}
```

- [ ] **Step 4: Delete the old `Invoke-ToggleScreen`**

Remove the entire `Invoke-ToggleScreen` function (lines ~113-148). Its callers are replaced by `Show-Checklist` in the next step.

- [ ] **Step 5: Replace the cleanup screen**

Replace `Show-CleanupScreen` (lines ~161-187) with:

```powershell
function Show-CleanupScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Preview (dry run, changes nothing)' }
        [pscustomobject]@{ Label = 'Run cleanup' }
        [pscustomobject]@{ Label = 'Choose tasks (detailed)' }
        [pscustomobject]@{ Label = 'Toggle scope (all users / current user)' }
        [pscustomobject]@{ Label = 'Reset to defaults' }
    )
    while ($true) {
        $onCount = @($script:CleanReg | Where-Object { $script:CleanOn.Contains($_.Id) }).Count
        $danger  = @($script:CleanReg | Where-Object { $script:CleanOn.Contains($_.Id) -and $_.Risk -eq 'Dangerous' }).Count
        $scope   = if ($script:CleanCU) { 'current user' } else { 'all users' }
        $status  = @("Selected: $onCount / $($script:CleanReg.Count) tasks    Scope: $scope")
        if ($danger) { $status += "Includes $danger DANGEROUS task(s) - you will be asked to confirm." }
        switch (Show-Menu -Title 'Disk cleanup' -Items $items -StatusLines $status) {
            0 { Invoke-Cleanup -Preview $true;  Wait-Enter }
            1 { Invoke-Cleanup -Preview $false; Wait-Enter }
            2 { Show-Checklist -Title 'Cleanup tasks' -Items (Get-CleanupItems) -OnSet $script:CleanOn }
            3 { $script:CleanCU = -not $script:CleanCU }
            4 { $script:CleanOn.Clear(); foreach ($t in (Resolve-CleanupSelection -Registry $script:CleanReg)) { [void]$script:CleanOn.Add($t.Id) } }
            $null { return }
        }
    }
}
```

- [ ] **Step 6: Replace the optimization screen**

Replace `Show-OptimizeScreen` (lines ~208-236) with:

```powershell
function Show-OptimizeScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Preview (dry run, changes nothing)' }
        [pscustomobject]@{ Label = 'Apply tweaks' }
        [pscustomobject]@{ Label = 'Choose tweaks (detailed, shows current state)' }
        [pscustomobject]@{ Label = 'Undo last optimization run' }
        [pscustomobject]@{ Label = 'Reset to defaults' }
    )
    while ($true) {
        $onCount = @($script:OptReg | Where-Object { $script:OptOn.Contains($_.Id) }).Count
        $status  = @("Selected: $onCount / $($script:OptReg.Count) tweaks", 'Every applied tweak is backed up first; use Undo to revert.')
        switch (Show-Menu -Title 'Windows optimization' -Items $items -StatusLines $status) {
            0 { Invoke-Optimize -Preview $true;  Wait-Enter }
            1 { Invoke-Optimize -Preview $false; Wait-Enter }
            2 {
                Write-Host '  Reading current state...' -ForegroundColor DarkGray
                $applied = Get-AppliedMap
                Show-Checklist -Title 'Optimization tweaks' -Items (Get-OptimizeItems -Applied $applied) -OnSet $script:OptOn
            }
            3 { Write-Host ''; & $script:OptimizeScript -Undo; Wait-Enter }
            4 { $script:OptOn.Clear(); foreach ($t in (Resolve-TweakSelection -Registry $script:OptReg)) { [void]$script:OptOn.Add($t.Id) } }
            $null { return }
        }
    }
}
```

- [ ] **Step 7: Replace the troubleshoot screen**

Replace `Show-TroubleshootScreen` (lines ~265-286) with:

```powershell
function Show-TroubleshootScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Scan & repair      (scan, then choose what to fix)' }
        [pscustomobject]@{ Label = 'Scan only          (diagnose, change nothing)' }
        [pscustomobject]@{ Label = 'Auto-fix safe      (apply Safe + Moderate fixes)' }
        [pscustomobject]@{ Label = 'Auto-fix all       (include heavy: SFC/DISM/WU/network)' }
    )
    $status = @('Scans for common Windows problems (read-only), then lets you repair.', 'A restore point is made before any repair.')
    while ($true) {
        switch (Show-Menu -Title 'Troubleshoot - scan & repair' -Items $items -StatusLines $status) {
            0 { Write-Host ''; & $script:RepairScript;                       Wait-Enter }
            1 { Write-Host ''; & $script:RepairScript -ScanOnly;             Wait-Enter }
            2 { Write-Host ''; & $script:RepairScript -FixAll;               Wait-Enter }
            3 { Write-Host ''; & $script:RepairScript -FixAll -IncludeHeavy; Wait-Enter }
            $null { return }
        }
    }
}
```

- [ ] **Step 8: Replace the main menu**

Replace `Show-MainMenu` (lines ~291-319) with:

```powershell
function Show-MainMenu {
    $items = @(
        [pscustomobject]@{ Label = 'Disk cleanup        (categories, preview, run)' }
        [pscustomobject]@{ Label = 'Optimize Windows    (performance / privacy / debloat / network)' }
        [pscustomobject]@{ Label = 'Troubleshoot        (scan for problems, then repair)' }
        [pscustomobject]@{ Label = 'Full run            (cleanup + optimization)' }
        [pscustomobject]@{ Label = 'Undo optimizations  (revert last run from backup)' }
        [pscustomobject]@{ Label = 'Create restore point' }
        [pscustomobject]@{ Label = 'List tasks, tweaks & checks' }
    )
    while ($true) {
        $admin = if (Test-Admin) { 'Administrator: yes' } else { 'Administrator: NO - re-run as admin' }
        switch (Show-Menu -Title 'Windows Senior - system maintenance' -Items $items -StatusLines @($admin)) {
            0 { Show-CleanupScreen }
            1 { Show-OptimizeScreen }
            2 { Show-TroubleshootScreen }
            3 { Invoke-FullRun }
            4 { Write-Banner 'Undo optimizations'; & $script:OptimizeScript -Undo; Wait-Enter }
            5 { Write-Banner 'Create restore point'; New-CleanupRestorePoint | Out-Null; Wait-Enter }
            6 { Write-Banner 'Tasks, tweaks & checks'; Show-TaskList; Show-TweakList; Show-CheckList; Wait-Enter }
            $null { Write-Host ''; Write-Host '  Bye.' -ForegroundColor Cyan; return }
        }
    }
}
```

- [ ] **Step 9: Verify the script parses and dot-sources cleanly**

Run:
```powershell
$tokens = $errs = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\WinSenior.ps1), [ref]$tokens, [ref]$errs)
$errs    # expected: empty
. .\WinSenior.UI.ps1; Get-Command Show-Menu, Show-Checklist | Select-Object Name   # expected: both listed
```
Expected: no parse errors; both commands resolve.

- [ ] **Step 10: Commit**

```bash
git add WinSenior.ps1
git commit -m "feat(ui): drive WinSenior menus with the arrow-key TUI"
```

---

### Task 7: Full verification & docs

**Files:**
- Modify: `README.md` (mention arrow-key navigation + `-Plain`)
- Verify: all `tests/*.Tests.ps1`

- [ ] **Step 1: Run the whole test suite**

Run: `Invoke-Pester -Path .\tests`
Expected: all green, including the existing cleanup/optimize/repair tests (unchanged) and the new `WinSenior.UI.Tests.ps1`.

> If `Invoke-Pester` is unavailable in this environment, instead dot-source each engine and `WinSenior.UI.ps1`, then call each pure function once with sample input and confirm no errors. Note in the commit that CI runs the Pester pass.

- [ ] **Step 2: Parse-check every changed .ps1**

Run:
```powershell
foreach ($f in 'WinSenior.ps1','WinSenior.UI.ps1') {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\$f), [ref]$null, [ref]$e)
    if ($e) { Write-Host "PARSE ERRORS in $f"; $e } else { Write-Host "$f OK" }
}
```
Expected: both `OK`.

- [ ] **Step 3: Manual smoke test (interactive console)**

In a normal (non-redirected) elevated PowerShell window:
```powershell
.\WinSenior.ps1 -NoElevate
```
Confirm: arrow keys move the highlight bar; `Enter` opens a screen; in "Choose tasks" `Space` toggles `[x]`; `Esc` goes back; `Plain` mode works: `.\WinSenior.ps1 -NoElevate -Plain` shows `+`/`-`/`|` borders.

> This step is manual and cannot run in the redirected agent shell. If you cannot run an interactive console, state that explicitly and rely on Steps 1-2 plus the unit tests for the logic.

- [ ] **Step 4: Update README**

In `README.md`, where it documents `WinSenior.ps1`, add a sentence: the menu is now arrow-key driven (Up/Down to move, Enter to select, Space to toggle tasks/tweaks, Esc to go back) and supports `-Plain` for terminals without box-drawing glyphs. Keep wording English and attribution to denfry.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: note arrow-key TUI navigation and -Plain switch"
```

---

## Self-Review

**Spec coverage:**
- Arrow-key single-select → Task 2 (`Get-MenuFrame`/`Resolve-MenuAction`) + Task 5 (`Show-Menu`). ✓
- Arrow-key multi-select with Space → Task 3 + Task 5 (`Show-Checklist`). ✓
- Pure render seam for Pester → Tasks 2/3 tests. ✓
- `Read-MenuKey` normalization + redirected sentinel → Task 4. ✓
- No-flicker painter + Clear-Host fallback → Task 4 (`Write-Frame`). ✓
- Non-interactive degradation → Task 5 fallbacks (tested). ✓
- Glyphs from code points / pure-ASCII source / `-Plain` → Task 1 + plain-ASCII assertions in Tasks 2/3 + `-Plain` wired in Task 6. ✓
- English UI, engines untouched, selection/dispatch untouched → Task 6 only swaps presentation. ✓
- Narrow-window clamp → `Get-FrameWidth` (Task 4) + `New-UiRow` truncation (Task 2). ✓
- Tests file picked up by CI glob → Task 1 creates `tests/WinSenior.UI.Tests.ps1`. ✓
- README mention → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step contains complete code. ✓

**Type consistency:** `Resolve-MenuAction` returns `Result`; `Show-Menu` switches on `$act.Result`. `Resolve-ChecklistAction` returns `Action`; `Show-Checklist` switches on `$act.Action`. Item shape `{Id,Name,Group,Risk,Applied}` produced by `Get-CleanupItems`/`Get-OptimizeItems` (Task 6) matches what `Get-ChecklistFrame` consumes (Task 3). Menu item shape `{Label}` produced in Task 6 matches `Get-MenuFrame` (Task 2). `New-UiRow` defined in Task 2, reused in Task 3. ✓
