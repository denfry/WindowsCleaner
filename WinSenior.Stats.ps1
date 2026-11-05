<#
.SYNOPSIS
    WinSenior statistics library - pure, dependency-free math used by the
    measurement, forecast and planning features.

.DESCRIPTION
    Dot-source this file. Every function is pure (no I/O, no global state) so the
    Pester suite can pin exact numbers. Works on Windows PowerShell 5.1 and pwsh 7.

    Robust statistics       Get-WsMedian, Get-WsQuantile (Hyndman-Fan type 7),
                            Get-WsMad, Test-WsOutlier (NIST modified Z > 3.5)
    Two-sample comparison   Get-WsMannWhitney (exact for small n without ties,
                            otherwise normal approximation with tie + continuity
                            correction), Get-WsHodgesLehmann (shift + rank CI),
                            Compare-WsMetric (verdict with an equivalence margin)
    Trend / forecast        Get-WsTheilSen (median of pairwise slopes),
                            Get-WsDiskForecast (segmented Theil-Sen, cleanup jumps
                            removed, days until the volume reaches a reserve)
    Planning                Find-WsCleanupPlan (0/1 min-cost cover knapsack:
                            free >= target bytes for the least total "pain")

    Sources: NIST e-Handbook 1.3.5.17 (modified Z), scipy.stats.mannwhitneyu
    (exact vs asymptotic), Hollander & Wolfe (Hodges-Lehmann CI), Sen 1968
    (Theil-Sen slope).
#>

# =====================================================================
# BASIC ROBUST STATISTICS
# =====================================================================
function ConvertTo-WsDoubleArray {
    param($Values)
    $list = New-Object System.Collections.Generic.List[double]
    foreach ($v in @($Values)) {
        if ($null -eq $v) { continue }
        $d = [double]$v
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { continue }
        $list.Add($d)
    }
    $arr = $list.ToArray()
    [Array]::Sort($arr)
    , $arr
}

# Type-7 quantile (the R / numpy default): linear interpolation between order
# statistics at h = (n-1)p.
function Get-WsQuantile {
    param($Values, [double]$P)
    $x = ConvertTo-WsDoubleArray $Values
    $n = $x.Length
    if ($n -eq 0) { return [double]::NaN }
    if ($P -le 0) { return $x[0] }
    if ($P -ge 1) { return $x[$n - 1] }
    $h  = ($n - 1) * $P
    $lo = [Math]::Floor($h)
    $hi = [Math]::Min($lo + 1, $n - 1)
    $x[[int]$lo] + ($h - $lo) * ($x[[int]$hi] - $x[[int]$lo])
}

function Get-WsMedian {
    param($Values)
    Get-WsQuantile -Values $Values -P 0.5
}

# Median absolute deviation (raw). Multiply by 1.4826 for a normal-consistent sigma.
function Get-WsMad {
    param($Values)
    $x = ConvertTo-WsDoubleArray $Values
    if ($x.Length -eq 0) { return [double]::NaN }
    $m = Get-WsMedian $x
    Get-WsMedian @($x | ForEach-Object { [Math]::Abs($_ - $m) })
}

# NIST modified Z-score: M = 0.6745 (x - median) / MAD, outlier when |M| > 3.5.
# Returns one bool per input value, in input order. MAD = 0 -> nothing is flagged
# (all-equal samples have no outliers by this rule).
function Test-WsOutlier {
    param($Values, [double]$Threshold = 3.5)
    $vals = @($Values | ForEach-Object { [double]$_ })
    if ($vals.Count -lt 3) { return @($vals | ForEach-Object { $false }) }
    $m   = Get-WsMedian $vals
    $mad = Get-WsMad $vals
    foreach ($v in $vals) {
        if ($mad -le 0) { $false } else { [Math]::Abs(0.6745 * ($v - $m) / $mad) -gt $Threshold }
    }
}

