# Pester tests for WinSenior.Insights.ps1 (pure parts) and the disk-history
# sampler in WinSenior.Common.ps1 (redirected to a temp file).

BeforeAll {
    . (Join-Path $PSScriptRoot '..\WinSenior.Insights.ps1')
    function New-Boot { param([datetime]$T, [int64]$Ms, [bool]$Upd = $false) [pscustomobject]@{ Time = $T; BootMs = $Ms; MainPathMs = $Ms - 5000; PostBootMs = 5000; StartupApps = 10; AfterUpdate = $Upd } }
}

Describe 'Compare-WsBootTime' {
    It 'detects a real speed-up and ignores update reboots and the cold first boot' {
        $t0 = Get-Date '2026-10-01'
        $boots = @()
        $boots += foreach ($i in 0..7) { New-Boot $t0.AddDays($i) (40000 + 500 * ($i % 3)) }
        $boots += New-Boot $t0.AddDays(7.5) 90000 $true            # after an update: excluded
        $change = $t0.AddDays(8)
        $boots += New-Boot $change.AddHours(1) 60000                 # first boot after change: dropped
        $boots += foreach ($i in 1..7) { New-Boot $change.AddDays($i) (30000 + 400 * ($i % 3)) }
        $r = Compare-WsBootTime -Boots $boots -ChangeTime $change
        $r.Verdict | Should -Be 'Improved'
        $r.NAfter | Should -Be 7
        $r.ChangePct | Should -BeLessThan -20
    }
    It 'needs boots on both sides' {
        $t0 = Get-Date '2026-10-01'
        $r = Compare-WsBootTime -Boots @(foreach ($i in 0..5) { New-Boot $t0.AddDays($i) 40000 }) -ChangeTime $t0.AddDays(10)
        $r.Verdict | Should -Be 'InsufficientData'
    }
}

Describe 'Cleanup planner' {
    BeforeAll {
        $script:Reg = @(
            [pscustomobject]@{ Id = 'temp-user'; Name = 'Temp'; Risk = 'Safe' }
            [pscustomobject]@{ Id = 'chrome'; Name = 'Chrome'; Risk = 'Safe' }
            [pscustomobject]@{ Id = 'game-shaders'; Name = 'Shaders'; Risk = 'Aggressive' }
            [pscustomobject]@{ Id = 'windows-old'; Name = 'Windows.old'; Risk = 'Dangerous' }
        )
    }
    It 'prices risk and regeneration' {
        Get-WsTaskCost $script:Reg[0] | Should -Be 1      # Safe + nothing to rebuild
        Get-WsTaskCost $script:Reg[1] | Should -Be 3      # Safe + slower first loads
        Get-WsTaskCost $script:Reg[2] | Should -Be 14     # Aggressive + shader stutter
        Get-WsTaskCost $script:Reg[3] | Should -Be 41
    }
    It 'prefers many cheap tasks over one painful one when they suffice' {
        $scan = @(
            [pscustomobject]@{ Task = 'temp-user'; Bytes = [int64](3GB) }
            [pscustomobject]@{ Task = 'chrome'; Bytes = [int64](2GB) }
            [pscustomobject]@{ Task = 'game-shaders'; Bytes = [int64](6GB) }
            [pscustomobject]@{ Task = 'windows-old'; Bytes = [int64](20GB) }
        )
        $p = Get-WsCleanupPlan -ScanItems $scan -Registry $script:Reg -TargetBytes 4GB
        @($p.Tasks.Id | Sort-Object) -join ',' | Should -Be 'chrome,temp-user'
        $p = Get-WsCleanupPlan -ScanItems $scan -Registry $script:Reg -TargetBytes 10GB
        @($p.Tasks.Id | Sort-Object) -join ',' | Should -Be 'chrome,game-shaders,temp-user'
        $p = Get-WsCleanupPlan -ScanItems $scan -Registry $script:Reg -TargetBytes 25GB
        $p.Tasks.Id | Should -Contain 'windows-old'
    }
    It 'skips tasks the scan skipped or found empty' {
        $scan = @([pscustomobject]@{ Task = 'chrome'; Bytes = [int64](2GB); Skipped = 'app running' }, [pscustomobject]@{ Task = 'temp-user'; Bytes = 0 })
        (Get-WsCleanupPlan -ScanItems $scan -Registry $script:Reg -TargetBytes 1GB).Tasks.Count | Should -Be 0
    }
}

Describe 'Disk history sampler' {
    BeforeAll {
        $script:Hist = Join-Path ([IO.Path]::GetTempPath()) ("ws-hist-{0}.csv" -f [guid]::NewGuid().ToString('N'))
    }
    AfterAll { [IO.File]::Delete($script:Hist) }
    It 'records one row per fixed drive and rate-limits repeats' {
        $n1 = Add-WsDiskSample -Path $script:Hist
        $n1 | Should -BeGreaterThan 0
        Add-WsDiskSample -Path $script:Hist | Should -Be 0
        $rows = @(Get-WsDiskSample -Path $script:Hist)
        $rows.Count | Should -Be $n1
        $rows[0].FreeBytes | Should -BeGreaterThan 0
        $rows[0].Time.Kind | Should -Be 'Utc'
    }
    It 'filters by drive letter' {
        $d = (Get-WsDiskSample -Path $script:Hist)[0].Drive
        @(Get-WsDiskSample -Path $script:Hist -Drive "${d}:\") | ForEach-Object { $_.Drive } | Sort-Object -Unique | Should -Be $d
    }
}
