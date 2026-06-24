<#
.SYNOPSIS
    Arrow-key TUI primitives for WinSenior (pure-PowerShell, no dependencies).
.DESCRIPTION
    A small library dot-sourced by WinSenior.ps1. It provides arrow-key driven
    single-select (Show-Menu) and multi-select (Show-Checklist) screens. The
    interactive loops are thin wrappers over pure functions - a key->action
    reducer (Resolve-MenuAction / Resolve-ChecklistAction) and a state->lines
    renderer (Get-MenuFrame / Get-ChecklistFrame) - which are the unit-tested seam.
.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Glyphs are built from code points so this source file stays pure ASCII.
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

function Show-Menu {
    param(
        [string]$Title,
        [object[]]$Items,
        [string[]]$StatusLines = @(),
        [string]$Footer = 'Up/Down move   Enter select   Esc back'
    )
    # Arrow-key TUI needs an interactive console. When input is redirected
    # (piped, CI, or a non-interactive host) a raw ReadKey/ReadLine would either
    # throw or block forever, so degrade to "exit the menu" rather than hang.
    if ([Console]::IsInputRedirected) {
        Write-Host 'WinSenior menu needs an interactive console (arrow-key navigation).' -ForegroundColor Yellow
        Write-Host 'For automation, run the engine scripts directly with parameters.' -ForegroundColor DarkGray
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
    # Best-effort: paint in place at the cursor home; if that console op is
    # unavailable (no real handle / redirected), fall back to Clear-Host, and
    # if even that fails just stream the lines. The painter must never throw.
    $placedHome = $false
    try { [Console]::SetCursorPosition(0, 0); $placedHome = $true } catch { try { Clear-Host } catch { } }
    foreach ($ln in $Lines) { Write-FrameLine -Line $ln -Width ($w - 1) }
    if ($placedHome) {
        $extra = $script:UiLastHeight - $Lines.Count
        for ($j = 0; $j -lt $extra; $j++) { Write-Host (' ' * ($w - 1)) }
        try { [Console]::SetCursorPosition(0, $Lines.Count) } catch { }
    }
    $script:UiLastHeight = $Lines.Count
}

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
