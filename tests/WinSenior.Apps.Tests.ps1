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
    It 'does not trust an InstallLocation whose name is unrelated to the app (D:\Games)' {
        $a = [pscustomobject]@{ Name = 'Cool Game'; Publisher = 'Cool Soft'; InstallLocation = 'D:\Games' }
        Get-WsLeftoverConfidence ([pscustomobject]@{ Path = 'D:\Games'; Leaf = 'Games' }) $a | Should -Be 'Bad'
        $b = [pscustomobject]@{ Name = 'Cool Game'; Publisher = 'Cool Soft'; InstallLocation = 'D:\Stuff\Archive' }
        Get-WsLeftoverConfidence ([pscustomobject]@{ Path = 'D:\Stuff\Archive'; Leaf = 'Archive' }) $b | Should -Be 'Bad'
    }
    It 'trusts an InstallLocation named after the publisher' {
        $a = [pscustomobject]@{ Name = 'Cool Editor'; Publisher = 'Cool Soft'; InstallLocation = 'D:\Apps\CoolSoft' }
        Get-WsLeftoverConfidence ([pscustomobject]@{ Path = 'D:\Apps\CoolSoft'; Leaf = 'CoolSoft' }) $a | Should -Be 'VeryGood'
    }
}

Describe 'Get-WsUninstallCommand scope' {
    It 'marks HKCU entries to run without elevation' {
        (Get-WsUninstallCommand ([pscustomobject]@{ Source = 'Win32'; Scope = 'User'; ProductCode = $null; QuietUninstallString = '"C:\Users\u\evil.exe"'; UninstallString = 'x' })).RunAsUser | Should -BeTrue
        (Get-WsUninstallCommand ([pscustomobject]@{ Source = 'MSI'; Scope = 'User'; ProductCode = '{A}'; QuietUninstallString = ''; UninstallString = '' })).RunAsUser | Should -BeTrue
        (Get-WsUninstallCommand ([pscustomobject]@{ Source = 'Win32'; Scope = 'Machine'; ProductCode = $null; QuietUninstallString = '"C:\P\u.exe"'; UninstallString = 'x' })).RunAsUser | Should -BeFalse
    }
}

Describe 'protected paths' {
    BeforeAll { $script:Set = New-WsProtectedSet @('C:\Windows', 'C:\Program Files', 'D:\Profiles\Ann', 'D:\Profiles\Ann\Documents') }
    It 'blocks drive roots, protected folders and their parents' {
        foreach ($p in 'C:\', 'D:', 'C:\Windows', 'c:\program files\', 'D:\Profiles', 'D:\Profiles\Ann', '\\srv\share') {
            Test-WsProtectedPath -Path $p -ProtectedSet $script:Set | Should -BeTrue -Because $p
        }
    }
    It 'allows folders inside a protected folder' {
        Test-WsProtectedPath -Path 'C:\Program Files\Cool Editor' -ProtectedSet $script:Set | Should -BeFalse
        Test-WsProtectedPath -Path 'D:\Profiles\Ann\AppData\Roaming\Cool' -ProtectedSet $script:Set | Should -BeFalse
    }
    It 'knows the real Program Files, profile and Documents of this machine' {
        $real = New-WsProtectedSet (Get-WsProtectedPath)
        foreach ($p in $env:ProgramFiles, $env:USERPROFILE, [Environment]::GetFolderPath('MyDocuments'), (Split-Path $env:USERPROFILE)) {
            Test-WsProtectedPath -Path $p -ProtectedSet $real | Should -BeTrue -Because $p
        }
    }
}

