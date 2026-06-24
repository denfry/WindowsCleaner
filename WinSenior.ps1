<#
.SYNOPSIS
    Windows Senior - one interactive menu for the cleanup and optimization engines.

.DESCRIPTION
    The single entry point. Run this and a menu opens with detailed screens for disk
    cleanup, Windows optimization, undo, restore point and reports. It drives the two
    engines (Cleanup-Windows-Senior.ps1 and Optimize-Windows-Senior.ps1) by invoking
    them with parameters, so every run goes through their tested logic, real -WhatIf,
    safety guard and per-tweak undo.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.0.0
    Requires: PowerShell 5.1+ (Windows). Administrator rights (auto-elevates).

.EXAMPLE
    .\WinSenior.ps1
    Open the interactive menu.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    # Do not try to relaunch elevated; run with whatever rights we have.
    [switch]$NoElevate,
    # Force ASCII-only glyphs (for terminals that can't render box-drawing chars).
    [switch]$Plain,
    # Register the recurring maintenance scheduled tasks, then exit.
    [switch]$InstallSchedule,
    # Remove the recurring maintenance scheduled tasks, then exit.
    [switch]$RemoveSchedule
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
# LOCATE ENGINES + ELEVATE
# =====================================================================
$script:Root           = $PSScriptRoot
$script:CommonScript   = Join-Path $script:Root 'WinSenior.Common.ps1'
$script:CleanupScript  = Join-Path $script:Root 'Cleanup-Windows-Senior.ps1'
$script:OptimizeScript = Join-Path $script:Root 'Optimize-Windows-Senior.ps1'
$script:RepairScript   = Join-Path $script:Root 'Repair-Windows-Senior.ps1'
$script:UiScript       = Join-Path $script:Root 'WinSenior.UI.ps1'
$script:ScheduleScript = Join-Path $script:Root 'WinSenior.Schedule.ps1'

foreach ($s in @($script:CommonScript, $script:CleanupScript, $script:OptimizeScript, $script:RepairScript, $script:UiScript, $script:ScheduleScript)) {
    if (-not (Test-Path $s)) {
        Write-Host "Engine not found: $s" -ForegroundColor Red
        Write-Host 'Keep WinSenior.ps1 next to the engine scripts and WinSenior.Common.ps1.' -ForegroundColor Yellow
        exit 1
    }
}

# Shared helpers (admin check, restore point, logging) - needed before elevation.
. $script:CommonScript

if (-not (Test-AdminPrivileges)) {
    if ($NoElevate) {
        Write-Host '[!] Not running as Administrator - most actions will fail.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Requesting administrator privileges...' -ForegroundColor Cyan
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
            exit 0
        } catch {
            Write-Host 'Elevation cancelled. Re-run as Administrator, or use -NoElevate.' -ForegroundColor Red
            exit 1
        }
    }
}

# Load the engines as libraries (their entry guards keep them from auto-running).
. $script:CleanupScript
. $script:OptimizeScript
. $script:RepairScript

# Load the TUI primitives and build the glyph/color theme.
. $script:UiScript
Initialize-UiTheme -Plain:$Plain

# Load the scheduled-task installer library.
. $script:ScheduleScript

# Schedule management is a fire-and-exit action, taken before the interactive menu.
if ($InstallSchedule) {
    Install-WinSeniorSchedule -Root $script:Root `
        -LogAction { param($m, $l) Write-WsLog -Message $m -Level $l } | Out-Null
    exit 0
}
if ($RemoveSchedule) {
    Remove-WinSeniorSchedule -Root $script:Root `
        -LogAction { param($m, $l) Write-WsLog -Message $m -Level $l } | Out-Null
    exit 0
}

# =====================================================================
# SELECTION STATE
# =====================================================================
$script:CleanReg = Get-CleanupTaskRegistry
$script:OptReg   = Get-OptimizationTweakRegistry

# Start from each engine's default selection.
$script:CleanOn = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($t in (Resolve-CleanupSelection -Registry $script:CleanReg)) { [void]$script:CleanOn.Add($t.Id) }
$script:OptOn = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($t in (Resolve-TweakSelection -Registry $script:OptReg)) { [void]$script:OptOn.Add($t.Id) }

$script:CleanCU = $false   # current-user-only toggle for cleanup

# =====================================================================
# UI HELPERS
# =====================================================================
function Write-Banner {
    param([string]$Title)
    Clear-Host
    Write-Host ''
    Write-Host "  ============================================================" -ForegroundColor DarkCyan
    Write-Host "   $Title" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor DarkCyan
    Write-Host ''
}

