<#
.SYNOPSIS
    Scheduled-task installer for WinSenior recurring maintenance.

.DESCRIPTION
    Dot-sourced by WinSenior.ps1. Registers two Task Scheduler jobs under the
    \WinSenior\ folder so maintenance runs unattended on a cadence:

      - WinSenior Weekly Cleanup       : weekly, Sunday 03:00
      - WinSenior Monthly Health Scan  : monthly, day 1 03:30 (scan only)

    The tasks run as SYSTEM, so they must never execute scripts from a folder a
    normal user can write to (a git clone in the user profile, Downloads, ...):
    whoever edits those files would get code execution as SYSTEM. Install therefore
    copies the engine scripts into "%ProgramFiles%\WinSenior" - which inherits the
    admins-only ACL of Program Files - and points the tasks there. Remove deletes
    that copy again.

    The work is split into a pure planner and thin registration wrappers, mirroring
    WinSenior.UI.ps1: Get-WinSeniorScheduleSpec returns plain spec objects that can
    be unit-tested with no side effect, while Install/Remove turn those specs into
    Register-ScheduledTask / Unregister-ScheduledTask calls.

    Source stays pure ASCII so it loads identically under Windows PowerShell 5.1.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.3.0
#>

$script:WinSeniorTaskPath = '\WinSenior\'

# Where the scheduled copy of the scripts lives (admins-only, inherited from Program Files).
function Get-WinSeniorInstallRoot {
    $pf = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    Join-Path $pf 'WinSenior'
}

# =====================================================================
# PURE PLANNER
#   Returns one spec per scheduled task. No registration, no I/O.
#   -InstallRoot is where the tasks run the scripts from; -Root (the source
#   checkout) is kept for compatibility and used only when -InstallRoot is empty.
# =====================================================================
function Get-WinSeniorScheduleSpec {
    param(
        [string]$Root,
        [string]$InstallRoot = (Get-WinSeniorInstallRoot),
        [string]$ReportDir = "$env:ProgramData\WinSenior\reports"
    )
    $base = if ($InstallRoot) { $InstallRoot } elseif ($Root) { $Root } else { throw 'Get-WinSeniorScheduleSpec: -InstallRoot or -Root is required.' }
    $common = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'

    [pscustomobject]@{
        Name        = 'WinSenior Weekly Cleanup'
        TaskPath    = $script:WinSeniorTaskPath
        Description = 'WinSenior: weekly unattended disk cleanup (no restore point, no slow SFC/DISM).'
        Execute     = 'powershell.exe'
        Argument    = ('{0} "{1}" -Unattended -NoRestorePoint -SkipOptimization -ReportPath "{2}"' -f
                        $common, (Join-Path $base 'Cleanup-Windows-Senior.ps1'), (Join-Path $ReportDir 'cleanup-{timestamp}.json'))
        ScriptRoot  = $base
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
                        $common, (Join-Path $base 'Repair-Windows-Senior.ps1'), (Join-Path $ReportDir 'repair-{timestamp}.json'))
        ScriptRoot  = $base
        Cadence     = 'Monthly'
        Day         = 1
        Time        = '03:30'
    }
}

# Which files the installed copy needs: every root *.ps1 of the source checkout.
function Get-WinSeniorInstallFile {
    param([Parameter(Mandatory)][string]$Root)
    @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
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
# INSTALLED COPY (Program Files)
# =====================================================================
function Test-WinSeniorSamePath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    try {
        [IO.Path]::GetFullPath($A).TrimEnd('\') -ieq [IO.Path]::GetFullPath($B).TrimEnd('\')
    } catch { $false }
}

function Copy-WinSeniorInstallFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$InstallRoot,
        [scriptblock]$LogAction = { param($m, $l) Write-Verbose "[$l] $m" }
    )
    if (Test-WinSeniorSamePath $Root $InstallRoot) {
        & $LogAction "Already running from $InstallRoot - nothing to copy." 'Info'
        return $true
    }
    $files = Get-WinSeniorInstallFile -Root $Root
    if (-not $files) { throw "No scripts found in $Root" }
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force -ErrorAction Stop | Out-Null
    }
    # Drop stale scripts from an older install, then copy the current set.
    $keep = @($files | ForEach-Object Name)
    Get-ChildItem -LiteralPath $InstallRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $keep -notcontains $_.Name } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $InstallRoot $f.Name) -Force -ErrorAction Stop
    }
    Get-ChildItem -LiteralPath $InstallRoot -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue
    & $LogAction ("Copied {0} script(s) to {1}" -f $files.Count, $InstallRoot) 'Info'
    $true
}

function Remove-WinSeniorInstallCopy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$Root,
        [scriptblock]$LogAction = { param($m, $l) Write-Verbose "[$l] $m" }
    )
    if (-not (Test-Path -LiteralPath $InstallRoot)) { return $false }
    if (Test-WinSeniorSamePath $Root $InstallRoot) {
        & $LogAction "Not deleting $InstallRoot - WinSenior is running from there." 'Warning'
        return $false
    }
    # Only ever delete a folder that is recognisably ours.
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'WinSenior.Common.ps1'))) {
        & $LogAction "Not deleting $InstallRoot - it does not look like a WinSenior install." 'Warning'
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($InstallRoot, 'Delete the scheduled-task copy of WinSenior')) { return $false }
    try {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction Stop
        & $LogAction "Deleted $InstallRoot" 'Info'
        $true
    }
    catch {
        & $LogAction "Could not delete ${InstallRoot}: $($_.Exception.Message)" 'Warning'
        $false
    }
}

# =====================================================================
# INSTALL / REMOVE
# =====================================================================
function Install-WinSeniorSchedule {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$InstallRoot = (Get-WinSeniorInstallRoot),
        [string]$ReportDir = "$env:ProgramData\WinSenior\reports",
        [scriptblock]$LogAction = { param($m, $l) Write-Host $m }
    )
    try { Copy-WinSeniorInstallFile -Root $Root -InstallRoot $InstallRoot -LogAction $LogAction | Out-Null }
    catch {
        & $LogAction ("Could not copy the scripts to {0}: {1}" -f $InstallRoot, $_.Exception.Message) 'Error'
        & $LogAction 'Scheduled tasks were NOT registered (they must not run from a user-writable folder).' 'Error'
        return 0
    }
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $ok = 0
    foreach ($spec in (Get-WinSeniorScheduleSpec -Root $Root -InstallRoot $InstallRoot -ReportDir $ReportDir)) {
        try {
            $action  = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument -WorkingDirectory $spec.ScriptRoot
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
    & $LogAction ("Scheduled tasks installed: {0}. Scripts run from {1}; reports go to {2}" -f $ok, $InstallRoot, $ReportDir) 'Info'
    return $ok
}

function Remove-WinSeniorSchedule {
    param(
        [string]$Root = $PSScriptRoot,
        [string]$InstallRoot = (Get-WinSeniorInstallRoot),
        [scriptblock]$LogAction = { param($m, $l) Write-Host $m }
    )
    $removed = 0
    foreach ($spec in (Get-WinSeniorScheduleSpec -Root $Root -InstallRoot $InstallRoot)) {
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
    Remove-WinSeniorInstallCopy -InstallRoot $InstallRoot -Root $Root -LogAction $LogAction | Out-Null
    & $LogAction ("Scheduled tasks removed: {0}" -f $removed) 'Info'
    return $removed
}
