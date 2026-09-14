# Pester tests for WinSenior.Gui.ps1 - the WPF desktop app - and the WinSenior.cmd launcher.
# The window itself is never shown; we verify the script parses, the embedded XAML
# loads into a real WPF object tree, and every control the code-behind wires exists.

BeforeAll {
    $script:Gui = Join-Path $PSScriptRoot '..\WinSenior.Gui.ps1'
    $script:Src = Get-Content $script:Gui -Raw
    $m = [regex]::Match($script:Src, "(?s)\`$xaml = @'\r?\n(.*?)\r?\n'@")
    $script:XamlText = if ($m.Success) { $m.Groups[1].Value } else { $null }
}

Describe 'WinSenior.Gui.ps1' {
    It 'parses without errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:Gui), [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
    It 'embeds a XAML here-string' {
        $script:XamlText | Should -Not -BeNullOrEmpty
    }
    It 'loads the XAML into a WPF Window' {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$script:XamlText)
        $win = [System.Windows.Markup.XamlReader]::Load($reader)
        $win | Should -BeOfType System.Windows.Window
        $win.Close()
    }
    It 'names every control the code-behind references' {
        $used  = [regex]::Matches($script:Src, '\$W\.([A-Za-z0-9]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $xml   = [xml]$script:XamlText
        $named = $xml.SelectNodes('//*[@*[local-name()="Name"]]') |
            ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') }
        $missing = @($used | Where-Object { $_ -notin $named })
        $missing | Should -BeNullOrEmpty
    }
    It 'runs the engines through their scripts instead of re-implementing deletion' {
        $script:Src | Should -Match 'Start-Engine -Script \$script:CleanupScript'
        $script:Src | Should -Not -Match 'Remove-Item -LiteralPath [^\r\n]*-Recurse'
    }
    It 'always passes -Unattended so engines never block on Read-Host' {
        $script:Src | Should -Match "\`$a \+= '-Unattended'"
    }
}

Describe 'WinSenior.cmd launcher' {
    BeforeAll { $script:Cmd = Get-Content (Join-Path $PSScriptRoot '..\WinSenior.cmd') -Raw }
    It 'elevates via RunAs and targets the GUI by default' {
        $script:Cmd | Should -Match 'RunAs'
        $script:Cmd | Should -Match 'WinSenior\.Gui\.ps1'
    }
    It 'unblocks downloaded scripts and offers a console mode' {
        $script:Cmd | Should -Match 'Unblock-File'
        $script:Cmd | Should -Match '"console"'
    }
}

Describe 'WinSenior.ps1 -Gui' {
    It 'exposes a -Gui switch' {
        $src = Get-Content (Join-Path $PSScriptRoot '..\WinSenior.ps1') -Raw
        $src | Should -Match '\[switch\]\$Gui'
    }
}
