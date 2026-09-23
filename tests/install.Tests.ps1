# Pester tests for the one-line web installer (install.ps1), run against a fake local
# "release" folder so nothing is downloaded and nothing outside $TestDrive is touched.

BeforeAll {
    $script:Installer = [scriptblock]::Create((Get-Content (Join-Path $PSScriptRoot '..\install.ps1') -Raw))

    function New-FakeRelease {
        param([string]$Dir, [switch]$Tamper)
        $payload = Join-Path $Dir 'payload'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        Set-Content -Path (Join-Path $payload 'WinSenior.Gui.ps1') -Value '# gui'
        Set-Content -Path (Join-Path $payload 'WinSenior.cmd') -Value '@echo off'
        $zip = Join-Path $Dir 'WinSenior-9.9.9.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($zip)) | ForEach-Object { $_.ToString('X2') })
        if ($Tamper) { $hash = ('0' * 64) }
        "$hash  WinSenior-9.9.9.zip`r`nABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789  install.ps1" |
            Set-Content -Path (Join-Path $Dir 'SHA256SUMS.txt') -Encoding ASCII
    }
}

Describe 'install.ps1' {
    It 'installs a verified release and leaks nothing into the caller' {
        $rel = Join-Path $TestDrive 'rel-ok'; New-FakeRelease -Dir $rel
        $root = Join-Path $TestDrive 'root-ok'
        $before = $ErrorActionPreference
        & $script:Installer -Source $rel -InstallRoot $root -NoLaunch -NoShortcut 6>$null
        Test-Path (Join-Path $root 'app\WinSenior.Gui.ps1') | Should -BeTrue
        $ErrorActionPreference | Should -Be $before
        Get-Command Invoke-WinSeniorInstall -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'refuses a zip whose SHA256 does not match and keeps the old install' {
        $good = Join-Path $TestDrive 'rel-good'; New-FakeRelease -Dir $good
        $bad  = Join-Path $TestDrive 'rel-bad';  New-FakeRelease -Dir $bad -Tamper
        $root = Join-Path $TestDrive 'root-bad'
        & $script:Installer -Source $good -InstallRoot $root -NoLaunch -NoShortcut 6>$null
        Set-Content -Path (Join-Path $root 'app\marker.txt') -Value 'old'
        & $script:Installer -Source $bad -InstallRoot $root -NoLaunch -NoShortcut 6>$null
        Test-Path (Join-Path $root 'app\marker.txt') | Should -BeTrue
    }

    It 'uninstalls the app folder' {
        $rel = Join-Path $TestDrive 'rel-un'; New-FakeRelease -Dir $rel
        $root = Join-Path $TestDrive 'root-un'
        & $script:Installer -Source $rel -InstallRoot $root -NoLaunch -NoShortcut 6>$null
        & $script:Installer -Source $rel -InstallRoot $root -Uninstall -NoShortcut 6>$null
        Test-Path (Join-Path $root 'app') | Should -BeFalse
    }
}