function Read-Key {
    param([string]$Prompt = '  > ')
    Write-Host $Prompt -ForegroundColor White -NoNewline
    Read-Host
}

function Wait-Enter { Write-Host ''; Write-Host '  Press Enter to continue...' -ForegroundColor DarkGray -NoNewline; [void](Read-Host) }

# Build -Include/-Exclude so the engine reproduces exactly the toggled set.
function Get-SelectionParams {
    param([object[]]$Registry, [object]$OnSet)
    $on  = @($Registry | Where-Object { $OnSet.Contains($_.Id) } | ForEach-Object Id)
    $off = @($Registry | Where-Object { -not $OnSet.Contains($_.Id) } | ForEach-Object Id)
    @{ Include = $on; Exclude = $off }
}

# Map the cleanup registry into checklist items (Group = Category).
function Get-CleanupItems {
    $script:CleanReg | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Group = $_.Category; Risk = $_.Risk; Applied = $null }
    }
}

# Map the optimization registry into checklist items (Group = Area), with live applied-state.
function Get-OptimizeItems {
    param([hashtable]$Applied)
    $script:OptReg | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Group = $_.Area; Risk = $_.Risk; Applied = $Applied[$_.Id] }
    }
}

# =====================================================================
# CLEANUP SCREEN
# =====================================================================
function Show-CleanupScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Preview (dry run, changes nothing)' }
        [pscustomobject]@{ Label = 'Run cleanup' }
        [pscustomobject]@{ Label = 'Choose tasks (detailed)' }
        [pscustomobject]@{ Label = 'Toggle scope (all users / current user)' }
        [pscustomobject]@{ Label = 'Reset to defaults' }
    )
    while ($true) {
        $onCount = @($script:CleanReg | Where-Object { $script:CleanOn.Contains($_.Id) }).Count
        $danger  = @($script:CleanReg | Where-Object { $script:CleanOn.Contains($_.Id) -and $_.Risk -eq 'Dangerous' }).Count
        $scope   = if ($script:CleanCU) { 'current user' } else { 'all users' }
        $status  = @("Selected: $onCount / $($script:CleanReg.Count) tasks    Scope: $scope")
        if ($danger) { $status += "Includes $danger DANGEROUS task(s) - you will be asked to confirm." }
        switch (Show-Menu -Title 'Disk cleanup' -Items $items -StatusLines $status) {
            0 { Invoke-Cleanup -Preview $true;  Wait-Enter }
            1 { Invoke-Cleanup -Preview $false; Wait-Enter }
            2 { Show-Checklist -Title 'Cleanup tasks' -Items (Get-CleanupItems) -OnSet $script:CleanOn }
            3 { $script:CleanCU = -not $script:CleanCU }
            4 { $script:CleanOn.Clear(); foreach ($t in (Resolve-CleanupSelection -Registry $script:CleanReg)) { [void]$script:CleanOn.Add($t.Id) } }
            $null { return }
        }
    }
}

function Invoke-Cleanup {
    param([bool]$Preview)
    $params = Get-SelectionParams -Registry $script:CleanReg -OnSet $script:CleanOn
    if (-not $params.Include.Count) { Write-Host '  Nothing selected.' -ForegroundColor Yellow; return }
    if ($script:CleanCU) { $params.CurrentUserOnly = $true }
    if ($Preview)        { $params.WhatIf = $true }
    Write-Host ''
    & $script:CleanupScript @params
}

# =====================================================================
# OPTIMIZATION SCREEN
# =====================================================================
function Get-AppliedMap {
    $m = @{}
    foreach ($t in $script:OptReg) { $m[$t.Id] = (Test-TweakApplied -Tweak $t) }
    $m
}

function Show-OptimizeScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Preview (dry run, changes nothing)' }
        [pscustomobject]@{ Label = 'Apply tweaks' }
        [pscustomobject]@{ Label = 'Choose tweaks (detailed, shows current state)' }
        [pscustomobject]@{ Label = 'Undo last optimization run' }
        [pscustomobject]@{ Label = 'Reset to defaults' }
    )
    while ($true) {
        $onCount = @($script:OptReg | Where-Object { $script:OptOn.Contains($_.Id) }).Count
        $status  = @("Selected: $onCount / $($script:OptReg.Count) tweaks", 'Every applied tweak is backed up first; use Undo to revert.')
        switch (Show-Menu -Title 'Windows optimization' -Items $items -StatusLines $status) {
            0 { Invoke-Optimize -Preview $true;  Wait-Enter }
            1 { Invoke-Optimize -Preview $false; Wait-Enter }
            2 {
                Write-Host '  Reading current state...' -ForegroundColor DarkGray
                $applied = Get-AppliedMap
                Show-Checklist -Title 'Optimization tweaks' -Items (Get-OptimizeItems -Applied $applied) -OnSet $script:OptOn
            }
            3 { Write-Host ''; & $script:OptimizeScript -Undo; Wait-Enter }
            4 { $script:OptOn.Clear(); foreach ($t in (Resolve-TweakSelection -Registry $script:OptReg)) { [void]$script:OptOn.Add($t.Id) } }
            $null { return }
        }
    }
}

