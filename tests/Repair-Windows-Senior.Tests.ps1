# Pester tests for the pure logic of Repair-Windows-Senior.ps1
# Run:  Invoke-Pester -Path .\tests
# Covers the check registry, selection, and scan/fix dispatch using synthetic checks
# (no DISM / network calls, so the tests are fast and deterministic), plus real runs of
# a few cheap read-only registry/CIM scans.

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\Repair-Windows-Senior.ps1'
    # Dot-sourcing is a no-op for the main flow (entry guard checks InvocationName -eq '.').
    . $script:Sut
    $script:Reg = Get-DiagnosticCheckRegistry
}

Describe 'Get-DiagnosticCheckRegistry' {
    It 'returns a non-empty set of checks' {
        $script:Reg.Count | Should -BeGreaterThan 40
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
    It 'contains every new check id with a known category' {
        $known = 'Integrity','Disk','Update','Network','Devices','Services','Security','System'
        $new = 'svc-defaults', 'wu-policy', 'wu-history', 'shell-appx', 'winre', 'secureboot-cert', 'pagefile',
               'winsock-lsp', 'net-adapter', 'bitlocker', 'uac-enabled', 'env-path', 'verifier-on', 'activation',
               'trim', 'rootcert-update', 'search-health', 'def-exclusions'
        foreach ($id in $new) {
            $c = $script:Reg | Where-Object Id -eq $id
            $c          | Should -Not -BeNullOrEmpty -Because "$id must be registered"
            $c.Category | Should -BeIn $known
        }
    }
    It 'keeps the report-only checks without a fix' {
        foreach ($id in 'wu-history', 'secureboot-cert', 'activation', 'def-exclusions', 'disk-reliability', 'crash-history') {
            ($script:Reg | Where-Object Id -eq $id).Fix | Should -BeNullOrEmpty
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
    It 'runs only the -Include ids when no -Category is given' {
        $sel = @(Resolve-CheckSelection -Registry $script:Reg -Include 'uac-enabled', 'trim')
        ($sel.Id | Sort-Object) -join ',' | Should -Be 'trim,uac-enabled'
    }
    It 'splits a comma-joined -Include string (as powershell -File passes it)' {
        $sel = @(Resolve-CheckSelection -Registry $script:Reg -Include 'uac-enabled,trim, img-health')
        ($sel.Id | Sort-Object) -join ',' | Should -Be 'img-health,trim,uac-enabled'
    }
    It 'treats an empty -Exclude as no exclusion' {
        @(Resolve-CheckSelection -Registry $script:Reg -Exclude '').Count | Should -Be $script:Reg.Count
    }
    It 'adds -Include ids to a -Category set' {
        $sel = @(Resolve-CheckSelection -Registry $script:Reg -Category 'Disk' -Include 'uac-enabled')
        $sel.Id | Should -Contain 'uac-enabled'
        $sel.Id | Should -Contain 'disk-space'
    }
}

Describe 'ConvertTo-RepIdList' {
    It 'splits, trims and drops empties' {
        (ConvertTo-RepIdList @('a,b', ' c ', '', 'd,,')) -join '|' | Should -Be 'a|b|c|d'
    }
    It 'returns nothing for null' {
        @(ConvertTo-RepIdList $null).Count | Should -Be 0
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
    It 'applies per-result NoFix / FixRisk / Reboot overrides' {
        $c = New-DiagnosticCheck syn 'synthetic' Network -Scan { @{ Status = 'Warn'; Detail = 'd'; FixRisk = 'Safe'; Reboot = $false } } `
                -Fix { } -FixRisk Aggressive -FixLabel 'x' -Reboot $true
        $r = Invoke-Scan -Check $c
        $r.FixRisk | Should -Be 'Safe'
        $r.Reboot  | Should -BeFalse
        $c2 = New-DiagnosticCheck syn2 'synthetic' Network -Scan { @{ Status = 'Warn'; Detail = 'd'; NoFix = $true } } -Fix { } -FixLabel 'x'
        (Invoke-Scan -Check $c2).HasFix | Should -BeFalse
    }
    It 'keeps the hashtable when a scan leaks extra pipeline output' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { 'noise'; @{ Status = 'OK'; Detail = 'd' } }
        (Invoke-Scan -Check $c).Status | Should -Be 'OK'
    }
    It 'counts a fix as Fixed only when the re-scan is OK, and updates the report row' {
        $state = @{ S = 'Warn' }
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = $state.S; Detail = "now $($state.S)" } }.GetNewClosure() `
                -Fix { $state.S = 'OK' }.GetNewClosure() -FixRisk Safe -FixLabel 'x'
        $row = Invoke-Scan -Check $c
        Invoke-Fix -Check $c -Result $row | Should -Be 'Fixed'
        $row.Status       | Should -Be 'OK'
        $row.PreFixStatus | Should -Be 'Warn'
        $row.FixOutcome   | Should -Be 'Fixed'
        $row.Detail       | Should -Be 'now OK'
    }
    It 'reports StillFailing when the fix ran but the problem remains' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = 'Fail'; Detail = 'd' } } `
                -Fix { } -FixRisk Safe -FixLabel 'x'
        Invoke-Fix -Check $c | Should -Be 'StillFailing'
    }
    It 'reports PendingReboot for a reboot fix whose effect is not visible yet' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = 'Warn'; Detail = 'd' } } `
                -Fix { } -FixRisk Moderate -FixLabel 'x' -Reboot $true
        Invoke-Fix -Check $c | Should -Be 'PendingReboot'
    }
    It 'reports Error when the fix throws' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = 'Warn'; Detail = 'd' } } `
                -Fix { throw 'nope' } -FixRisk Safe -FixLabel 'x'
        Invoke-Fix -Check $c | Should -Be 'Error'
    }
    It 'honours -WhatIf (does not run the fix, counts it as previewed)' {
        $c = New-DiagnosticCheck syn 'synthetic' Disk -Scan { @{ Status = 'Warn'; Detail = 'd' } } `
                -Fix { throw 'should not run under WhatIf' } -FixRisk Safe -FixLabel 'x'
        $row = Invoke-Scan -Check $c
        Invoke-Fix -Check $c -Result $row -WhatIf | Should -Be 'Previewed'
        $row.Status     | Should -Be 'Warn'
        $row.FixOutcome | Should -Be 'Previewed'
    }
}

