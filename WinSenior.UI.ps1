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
