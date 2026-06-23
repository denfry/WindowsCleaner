# Pester tests for the pure logic of Optimize-Windows-Senior.ps1
# Run:  Invoke-Pester -Path .\tests
# Covers tweak-registry integrity, selection, and a registry backup->apply->undo round-trip.

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\Optimize-Windows-Senior.ps1'
    # Dot-sourcing is a no-op for the main flow (entry guard checks InvocationName -eq '.').
    . $script:Sut
    $script:Reg = Get-OptimizationTweakRegistry
}

Describe 'Get-OptimizationTweakRegistry' {
    It 'returns a non-empty set of tweaks' {
        $script:Reg.Count | Should -BeGreaterThan 20
    }
    It 'gives every tweak a unique id' {
        ($script:Reg.Id | Sort-Object -Unique).Count | Should -Be $script:Reg.Count
    }
    It 'only uses known areas' {
        $known = 'Performance','Privacy','Debloat','Network'
        ($script:Reg | Where-Object { $_.Area -notin $known }) | Should -BeNullOrEmpty
    }
    It 'only uses known risk tiers' {
        $known = 'Safe','Moderate','Aggressive','Dangerous'
        ($script:Reg | Where-Object { $_.Risk -notin $known }) | Should -BeNullOrEmpty
    }
    It 'only uses known tweak types' {
        $known = 'Registry','Service','ScheduledTask','Custom'
        ($script:Reg | Where-Object { $_.Type -notin $known }) | Should -BeNullOrEmpty
    }
    It 'gives every tweak a non-empty explanation' {
        ($script:Reg | Where-Object { [string]::IsNullOrWhiteSpace($_.Explain) }) | Should -BeNullOrEmpty
    }
    It 'gives Registry tweaks a path and at least one value' {
        foreach ($t in ($script:Reg | Where-Object Type -eq 'Registry')) {
            $t.Spec.Path   | Should -Not -BeNullOrEmpty
            @($t.Spec.Values).Count | Should -BeGreaterThan 0
        }
    }
    It 'gives Service tweaks a service name and startup type' {
        foreach ($t in ($script:Reg | Where-Object Type -eq 'Service')) {
            $t.Spec.Service | Should -Not -BeNullOrEmpty
            $t.Spec.Startup | Should -BeIn @('Disabled','Manual','Automatic')
        }
    }
    It 'gives Custom tweaks an apply and undo scriptblock' {
        foreach ($t in ($script:Reg | Where-Object Type -eq 'Custom')) {
            $t.Spec.Apply | Should -BeOfType ([scriptblock])
            $t.Spec.Undo  | Should -BeOfType ([scriptblock])
        }
    }
}

Describe 'Resolve-TweakSelection' {
    It 'selects Safe and Moderate default-on tweaks out of the box' {
        $sel = Resolve-TweakSelection -Registry $script:Reg
        @($sel | Where-Object Risk -eq 'Safe').Count     | Should -BeGreaterThan 0
        @($sel | Where-Object Risk -eq 'Moderate').Count | Should -BeGreaterThan 0
    }
    It 'leaves default-off tweaks out by default' {
        $sel = Resolve-TweakSelection -Registry $script:Reg
        @($sel | Where-Object Id -eq 'perf-sysmain').Count | Should -Be 0
    }
    It 'lets -Include force a default-off tweak on' {
        $sel = Resolve-TweakSelection -Registry $script:Reg -Include 'perf-sysmain'
        @($sel | Where-Object Id -eq 'perf-sysmain').Count | Should -Be 1
    }
    It 'honours -Exclude over the default' {
        $sel = Resolve-TweakSelection -Registry $script:Reg -Exclude 'priv-adid'
        @($sel | Where-Object Id -eq 'priv-adid').Count | Should -Be 0
    }
    It 'lets -Exclude win over -Include' {
        $sel = Resolve-TweakSelection -Registry $script:Reg -Include 'priv-adid' -Exclude 'priv-adid'
        @($sel | Where-Object Id -eq 'priv-adid').Count | Should -Be 0
    }
    It 'limits to the requested area' {
        $sel = Resolve-TweakSelection -Registry $script:Reg -Area 'Privacy'
        @($sel | Where-Object Area -ne 'Privacy').Count | Should -Be 0
    }
}

Describe 'Registry value backup / restore' {
    BeforeAll {
        $script:TestKey = 'HKCU:\Software\WinSeniorTest'
        if (Test-Path $script:TestKey) { Remove-Item $script:TestKey -Recurse -Force }
    }
    AfterAll {
        if (Test-Path $script:TestKey) { Remove-Item $script:TestKey -Recurse -Force }
    }
    It 'restores a previously-absent value by removing it' {
        $snap = Get-RegValueSnapshot -Path $script:TestKey -Name 'Foo'
        $snap.Existed | Should -BeFalse
        Set-RegValue -Path $script:TestKey -Name 'Foo' -Kind DWord -Value 1
        (Get-ItemProperty $script:TestKey -Name Foo).Foo | Should -Be 1
        Restore-RegValue -Path $script:TestKey -Snap $snap
        (Get-Item $script:TestKey).GetValueNames() | Should -Not -Contain 'Foo'
    }
    It 'restores a previously-existing value to its old data' {
        Set-RegValue -Path $script:TestKey -Name 'Bar' -Kind DWord -Value 5
        $snap = Get-RegValueSnapshot -Path $script:TestKey -Name 'Bar'
        $snap.Existed | Should -BeTrue
        $snap.Value   | Should -Be 5
        Set-RegValue -Path $script:TestKey -Name 'Bar' -Kind DWord -Value 9
        (Get-ItemProperty $script:TestKey -Name Bar).Bar | Should -Be 9
        Restore-RegValue -Path $script:TestKey -Snap $snap
        (Get-ItemProperty $script:TestKey -Name Bar).Bar | Should -Be 5
    }
}

Describe 'Tweak-level apply / undo (Registry type)' {
    BeforeAll {
        $script:TestKey2 = 'HKCU:\Software\WinSeniorTest'
        if (Test-Path $script:TestKey2) { Remove-Item $script:TestKey2 -Recurse -Force }
    }
    AfterAll {
        if (Test-Path $script:TestKey2) { Remove-Item $script:TestKey2 -Recurse -Force }
    }
    It 'applies via Set-TweakState and reverts via Restore-Tweak' {
        $t = New-RegTweak rt-test 'round-trip test' Performance Safe `
                -Path $script:TestKey2 -Values @((RegVal 'Vfx' DWord 2)) -Explain 'test'
        Test-TweakApplied -Tweak $t | Should -BeFalse
        $snap = Get-TweakSnapshot -Tweak $t
        Set-TweakState -Tweak $t -Snapshot $snap
        Test-TweakApplied -Tweak $t | Should -BeTrue
        $entry = [pscustomobject]@{ Id = 'rt-test'; Type = 'Registry'; Snapshot = $snap }
        Restore-Tweak -Entry $entry -Registry @($t)
        Test-TweakApplied -Tweak $t | Should -BeFalse
    }
}
