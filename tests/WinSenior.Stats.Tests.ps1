# Pester tests for WinSenior.Stats.ps1 - pure math, pinned to hand-computed values.
# Run:  Invoke-Pester -Path .\tests

BeforeAll {
    . (Join-Path $PSScriptRoot '..\WinSenior.Stats.ps1')
}

Describe 'Robust statistics' {
    It 'type-7 quantiles match R/numpy' {
        Get-WsQuantile @(1, 2, 3, 4) 0.5  | Should -Be 2.5
        Get-WsQuantile @(4, 1, 3, 2) 0.25 | Should -Be 1.75
        Get-WsMedian @(5, 1, 3) | Should -Be 3
    }
    It 'returns NaN for an empty sample' {
        [double]::IsNaN((Get-WsMedian @())) | Should -BeTrue
    }
    It 'computes the raw MAD' {
        Get-WsMad @(1, 1, 2, 2, 4, 6, 9) | Should -Be 1
    }
    It 'flags only the gross outlier (NIST modified Z > 3.5)' {
        $f = @(Test-WsOutlier @(10, 11, 10, 12, 11, 50))
        $f[5] | Should -BeTrue
        @($f[0..4] | Where-Object { $_ }).Count | Should -Be 0
    }
    It 'normal CDF / quantile are accurate' {
        [Math]::Abs((Get-WsNormalCdf 1.96) - 0.9750021) | Should -BeLessThan 1e-6
        [Math]::Abs((Get-WsNormalQuantile 0.975) - 1.959964) | Should -BeLessThan 1e-5
        [Math]::Abs((Get-WsNormalQuantile 0.01) + 2.326348) | Should -BeLessThan 1e-5
    }
}

Describe 'Mann-Whitney U' {
    It 'exact p for fully separated 3 vs 3 is 1/20' {
        $r = Get-WsMannWhitney -X @(1, 2, 3) -Y @(4, 5, 6)
        $r.U1 | Should -Be 0
        $r.Method | Should -Be 'exact'
        [Math]::Abs($r.PLess - 0.05) | Should -BeLessThan 1e-12
        [Math]::Abs($r.PTwoSided - 0.1) | Should -BeLessThan 1e-12
        $r.EffectR | Should -Be -1
    }
    It 'exact p for fully separated 5 vs 5 is 1/252' {
        $r = Get-WsMannWhitney -X @(1..5) -Y @(6..10)
        [Math]::Abs($r.PLess - 1 / 252) | Should -BeLessThan 1e-12
    }
    It 'uses average ranks and the normal approximation with ties' {
        $r = Get-WsMannWhitney -X @(1, 2, 2, 3) -Y @(2, 3, 4, 5)
        $r.U1 | Should -Be 2.5
        $r.Method | Should -Be 'normal'
        $r.PLess | Should -BeGreaterThan 0
        $r.PLess | Should -BeLessThan 0.2
    }
    It 'Hodges-Lehmann shift is the median pairwise difference' {
        (Get-WsHodgesLehmann -X @(10, 11, 12) -Y @(1, 2, 3)).Shift | Should -Be 9
    }
}

Describe 'Compare-WsMetric verdicts' {
    It 'Improved when boot time clearly drops' {
        $v = Compare-WsMetric -Before @(40, 42, 41, 43, 44, 40) -After @(33, 34, 35, 33, 36, 34)
        $v.Verdict | Should -Be 'Improved'
        $v.ChangePct | Should -BeLessThan -15
    }
    It 'Worse when it clearly rises' {
        (Compare-WsMetric -Before @(33, 34, 35, 33, 36, 34) -After @(40, 42, 41, 43, 44, 40)).Verdict | Should -Be 'Worse'
    }
    It 'Equivalent when the change is inside the margin' {
        $v = Compare-WsMetric -Before @(100, 101, 99, 100, 102, 98, 100, 101) -After @(100, 100, 101, 99, 100, 101, 99, 100)
        $v.Verdict | Should -Be 'Equivalent'
    }
    It 'InsufficientData below the minimum run count' {
        (Compare-WsMetric -Before @(1, 2, 3) -After @(4, 5, 6)).Verdict | Should -Be 'InsufficientData'
    }
    It 'respects HigherIsBetter' {
        (Compare-WsMetric -Before @(10, 11, 10, 12, 11) -After @(20, 21, 22, 20, 21) -HigherIsBetter).Verdict | Should -Be 'Improved'
    }
}

Describe 'Theil-Sen and disk forecast' {
    It 'ignores a single outlier' {
        $x = [double[]](0..9); $y = [double[]]@(0..9 | ForEach-Object { 2 * $_ + 1 })
        $y[7] = 500
        (Get-WsTheilSen -X $x -Y $y).Slope | Should -Be 2
    }
    It 'removes the cleanup jump and forecasts days left' {
        $t0 = Get-Date '2026-01-01'
        $s = foreach ($d in 0..9) {
            $gb = if ($d -lt 5) { 50 - $d } else { 60 - $d }
            [pscustomobject]@{ Time = $t0.AddDays($d); FreeBytes = [int64]($gb * 1GB) }
        }
        $f = Get-WsDiskForecast -Samples $s
        $f.Status | Should -Be 'Filling'
        $f.RateBytesPerDay | Should -Be ([int64]1GB)
        $f.DaysLeft | Should -Be 51
    }
    It 'needs enough history' {
        $s = @([pscustomobject]@{ Time = (Get-Date); FreeBytes = 1GB }, [pscustomobject]@{ Time = (Get-Date).AddDays(1); FreeBytes = 1GB })
        (Get-WsDiskForecast -Samples $s).Status | Should -Be 'InsufficientData'
    }
    It 'reports Stable when nothing is consumed' {
        $t0 = Get-Date '2026-01-01'
        $s = foreach ($d in 0..9) { [pscustomobject]@{ Time = $t0.AddDays($d); FreeBytes = [int64](40GB) } }
        (Get-WsDiskForecast -Samples $s).Status | Should -Be 'Stable'
    }
}

Describe 'Find-WsCleanupPlan (min-cost cover)' {
    BeforeAll {
        $script:Items = @(
            [pscustomobject]@{ Id = 'A'; Bytes = [int64](10GB); Cost = 1 }
            [pscustomobject]@{ Id = 'B'; Bytes = [int64](5GB);  Cost = 1 }
            [pscustomobject]@{ Id = 'C'; Bytes = [int64](20GB); Cost = 10 }
            [pscustomobject]@{ Id = 'D'; Bytes = [int64](1GB);  Cost = 0 }
            [pscustomobject]@{ Id = 'E'; Bytes = [int64]0;      Cost = 1 }
        )
    }
    It 'always takes free items and the cheapest sufficient set' {
        $p = Find-WsCleanupPlan -Items $script:Items -TargetBytes 15GB
        ($p.Ids | Sort-Object) -join ',' | Should -Be 'A,B,D'
        $p.Cost | Should -Be 2
        $p.Reached | Should -BeTrue
    }
    It 'pays for the big item only when it must' {
        $p = Find-WsCleanupPlan -Items $script:Items -TargetBytes 30GB
        ($p.Ids | Sort-Object) -join ',' | Should -Be 'A,C,D'
        $p.Cost | Should -Be 11
    }
    It 'returns everything and Reached=false when the target is impossible' {
        $p = Find-WsCleanupPlan -Items $script:Items -TargetBytes 100GB
        ($p.Ids | Sort-Object) -join ',' | Should -Be 'A,B,C,D'
        $p.Reached | Should -BeFalse
    }
}