# Standard normal CDF via erf (Abramowitz & Stegun 7.1.26, |error| < 1.5e-7).
function Get-WsNormalCdf {
    param([double]$Z)
    $x = [Math]::Abs($Z) / [Math]::Sqrt(2)
    $t = 1 / (1 + 0.3275911 * $x)
    $y = 1 - (((((1.061405429 * $t - 1.453152027) * $t) + 1.421413741) * $t - 0.284496736) * $t + 0.254829592) * $t * [Math]::Exp(-$x * $x)
    if ($Z -ge 0) { 0.5 * (1 + $y) } else { 0.5 * (1 - $y) }
}

# Inverse normal CDF (Acklam's rational approximation, relative error < 1.2e-9).
function Get-WsNormalQuantile {
    param([double]$P)
    if ($P -le 0) { return [double]::NegativeInfinity }
    if ($P -ge 1) { return [double]::PositiveInfinity }
    $a = -39.69683028665376, 220.9460984245205, -275.9285104469687, 138.3577518672690, -30.66479806614716, 2.506628277459239
    $b = -54.47609879822406, 161.5858368580409, -155.6989798598866, 66.80131188771972, -13.28068155288572
    $c = -0.007784894002430293, -0.3223964580411365, -2.400758277161838, -2.549732539343734, 4.374664141464968, 2.938163982698783
    $d = 0.007784695709041462, 0.3224671290700398, 2.445134137142996, 3.754408661907416
    $pl = 0.02425
    if ($P -lt $pl) {
        $q = [Math]::Sqrt(-2 * [Math]::Log($P))
        return ((((($c[0]*$q+$c[1])*$q+$c[2])*$q+$c[3])*$q+$c[4])*$q+$c[5]) / (((($d[0]*$q+$d[1])*$q+$d[2])*$q+$d[3])*$q+1)
    }
    if ($P -gt 1 - $pl) {
        $q = [Math]::Sqrt(-2 * [Math]::Log(1 - $P))
        return -((((($c[0]*$q+$c[1])*$q+$c[2])*$q+$c[3])*$q+$c[4])*$q+$c[5]) / (((($d[0]*$q+$d[1])*$q+$d[2])*$q+$d[3])*$q+1)
    }
    $q = $P - 0.5; $r = $q * $q
    ((((($a[0]*$r+$a[1])*$r+$a[2])*$r+$a[3])*$r+$a[4])*$r+$a[5])*$q / ((((($b[0]*$r+$b[1])*$r+$b[2])*$r+$b[3])*$r+$b[4])*$r+1)
}

# =====================================================================
# TWO-SAMPLE COMPARISON
# =====================================================================

# Exact null distribution of U for sample sizes m, n (no ties): counts c[u] of
# arrangements with statistic u, via the recurrence
#   N(u; m, n) = N(u - n; m - 1, n) + N(u; m, n - 1).
# Returns a double[] of probabilities indexed by u = 0..m*n.
function Get-WsMannWhitneyExactPmf {
    param([int]$M, [int]$N)
    $max = $M * $N
    # table[i][j] = counts array for sizes (i, j); built bottom-up.
    $prev = @{}
    for ($i = 0; $i -le $M; $i++) {
        for ($j = 0; $j -le $N; $j++) {
            $arr = New-Object 'double[]' ($i * $j + 1)
            if ($i -eq 0 -or $j -eq 0) { $arr[0] = 1 }
            else {
                $a = $prev["$($i-1),$j"]; $b = $prev["$i,$($j-1)"]
                for ($u = 0; $u -le $i * $j; $u++) {
                    $v = 0.0
                    if ($u - $j -ge 0 -and ($u - $j) -lt $a.Length) { $v += $a[$u - $j] }
                    if ($u -lt $b.Length) { $v += $b[$u] }
                    $arr[$u] = $v
                }
            }
            $prev["$i,$j"] = $arr
        }
    }
    $counts = $prev["$M,$N"]
    $total = 0.0; foreach ($c in $counts) { $total += $c }
    $pmf = New-Object 'double[]' ($max + 1)
    for ($u = 0; $u -le $max; $u++) { $pmf[$u] = $counts[$u] / $total }
    , $pmf
}

