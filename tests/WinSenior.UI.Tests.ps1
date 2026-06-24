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
