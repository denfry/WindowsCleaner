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
    [switch]$NoElevate
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
# LOCATE ENGINES + ELEVATE
# =====================================================================
$script:Root           = $PSScriptRoot
$script:CleanupScript  = Join-Path $script:Root 'Cleanup-Windows-Senior.ps1'
$script:OptimizeScript = Join-Path $script:Root 'Optimize-Windows-Senior.ps1'
$script:RepairScript   = Join-Path $script:Root 'Repair-Windows-Senior.ps1'

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

foreach ($s in @($script:CleanupScript, $script:OptimizeScript, $script:RepairScript)) {
    if (-not (Test-Path $s)) {
        Write-Host "Engine not found: $s" -ForegroundColor Red
        Write-Host 'Keep WinSenior.ps1 next to the two engine scripts.' -ForegroundColor Yellow
        exit 1
    }
}

if (-not (Test-Admin)) {
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

# Generic toggle screen. $OnSet is mutated in place (HashSet is a reference type).
function Invoke-ToggleScreen {
    param([string]$Title, [object[]]$Items, [object]$OnSet, [string]$GroupProp, [hashtable]$AppliedMap)
    while ($true) {
        Write-Banner $Title
        $i = 0; $map = @{}; $last = $null
        foreach ($it in $Items) {
            if ($it.$GroupProp -ne $last) {
                Write-Host "  $($it.$GroupProp)" -ForegroundColor Yellow
                $last = $it.$GroupProp
            }
            $i++; $map[$i] = $it.Id
            $on   = $OnSet.Contains($it.Id)
            $mark = if ($on) { '[x]' } else { '[ ]' }
            $col  = if ($on) { 'Green' } else { 'DarkGray' }
            $suffix = ''
            if ($AppliedMap -and $AppliedMap.ContainsKey($it.Id)) {
                $st = $AppliedMap[$it.Id]
                if ($st -eq $true) { $suffix = '  (applied)' } elseif ($st -eq $false) { $suffix = '  (not set)' }
            }
            Write-Host ("   {0,3}. {1} {2,-11} {3}{4}" -f $i, $mark, $it.Risk, $it.Name, $suffix) -ForegroundColor $col
        }
        Write-Host ''
        Write-Host '  Type numbers (space/comma separated) to toggle | a=all  n=none  Enter=done' -ForegroundColor DarkGray
        $in = (Read-Key).Trim()
        if ($in -eq '')  { break }
        if ($in -eq 'a') { foreach ($it in $Items) { [void]$OnSet.Add($it.Id) }; continue }
        if ($in -eq 'n') { $OnSet.Clear(); continue }
        foreach ($tok in ($in -split '[\s,]+')) {
            if ($tok -match '^\d+$' -and $map.ContainsKey([int]$tok)) {
                $id = $map[[int]$tok]
                if ($OnSet.Contains($id)) { [void]$OnSet.Remove($id) } else { [void]$OnSet.Add($id) }
            }
        }
    }
}

# Build -Include/-Exclude so the engine reproduces exactly the toggled set.
function Get-SelectionParams {
    param([object[]]$Registry, [object]$OnSet)
    $on  = @($Registry | Where-Object { $OnSet.Contains($_.Id) } | ForEach-Object Id)
    $off = @($Registry | Where-Object { -not $OnSet.Contains($_.Id) } | ForEach-Object Id)
    @{ Include = $on; Exclude = $off }
}

# =====================================================================
# CLEANUP SCREEN
# =====================================================================
function Show-CleanupScreen {
    while ($true) {
        Write-Banner 'Disk cleanup'
        $onCount = @($script:CleanReg | Where-Object { $script:CleanOn.Contains($_.Id) }).Count
        $danger  = @($script:CleanReg | Where-Object { $script:CleanOn.Contains($_.Id) -and $_.Risk -eq 'Dangerous' }).Count
        $scope   = if ($script:CleanCU) { 'current user' } else { 'all users' }
        Write-Host "  Selected: $onCount / $($script:CleanReg.Count) tasks   Scope: $scope" -ForegroundColor Gray
        if ($danger) { Write-Host "  Includes $danger DANGEROUS task(s) - you will be asked to confirm." -ForegroundColor Magenta }
        Write-Host ''
        Write-Host '   1. Preview (dry run, changes nothing)' -ForegroundColor White
        Write-Host '   2. Run cleanup' -ForegroundColor White
        Write-Host '   3. Choose tasks (detailed toggle)' -ForegroundColor White
        Write-Host "   4. Scope: toggle current-user-only (now: $scope)" -ForegroundColor White
        Write-Host '   5. Reset to defaults' -ForegroundColor White
        Write-Host '   0. Back' -ForegroundColor White
        Write-Host ''
        switch ((Read-Key).Trim()) {
            '1' { Invoke-Cleanup -Preview $true;  Wait-Enter }
            '2' { Invoke-Cleanup -Preview $false; Wait-Enter }
            '3' { Invoke-ToggleScreen -Title 'Cleanup tasks' -Items $script:CleanReg -OnSet $script:CleanOn -GroupProp 'Category' }
            '4' { $script:CleanCU = -not $script:CleanCU }
            '5' { $script:CleanOn.Clear(); foreach ($t in (Resolve-CleanupSelection -Registry $script:CleanReg)) { [void]$script:CleanOn.Add($t.Id) } }
            '0' { return }
            default { }
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
    while ($true) {
        Write-Banner 'Windows optimization'
        $onCount = @($script:OptReg | Where-Object { $script:OptOn.Contains($_.Id) }).Count
        Write-Host "  Selected: $onCount / $($script:OptReg.Count) tweaks" -ForegroundColor Gray
        Write-Host '  Every applied tweak is backed up first; use Undo to revert.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   1. Preview (dry run, changes nothing)' -ForegroundColor White
        Write-Host '   2. Apply tweaks' -ForegroundColor White
        Write-Host '   3. Choose tweaks (detailed toggle, shows current state)' -ForegroundColor White
        Write-Host '   4. Undo last optimization run' -ForegroundColor White
        Write-Host '   5. Reset to defaults' -ForegroundColor White
        Write-Host '   0. Back' -ForegroundColor White
        Write-Host ''
        switch ((Read-Key).Trim()) {
            '1' { Invoke-Optimize -Preview $true;  Wait-Enter }
            '2' { Invoke-Optimize -Preview $false; Wait-Enter }
            '3' {
                Write-Host '  Reading current state...' -ForegroundColor DarkGray
                $applied = Get-AppliedMap
                Invoke-ToggleScreen -Title 'Optimization tweaks' -Items $script:OptReg -OnSet $script:OptOn -GroupProp 'Area' -AppliedMap $applied
            }
            '4' { Write-Host ''; & $script:OptimizeScript -Undo; Wait-Enter }
            '5' { $script:OptOn.Clear(); foreach ($t in (Resolve-TweakSelection -Registry $script:OptReg)) { [void]$script:OptOn.Add($t.Id) } }
            '0' { return }
            default { }
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
    while ($true) {
        Write-Banner 'Troubleshoot - scan & repair'
        Write-Host '  Scans for common Windows problems (read-only), then lets you repair them.' -ForegroundColor DarkGray
        Write-Host '  A restore point is made before any repair.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   1. Scan & repair      (scan, then choose what to fix)' -ForegroundColor White
        Write-Host '   2. Scan only          (diagnose, change nothing)' -ForegroundColor White
        Write-Host '   3. Auto-fix safe      (apply Safe + Moderate fixes automatically)' -ForegroundColor White
        Write-Host '   4. Auto-fix all       (include heavy repairs: SFC/DISM/WU/network)' -ForegroundColor White
        Write-Host '   0. Back' -ForegroundColor White
        Write-Host ''
        switch ((Read-Key).Trim()) {
            '1' { Write-Host ''; & $script:RepairScript;                          Wait-Enter }
            '2' { Write-Host ''; & $script:RepairScript -ScanOnly;                Wait-Enter }
            '3' { Write-Host ''; & $script:RepairScript -FixAll;                  Wait-Enter }
            '4' { Write-Host ''; & $script:RepairScript -FixAll -IncludeHeavy;    Wait-Enter }
            '0' { return }
            default { }
        }
    }
}

# =====================================================================
# MAIN MENU
# =====================================================================
function Show-MainMenu {
    while ($true) {
        Write-Banner 'Windows Senior - system maintenance'
        $admin = if (Test-Admin) { 'yes' } else { 'NO (run as admin)' }
        Write-Host "  Administrator: $admin" -ForegroundColor $(if (Test-Admin) { 'Green' } else { 'Red' })
        Write-Host ''
        Write-Host '   1. Disk cleanup        (detailed - categories, preview, run)' -ForegroundColor White
        Write-Host '   2. Optimize Windows    (performance / privacy / debloat / network)' -ForegroundColor White
        Write-Host '   3. Troubleshoot        (scan for problems, then repair)' -ForegroundColor White
        Write-Host '   4. Full run            (cleanup + optimization)' -ForegroundColor White
        Write-Host '   5. Undo optimizations  (revert last run from backup)' -ForegroundColor White
        Write-Host '   6. Create restore point' -ForegroundColor White
        Write-Host '   7. List tasks, tweaks & checks' -ForegroundColor White
        Write-Host '   0. Exit' -ForegroundColor White
        Write-Host ''
        switch ((Read-Key).Trim()) {
            '1' { Show-CleanupScreen }
            '2' { Show-OptimizeScreen }
            '3' { Show-TroubleshootScreen }
            '4' { Invoke-FullRun }
            '5' { Write-Banner 'Undo optimizations'; & $script:OptimizeScript -Undo; Wait-Enter }
            '6' { Write-Banner 'Create restore point'; New-CleanupRestorePoint | Out-Null; Wait-Enter }
            '7' { Write-Banner 'Tasks, tweaks & checks'; Show-TaskList; Show-TweakList; Show-CheckList; Wait-Enter }
            '0' { Write-Host ''; Write-Host '  Bye.' -ForegroundColor Cyan; return }
            'q' { return }
            default { }
        }
    }
}

Show-MainMenu