# Mann-Whitney U test. U1 counts pairs where X > Y (+0.5 per tie).
# PLess  = P(U1 <= observed) -> evidence that X tends to be SMALLER than Y.
# PGreater, PTwoSided analogous. Exact when both n <= 20 and there are no ties.
function Get-WsMannWhitney {
    param($X, $Y)
    $xs = @($X | ForEach-Object { [double]$_ }); $ys = @($Y | ForEach-Object { [double]$_ })
    $m = $xs.Count; $n = $ys.Count
    if ($m -eq 0 -or $n -eq 0) { return $null }

    # Rank the pooled sample (average ranks for ties) and collect tie group sizes.
    $pool = @(for ($i = 0; $i -lt $m; $i++) { [pscustomobject]@{ V = $xs[$i]; G = 0 } }) +
            @(for ($j = 0; $j -lt $n; $j++) { [pscustomobject]@{ V = $ys[$j]; G = 1 } })
    $sorted = @($pool | Sort-Object V)
    # NB: PowerShell variables are case-insensitive - never call this $N (= $n).
    $tot = $sorted.Count
    $rank = New-Object 'double[]' $tot
    $tieTerm = 0.0; $hasTies = $false
    $k = 0
    while ($k -lt $tot) {
        $e = $k
        while ($e + 1 -lt $tot -and $sorted[$e + 1].V -eq $sorted[$k].V) { $e++ }
        $avg = (($k + 1) + ($e + 1)) / 2.0
        for ($q = $k; $q -le $e; $q++) { $rank[$q] = $avg }
        $t = $e - $k + 1
        if ($t -gt 1) { $hasTies = $true; $tieTerm += ($t * $t * $t - $t) }
        $k = $e + 1
    }
    $r1 = 0.0
    for ($q = 0; $q -lt $tot; $q++) { if ($sorted[$q].G -eq 0) { $r1 += $rank[$q] } }
    $u1 = $r1 - $m * ($m + 1) / 2.0
    $mu = $m * $n / 2.0

    $exact = (-not $hasTies) -and $m -le 20 -and $n -le 20
    if ($exact) {
        $pmf = Get-WsMannWhitneyExactPmf -M $m -N $n
        $ui = [int][Math]::Round($u1)
        $pLess = 0.0; for ($u = 0; $u -le $ui; $u++) { $pLess += $pmf[$u] }
        $pGreater = 0.0; for ($u = $ui; $u -lt $pmf.Length; $u++) { $pGreater += $pmf[$u] }
        $method = 'exact'
    }
    else {
        $var = ($m * $n / 12.0) * (($tot + 1) - $tieTerm / ($tot * ($tot - 1)))
        if ($var -le 0) { $pLess = 1.0; $pGreater = 1.0 }
        else {
            $sd = [Math]::Sqrt($var)
            $pLess    = Get-WsNormalCdf ((($u1 - $mu) + 0.5) / $sd)
            $pGreater = 1 - (Get-WsNormalCdf ((($u1 - $mu) - 0.5) / $sd))
        }
        $method = 'normal'
    }
    $pLess = [Math]::Min(1.0, $pLess); $pGreater = [Math]::Min(1.0, $pGreater)
    [pscustomobject]@{
        U1 = $u1; N1 = $m; N2 = $n; Method = $method
        PLess = $pLess; PGreater = $pGreater
        PTwoSided = [Math]::Min(1.0, 2 * [Math]::Min($pLess, $pGreater))
        # rank-biserial correlation: +1 = every X > every Y
        EffectR = 2 * $u1 / ($m * $n) - 1
    }
}

# Hodges-Lehmann shift estimate (median of all X_i - Y_j) with the distribution-free
# confidence interval from the order statistics of those differences.
function Get-WsHodgesLehmann {
    param($X, $Y, [double]$Confidence = 0.95)
    $xs = @($X | ForEach-Object { [double]$_ }); $ys = @($Y | ForEach-Object { [double]$_ })
    $m = $xs.Count; $n = $ys.Count
    if ($m -eq 0 -or $n -eq 0) { return $null }
    $d = New-Object 'double[]' ($m * $n)
    $i = 0
    foreach ($a in $xs) { foreach ($b in $ys) { $d[$i++] = $a - $b } }
    [Array]::Sort($d)
    $mn = $m * $n
    # k = lower critical value of U (normal approximation, floor), 1-based index.
    $z = Get-WsNormalQuantile (1 - (1 - $Confidence) / 2)
    $k = [Math]::Floor($mn / 2.0 - $z * [Math]::Sqrt($mn * ($m + $n + 1) / 12.0))
    $lo = $null; $hi = $null
    if ($k -ge 1) { $lo = $d[[int]$k - 1]; $hi = $d[[int]($mn - $k)] }
    [pscustomobject]@{ Shift = (Get-WsMedian $d); Low = $lo; High = $hi; Confidence = $Confidence }
}

