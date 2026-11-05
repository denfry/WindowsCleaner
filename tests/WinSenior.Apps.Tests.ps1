# Pester tests for WinSenior.Apps.ps1 - pure pieces: uninstall-key filtering, the
# silent-uninstall command builder, leftover confidence scoring and the winget
# table parser (fed with real, localized winget output). Nothing is uninstalled.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\WinSenior.Apps.ps1')
}

Describe 'ConvertTo-WsAppRecord' {
    It 'keeps a normal app and parses its date and size' {
        $r = ConvertTo-WsAppRecord ([pscustomobject]@{ DisplayName = 'Foo'; DisplayVersion = '1.2'; Publisher = 'Foo Inc'
                InstallDate = '20260115'; EstimatedSize = 2048; UninstallString = 'C:\Foo\uninst.exe' }) -KeyName 'Foo' -KeyPath 'HKEY_LOCAL_MACHINE\X\Foo' -Scope Machine -Arch x64
        $r.Name | Should -Be 'Foo'
        $r.SizeBytes | Should -Be 2MB
        $r.InstallDate.ToString('yyyy-MM-dd') | Should -Be '2026-01-15'
        $r.Source | Should -Be 'Win32'
    }
    It 'detects MSI products by GUID key' {
        $r = ConvertTo-WsAppRecord ([pscustomobject]@{ DisplayName = 'Bar'; WindowsInstaller = 1; UninstallString = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}' }) -KeyName '{11111111-2222-3333-4444-555555555555}' -KeyPath 'k' -Scope Machine -Arch x64
        $r.Source | Should -Be 'MSI'
        $r.ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
    }
    It 'hides system components, updates and entries without an uninstaller' {
        ConvertTo-WsAppRecord ([pscustomobject]@{ DisplayName = 'X'; SystemComponent = 1; UninstallString = 'a' }) -KeyName 'X' -KeyPath 'k' -Scope Machine -Arch x64 | Should -BeNullOrEmpty
        ConvertTo-WsAppRecord ([pscustomobject]@{ DisplayName = 'KB1'; ParentKeyName = 'Office'; UninstallString = 'a' }) -KeyName 'KB1' -KeyPath 'k' -Scope Machine -Arch x64 | Should -BeNullOrEmpty
        ConvertTo-WsAppRecord ([pscustomobject]@{ DisplayName = 'Y' }) -KeyName 'Y' -KeyPath 'k' -Scope Machine -Arch x64 | Should -BeNullOrEmpty
    }
}

Describe 'Get-WsUninstallCommand' {
    It 'uses msiexec /x /qn for MSI products' {
        $c = Get-WsUninstallCommand ([pscustomobject]@{ Source = 'MSI'; ProductCode = '{A}'; QuietUninstallString = ''; UninstallString = '' })
        $c.Kind | Should -Be 'MSI'; $c.Args | Should -Be '/x {A} /qn /norestart'
    }
    It 'prefers QuietUninstallString' {
        $c = Get-WsUninstallCommand ([pscustomobject]@{ Source = 'Win32'; ProductCode = $null; QuietUninstallString = '"C:\Program Files\App\un.exe" --silent'; UninstallString = 'x' })
        $c.Kind | Should -Be 'Quiet'; $c.Exe | Should -Be 'C:\Program Files\App\un.exe'; $c.Args | Should -Be '--silent'
    }
    It 'adds Inno Setup silent switches' {
        $c = Get-WsUninstallCommand ([pscustomobject]@{ Source = 'Win32'; ProductCode = $null; QuietUninstallString = ''; UninstallString = '"C:\Program Files\App\unins000.exe"' })
        $c.Kind | Should -Be 'Inno'; $c.Args | Should -Match '/VERYSILENT'
    }
    It 'adds /S for NSIS uninstallers, even with an unquoted path with spaces' {
        $c = Get-WsUninstallCommand ([pscustomobject]@{ Source = 'Win32'; ProductCode = $null; QuietUninstallString = ''; UninstallString = 'C:\Program Files\My App\uninstall.exe' })
        $c.Kind | Should -Be 'NSIS'; $c.Exe | Should -Be 'C:\Program Files\My App\uninstall.exe'; $c.Args | Should -Be '/S'
    }
    It 'turns an msiexec /I uninstall string into a silent /x' {
        $c = Get-WsUninstallCommand ([pscustomobject]@{ Source = 'Win32'; ProductCode = $null; QuietUninstallString = ''; UninstallString = 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}' })
        $c.Kind | Should -Be 'MSI'; $c.Args | Should -Match '/x \{11111111'
    }
    It 'falls back to interactive for unknown uninstallers' {
        (Get-WsUninstallCommand ([pscustomobject]@{ Source = 'Win32'; ProductCode = $null; QuietUninstallString = ''; UninstallString = '"C:\X\setup.exe" -remove' })).Silent | Should -BeFalse
    }
}

Describe 'Get-WsLeftoverConfidence' {
    BeforeAll { $script:App = [pscustomobject]@{ Name = 'Cool Editor 3.2 (x64)'; Publisher = 'Cool Soft'; InstallLocation = 'C:\Program Files\Cool Editor' } }
    It 'VeryGood for the app''s own install folder' {
        Get-WsLeftoverConfidence ([pscustomobject]@{ Path = 'C:\Program Files\Cool Editor'; Leaf = 'Cool Editor' }) $script:App | Should -Be 'VeryGood'
    }
    It 'Good for a same-name AppData folder' {
        Get-WsLeftoverConfidence ([pscustomobject]@{ Path = 'C:\Users\u\AppData\Roaming\Cool Editor'; Leaf = 'Cool Editor' }) $script:App | Should -Be 'Good'
    }
    It 'Bad for generic names' {
        Get-WsLeftoverConfidence ([pscustomobject]@{ Path = 'C:\ProgramData\Microsoft'; Leaf = 'Microsoft' }) $script:App | Should -Be 'Bad'
    }
    It 'Bad when another installed app lives inside' {
        Get-WsLeftoverConfidence ([pscustomobject]@{ Path = 'C:\Program Files\Cool Editor'; Leaf = 'Cool Editor' }) $script:App -OtherLocations @('C:\Program Files\Cool Editor\Plugins\Other') | Should -Be 'Bad'
    }
    It 'Bad when another installed app has the same name' {
        Get-WsLeftoverConfidence ([pscustomobject]@{ Path = 'C:\Users\u\AppData\Roaming\Cool Editor'; Leaf = 'Cool Editor' }) $script:App -OtherNames @('Cool Editor 4') | Should -Be 'Bad'
    }
}

Describe 'ConvertFrom-WsWingetTable' {
    It 'parses localized (Russian) output by column position' {
        $lines = @(
            "   - `r   \ `rИмя                                              ИД                                     Версия               Доступно         Источник"
            '--------------------------------------------------------------------------------------------------------------------------------------'
            '7-Zip 26.02 (x64)                                7zip.7zip                              26.02                26.05            winget'
            'Unity Hub 3.14.3                                 Unity.UnityHub                         < 3.21.0.65535       3.22.5.65535     winget'
            'Подсистема Windows для Linux                     Microsoft.WSL                          2.6.2.0              2.6.3.0          winget'
            'Доступных обновлений: 3.'
        )
        $r = @(ConvertFrom-WsWingetTable $lines)
        $r.Count | Should -Be 3
        $r[0].Id | Should -Be '7zip.7zip'; $r[0].Available | Should -Be '26.05'
        $r[1].Version | Should -Be '< 3.21.0.65535'
        $r[2].Name | Should -Be 'Подсистема Windows для Linux'; $r[2].Source | Should -Be 'winget'
    }
    It 'returns nothing without a table' {
        @(ConvertFrom-WsWingetTable @('No installed package found matching input criteria.')).Count | Should -Be 0
    }
}

Describe 'Get-WsAppCatalog' {
    It 'has unique, dotted ids' {
        $c = @(Get-WsAppCatalog)
        $c.Count | Should -BeGreaterThan 40
        @($c.Id | Sort-Object -Unique).Count | Should -Be $c.Count
        foreach ($i in $c.Id) { $i | Should -Match '^[^\s]+\.[^\s]+$' }
    }
}