function Invoke-Optimize {
    param([bool]$Preview)
    $params = Get-SelectionParams -Registry $script:OptReg -OnSet $script:OptOn
    if (-not $params.Include.Count) { Write-Host '  Nothing selected.' -ForegroundColor Yellow; return }
    if ($Preview) { $params.WhatIf = $true }
    Write-Host ''
    & $script:OptimizeScript @params
}

# =====================================================================
# FULL RUN
# =====================================================================
function Invoke-FullRun {
    Write-Banner 'Full run: cleanup + optimization'
    Write-Host '  This will run the selected cleanup tasks AND apply the selected tweaks.' -ForegroundColor Yellow
    Write-Host '  A restore point is created first; tweaks are backed up for undo.' -ForegroundColor DarkGray
    Write-Host ''
    if ((Read-Key '  Type "yes" to proceed: ').Trim() -notmatch '^(y|yes)$') { Write-Host '  Cancelled.' -ForegroundColor Gray; Wait-Enter; return }
    Write-Host ''
    Invoke-Cleanup  -Preview $false
    Invoke-Optimize -Preview $false
    Wait-Enter
}

# =====================================================================
# TROUBLESHOOT SCREEN
# =====================================================================
function Show-TroubleshootScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Scan & repair      (scan, then choose what to fix)' }
        [pscustomobject]@{ Label = 'Scan only          (diagnose, change nothing)' }
        [pscustomobject]@{ Label = 'Auto-fix safe      (apply Safe + Moderate fixes)' }
        [pscustomobject]@{ Label = 'Auto-fix all       (include heavy: SFC/DISM/WU/network)' }
    )
    $status = @('Scans for common Windows problems (read-only), then lets you repair.', 'A restore point is made before any repair.')
    while ($true) {
        switch (Show-Menu -Title 'Troubleshoot - scan & repair' -Items $items -StatusLines $status) {
            0 { Write-Host ''; & $script:RepairScript;                       Wait-Enter }
            1 { Write-Host ''; & $script:RepairScript -ScanOnly;             Wait-Enter }
            2 { Write-Host ''; & $script:RepairScript -FixAll;               Wait-Enter }
            3 { Write-Host ''; & $script:RepairScript -FixAll -IncludeHeavy; Wait-Enter }
            $null { return }
        }
    }
}

# =====================================================================
# MAIN MENU
# =====================================================================
function Show-MainMenu {
    $items = @(
        [pscustomobject]@{ Label = 'Disk cleanup        (categories, preview, run)' }
        [pscustomobject]@{ Label = 'Optimize Windows    (performance / privacy / debloat / network)' }
        [pscustomobject]@{ Label = 'Troubleshoot        (scan for problems, then repair)' }
        [pscustomobject]@{ Label = 'Full run            (cleanup + optimization)' }
        [pscustomobject]@{ Label = 'Undo optimizations  (revert last run from backup)' }
        [pscustomobject]@{ Label = 'Create restore point' }
        [pscustomobject]@{ Label = 'List tasks, tweaks & checks' }
    )
    while ($true) {
        $admin = if (Test-Admin) { 'Administrator: yes' } else { 'Administrator: NO - re-run as admin' }
        switch (Show-Menu -Title 'Windows Senior - system maintenance' -Items $items -StatusLines @($admin)) {
            0 { Show-CleanupScreen }
            1 { Show-OptimizeScreen }
            2 { Show-TroubleshootScreen }
            3 { Invoke-FullRun }
            4 { Write-Banner 'Undo optimizations'; & $script:OptimizeScript -Undo; Wait-Enter }
            5 { Write-Banner 'Create restore point'; New-CleanupRestorePoint | Out-Null; Wait-Enter }
            6 { Write-Banner 'Tasks, tweaks & checks'; Show-TaskList; Show-TweakList; Show-CheckList; Wait-Enter }
            $null { Write-Host ''; Write-Host '  Bye.' -ForegroundColor Cyan; return }
        }
    }
}

Show-MainMenu
