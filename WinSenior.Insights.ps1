<#
.SYNOPSIS
    WinSenior insights - measurements and math instead of guesses.

.DESCRIPTION
      Boot history       Event 100 of Microsoft-Windows-Diagnostics-Performance/
                         Operational (BootTime = MainPathBootTime + BootPostBootTime,
                         ms). Boots right after an update install are excluded.
      Before / after     the boots before the last optimization vs the boots after
                         it (first boot after the change dropped - it is cold),
                         compared with Mann-Whitney U + Hodges-Lehmann + a 5 %
                         equivalence margin (Compare-WsMetric). Verdict: Improved /
                         Worse / Equivalent (= no real effect) / Inconclusive.
      Boot slowdowns     events 101-110 aggregated per app/driver/service: count
                         and median extra milliseconds - the real startup offenders.
      Disk forecast      segmented Theil-Sen over the disk-history samples: days
                         until a drive drops below 10 % free (or 10 GB).
      Cleanup plan       0/1 min-cost cover over the last scan: the set of cleanup
                         tasks that frees >= N GB with the least side effects.

    Reading the Diagnostics-Performance log needs administrator rights.

.EXAMPLE
    .\WinSenior.Insights.ps1                    # boot + slowdowns + forecast
    .\WinSenior.Insights.ps1 -Plan 20           # cheapest way to free 20 GB (uses the last scan)
    .\WinSenior.Insights.ps1 -Plan 20 -Apply    # ... and run exactly those tasks
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [double]$Plan,
    [string]$ScanReport,
    [switch]$Apply,
    [switch]$IncludeDangerous,
    [datetime]$Since,
    [switch]$Sample,
    [string]$LogPath = "$env:TEMP\WinSenior-Insights.log",
    [string]$ReportPath
)

. (Join-Path $PSScriptRoot 'WinSenior.Common.ps1')
. (Join-Path $PSScriptRoot 'WinSenior.Stats.ps1')

function Write-InsLog { param([string]$Message, [string]$Level = 'Info') Write-WsLog -Message $Message -Level $Level -LogPath $LogPath }

$script:WsDiagLog = 'Microsoft-Windows-Diagnostics-Performance/Operational'

# =====================================================================
# BOOT
# =====================================================================
function ConvertFrom-WsEventData {
    param([object]$Record)
    $d = @{}
    try { foreach ($n in ([xml]$Record.ToXml()).Event.EventData.Data) { $d[$n.Name] = [string]$n.'#text' } } catch { Write-Verbose $_ }
    $d
}

function Get-WsBootHistory {
    param([int]$Max = 200)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $script:WsDiagLog; Id = 100 } -MaxEvents $Max -ErrorAction Stop)
    foreach ($e in $ev) {
        $d = ConvertFrom-WsEventData $e
        [pscustomobject]@{
            Time = $e.TimeCreated
            BootMs = [int64]$d['BootTime']; MainPathMs = [int64]$d['MainPathBootTime']; PostBootMs = [int64]$d['BootPostBootTime']
            StartupApps = [int]$d['BootNumStartupApps']
            AfterUpdate = ([string]$d['BootIsRebootAfterInstall'] -match '^(true|1)$')
        }
    }
}

# Pure: split boots at the change time and compare. Boots after an update install
# are excluded; the first boot after the change is dropped (caches are cold).
function Compare-WsBootTime {
    param([object[]]$Boots, [datetime]$ChangeTime, [string]$Metric = 'BootMs', [int]$Window = 15)
    $ok = @($Boots | Where-Object { -not $_.AfterUpdate -and $_.$Metric -gt 0 } | Sort-Object Time)
    $before = @($ok | Where-Object { $_.Time -lt $ChangeTime } | Select-Object -Last $Window | ForEach-Object { $_.$Metric })
    $after  = @($ok | Where-Object { $_.Time -ge $ChangeTime } | Select-Object -Skip 1 -First $Window | ForEach-Object { $_.$Metric })
    Compare-WsMetric -Before $before -After $after -Margin 0.05 -DropOutliers
}

