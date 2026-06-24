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