Describe 'leftover safety checks and quarantine' {
    BeforeAll {
        $script:Base = Join-Path $TestDrive 'lo'
        New-Item -ItemType Directory -Path $script:Base -Force | Out-Null
        $script:Empty = New-WsProtectedSet @()
        function New-Lo { param([string]$Name) $p = Join-Path $script:Base $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }
    }
    It 'allows a plain data folder' {
        $p = New-Lo 'Cool Editor'; Set-Content (Join-Path $p 'settings.ini') 'x'
        Get-WsLeftoverBlocker ([pscustomobject]@{ Kind = 'Folder'; Path = $p }) -ProtectedSet $script:Empty -UserData @() | Should -BeNullOrEmpty
    }
    It 'keeps a folder that still contains programs' {
        $p = New-Lo 'WithExe'; New-Item -ItemType Directory (Join-Path $p 'bin') | Out-Null; Set-Content (Join-Path $p 'bin\tool.exe') 'x'
        Get-WsLeftoverBlocker ([pscustomobject]@{ Kind = 'Folder'; Path = $p }) -ProtectedSet $script:Empty -UserData @() | Should -Match 'programs'
    }
    It 'keeps a folder with a subfolder of another installed app' {
        $p = New-Lo 'Suite'; New-Item -ItemType Directory (Join-Path $p 'Other Tool') | Out-Null
        Get-WsLeftoverBlocker ([pscustomobject]@{ Kind = 'Folder'; Path = $p }) -Remaining @([pscustomobject]@{ Name = 'Other Tool'; InstallLocation = '' }) -ProtectedSet $script:Empty -UserData @() |
            Should -Match 'another installed app'
    }
    It 'keeps personal folders, protected folders, links and 8.3 paths' {
        $p = New-Lo 'Docs\Cool'
        Get-WsLeftoverBlocker ([pscustomobject]@{ Kind = 'Folder'; Path = $p }) -ProtectedSet $script:Empty -UserData @((Join-Path $script:Base 'Docs')) | Should -Match 'personal'
        Get-WsLeftoverBlocker ([pscustomobject]@{ Kind = 'Folder'; Path = $p }) -ProtectedSet (New-WsProtectedSet @("$p\x")) -UserData @() | Should -Match 'protected'
        Get-WsLeftoverBlocker ([pscustomobject]@{ Kind = 'Folder'; Path = 'C:\PROGRA~1\Cool' }) -ProtectedSet $script:Empty -UserData @() | Should -Match '8\.3'
        $t = New-Lo 'Target'; $j = Join-Path $script:Base 'Junction'
        cmd /c mklink /J "$j" "$t" | Out-Null
        Get-WsLeftoverBlocker ([pscustomobject]@{ Kind = 'Folder'; Path = $j }) -ProtectedSet $script:Empty -UserData @() | Should -Match 'link'
    }
    It 'moves a leftover to quarantine instead of deleting it, without following junctions' {
        $p = New-Lo 'Gone App'; Set-Content (Join-Path $p 'a.txt') 'x'
        $keep = New-Lo 'Precious'; Set-Content (Join-Path $keep 'data.txt') 'keep me'
        cmd /c mklink /J "$(Join-Path $p 'link')" "$keep" | Out-Null
        $q = Join-Path $script:Base 'Q'
        Mock Get-WsLeftoverBlocker { $null }       # TestDrive sits in %TEMP%; the checks are tested above
        $n = Remove-WsAppLeftover -Leftovers @([pscustomobject]@{ Kind = 'Folder'; Path = $p; Confidence = 'VeryGood'; SizeBytes = 1 }) -QuarantineRoot $q 6>$null
        $n | Should -Be 1
        Test-Path $p | Should -BeFalse
        $batch = @(Get-ChildItem $q -Directory)[0].FullName
        Test-Path (Join-Path $batch '01-Gone App\a.txt') | Should -BeTrue
        Test-Path (Join-Path $batch 'manifest.json') | Should -BeTrue
        # purge after 30 days: the junction is removed, its target survives
        (Get-Item $batch).CreationTime = (Get-Date).AddDays(-31)
        Clear-WsAppQuarantine -Root $q | Should -Be 1
        Test-Path $batch | Should -BeFalse
        Get-Content (Join-Path $keep 'data.txt') | Should -Be 'keep me'
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
