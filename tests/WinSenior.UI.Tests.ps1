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
