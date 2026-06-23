# Pester tests for the pure logic of Repair-Windows-Senior.ps1
# Run:  Invoke-Pester -Path .\tests
# Covers the check registry, selection, and scan/fix dispatch using synthetic checks
# (no real DISM / network calls, so the tests are fast and deterministic).

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\Repair-Windows-Senior.ps1'
    # Dot-sourcing is a no-op for the main flow (entry guard checks InvocationName -eq '.').
    . $script:Sut
    $script:Reg = Get-DiagnosticCheckRegistry
}

Describe 'Get-DiagnosticCheckRegistry' {
    It 'returns a non-empty set of checks' {
        $script:Reg.Count | Should -BeGreaterThan 10
    }
    It 'gives every check a unique id' {
        ($script:Reg.Id | Sort-Object -Unique).Count | Should -Be $script:Reg.Count
    }
    It 'only uses known categories' {
        $known = 'Integrity','Disk','Update','Network','Devices','Services','Security','System'
        ($script:Reg | Where-Object { $_.Category -notin $known }) | Should -BeNullOrEmpty
    }
    It 'gives every check a Scan scriptblock' {
        foreach ($c in $script:Reg) { $c.Scan | Should -BeOfType ([scriptblock]) }
    }
    It 'gives every fixable check a known FixRisk and a label' {
        foreach ($c in ($script:Reg | Where-Object Fix)) {
            $c.FixRisk  | Should -BeIn @('Safe','Moderate','Aggressive')
            $c.FixLabel | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Resolve-CheckSelection' {
    It 'limits to the requested category' {
        $sel = Resolve-CheckSelection -Registry $script:Reg -Category 'Disk'
        @($sel | Where-Object Category -ne 'Disk').Count | Should -Be 0
        @($sel).Count | Should -BeGreaterThan 0
    }
    It 'honours -Exclude' {
        $sel = Resolve-CheckSelection -Registry $script:Reg -Exclude 'disk-smart'
        @($sel | Where-Object Id -eq 'disk-smart').Count | Should -Be 0
    }
    It 'lets -Exclude win over -Include' {
        $sel = Resolve-CheckSelection -Registry $script:Reg -Include 'img-health' -Exclude 'img-health'
        @($sel | Where-Object Id -eq 'img-health').Count | Should -Be 0
    }
}

Describe 'Invoke-Scan / Invoke-Fix (synthetic checks)' {
    It 'wraps a scan result and flags it as fixable' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = 'Warn'; Detail = 'd' } } `
                -Fix { } -FixRisk Safe -FixLabel 'x'
        $r = Invoke-Scan -Check $c
        $r.Status | Should -Be 'Warn'
        $r.HasFix | Should -BeTrue
    }
    It 'turns a throwing scan into Skip' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { throw 'boom' }
        (Invoke-Scan -Check $c).Status | Should -Be 'Skip'
    }
    It 'reports a report-only check as not fixable' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = 'Fail'; Detail = 'd' } }
        (Invoke-Scan -Check $c).HasFix | Should -BeFalse
    }
    It 'runs the fix and returns true' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = 'Warn'; Detail = 'd' } } `
                -Fix { } -FixRisk Safe -FixLabel 'x'
        Invoke-Fix -Check $c | Should -BeTrue
    }
    It 'honours -WhatIf (does not run the fix)' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = 'Warn'; Detail = 'd' } } `
                -Fix { throw 'should not run under WhatIf' } -FixRisk Safe -FixLabel 'x'
        Invoke-Fix -Check $c -WhatIf | Should -BeFalse
    }
}