# Did a metric change between two sets of runs? Verdict rules:
#   InsufficientData : < MinRuns runs on either side
#   Improved / Worse : one-sided Mann-Whitney p < Alpha AND the median moved by
#                      more than Margin (relative), in the good / bad direction
#   Equivalent       : the HL confidence interval sits inside +/- Margin of the
#                      baseline median (the change is too small to matter)
#   Inconclusive     : anything else (needs more runs)
function Compare-WsMetric {
    param(
        $Before, $After,
        [switch]$HigherIsBetter,
        [double]$Margin = 0.03,
        [double]$Alpha = 0.05,
        [int]$MinRuns = 4,
        [switch]$DropOutliers
    )
    $b = @($Before | ForEach-Object { [double]$_ }); $a = @($After | ForEach-Object { [double]$_ })
    if ($DropOutliers) {
        $fb = @(Test-WsOutlier $b); $fa = @(Test-WsOutlier $a)
        $b = @(for ($i = 0; $i -lt $b.Count; $i++) { if (-not $fb[$i]) { $b[$i] } })
        $a = @(for ($i = 0; $i -lt $a.Count; $i++) { if (-not $fa[$i]) { $a[$i] } })
    }
    $res = [ordered]@{
        Verdict = 'InsufficientData'; NBefore = $b.Count; NAfter = $a.Count
        MedianBefore = $null; MedianAfter = $null; ChangePct = $null
        Shift = $null; ShiftLow = $null; ShiftHigh = $null; P = $null
    }
    if ($b.Count -lt $MinRuns -or $a.Count -lt $MinRuns) { return [pscustomobject]$res }

    $mb = Get-WsMedian $b; $ma = Get-WsMedian $a
    $res.MedianBefore = $mb; $res.MedianAfter = $ma
    if ($mb -ne 0) { $res.ChangePct = [Math]::Round(100 * ($ma - $mb) / [Math]::Abs($mb), 2) }

    $mw = Get-WsMannWhitney -X $a -Y $b                    # X = after
    $hl = Get-WsHodgesLehmann -X $a -Y $b
    $res.Shift = $hl.Shift; $res.ShiftLow = $hl.Low; $res.ShiftHigh = $hl.High
    $pGood = if ($HigherIsBetter) { $mw.PGreater } else { $mw.PLess }
    $pBad  = if ($HigherIsBetter) { $mw.PLess } else { $mw.PGreater }
    $band  = [Math]::Abs($mb) * $Margin
    $moved = [Math]::Abs($ma - $mb) -gt $band
    $goodDir = if ($HigherIsBetter) { $ma -gt $mb } else { $ma -lt $mb }

    if ($pGood -lt $Alpha -and $moved -and $goodDir) { $res.Verdict = 'Improved'; $res.P = $pGood }
    elseif ($pBad -lt $Alpha -and $moved -and -not $goodDir) { $res.Verdict = 'Worse'; $res.P = $pBad }
    elseif ($null -ne $hl.Low -and $hl.Low -ge -$band -and $hl.High -le $band) { $res.Verdict = 'Equivalent'; $res.P = [Math]::Min($pGood, $pBad) }
    else { $res.Verdict = 'Inconclusive'; $res.P = [Math]::Min($pGood, $pBad) }
    [pscustomobject]$res
}

# =====================================================================
# TREND / FORECAST
# =====================================================================

