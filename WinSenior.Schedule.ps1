<#
.SYNOPSIS
    Scheduled-task installer for WinSenior recurring maintenance.

.DESCRIPTION
    Dot-sourced by WinSenior.ps1. Registers two Task Scheduler jobs under the
    \WinSenior\ folder so maintenance runs unattended on a cadence:

      - WinSenior Weekly Cleanup       : weekly, Sunday 03:00
      - WinSenior Monthly Health Scan  : monthly, day 1 03:30 (scan only)

    The work is split into a pure planner and thin registration wrappers, mirroring
    WinSenior.UI.ps1: Get-WinSeniorScheduleSpec returns plain spec objects that can
    be unit-tested with no side effect, while Install/Remove turn those specs into
    Register-ScheduledTask / Unregister-ScheduledTask calls.

    Source stays pure ASCII so it loads identically under Windows PowerShell 5.1.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.0.0
#>

$script:WinSeniorTaskPath = '\WinSenior\'

# =====================================================================
# PURE PLANNER
#   Returns one spec per scheduled task. No registration, no I/O.
# =====================================================================
function Get-WinSeniorScheduleSpec {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ReportDir = "$env:ProgramData\WinSenior\reports"
    )
    $common = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'

    [pscustomobject]@{
        Name        = 'WinSenior Weekly Cleanup'
        TaskPath    = $script:WinSeniorTaskPath
        Description = 'WinSenior: weekly unattended disk cleanup (no restore point, no slow SFC/DISM).'
        Execute     = 'powershell.exe'
        Argument    = ('{0} "{1}" -Unattended -NoRestorePoint -SkipOptimization -ReportPath "{2}"' -f
                        $common, (Join-Path $Root 'Cleanup-Windows-Senior.ps1'), (Join-Path $ReportDir 'cleanup.json'))
        Cadence     = 'Weekly'
        Day         = 'Sunday'
        Time        = '03:00'
    }

    [pscustomobject]@{
        Name        = 'WinSenior Monthly Health Scan'
        TaskPath    = $script:WinSeniorTaskPath
        Description = 'WinSenior: monthly read-only health scan (changes nothing, writes a JSON report).'
        Execute     = 'powershell.exe'
        Argument    = ('{0} "{1}" -ScanOnly -Unattended -ReportPath "{2}"' -f
                        $common, (Join-Path $Root 'Repair-Windows-Senior.ps1'), (Join-Path $ReportDir 'repair.json'))
        Cadence     = 'Monthly'
        Day         = 1
        Time        = '03:30'
    }
}

# =====================================================================
# TRIGGER BUILDER
#   Weekly via the cmdlet; monthly via the CIM class (New-ScheduledTaskTrigger
#   has no -Monthly). DaysOfMonth and MonthsOfYear are bitmasks.
# =====================================================================
function New-WinSeniorTrigger {
    param([Parameter(Mandatory)]$Spec)
    $at = [datetime]::ParseExact($Spec.Time, 'HH:mm', $null)
    switch ($Spec.Cadence) {
        'Weekly' {
            return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Spec.Day -At $at
        }
        'Monthly' {
            # New-ScheduledTaskTrigger has no -Monthly, so build the CIM trigger.
            # MSFT_TaskMonthlyTrigger: DaysOfMonth and MonthOfYear (singular) are
            # bitmasks; MonthOfYear MUST be set or the task never fires.
            $cls = Get-CimClass -ClassName MSFT_TaskMonthlyTrigger `
                -Namespace 'Root/Microsoft/Windows/TaskScheduler'
            $t = New-CimInstance -CimClass $cls -ClientOnly
            $t.DaysOfMonth   = 1 -shl ([int]$Spec.Day - 1)  # day 1 -> bit 0 -> 1
            $t.MonthOfYear   = 0xFFF                          # all 12 months
            $t.StartBoundary = $at.ToString('yyyy-MM-ddTHH:mm:ss')
            $t.Enabled       = $true
            return $t
        }
        default { throw "Unknown cadence: $($Spec.Cadence)" }
    }
}

# =====================================================================
# INSTALL / REMOVE
# =====================================================================
function Install-WinSeniorSchedule {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ReportDir = "$env:ProgramData\WinSenior\reports",
        [scriptblock]$LogAction = { param($m, $l) Write-Host $m }
    )
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $ok = 0
    foreach ($spec in (Get-WinSeniorScheduleSpec -Root $Root -ReportDir $ReportDir)) {
        try {
            $action  = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
            $trigger = New-WinSeniorTrigger -Spec $spec
            Register-ScheduledTask -TaskName $spec.Name -TaskPath $spec.TaskPath `
                -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                -Description $spec.Description -Force -ErrorAction Stop | Out-Null
            & $LogAction ("Registered: {0} ({1})" -f $spec.Name, $spec.Cadence) 'Success'
            $ok++
        }
        catch {
            & $LogAction ("Failed to register '{0}': {1}" -f $spec.Name, $_.Exception.Message) 'Error'
        }
    }
    & $LogAction ("Scheduled tasks installed: {0}. Reports go to {1}" -f $ok, $ReportDir) 'Info'
    return $ok
}

function Remove-WinSeniorSchedule {
    param(
        [string]$Root = $PSScriptRoot,
        [scriptblock]$LogAction = { param($m, $l) Write-Host $m }
    )
    $removed = 0
    foreach ($spec in (Get-WinSeniorScheduleSpec -Root $Root)) {
        try {
            $existing = Get-ScheduledTask -TaskName $spec.Name -TaskPath $spec.TaskPath -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskName $spec.Name -TaskPath $spec.TaskPath -Confirm:$false -ErrorAction Stop
                & $LogAction ("Removed: {0}" -f $spec.Name) 'Success'
                $removed++
            }
            else {
                & $LogAction ("Not present: {0}" -f $spec.Name) 'Info'
            }
        }
        catch {
            & $LogAction ("Failed to remove '{0}': {1}" -f $spec.Name, $_.Exception.Message) 'Warning'
        }
    }
    & $LogAction ("Scheduled tasks removed: {0}" -f $removed) 'Info'
    return $removed
}
