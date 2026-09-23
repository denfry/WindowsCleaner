# Pester tests for WinSenior.Schedule.ps1
# Run:  Invoke-Pester -Path .\tests
# Covers the pure planner Get-WinSeniorScheduleSpec plus the Program Files copy
# helpers (exercised against temp folders) - no task is registered, so the tests
# are safe and deterministic. Install/Remove call Register-/Unregister-
# ScheduledTask and are verified on a real machine.

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\WinSenior.Schedule.ps1'
    . $script:Sut
    $script:Spec = Get-WinSeniorScheduleSpec -Root 'C:\Users\me\src\WS' -InstallRoot 'C:\PF\WinSenior' -ReportDir 'C:\WS\reports'
}

Describe 'Get-WinSeniorScheduleSpec' {
    It 'returns two task specs' {
        @($script:Spec).Count | Should -Be 2
    }
    It 'places both tasks under the \WinSenior\ folder' {
        foreach ($s in $script:Spec) { $s.TaskPath | Should -Be '\WinSenior\' }
    }
    It 'launches powershell.exe with bypass and a hidden window' {
        foreach ($s in $script:Spec) {
            $s.Execute  | Should -Be 'powershell.exe'
            $s.Argument | Should -Match '-ExecutionPolicy Bypass'
            $s.Argument | Should -Match '-WindowStyle Hidden'
        }
    }
    It 'points every report under the given ReportDir' {
        foreach ($s in $script:Spec) {
            $s.Argument | Should -Match ([regex]::Escape('C:\WS\reports'))
        }
    }
    It 'runs the scripts from the install root, never from the source checkout' {
        foreach ($s in $script:Spec) {
            $s.Argument   | Should -Match ([regex]::Escape('"C:\PF\WinSenior\'))
            $s.Argument   | Should -Not -Match ([regex]::Escape('C:\Users\me\src'))
            $s.ScriptRoot | Should -Be 'C:\PF\WinSenior'
        }
    }
    It 'defaults the install root to Program Files\WinSenior' {
        Get-WinSeniorInstallRoot | Should -Match 'WinSenior$'
        $d = Get-WinSeniorScheduleSpec -Root 'C:\src'
        foreach ($s in $d) { $s.Argument | Should -Match ([regex]::Escape((Get-WinSeniorInstallRoot))) }
    }
    It 'runs the cleanup weekly, unattended, with no restore point' {
        $c = $script:Spec | Where-Object { $_.Name -match 'Cleanup' }
        $c.Cadence  | Should -Be 'Weekly'
        $c.Day      | Should -Be 'Sunday'
        $c.Argument | Should -Match '-Unattended'
        $c.Argument | Should -Match '-NoRestorePoint'
        $c.Argument | Should -Match 'Cleanup-Windows-Senior\.ps1'
    }
    It 'runs the health scan monthly and read-only' {
        $r = $script:Spec | Where-Object { $_.Name -match 'Scan' }
        $r.Cadence  | Should -Be 'Monthly'
        $r.Day      | Should -Be 1
        $r.Argument | Should -Match '-ScanOnly'
        $r.Argument | Should -Match 'Repair-Windows-Senior\.ps1'
    }
}

Describe 'Program Files copy helpers' {
    BeforeEach {
        $script:Src = Join-Path $env:TEMP ("ws-sched-src-{0}" -f [guid]::NewGuid().ToString('N'))
        $script:Dst = Join-Path $env:TEMP ("ws-sched-dst-{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Src, (Join-Path $script:Src 'tests') -Force | Out-Null
        foreach ($n in 'WinSenior.Common.ps1', 'Cleanup-Windows-Senior.ps1', 'Repair-Windows-Senior.ps1') {
            Set-Content -LiteralPath (Join-Path $script:Src $n) -Value "# $n" -Encoding ASCII
        }
        Set-Content -LiteralPath (Join-Path $script:Src 'README.md') -Value 'x' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:Src 'tests\x.Tests.ps1') -Value 'x' -Encoding ASCII
        $script:Quiet = { }
    }
    AfterEach {
        foreach ($p in $script:Src, $script:Dst) { if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
    }

    It 'lists only the root *.ps1 files' {
        $names = (Get-WinSeniorInstallFile -Root $script:Src).Name
        $names | Should -Contain 'WinSenior.Common.ps1'
        $names | Should -Not -Contain 'README.md'
        $names | Should -Not -Contain 'x.Tests.ps1'
        @($names).Count | Should -Be 3
    }
    It 'copies the scripts and drops stale ones from an older install' {
        New-Item -ItemType Directory -Path $script:Dst -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dst 'Old-Engine.ps1') -Value 'old' -Encoding ASCII
        Copy-WinSeniorInstallFile -Root $script:Src -InstallRoot $script:Dst -LogAction $script:Quiet | Should -BeTrue
        (Get-ChildItem -LiteralPath $script:Dst -Filter *.ps1).Name | Sort-Object |
            Should -Be @('Cleanup-Windows-Senior.ps1', 'Repair-Windows-Senior.ps1', 'WinSenior.Common.ps1')
    }
    It 'removes only a folder that looks like a WinSenior install' {
        New-Item -ItemType Directory -Path $script:Dst -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dst 'other.txt') -Value 'x' -Encoding ASCII
        Remove-WinSeniorInstallCopy -InstallRoot $script:Dst -LogAction $script:Quiet | Should -BeFalse
        Test-Path $script:Dst | Should -BeTrue

        Copy-WinSeniorInstallFile -Root $script:Src -InstallRoot $script:Dst -LogAction $script:Quiet | Out-Null
        Remove-WinSeniorInstallCopy -InstallRoot $script:Dst -LogAction $script:Quiet | Should -BeTrue
        Test-Path $script:Dst | Should -BeFalse
    }
    It 'never deletes the folder it is running from' {
        Remove-WinSeniorInstallCopy -InstallRoot $script:Src -Root $script:Src -LogAction $script:Quiet | Should -BeFalse
        Test-Path (Join-Path $script:Src 'WinSenior.Common.ps1') | Should -BeTrue
    }
}