# Theil-Sen estimator: slope = median of pairwise slopes (x distinct),
# intercept = median(y - slope*x). SlopeLow/High = 25th/75th percentile slopes.
function Get-WsTheilSen {
    param([double[]]$X, [double[]]$Y)
    $n = [Math]::Min($X.Count, $Y.Count)
    $slopes = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $n; $i++) {
        for ($j = $i + 1; $j -lt $n; $j++) {
            $dx = $X[$j] - $X[$i]
            if ($dx -ne 0) { $slopes.Add(($Y[$j] - $Y[$i]) / $dx) }
        }
    }
    if ($slopes.Count -eq 0) { return $null }
    $s = Get-WsMedian $slopes
    $res = for ($i = 0; $i -lt $n; $i++) { $Y[$i] - $s * $X[$i] }
    [pscustomobject]@{
        Slope = $s; Intercept = (Get-WsMedian $res)
        SlopeLow = (Get-WsQuantile $slopes 0.25); SlopeHigh = (Get-WsQuantile $slopes 0.75)
        Pairs = $slopes.Count
    }
}

# Days until free space falls to ReserveBytes.
#   Samples: objects with Time ([datetime]) and FreeBytes ([int64]), any order.
#   Upward jumps (cleanups, user deletions) split the series into segments; only
#   within-segment pairwise slopes are pooled, so a cleanup never looks like
#   "the disk is filling backwards". The gross rate (sum of drops / span) is a
#   conservative worst case. Needs >= MinPoints samples spanning >= MinDays.
function Get-WsDiskForecast {
    param(
        [object[]]$Samples,
        [int64]$ReserveBytes = 0,
        [int]$MinPoints = 5,
        [double]$MinDays = 7,
        [int64]$JumpBytes = 1GB
    )
    $s = @($Samples | Where-Object { $_ -and $null -ne $_.FreeBytes } | Sort-Object { [datetime]$_.Time })
    $out = [ordered]@{ Status = 'InsufficientData'; Points = $s.Count; SpanDays = 0
                       RateBytesPerDay = $null; RateLow = $null; RateHigh = $null
                       GrossRateBytesPerDay = $null; DaysLeft = $null; DaysLeftLow = $null; DaysLeftHigh = $null
                       FreeBytes = $null }
    if ($s.Count -lt 2) { return [pscustomobject]$out }
    $t0 = [datetime]$s[0].Time
    $days = @($s | ForEach-Object { ([datetime]$_.Time - $t0).TotalDays })
    $free = @($s | ForEach-Object { [double]$_.FreeBytes })
    $out.SpanDays = [Math]::Round($days[-1], 2)
    $out.FreeBytes = [int64]$free[-1]
    if ($s.Count -lt $MinPoints -or $days[-1] -lt $MinDays) { return [pscustomobject]$out }

    # Jump threshold: max(JumpBytes, 3 x MAD of the step deltas).
    $deltas = @(for ($i = 1; $i -lt $free.Count; $i++) { $free[$i] - $free[$i - 1] })
    $thr = [Math]::Max([double]$JumpBytes, 3 * 1.4826 * (Get-WsMad $deltas))

    $slopes = New-Object System.Collections.Generic.List[double]
    $segStart = 0; $drops = 0.0
    for ($i = 1; $i -le $free.Count; $i++) {
        $isEnd = ($i -eq $free.Count) -or (($free[$i] - $free[$i - 1]) -gt $thr)
        if ($i -lt $free.Count -and ($free[$i] - $free[$i - 1]) -lt 0) { $drops += -($free[$i] - $free[$i - 1]) }
        if (-not $isEnd) { continue }
        for ($a = $segStart; $a -lt $i; $a++) {
            for ($b = $a + 1; $b -lt $i; $b++) {
                $dx = $days[$b] - $days[$a]
                if ($dx -gt 0) { $slopes.Add(($free[$b] - $free[$a]) / $dx) }
            }
        }
        $segStart = $i
    }
    $out.GrossRateBytesPerDay = [Math]::Round($drops / $days[-1])
    if ($slopes.Count -eq 0) { $out.Status = 'NoTrend'; return [pscustomobject]$out }

    # Free space falls -> slopes are negative; report consumption as a positive rate.
    $rate = -(Get-WsMedian $slopes); $rLo = -(Get-WsQuantile $slopes 0.75); $rHi = -(Get-WsQuantile $slopes 0.25)
    $out.RateBytesPerDay = [Math]::Round($rate); $out.RateLow = [Math]::Round($rLo); $out.RateHigh = [Math]::Round($rHi)
    $room = $free[-1] - $ReserveBytes
    if ($room -le 0) { $out.Status = 'Full'; $out.DaysLeft = 0; return [pscustomobject]$out }
    if ($rate -le 0) { $out.Status = 'Stable'; return [pscustomobject]$out }
    $out.Status = 'Filling'
    $out.DaysLeft = [Math]::Round($room / $rate, 1)
    if ($rHi -gt 0) { $out.DaysLeftLow = [Math]::Round($room / $rHi, 1) }
    if ($rLo -gt 0) { $out.DaysLeftHigh = [Math]::Round($room / $rLo, 1) }
    [pscustomobject]$out
}