# Aggregate 101-110 by component: how often it slowed boot and by how much.
function Get-WsBootDegrader {
    param([int]$Days = 90)
    $kind = @{ 101 = 'App'; 102 = 'Driver'; 103 = 'Service'; 104 = 'System'; 105 = 'Prefetch'; 106 = 'Prefetch'
               107 = 'Policy'; 108 = 'Policy'; 109 = 'Device'; 110 = 'Session' }
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $script:WsDiagLog; Id = 101..110; StartTime = (Get-Date).AddDays(-$Days) } -ErrorAction SilentlyContinue)
    $rows = foreach ($e in $ev) {
        $d = ConvertFrom-WsEventData $e
        $name = @($d['FriendlyName'], $d['Name'], $d['FileName']) | Where-Object { $_ } | Select-Object -First 1
        $deg  = @($d['DegradationTime'], $d['TotalTime']) | Where-Object { $_ } | Select-Object -First 1
        if (-not $name) { continue }
        [pscustomobject]@{ Kind = $kind[[int]$e.Id]; Name = $name; DegradationMs = [int64]$deg }
    }
    $rows | Group-Object Kind, Name | ForEach-Object {
        [pscustomobject]@{
            Kind = $_.Group[0].Kind; Name = $_.Group[0].Name; Count = $_.Count
            MedianMs = [int64](Get-WsMedian @($_.Group | ForEach-Object { $_.DegradationMs }))
            TotalMs = [int64](($_.Group | Measure-Object DegradationMs -Sum).Sum)
        }
    } | Sort-Object TotalMs -Descending
}

function Get-WsLastOptimizationTime {
    $f = Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'WinSenior\backups') -Filter 'optimize-backup-*.json' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { $f.LastWriteTime } else { $null }
}

# =====================================================================
# CLEANUP PLAN
# =====================================================================
# "Pain" of running a task: its risk tier plus what you lose until it rebuilds.
# Integers, so the knapsack DP stays exact and small.
function Get-WsTaskCost {
    param([object]$Task)
    $tier = @{ Safe = 1; Moderate = 3; Aggressive = 8; Dangerous = 40 }[[string]$Task.Risk]
    if (-not $tier) { $tier = 5 }
    $regen = switch -Regex ([string]$Task.Id) {
        '^(temp-|systemtemp|svc-temp|wer|livekernel|crashdumps|dism-logs|upgrade-logs|extra-logs|app-logs|game-logs|installer-leftovers|disk-chkdsk|empty-dirs|deliveryopt|recyclebin)' { 0; break }
        '^(chrome|edge|firefox|opera|yandex|brave|vivaldi|webview2|electron-generic|discord|slack|teams|telegram|whatsapp|spotify)' { 2; break }   # first page/app loads slower
        '^(thumbnails|fontcache|inetcache|webcache|notifications)' { 2; break }
        '^(shadercache|game-shaders|gpu-apps)' { 6; break }                       # stutter while shaders rebuild
        '^(npm|pip|nuget|yarn|gradle|pnpm|pkgmgr|python-tools|java-tools|node-tools|composer-php|vs|vscode|jetbrains)' { 4; break }   # re-download / rebuild
        '^(nuget-global|ml-caches|chrome-ai-model|docker)' { 10; break }            # large re-downloads
        '^(prefetch|search-index)' { 12; break }
        '^(wu-cache|wu-full|bits-cache|office-c2r)' { 3; break }
        default { 1 }
    }
    [int]($tier + $regen)
}

# Pure: scan items (Task, Bytes) + registry -> plan.
function Get-WsCleanupPlan {
    param([object[]]$ScanItems, [object[]]$Registry, [int64]$TargetBytes)
    $byId = @{}; foreach ($t in $Registry) { $byId[$t.Id] = $t }
    $items = foreach ($s in $ScanItems) {
        $t = $byId[[string]$s.Task]
        if (-not $t -or [int64]$s.Bytes -le 0 -or $s.Skipped) { continue }
        [pscustomobject]@{ Id = $t.Id; Name = $t.Name; Risk = $t.Risk; Bytes = [int64]$s.Bytes; Cost = (Get-WsTaskCost $t) }
    }
    $p = Find-WsCleanupPlan -Items @($items) -TargetBytes $TargetBytes
    $chosen = @($items | Where-Object { $p.Ids -contains $_.Id } | Sort-Object Bytes -Descending)
    [pscustomobject]@{ Reached = $p.Reached; Bytes = $p.Bytes; Cost = $p.Cost; TargetBytes = $TargetBytes; Tasks = $chosen
                       Available = [int64](($items | Measure-Object Bytes -Sum).Sum) }
}

