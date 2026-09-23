# Pester tests for WinSenior.Startup.ps1 - the startup-apps library behind the desktop
# app's Startup page. Every registry root and folder is injected: the tests build a
# throwaway key under HKCU:\Software\WinSeniorTest-<guid> and a temp folder, so the
# real Run keys and Startup folders are never read or written.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\WinSenior.Startup.ps1')

    $script:TestKey = "HKCU:\Software\WinSeniorTest-$([guid]::NewGuid().ToString('N'))"
    $script:UserRoot = "$script:TestKey\User"
    $script:MachineRoot = "$script:TestKey\Machine"
    $script:UserFolder = Join-Path $env:TEMP "winsenior-startup-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:UserFolder -Force | Out-Null

    $run = 'Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path "$script:UserRoot\$run" -Force | Out-Null
    New-Item -Path "$script:MachineRoot\$run" -Force | Out-Null
    New-ItemProperty -Path "$script:UserRoot\$run" -Name 'UserApp' -Value '"C:\Program Files\User App\app.exe" /background' -PropertyType String | Out-Null
    New-ItemProperty -Path "$script:UserRoot\$run" -Name 'Weird*Name' -Value 'C:\Tools\weird.exe' -PropertyType String | Out-Null
    New-ItemProperty -Path "$script:MachineRoot\$run" -Name 'MachineApp' -Value 'C:\Machine\svc.exe -silent' -PropertyType String | Out-Null
    Set-Content -LiteralPath (Join-Path $script:UserFolder 'notes.cmd') -Value '@echo off' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $script:UserFolder 'desktop.ini') -Value '[.ShellClassInfo]' -Encoding ASCII

    $script:Locations = Get-WinSeniorStartupLocation -UserRoot $script:UserRoot -MachineRoot $script:MachineRoot `
        -UserStartupFolder $script:UserFolder -CommonStartupFolder (Join-Path $script:UserFolder 'missing-common')
    $script:ApprovedRun = "$script:UserRoot\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
}

AfterAll {
    if ($script:TestKey -and (Test-Path $script:TestKey)) { Remove-Item -Path $script:TestKey -Recurse -Force }
    if ($script:UserFolder -and (Test-Path $script:UserFolder)) { Remove-Item -LiteralPath $script:UserFolder -Recurse -Force }
}

Describe 'Get-WinSeniorStartupLocation' {
    It 'maps every source to its StartupApproved key' {
        $l = Get-WinSeniorStartupLocation -UserRoot 'HKCU:\X' -MachineRoot 'HKLM:\Y' -UserStartupFolder 'C:\U' -CommonStartupFolder 'C:\C'
        @($l).Count | Should -Be 5
        ($l | Where-Object Location -eq 'HKCU Run').ApprovedKey | Should -Be 'HKCU:\X\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        ($l | Where-Object Location -eq 'HKLM Run (32-bit)').Path | Should -Be 'HKLM:\Y\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        ($l | Where-Object Location -eq 'HKLM Run (32-bit)').ApprovedKey | Should -Match 'StartupApproved\\Run32$'
        ($l | Where-Object Location -eq 'Startup folder').ApprovedKey | Should -Match '^HKCU:\\X\\.*StartupApproved\\StartupFolder$'
        ($l | Where-Object Location -eq 'Common Startup folder').ApprovedKey | Should -Match '^HKLM:\\Y\\.*StartupApproved\\StartupFolder$'
    }
}

Describe 'ConvertFrom-StartupApprovedValue' {
    It 'treats a missing value as enabled' { ConvertFrom-StartupApprovedValue $null | Should -BeTrue }
    It 'reads 0x02 as enabled'  { ConvertFrom-StartupApprovedValue ([byte[]](2,0,0,0,0,0,0,0,0,0,0,0)) | Should -BeTrue }
    It 'reads 0x06 as enabled'  { ConvertFrom-StartupApprovedValue ([byte[]](6,0,0,0)) | Should -BeTrue }
    It 'reads 0x03 as disabled' { ConvertFrom-StartupApprovedValue ([byte[]](3,0,0,0,1,2,3,4,5,6,7,8)) | Should -BeFalse }
}

Describe 'ConvertTo-StartupApprovedValue' {
    It 'writes the 12-byte enabled form' {
        $b = ConvertTo-StartupApprovedValue -Enabled $true
        $b.Length | Should -Be 12
        $b[0] | Should -Be 2
        ($b | Measure-Object -Sum).Sum | Should -Be 2
    }
    It 'writes the disabled form with a FILETIME' {
        $when = [datetime]'2026-01-02T03:04:05Z'
        $b = ConvertTo-StartupApprovedValue -Enabled $false -When $when
        $b[0] | Should -Be 3
        [BitConverter]::ToInt64($b, 4) | Should -Be $when.ToFileTimeUtc()
    }
}

Describe 'Get-WinSeniorStartupTarget' {
    It 'unquotes a quoted path'       { Get-WinSeniorStartupTarget '"C:\A B\x.exe" /min' | Should -Be 'C:\A B\x.exe' }
    It 'finds an unquoted exe with spaces' { Get-WinSeniorStartupTarget 'C:\Program Files\Foo\foo.exe -silent' | Should -Be 'C:\Program Files\Foo\foo.exe' }
    It 'handles rundll32 style'       { Get-WinSeniorStartupTarget 'rundll32.exe shell32.dll,Control_RunDLL' | Should -Be 'rundll32.exe' }
    It 'returns null for empty'       { Get-WinSeniorStartupTarget '' | Should -BeNullOrEmpty }
}

Describe 'Get-WinSeniorStartupItem' {
    BeforeAll { $script:Items = @(Get-WinSeniorStartupItem -Locations $script:Locations) }

    It 'lists registry and folder entries (desktop.ini skipped)' {
        $script:Items.Name | Should -Contain 'UserApp'
        $script:Items.Name | Should -Contain 'Weird*Name'
        $script:Items.Name | Should -Contain 'MachineApp'
        $script:Items.Name | Should -Contain 'notes.cmd'
        $script:Items.Name | Should -Not -Contain 'desktop.ini'
        $script:Items.Count | Should -Be 4
    }
    It 'reports location, scope, command and target' {
        $u = $script:Items | Where-Object Name -eq 'UserApp'
        $u.Location | Should -Be 'HKCU Run'
        $u.Scope    | Should -Be 'Current user'
        $u.Command  | Should -Match 'app\.exe'
        $u.Target   | Should -Be 'C:\Program Files\User App\app.exe'
        ($script:Items | Where-Object Name -eq 'MachineApp').Scope | Should -Be 'All users'
    }
    It 'is enabled when no StartupApproved value exists' {
        foreach ($i in $script:Items) { $i.Enabled | Should -BeTrue }
    }
    It 'reads a disabled StartupApproved value' {
        New-Item -Path $script:ApprovedRun -Force | Out-Null
        New-ItemProperty -Path $script:ApprovedRun -Name 'UserApp' -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -PropertyType Binary -Force | Out-Null
        $u = Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'UserApp'
        $u.Enabled | Should -BeFalse
        Remove-ItemProperty -Path $script:ApprovedRun -Name 'UserApp'
    }
    It 'also answers to the plural alias' {
        @(Get-WinSeniorStartupItems -Locations $script:Locations).Count | Should -Be 4
    }
}

Describe 'Set-WinSeniorStartupItemState' {
    It 'disables and re-enables through StartupApproved only' {
        $runKey = "$script:UserRoot\Microsoft\Windows\CurrentVersion\Run"
        $before = (Get-ItemProperty -LiteralPath $runKey).UserApp
        $item = Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'UserApp'

        Set-WinSeniorStartupItemState -Item $item -Enabled $false | Out-Null
        $raw = (Get-ItemProperty -LiteralPath $script:ApprovedRun).UserApp
        $raw[0] | Should -Be 3
        $raw.Length | Should -Be 12
        (Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'UserApp').Enabled | Should -BeFalse
        (Get-ItemProperty -LiteralPath $runKey).UserApp | Should -Be $before

        Set-WinSeniorStartupItemState -Item $item -Enabled $true | Out-Null
        (Get-ItemProperty -LiteralPath $script:ApprovedRun).UserApp[0] | Should -Be 2
        (Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'UserApp').Enabled | Should -BeTrue
        (Get-ItemProperty -LiteralPath $runKey).UserApp | Should -Be $before
    }
    It 'handles value names with wildcard characters literally' {
        $item = Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'Weird*Name'
        Set-WinSeniorStartupItemState -Item $item -Enabled $false | Out-Null
        (Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'Weird*Name').Enabled | Should -BeFalse
        (Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'UserApp').Enabled | Should -BeTrue
    }
    It 'toggles a Startup-folder item without touching the file' {
        $item = Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'notes.cmd'
        Set-WinSeniorStartupItemState -Item $item -Enabled $false | Out-Null
        (Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'notes.cmd').Enabled | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:UserFolder 'notes.cmd') | Should -BeTrue
    }
    It 'changes nothing under -WhatIf' {
        $item = Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'MachineApp'
        Set-WinSeniorStartupItemState -Item $item -Enabled $false -WhatIf | Out-Null
        (Get-WinSeniorStartupItem -Locations $script:Locations | Where-Object Name -eq 'MachineApp').Enabled | Should -BeTrue
    }
}