# =====================================================================
# PLANNING: free >= TargetBytes for the least total cost
# =====================================================================
# Items: objects with Id, Bytes (int64) and Cost (int >= 0; the "pain" of running
# the task: regeneration time, re-downloads, lost history, risk tier).
# Exact 0/1 min-cost cover by dynamic programming over total cost:
#   best[c] = most bytes reachable with total cost exactly <= c.
# Zero-cost items with bytes are always taken. Cost is integer and small (<= a few
# thousand in total), so O(n * sum(cost)) is cheap. If the target is unreachable,
# every item with bytes is returned and Reached = $false.
function Find-WsCleanupPlan {
    param([object[]]$Items, [int64]$TargetBytes)
    $cand = @($Items | Where-Object { $_ -and [int64]$_.Bytes -gt 0 })
    $free = @($cand | Where-Object { [int]$_.Cost -le 0 })
    $paid = @($cand | Where-Object { [int]$_.Cost -gt 0 })
    [int64]$base = 0; foreach ($f in $free) { $base += [int64]$f.Bytes }
    $need = $TargetBytes - $base

    $chosen = New-Object System.Collections.Generic.List[object]
    foreach ($f in $free) { $chosen.Add($f) }
    if ($need -gt 0 -and $paid.Count) {
        # NB: PowerShell variables are case-insensitive - capacity must not be $C (= $c).
        $cap = 0; foreach ($p in $paid) { $cap += [int]$p.Cost }
        $n = $paid.Count
        $best = New-Object 'double[]' ($cap + 1)              # bytes, -1 = unreachable
        for ($c = 1; $c -le $cap; $c++) { $best[$c] = -1 }
        $take = New-Object 'bool[,]' ($n, ($cap + 1))
        for ($i = 0; $i -lt $n; $i++) {
            $w = [int]$paid[$i].Cost; $v = [double]$paid[$i].Bytes
            for ($c = $cap; $c -ge $w; $c--) {
                if ($best[$c - $w] -ge 0 -and $best[$c - $w] + $v -gt $best[$c]) {
                    $best[$c] = $best[$c - $w] + $v; $take[$i, $c] = $true
                }
            }
        }
        $target = -1
        for ($c = 0; $c -le $cap; $c++) { if ($best[$c] -ge $need) { $target = $c; break } }
        if ($target -lt 0) {
            # unreachable: take the max-bytes solution
            $target = 0; for ($c = 0; $c -le $cap; $c++) { if ($best[$c] -gt $best[$target]) { $target = $c } }
        }
        $c = $target
        for ($i = $n - 1; $i -ge 0 -and $c -gt 0; $i--) {
            if ($take[$i, $c]) { $chosen.Add($paid[$i]); $c -= [int]$paid[$i].Cost }
        }
    }
    [int64]$bytes = 0; $cost = 0
    foreach ($x in $chosen) { $bytes += [int64]$x.Bytes; $cost += [int]$x.Cost }
    [pscustomobject]@{
        Ids = @($chosen | ForEach-Object { $_.Id }); Bytes = $bytes; Cost = $cost
        Reached = ($bytes -ge $TargetBytes); TargetBytes = $TargetBytes
    }
}