function Find-WsLatestScanReport {
    $dirs = @("$env:LOCALAPPDATA\WinSenior", "$env:ProgramData\WinSenior\reports", $env:TEMP) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $best = $null
    foreach ($d in $dirs) {
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter '*.json' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue)) {
            if ($f.Length -gt 20MB) { continue }
            try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($j.Tool -ne 'WinSenior' -or $j.Engine -ne 'Cleanup' -or $j.Mode -ne 'DryRun') { continue }
            if (-not $best -or $f.LastWriteTime -gt $best.LastWriteTime) { $best = $f }
        }
    }
    $best
}

# =====================================================================
# CLI
# =====================================================================
function Start-WsInsights {
    if ($Sample) { $n = Add-WsDiskSample -MinHours 0; Write-InsLog "Recorded $n disk sample(s) -> $(Get-WsDiskHistoryPath)" 'Success'; return }

    if ($PSBoundParameters.ContainsKey('Plan')) {
        $cleanup = Join-Path $PSScriptRoot 'Cleanup-Windows-Senior.ps1'
        . $cleanup
        # Irreversible tasks only enter the plan when asked for: -Apply runs unattended.
        $reg = @(Get-CleanupTaskRegistry | Where-Object { $IncludeDangerous -or $_.Risk -ne 'Dangerous' })
        $rep = if ($ScanReport) { Get-Item -LiteralPath $ScanReport -ErrorAction Stop } else { Find-WsLatestScanReport }
        if (-not $rep) {
            Write-InsLog 'No scan yet - running a dry-run scan first (this takes a minute)...' 'Step'
            $rep = Join-Path $env:LOCALAPPDATA ('WinSenior\scan-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
            New-Item -ItemType Directory -Path (Split-Path $rep) -Force | Out-Null
            $exe = (Get-Process -Id $PID).Path
            & $exe -NoProfile -ExecutionPolicy Bypass -File $cleanup -WhatIf -Unattended -IncludeDangerous -Include ($reg.Id -join ',') -ReportPath $rep | Out-Null
            $rep = Get-Item -LiteralPath $rep
        }
        $scan = Get-Content -LiteralPath $rep.FullName -Raw | ConvertFrom-Json
        $plan = Get-WsCleanupPlan -ScanItems @($scan.Items) -Registry $reg -TargetBytes ([int64]($Plan * 1GB))
        Write-InsLog ("Plan for {0} GB (scan {1:yyyy-MM-dd HH:mm}, {2} reclaimable in total)" -f $Plan, $rep.LastWriteTime, (Format-FileSize $plan.Available)) 'Step'
        foreach ($t in $plan.Tasks) { Write-InsLog ("  {0,-12} {1,-10} cost {2,-3} {3}" -f (Format-FileSize $t.Bytes), $t.Risk, $t.Cost, $t.Name) 'Info' }
        Write-InsLog ("Total {0} for side-effect cost {1}{2}" -f (Format-FileSize $plan.Bytes), $plan.Cost, $(if ($plan.Reached) { '' } else { ' - target NOT reachable with cleanup alone' })) $(if ($plan.Reached) { 'Success' } else { 'Warning' })
        if ($Apply -and $plan.Tasks) {
            $ids = @($plan.Tasks | ForEach-Object { $_.Id })
            $exe = (Get-Process -Id $PID).Path
            $all = @($reg | ForEach-Object { $_.Id } | Where-Object { $ids -notcontains $_ })
            $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cleanup, '-Include', ($ids -join ','), '-Exclude', ($all -join ','), '-Unattended')
            if (@($plan.Tasks | Where-Object Risk -eq 'Dangerous')) { $args2 += '-IncludeDangerous' }
            if (Test-WhatIfMode) { $args2 += '-WhatIf' }
            & $exe @args2
        }
        return
    }

    # Boot
    Write-InsLog 'Boot time' 'Step'
    $boots = @()
    try { $boots = @(Get-WsBootHistory) } catch { Write-InsLog "  boot history unavailable: $($_.Exception.Message) (needs administrator rights)" 'Warning' }
    $clean = @($boots | Where-Object { -not $_.AfterUpdate -and $_.BootMs -gt 0 })
    $cmp = $null
    if ($clean) {
        $recent = @($clean | Sort-Object Time | Select-Object -Last 10)
        Write-InsLog ("  last {0} boots: median {1:N1} s (main path {2:N1} s + post-boot {3:N1} s), {4} startup apps" -f $recent.Count,
            ((Get-WsMedian ($recent | ForEach-Object { $_.BootMs })) / 1000), ((Get-WsMedian ($recent | ForEach-Object { $_.MainPathMs })) / 1000),
            ((Get-WsMedian ($recent | ForEach-Object { $_.PostBootMs })) / 1000), [int](Get-WsMedian ($recent | ForEach-Object { $_.StartupApps }))) 'Info'
        $change = if ($Since) { $Since } else { Get-WsLastOptimizationTime }
        if ($change) {
            $cmp = Compare-WsBootTime -Boots $boots -ChangeTime $change
            $txt = switch ($cmp.Verdict) {
                'Improved'     { "faster: {0:N1} s -> {1:N1} s ({2:+0.0;-0.0} %, p = {3:N3})" -f ($cmp.MedianBefore / 1000), ($cmp.MedianAfter / 1000), $cmp.ChangePct, $cmp.P }
                'Worse'        { "slower: {0:N1} s -> {1:N1} s ({2:+0.0;-0.0} %, p = {3:N3})" -f ($cmp.MedianBefore / 1000), ($cmp.MedianAfter / 1000), $cmp.ChangePct, $cmp.P }
                'Equivalent'   { 'no measurable effect (within 5 %)' }
                'Inconclusive' { "not clear yet ({0} vs {1} boots) - keep using the PC and check again" -f $cmp.NBefore, $cmp.NAfter }
                default        { "need at least 4 boots on each side ({0} before, {1} after)" -f $cmp.NBefore, $cmp.NAfter }
            }
            Write-InsLog ("  since {0:yyyy-MM-dd HH:mm}: {1}" -f $change, $txt) $(if ($cmp.Verdict -eq 'Improved') { 'Success' } elseif ($cmp.Verdict -eq 'Worse') { 'Warning' } else { 'Info' })
        }
        Write-InsLog 'Boot slowdowns (last 90 days)' 'Step'
        $deg = @(Get-WsBootDegrader | Select-Object -First 8)
        if (-not $deg) { Write-InsLog '  none recorded' 'Success' }
        foreach ($g in $deg) { Write-InsLog ("  {0,-8} {1,-40} x{2,-3} median +{3:N1} s" -f $g.Kind, $g.Name, $g.Count, ($g.MedianMs / 1000)) 'Info' }
    }

    # Disk
    Write-InsLog 'Disk space forecast' 'Step'
    [void](Add-WsDiskSample)
    $fc = foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        $letter = $d.Name.Substring(0, 1)
        $reserve = [int64][Math]::Min(0.10 * $d.TotalSize, 10GB)
        $f = Get-WsDiskForecast -Samples @(Get-WsDiskSample -Drive $letter) -ReserveBytes $reserve
        $msg = switch ($f.Status) {
            'Filling' { "{0} free, shrinking ~{1}/day -> below {2} in ~{3:N0} days (range {4}-{5})" -f (Format-FileSize $d.AvailableFreeSpace), (Format-FileSize $f.RateBytesPerDay), (Format-FileSize $reserve), $f.DaysLeft, $(if ($f.DaysLeftLow) { '{0:N0}' -f $f.DaysLeftLow } else { '?' }), $(if ($f.DaysLeftHigh) { '{0:N0}' -f $f.DaysLeftHigh } else { '?' }) }
            'Stable'  { "{0} free, not shrinking" -f (Format-FileSize $d.AvailableFreeSpace) }
            'Full'    { "{0} free - already below the {1} reserve" -f (Format-FileSize $d.AvailableFreeSpace), (Format-FileSize $reserve) }
            default   { "{0} free - collecting history ({1} samples over {2:N1} days; needs 5 over 7)" -f (Format-FileSize $d.AvailableFreeSpace), $f.Points, $f.SpanDays }
        }
        Write-InsLog "  ${letter}: $msg" $(if ($f.Status -eq 'Full' -or ($f.Status -eq 'Filling' -and $f.DaysLeft -lt 30)) { 'Warning' } else { 'Info' })
        [pscustomobject]@{ Drive = $letter; Status = $f.Status; DaysLeft = $f.DaysLeft; RateBytesPerDay = $f.RateBytesPerDay; FreeBytes = $d.AvailableFreeSpace }
    }

    if ($ReportPath) {
        Write-WinSeniorReport -ReportPath $ReportPath -Engine 'Insights' -Summary @{
            Boots = $clean.Count; BootVerdict = $(if ($cmp) { $cmp.Verdict } else { $null })
            BootMedianMs = $(if ($clean) { [int64](Get-WsMedian ($clean | Select-Object -Last 10 | ForEach-Object { $_.BootMs })) } else { $null })
        } -Items ([object[]]@($fc)) -LogAction { param($m, $l) Write-InsLog $m $l }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Start-WsInsights }