Describe 'Get-WuErrorRoute' {
    It 'routes <Code> to <Route>' -ForEach @(
        @{ Code = '0x800F081F'; Route = 'img-health' }
        @{ Code = '800f0831';   Route = 'img-health' }
        @{ Code = '0x80070643'; Route = 'winre' }
        @{ Code = '0x80070422'; Route = 'svc-defaults' }
        @{ Code = '0x80072EFD'; Route = 'net-connectivity/proxy-hijack' }
        @{ Code = '0x8007000D'; Route = 'wu-health' }
        @{ Code = '0x80242014'; Route = 'reboot-pending' }
        @{ Code = '0x80070070'; Route = 'disk-space' }
        @{ Code = '0x80072F8F'; Route = 'time-sync' }
    ) {
        Get-WuErrorRoute $Code | Should -Be $Route
    }
    It 'accepts a negative Int32 HResult as returned by the COM API' {
        Get-WuErrorRoute ([int]-2146498529) | Should -Be 'img-health'   # 0x800F081F
    }
    It 'accepts a positive Int64 HResult' {
        Get-WuErrorRoute ([int64]2147944003) | Should -Be 'winre'         # 0x80070643
    }
    It 'returns nothing for unknown or empty codes' {
        Get-WuErrorRoute '0x12345678' | Should -BeNullOrEmpty
        Get-WuErrorRoute $null        | Should -BeNullOrEmpty
        Get-WuErrorRoute ''           | Should -BeNullOrEmpty
    }
}

Describe 'Test-RepHostsHijackLine' {
    It 'flags <Line>' -ForEach @(
        @{ Line = '0.0.0.0 fe2.update.microsoft.com' }
        @{ Line = '127.0.0.1  download.windowsupdate.com  # blocked' }
        @{ Line = '1.2.3.4 activation-v2.sls.microsoft.com' }
        @{ Line = '0.0.0.0 wdcp.microsoft.com' }
        @{ Line = '0.0.0.0 www.msftconnecttest.com' }
    ) {
        Test-RepHostsHijackLine $Line | Should -BeTrue
    }
    It 'ignores <Line>' -ForEach @(
        @{ Line = '# 0.0.0.0 windowsupdate.com' }
        @{ Line = '0.0.0.0 ads.example.com' }
        @{ Line = '0.0.0.0 office.com' }
        @{ Line = '0.0.0.0 notupdate.microsoft.com.evil.net' }
        @{ Line = '127.0.0.1 localhost' }
        @{ Line = '' }
    ) {
        Test-RepHostsHijackLine $Line | Should -BeFalse
    }
}

Describe 'Fix policy' {
    It 'rates SMBv1 removal Moderate (old NAS may break)' {
        ($script:Reg | Where-Object Id -eq 'smb1-disabled').FixRisk | Should -Be 'Moderate'
    }
    It 'never schedules a restart from reboot-pending' {
        "$(($script:Reg | Where-Object Id -eq 'reboot-pending').Fix)" | Should -Not -Match 'shutdown'
    }
    It 'only removes BITS jobs in Error state' {
        "$(($script:Reg | Where-Object Id -eq 'bits-health').Fix)" | Should -Match "'Error'"
    }
    It 'keeps all fix risks within the allowed tiers' {
        foreach ($c in ($script:Reg | Where-Object Fix)) { $c.FixRisk | Should -BeIn @('Safe', 'Moderate', 'Aggressive') }
    }
}

Describe 'Real read-only scans (cheap ones)' {
    It 'scan <Id> returns a valid status' -ForEach @(
        @{ Id = 'svc-defaults' }, @{ Id = 'wu-policy' }, @{ Id = 'uac-enabled' }, @{ Id = 'env-path' },
        @{ Id = 'verifier-on' }, @{ Id = 'trim' }, @{ Id = 'rootcert-update' }, @{ Id = 'pagefile' }
    ) {
        $c = $script:Reg | Where-Object Id -eq $Id
        $raw = & $c.Scan
        $raw | Should -BeOfType ([hashtable])
        $raw.Status | Should -BeIn @('OK', 'Warn', 'Fail', 'Skip')
        $raw.Detail | Should -Not -BeNullOrEmpty
    }
}
