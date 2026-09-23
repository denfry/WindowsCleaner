<#
.SYNOPSIS
    Windows Senior - desktop (WPF) application for the cleanup, optimization and
    troubleshooting engines.

.DESCRIPTION
    A native Windows window built on WPF (ships with every Windows 10/11, nothing to
    install). It drives the three engines exactly like the console menu does - by
    launching them with parameters - so every action keeps the engines' real -WhatIf,
    the safety guard, restore points and per-tweak undo. Engine output streams into
    the log panel; JSON reports feed the per-task size and health columns and the
    History page. The Startup page toggles autostart entries the way Task Manager
    does (WinSenior.Startup.ps1).

    Normally started through WinSenior.cmd (double-click) or WinSenior.ps1 -Gui;
    both elevate first. Run directly with -NoElevate to skip the UAC prompt.

    Automation hooks (smoke tests; all optional environment variables):
      WINSENIOR_GUI_AUTOCLOSE=<s>      close by itself after <s> seconds (waits while an engine runs)
      WINSENIOR_GUI_SCREENSHOT=<png>   render the window to a PNG right before closing
      WINSENIOR_GUI_AUTORUN=<button>   press a NON-destructive button once shown (scan / preview / refresh)
      WINSENIOR_GUI_PAGE=<NavName>     open that page first (NavStartup, NavHistory, ...)
      WINSENIOR_GUI_DATADIR=<dir>      keep settings, logs and reports there instead of %ProgramData%
      WINSENIOR_GUI_SMOKELOG=<file>    write the log panel text (and final status) to a file when closing
      WINSENIOR_GUI_AUTOCANCEL=<s>     press Cancel <s> seconds after the window shows
      WINSENIOR_NOELEVATE=1            same as -NoElevate

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Requires: PowerShell 5.1+ (Windows), .NET Framework 4.x (built in).
    Source stays pure ASCII; non-ASCII glyphs are built from code points.
#>

#Requires -Version 5.1

# UI helpers named Set-/Start-/Update-* only change in-memory window state; every
# system change goes through the engines, which implement ShouldProcess themselves.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'UI helpers change window state only; the engines implement ShouldProcess.')]
[CmdletBinding()]
param(
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { Write-Verbose 'console encoding unchanged' }

# WPF first: every error path below may need a MessageBox.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:Win    = $null
$script:LogDir = $null

function Show-WsMessage {
    param([string]$Text, [string]$Title = 'Windows Senior', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    if ($script:Win -and $script:Win.IsLoaded) {
        return [System.Windows.MessageBox]::Show($script:Win, $Text, $Title, $Buttons, $Icon)
    }
    [System.Windows.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}

function Get-WsErrorText {
    param($ErrorObject)
    $ex = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) { $ErrorObject.Exception } else { $ErrorObject }
    $msg = if ($ex) { $ex.Message } else { [string]$ErrorObject }
    # PowerShell wraps handler errors ("Exception calling RaiseEvent ...") - show the root cause.
    while ($ex -and $ex.InnerException) { $ex = $ex.InnerException; $msg = $ex.Message }
    $msg
}

function Write-CrashLog {
    param($ErrorObject, [string]$Context = '')
    $dir = if ($script:LogDir -and (Test-Path -LiteralPath $script:LogDir)) { $script:LogDir } else { $env:TEMP }
    $file = Join-Path $dir 'gui-crash.log'
    try {
        $detail = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
            "$($ErrorObject | Out-String)`r`n$($ErrorObject.ScriptStackTrace)"
        } else { [string]$ErrorObject }
        $text = "==== {0:yyyy-MM-dd HH:mm:ss}  {1}  (PowerShell {2})`r`n{3}`r`n" -f (Get-Date), $Context, $PSVersionTable.PSVersion, $detail
        [System.IO.File]::AppendAllText($file, $text, [System.Text.Encoding]::UTF8)
    } catch { Write-Verbose 'crash log not writable' }
    $file
}

# Anything that escapes before the window is up would otherwise die silently
# (the console is hidden): log it and tell the user.
trap {
    $f = Write-CrashLog $_ 'startup'
    try {
        Show-WsMessage -Text ("Windows Senior could not start:`n`n{0}`n`nDetails: {1}" -f (Get-WsErrorText $_), $f) -Title 'Windows Senior' -Buttons 'OK' -Icon 'Error' | Out-Null
    } catch { Write-Verbose 'no message box' }
    exit 1
}

# =====================================================================
# LOCATE ENGINES + ELEVATE
# =====================================================================
$script:Root           = $PSScriptRoot
$script:CommonScript   = Join-Path $script:Root 'WinSenior.Common.ps1'
$script:CleanupScript  = Join-Path $script:Root 'Cleanup-Windows-Senior.ps1'
$script:OptimizeScript = Join-Path $script:Root 'Optimize-Windows-Senior.ps1'
$script:RepairScript   = Join-Path $script:Root 'Repair-Windows-Senior.ps1'
$script:MenuScript     = Join-Path $script:Root 'WinSenior.ps1'
$script:ScheduleScript = Join-Path $script:Root 'WinSenior.Schedule.ps1'
$script:StartupScript  = Join-Path $script:Root 'WinSenior.Startup.ps1'

foreach ($s in @($script:CommonScript, $script:CleanupScript, $script:OptimizeScript, $script:RepairScript, $script:ScheduleScript)) {
    if (-not (Test-Path -LiteralPath $s)) {
        Show-WsMessage -Text "Engine not found:`n$s`n`nKeep WinSenior.Gui.ps1 next to the engine scripts." -Title 'Windows Senior' -Buttons 'OK' -Icon 'Error' | Out-Null
        exit 1
    }
}

. $script:CommonScript

# One command-line argument, quoted by the Windows (CommandLineToArgvW) rules, so
# paths with spaces, quotes or a trailing backslash survive the trip.
function ConvertTo-WsCmdArg {
    param([string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Which host are we? Children run on the same one so behaviour matches.
function Get-WsHostExe {
    $exe = $null
    try { $exe = (Get-Process -Id $PID -ErrorAction Stop).Path } catch { $exe = $null }
    if (-not $exe -or ((Split-Path $exe -Leaf) -notmatch '^(pwsh|powershell)\.exe$')) {
        $exe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    }
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
    $exe
}
$script:HostExe = Get-WsHostExe

if ($env:WINSENIOR_NOELEVATE) { $NoElevate = [switch]$true }
if (-not (Test-AdminPrivileges) -and -not $NoElevate) {
    $elevateError = $null
    try {
        $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', (ConvertTo-WsCmdArg $PSCommandPath)) -join ' '
        Start-Process -FilePath $script:HostExe -Verb RunAs -WindowStyle Hidden -ArgumentList $relaunch -ErrorAction Stop
    }
    catch { $elevateError = Get-WsErrorText $_ }
    if (-not $elevateError) { exit 0 }
    $answer = Show-WsMessage -Text ("Windows Senior needs administrator rights to clean system folders, apply tweaks and run repairs.`n`n" +
        "The administrator (UAC) prompt was cancelled or failed:`n$elevateError`n`n" +
        "Start anyway with limited rights? Most actions will fail until you restart it as administrator.") -Title 'Administrator rights required' -Buttons 'YesNo' -Icon 'Warning'
    if ($answer -ne 'Yes') { exit 1 }
}

# One window at a time: two instances would race on the same engines and settings.
$script:Mutex = $null
foreach ($mutexName in 'Global\WinSeniorGui', 'Local\WinSeniorGui') {
    try { $script:Mutex = New-Object System.Threading.Mutex($false, $mutexName); break } catch { $script:Mutex = $null }
}
if ($script:Mutex) {
    $owned = $false
    try { $owned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        Show-WsMessage -Text 'Windows Senior is already running. Switch to the open window (check the taskbar).' -Title 'Windows Senior' -Buttons 'OK' -Icon 'Information' | Out-Null
        exit 0
    }
}

# Hide the console window that hosts us (when launched from a console).
try {
    if (-not ('WinSenior.ConsoleWin' -as [type])) {
        Add-Type -Namespace WinSenior -Name ConsoleWin -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
    }
    $h = [WinSenior.ConsoleWin]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) { [void][WinSenior.ConsoleWin]::ShowWindow($h, 0) }
} catch { Write-Verbose 'console stays visible' }

# Load the engines as libraries: registries, applied-state checks, selection defaults.
. $script:CleanupScript
. $script:OptimizeScript
. $script:RepairScript
. $script:ScheduleScript
$script:HasStartup = Test-Path -LiteralPath $script:StartupScript
if ($script:HasStartup) { . $script:StartupScript }

# =====================================================================
# ROW MODEL (INotifyPropertyChanged so the grids update live)
# =====================================================================
if (-not ('WinSenior.Row' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace WinSenior {
    public class Row : INotifyPropertyChanged {
        string _id="", _name="", _group="", _risk="", _size="", _state="", _detail="", _explain="", _tip="", _info="";
        bool _selected, _enabled = true; long _bytes; int _rank;
        public event PropertyChangedEventHandler PropertyChanged;
        void On(string n){ var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
        static string S(string v){ return v ?? ""; }
        // Setters only notify on a real change, so "Select all" stays cheap.
        public string Id      { get { return _id; }      set { if (_id == S(value)) return; _id = S(value); On("Id"); } }
        public string Name    { get { return _name; }    set { if (_name == S(value)) return; _name = S(value); On("Name"); } }
        public string Group   { get { return _group; }   set { if (_group == S(value)) return; _group = S(value); On("Group"); } }
        public string Risk    { get { return _risk; }    set { if (_risk == S(value)) return; _risk = S(value); On("Risk"); } }
        public string Size    { get { return _size; }    set { if (_size == S(value)) return; _size = S(value); On("Size"); } }
        public string State   { get { return _state; }   set { if (_state == S(value)) return; _state = S(value); On("State"); } }
        public string Detail  { get { return _detail; }  set { if (_detail == S(value)) return; _detail = S(value); On("Detail"); } }
        public string Explain { get { return _explain; } set { if (_explain == S(value)) return; _explain = S(value); On("Explain"); } }
        public string Tip     { get { return _tip; }     set { if (_tip == S(value)) return; _tip = S(value); On("Tip"); } }
        public string Info    { get { return _info; }    set { if (_info == S(value)) return; _info = S(value); On("Info"); } }
        public bool   Selected{ get { return _selected; }set { if (_selected == value) return; _selected = value; On("Selected"); } }
        public bool   Enabled { get { return _enabled; } set { if (_enabled == value) return; _enabled = value; On("Enabled"); } }
        public long   Bytes   { get { return _bytes; }   set { if (_bytes == value) return; _bytes = value; On("Bytes"); } }
        public int    Rank    { get { return _rank; }    set { if (_rank == value) return; _rank = value; On("Rank"); } }
    }
}
'@
}

$script:RiskRank = @{ Safe = 0; Moderate = 1; Aggressive = 2; Dangerous = 3 }

# =====================================================================
# SETTINGS (persisted selections & options)
# =====================================================================
$script:SettingsDir = Join-Path $env:ProgramData 'WinSenior'
if ($env:WINSENIOR_GUI_DATADIR) {
    $script:SettingsDir = $env:WINSENIOR_GUI_DATADIR
}
else {
    try {
        if (-not (Test-Path $script:SettingsDir)) { New-Item -ItemType Directory -Path $script:SettingsDir -Force -ErrorAction Stop | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $script:SettingsDir '.write-test'), 'ok'); Remove-Item (Join-Path $script:SettingsDir '.write-test') -Force
    } catch {
        # Not writable (running without admin via -NoElevate): keep settings per user instead.
        $script:SettingsDir = Join-Path $env:LOCALAPPDATA 'WinSenior'
    }
}
$script:SettingsFile = Join-Path $script:SettingsDir 'gui-settings.json'
$script:LogDir       = Join-Path $script:SettingsDir 'logs'
$script:ReportDir    = Join-Path $script:SettingsDir 'reports'
foreach ($d in $script:SettingsDir, $script:LogDir, $script:ReportDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
# Scheduled tasks always write here; read it too when our own dir is elsewhere.
$script:ReportDirs = @($script:ReportDir)
$sharedReports = Join-Path $env:ProgramData 'WinSenior\reports'
if (-not $env:WINSENIOR_GUI_DATADIR -and $sharedReports -ne $script:ReportDir) { $script:ReportDirs += $sharedReports }

# Keep the capture logs from piling up forever.
Get-ChildItem -LiteralPath $script:LogDir -Filter 'gui-*.out.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 40 |
    Remove-Item -Force -ErrorAction SilentlyContinue

function Get-GuiSettings {
    $def = [ordered]@{
        CleanOn = $null; OptOn = $null
        CurrentUserOnly = $false; RestorePoint = $true; DeferLocked = $true
        SkipOptimization = $false; MaxAgeDays = 0
        CloseApps = $true; Conservative = $false; Drives = $null; OptRestorePoint = $true
    }
    if (Test-Path $script:SettingsFile) {
        try {
            $j = Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $def[$p.Name] = $p.Value }
        } catch { Write-Verbose 'settings unreadable - using defaults' }
    }
    $def
}

# Returns the day count, or $null when the box holds something that is not 0..3650.
function Get-WsMaxAge {
    param([string]$Text)
    $n = 0
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    if (-not [int]::TryParse($Text.Trim(), [ref]$n)) { return $null }
    if ($n -lt 0 -or $n -gt 3650) { return $null }
    $n
}

function Save-GuiSettings {
    if (-not $script:CleanRows -or -not $script:OptRows) { return }
    try {
        $age = Get-WsMaxAge $W.TxtMaxAge.Text
        if ($null -eq $age) { $age = [int]$script:Settings.MaxAgeDays }
        $drives = $null
        if ($script:DriveChecks.Count -and @($script:DriveChecks | Where-Object { -not $_.IsChecked }).Count) {
            $drives = [string[]]@($script:DriveChecks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
        }
        # Explicit arrays (even empty ones) so "nothing ticked" is remembered too.
        $o = [ordered]@{
            CleanOn          = [string[]]@($script:CleanRows | Where-Object Selected | ForEach-Object Id)
            OptOn            = [string[]]@($script:OptRows   | Where-Object Selected | ForEach-Object Id)
            CurrentUserOnly  = [bool]$W.ChkCurrentUser.IsChecked
            RestorePoint     = [bool]$W.ChkRestore.IsChecked
            DeferLocked      = [bool]$W.ChkDefer.IsChecked
            SkipOptimization = [bool]$W.ChkSkipOpt.IsChecked
            MaxAgeDays       = [int]$age
            CloseApps        = [bool]$W.ChkCloseApps.IsChecked
            Conservative     = [bool]$W.ChkConservative.IsChecked
            Drives           = $drives
            OptRestorePoint  = [bool]$W.ChkOptRestore.IsChecked
        }
        ($o | ConvertTo-Json -Depth 4) | Set-Content -Path $script:SettingsFile -Encoding UTF8
    } catch { Write-Verbose "settings not saved: $($_.Exception.Message)" }
}

# =====================================================================
# PURE HELPERS (no UI access - unit-tested from tests\WinSenior.Gui.Tests.ps1)
# =====================================================================
# -Include / -Exclude for an engine. Empty lists are omitted, never sent as ''.
function Get-WsSelectionArg {
    param([string[]]$AllIds, [string[]]$OnIds)
    $on  = @($AllIds | Where-Object { $OnIds -contains $_ })
    $off = @($AllIds | Where-Object { $OnIds -notcontains $_ })
    $a = @()
    if ($on.Count)  { $a += @('-Include', ($on -join ',')) }
    if ($off.Count) { $a += @('-Exclude', ($off -join ',')) }
    $a
}

# Split decoded child output into complete lines; the unfinished tail is carried
# over to the next read instead of being printed as a broken line.
function Split-WsLogChunk {
    param([string]$Pending, [string]$Chunk)
    $all = ([string]$Pending + [string]$Chunk).Replace([string][char]0xFEFF, '')
    $idx = $all.LastIndexOf("`n")
    if ($idx -lt 0) { return [pscustomobject]@{ Lines = @(); Rest = $all } }
    $lines = @($all.Substring(0, $idx) -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    [pscustomobject]@{ Lines = $lines; Rest = $all.Substring($idx + 1) }
}

# ShouldProcess preview lines are localized ("What if:", "WhatIf:", ...) - match the
# engines' own operation text instead, which never changes with the UI language.
$script:WhatIfPattern = '^[^"]*"(?<op>Remove \((?<d>[^"]*)\)|Apply tweak \[[^"\]]*\]|Revert tweak|Fix: [^"]*|Enable startup entry|Disable startup entry)"[^"]*"(?<t>.*)"\s*\.?\s*$'

function Format-WsEngineLine {
    param([string]$Line)
    $l = $Line -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', ''
    $m = [regex]::Match($l, $script:WhatIfPattern)
    if ($m.Success) {
        $op = $m.Groups['op'].Value
        if ($op.StartsWith('Remove (')) { return ('  [WhatIf] ' + $m.Groups['t'].Value) }
        return ('  [WhatIf] ' + $op + ': ' + $m.Groups['t'].Value)
    }
    $l
}

# Name of the task / tweak a line starts or finishes, or $null. Cleanup announces
# each task with a '==>' step line; Optimize prints the tweak name when applied
# (or its WhatIf preview).
function Get-WsStepName {
    param([string]$Line, [string[]]$Names)
    $l = $Line -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', ''
    $m = [regex]::Match($l, '^==> (?<n>.+?)\s{2,}\[[^\]/]+/[^\]]+\]\s*$')
    if ($m.Success) { return $m.Groups['n'].Value }
    $m = [regex]::Match($l, '"Apply tweak \[[^"\]]*\]"[^"]*"(?<n>[^"]+)"')
    if ($m.Success) { return $m.Groups['n'].Value }
    if ($Names) {
        $m = [regex]::Match($l, '^\[\+\] (?<n>.+?)\s*$')
        if ($m.Success -and ($Names -contains $m.Groups['n'].Value)) { return $m.Groups['n'].Value }
        $m = [regex]::Match($l, '^\[x\]\s+(?<n>.+?): ')
        if ($m.Success -and ($Names -contains $m.Groups['n'].Value)) { return $m.Groups['n'].Value }
    }
    $null
}

function ConvertTo-WsDate {
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    $d = [datetime]::MinValue
    if ($Value -and [datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$d)) { return $d }
    $null
}

# One History row from a parsed engine report.
function Get-WsHistoryEntry {
    param([Parameter(Mandatory)]$Report, [string]$Path, [datetime]$FileTime = (Get-Date))
    $date = ConvertTo-WsDate $Report.Timestamp
    if (-not $date) { $date = $FileTime }
    $s = $Report.Summary
    $dry = ($Report.Mode -eq 'DryRun')
    $items = @($Report.Items)
    $bytes = [int64]0; $errors = 0; $result = ''
    switch ([string]$Report.Engine) {
        'Cleanup' {
            $b = [int64]0; if ($s -and $null -ne $s.TotalBytes) { $b = [int64]$s.TotalBytes }
            $freed = if ($s -and $s.TotalFreed) { [string]$s.TotalFreed } else { Format-FileSize $b }
            $result = if ($dry) { "Would free $freed" } else { "Freed $freed" }
            if ($s -and $null -ne $s.TotalFiles) { $result += " ($($s.TotalFiles) items)" }
            if (-not $dry) { $bytes = $b }
            if ($s -and $null -ne $s.TotalErrors) { $errors = [int]$s.TotalErrors }
        }
        'Optimize' {
            if ($dry) { $result = "Would apply {0} tweak(s)" -f @($items | Where-Object { $_.Result -eq 'would-apply' }).Count }
            else {
                $result = "Applied {0}, skipped {1}" -f [int]$s.Applied, [int]$s.Skipped
            }
            if ($s -and $null -ne $s.Errors) { $errors = [int]$s.Errors }
        }
        'Repair' {
            $fail = @($items | Where-Object { $_.Status -eq 'Fail' }).Count
            $warn = @($items | Where-Object { $_.Status -eq 'Warn' }).Count
            $result = "{0} failing, {1} warning" -f $fail, $warn
            if ($s -and [int]$s.Fixed -gt 0) { $result += ", fixed $([int]$s.Fixed)" }
            if ($s -and $s.Reboot) { $result += ' (reboot needed)' }
            if ($s -and $null -ne $s.FixErrors) { $errors = [int]$s.FixErrors }
        }
        default { $result = '' }
    }
    $leaf = if ($Path) { Split-Path $Path -Leaf } else { '' }
    [pscustomobject]@{
        Date   = $date
        Engine = [string]$Report.Engine
        Mode   = $(if ($dry) { 'Dry run' } else { 'Live' })
        Result = $result
        Errors = $errors
        Bytes  = $bytes
        Source = $(if ($leaf -match '^(cleanup|repair)(-\d{8}-\d{6})?\.json$') { 'Scheduled' } else { 'App' })
        Path   = $Path
    }
}

# Self-contained HTML page for one engine report (no scripts, no external files).
function ConvertTo-WsReportHtml {
    param([Parameter(Mandatory)]$Report, [string]$SourcePath)
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }
    $cell = {
        param($v)
        if ($null -eq $v) { return '' }
        if ($v -is [string] -or $v -is [ValueType]) { return (& $enc $v) }
        & $enc (($v | ConvertTo-Json -Depth 3 -Compress))
    }
    $sb = New-Object System.Text.StringBuilder
    $title = "WinSenior {0} report - {1}" -f $Report.Engine, $Report.Timestamp
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine("<title>$(& $enc $title)</title>")
    [void]$sb.AppendLine('<style>body{font-family:"Segoe UI",Arial,sans-serif;margin:24px;color:#1d1f24;background:#fff}' +
        'h1{font-size:22px;margin:0 0 4px}p.sub{color:#666;margin:0 0 18px}' +
        'table{border-collapse:collapse;margin:0 0 22px;font-size:13px;min-width:420px}' +
        'th,td{border:1px solid #d7d9de;padding:5px 9px;text-align:left;vertical-align:top}' +
        'th{background:#eef0f4}tr:nth-child(even) td{background:#fafbfc}td.num{text-align:right}' +
        'h2{font-size:16px;margin:18px 0 8px}</style></head><body>')
    [void]$sb.AppendLine("<h1>$(& $enc $title)</h1>")
    $sub = "Host {0} - WinSenior {1} - mode {2}" -f $Report.Host, $Report.Version, $Report.Mode
    if ($SourcePath) { $sub += " - source $SourcePath" }
    [void]$sb.AppendLine("<p class=`"sub`">$(& $enc $sub)</p>")

    [void]$sb.AppendLine('<h2>Summary</h2><table><tbody>')
    $top = [ordered]@{ Engine = $Report.Engine; Mode = $Report.Mode; Timestamp = $Report.Timestamp
                       'Duration (s)' = $Report.DurationSec; 'Restore point' = $Report.RestorePoint }
    foreach ($k in $top.Keys) { [void]$sb.AppendLine("<tr><th>$(& $enc $k)</th><td>$(& $cell $top[$k])</td></tr>") }
    if ($Report.Summary) {
        foreach ($p in $Report.Summary.PSObject.Properties) {
            [void]$sb.AppendLine("<tr><th>$(& $enc $p.Name)</th><td>$(& $cell $p.Value)</td></tr>")
        }
    }
    [void]$sb.AppendLine('</tbody></table>')

    $items = @($Report.Items | Where-Object { $null -ne $_ })
    [void]$sb.AppendLine("<h2>Items ($($items.Count))</h2>")
    if ($items.Count) {
        $cols = New-Object System.Collections.Generic.List[string]
        foreach ($it in ($items | Select-Object -First 50)) {
            foreach ($p in $it.PSObject.Properties) { if (-not $cols.Contains($p.Name)) { $cols.Add($p.Name) } }
        }
        [void]$sb.Append('<table><thead><tr>')
        foreach ($c in $cols) { [void]$sb.Append("<th>$(& $enc $c)</th>") }
        [void]$sb.AppendLine('</tr></thead><tbody>')
        foreach ($it in $items) {
            [void]$sb.Append('<tr>')
            foreach ($c in $cols) {
                $v = $it.$c
                if ($c -eq 'Bytes' -and $null -ne $v) {
                    [void]$sb.Append("<td class=`"num`">$(& $enc (Format-FileSize ([int64]$v)))</td>")
                }
                else { [void]$sb.Append("<td>$(& $cell $v)</td>") }
            }
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    [void]$sb.AppendLine('</body></html>')
    $sb.ToString()
}

# =====================================================================
# XAML
# =====================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Senior" Width="1200" Height="800" MinWidth="940" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#1B1C20" FontFamily="Segoe UI" FontSize="13"
        Foreground="#E8E8EA" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Panel"  Color="#24252B"/>
    <SolidColorBrush x:Key="Panel2" Color="#2C2D34"/>
    <SolidColorBrush x:Key="Line"   Color="#3A3B44"/>
    <SolidColorBrush x:Key="Accent" Color="#5B8DEF"/>
    <SolidColorBrush x:Key="Muted"  Color="#9DA2AC"/>
    <SolidColorBrush x:Key="Text"   Color="#E8E8EA"/>

    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#383943"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#7A2E2E"/>
      <Setter Property="BorderBrush" Value="#A33"/>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Padding="16,10" Margin="8,2" CornerRadius="6" Background="Transparent">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="#2E3E63"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#2C2D34"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,14,0"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="CaretBrush" Value="White"/>
    </Style>
    <!-- Search box: shows its Tag as a hint while empty. -->
    <Style x:Key="FilterBox" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="Width" Value="340"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5">
              <Grid>
                <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                <TextBlock x:Name="Hint" Text="{TemplateBinding Tag}" Foreground="#6D717A" Margin="9,0,0,0"
                           VerticalAlignment="Center" IsHitTestVisible="False" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value=""><Setter TargetName="Hint" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="MaxWidth" Value="620"/>
      <Setter Property="Background" Value="#2C2D34"/>
      <Setter Property="Foreground" Value="#E8E8EA"/>
      <Setter Property="BorderBrush" Value="#4A4B55"/>
      <Setter Property="Padding" Value="9,7"/>
      <Setter Property="ContentTemplate">
        <Setter.Value>
          <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap"/></DataTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListView">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Padding" Value="4,3"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="ToolTip" Value="{Binding Tip}"/>
      <Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="ToolTipService.InitialShowDelay" Value="450"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Tip}" Value=""><Setter Property="ToolTip" Value="{x:Null}"/></DataTrigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#2E3E63"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#2C2D34"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Padding" Value="10"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="Margin" Value="0,0,0,12"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7E838D"/><Setter Property="FontSize" Value="12"/><Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <DataTemplate x:Key="RiskCell">
      <Border CornerRadius="4" Padding="6,1" HorizontalAlignment="Left">
        <Border.Style>
          <Style TargetType="Border">
            <Setter Property="Background" Value="#3A3B44"/>
            <Style.Triggers>
              <DataTrigger Binding="{Binding Risk}" Value="Safe"><Setter Property="Background" Value="#1F5A3A"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Moderate"><Setter Property="Background" Value="#6A5314"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Aggressive"><Setter Property="Background" Value="#7A3E12"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Dangerous"><Setter Property="Background" Value="#7A2323"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value=""><Setter Property="Background" Value="Transparent"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </Border.Style>
        <TextBlock Text="{Binding Risk}" FontSize="11" Foreground="White"/>
      </Border>
    </DataTemplate>
    <DataTemplate x:Key="StateCell">
      <TextBlock Text="{Binding State}" FontWeight="SemiBold">
        <TextBlock.Style>
          <Style TargetType="TextBlock">
            <Style.Triggers>
              <DataTrigger Binding="{Binding State}" Value="OK"><Setter Property="Foreground" Value="#3DDC84"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="Warn"><Setter Property="Foreground" Value="#F5B942"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="Fail"><Setter Property="Foreground" Value="#FF5C5C"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="applied"><Setter Property="Foreground" Value="#3DDC84"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="not applied"><Setter Property="Foreground" Value="#9DA2AC"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="Enabled"><Setter Property="Foreground" Value="#3DDC84"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="Disabled"><Setter Property="Foreground" Value="#9DA2AC"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="undone"><Setter Property="Foreground" Value="#9DA2AC"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="active"><Setter Property="Foreground" Value="#3DDC84"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </TextBlock.Style>
      </TextBlock>
    </DataTemplate>
    <DataTemplate x:Key="CheckCell">
      <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding Enabled}" Margin="0"/>
    </DataTemplate>
  </Window.Resources>

  <Grid Background="#1B1C20">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="210"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- SIDEBAR -->
    <Border Grid.Column="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="20,22,20,18">
          <TextBlock Text="Windows Senior" FontSize="18" FontWeight="Bold"/>
          <TextBlock x:Name="LblVersion" Text="v" Foreground="{StaticResource Muted}" FontSize="11"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="20,0,20,18">
          <TextBlock x:Name="LblAdmin" Text="" FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
          <TextBlock x:Name="LblHost" Text="" FontSize="11" Foreground="{StaticResource Muted}"/>
        </StackPanel>
        <StackPanel>
          <RadioButton x:Name="NavClean"    Style="{StaticResource Nav}" Content="Disk cleanup" IsChecked="True"/>
          <RadioButton x:Name="NavOpt"      Style="{StaticResource Nav}" Content="Optimize"/>
          <RadioButton x:Name="NavRepair"   Style="{StaticResource Nav}" Content="Troubleshoot"/>
          <RadioButton x:Name="NavStartup"  Style="{StaticResource Nav}" Content="Startup apps"/>
          <RadioButton x:Name="NavHistory"  Style="{StaticResource Nav}" Content="History"/>
          <RadioButton x:Name="NavUndo"     Style="{StaticResource Nav}" Content="Undo &amp; restore"/>
          <RadioButton x:Name="NavSchedule" Style="{StaticResource Nav}" Content="Schedule"/>
          <RadioButton x:Name="NavAbout"    Style="{StaticResource Nav}" Content="About"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- MAIN -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*" MinHeight="200"/>
        <RowDefinition Height="6"/>
        <RowDefinition x:Name="LogRow" Height="200" MinHeight="90"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="22,18,22,8">
        <!-- CLEANUP -->
        <DockPanel x:Name="PageClean">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Disk cleanup"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Scan measures what each task would free (nothing is deleted). Clean removes the checked tasks. Dangerous tasks are irreversible and must be checked by hand."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <Button x:Name="BtnScan"  Content="Scan (dry run)"/>
            <Button x:Name="BtnClean" Content="Clean now" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnCleanAll"  Content="Select all" Padding="10,7"/>
            <Button x:Name="BtnCleanSafe" Content="Safe only" Padding="10,7"/>
            <Button x:Name="BtnCleanDef"  Content="Defaults" Padding="10,7"/>
            <Button x:Name="BtnCleanNone" Content="None" Padding="10,7"/>
          </WrapPanel>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,6">
            <CheckBox x:Name="ChkCurrentUser" Content="Current user only"/>
            <CheckBox x:Name="ChkRestore" Content="Restore point first" IsChecked="True"/>
            <CheckBox x:Name="ChkDefer" Content="Delete locked files at reboot" IsChecked="True"/>
            <CheckBox x:Name="ChkCloseApps" Content="Close running browsers first" IsChecked="True"
                      ToolTip="Closes browsers in this session before their cache tasks. Unticked: caches of running browsers are skipped."/>
            <CheckBox x:Name="ChkSkipOpt" Content="Skip SFC / DISM (slow)"/>
            <CheckBox x:Name="ChkConservative" Content="Conservative (Safe + Moderate only)"
                      ToolTip="Never run Aggressive or Dangerous tasks, even when they are ticked."/>
          </WrapPanel>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <TextBlock Text="Only files older than" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,0,6,0"/>
            <TextBox x:Name="TxtMaxAge" Width="46" Text="0" ToolTip="0 = no age filter. Whole days, 0 to 3650."/>
            <TextBlock Text="days" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="6,0,22,0"/>
            <TextBlock Text="Drives:" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,0,8,0"/>
            <WrapPanel x:Name="PanelDrives" VerticalAlignment="Center"/>
          </WrapPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <TextBlock DockPanel.Dock="Right" Style="{StaticResource Hint}" Text="Hover a task for its paths - click a column header to sort"/>
            <TextBox x:Name="TxtCleanFilter" Style="{StaticResource FilterBox}" Tag="Filter by name, id or category"/>
          </DockPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblCleanStatus" Margin="0,8,0,0" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
          <ListView x:Name="LvClean">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Task" Width="420" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Category" Width="100" DisplayMemberBinding="{Binding Group}"/>
                <GridViewColumn Header="Risk" Width="96" CellTemplate="{StaticResource RiskCell}"/>
                <GridViewColumn Header="Would free" Width="130" DisplayMemberBinding="{Binding Size}"/>
                <GridViewColumn Header="Id" Width="140" DisplayMemberBinding="{Binding Id}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- OPTIMIZE -->
        <DockPanel x:Name="PageOpt" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Optimize Windows"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Performance, privacy, debloat and network tweaks. Every applied tweak is backed up first and can be reverted from Undo &amp; restore."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="BtnOptPreview" Content="Preview"/>
            <Button x:Name="BtnOptApply"   Content="Apply tweaks" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnOptRefresh" Content="Refresh state" Padding="10,7"/>
            <Button x:Name="BtnOptAll"  Content="Select all" Padding="10,7"/>
            <Button x:Name="BtnOptDef"  Content="Defaults" Padding="10,7"/>
            <Button x:Name="BtnOptNone" Content="None" Padding="10,7"/>
            <CheckBox x:Name="ChkOptRestore" Content="Restore point first" IsChecked="True" Margin="10,0,0,0"/>
          </WrapPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <TextBlock DockPanel.Dock="Right" Style="{StaticResource Hint}" Text="Hover a tweak for what it changes"/>
            <TextBox x:Name="TxtOptFilter" Style="{StaticResource FilterBox}" Tag="Filter by name, id or area"/>
          </DockPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblOptStatus" Margin="0,8,0,0" Foreground="{StaticResource Muted}"/>
          <ListView x:Name="LvOpt">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Tweak" Width="400" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Area" Width="100" DisplayMemberBinding="{Binding Group}"/>
                <GridViewColumn Header="Risk" Width="96" CellTemplate="{StaticResource RiskCell}"/>
                <GridViewColumn Header="State" Width="100" CellTemplate="{StaticResource StateCell}"/>
                <GridViewColumn Header="Id" Width="160" DisplayMemberBinding="{Binding Id}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- TROUBLESHOOT -->
        <DockPanel x:Name="PageRepair" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Troubleshoot"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Scan is read-only. Afterwards tick the problems you want repaired and press Fix. Heavy repairs (SFC, DISM, Windows Update reset, network stack) may need a reboot."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="BtnRepScan" Content="Scan" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnRepFix"  Content="Fix selected" IsEnabled="False"/>
            <Button x:Name="BtnRepFixAll" Content="Auto-fix everything (incl. heavy)" IsEnabled="False"/>
          </WrapPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <TextBlock DockPanel.Dock="Right" Style="{StaticResource Hint}" Text="Hover a check for its fix"/>
            <TextBox x:Name="TxtRepFilter" Style="{StaticResource FilterBox}" Tag="Filter by name, id or category"/>
          </DockPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblRepStatus" Margin="0,8,0,0" Foreground="{StaticResource Muted}"/>
          <ListView x:Name="LvRep">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Check" Width="260" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Category" Width="90" DisplayMemberBinding="{Binding Group}"/>
                <GridViewColumn Header="Status" Width="70" CellTemplate="{StaticResource StateCell}"/>
                <GridViewColumn Header="Detail" Width="330" DisplayMemberBinding="{Binding Detail}"/>
                <GridViewColumn Header="Fix" Width="96" CellTemplate="{StaticResource RiskCell}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- STARTUP APPS -->
        <DockPanel x:Name="PageStartup" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Startup apps"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Programs that start with Windows. Untick to disable an entry the same way Task Manager does - the entry itself is kept, so ticking it again restores it exactly."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="BtnStartupRefresh" Content="Refresh" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnStartupOpen" Content="Open file location"/>
            <Button x:Name="BtnStartupTaskMgr" Content="Open Task Manager" Padding="10,7"/>
          </WrapPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <TextBlock DockPanel.Dock="Right" Style="{StaticResource Hint}" Text="Hover an entry for its full command"/>
            <TextBox x:Name="TxtStartupFilter" Style="{StaticResource FilterBox}" Tag="Filter by name, command or location"/>
          </DockPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblStartupStatus" Margin="0,8,0,0" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
          <ListView x:Name="LvStartup">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Name" Width="220" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Status" Width="80" CellTemplate="{StaticResource StateCell}"/>
                <GridViewColumn Header="Scope" Width="100" DisplayMemberBinding="{Binding Group}"/>
                <GridViewColumn Header="Location" Width="160" DisplayMemberBinding="{Binding Detail}"/>
                <GridViewColumn Header="Command" Width="420" DisplayMemberBinding="{Binding Info}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- HISTORY -->
        <DockPanel x:Name="PageHistory" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="History"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Every run's JSON report - from this app and from the scheduled tasks. Open one, or export it as a self-contained HTML page."/>
          <Border DockPanel.Dock="Top" Background="{StaticResource Panel2}" CornerRadius="8" Padding="16,10" Margin="0,0,0,10" HorizontalAlignment="Left">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Total freed all time" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,14,0"/>
              <TextBlock x:Name="LblHistTotal" Text="0 B" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="LblHistCounts" Text="" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="18,0,0,0"/>
            </StackPanel>
          </Border>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="BtnHistRefresh" Content="Refresh" Padding="10,7"/>
            <Button x:Name="BtnHistOpen" Content="Open report"/>
            <Button x:Name="BtnHistHtml" Content="Export HTML" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnHistFolder" Content="Open folder" Padding="10,7"/>
          </WrapPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblHistStatus" Margin="0,8,0,0" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
          <ListView x:Name="LvHistory">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Date" Width="140" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Engine" Width="90" DisplayMemberBinding="{Binding Group}"/>
                <GridViewColumn Header="Mode" Width="80" DisplayMemberBinding="{Binding Detail}"/>
                <GridViewColumn Header="Result" Width="340" DisplayMemberBinding="{Binding Size}"/>
                <GridViewColumn Header="Errors" Width="70" DisplayMemberBinding="{Binding State}"/>
                <GridViewColumn Header="Source" Width="90" DisplayMemberBinding="{Binding Info}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- UNDO / RESTORE -->
        <ScrollViewer x:Name="PageUndo" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,8,0">
            <TextBlock Style="{StaticResource H1}" Text="Undo &amp; restore"/>
            <TextBlock Style="{StaticResource Sub}" Text="Safety nets: revert an optimization run from its backup manifest, or create a System Restore point right now."/>
            <GroupBox Header="Optimization backups">
              <StackPanel>
                <ListView x:Name="LvBackups" Height="180">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="Backup manifest" Width="330" DisplayMemberBinding="{Binding Name}"/>
                      <GridViewColumn Header="Created" Width="150" DisplayMemberBinding="{Binding Detail}"/>
                      <GridViewColumn Header="Tweaks" Width="70" DisplayMemberBinding="{Binding Size}"/>
                      <GridViewColumn Header="Status" Width="200" CellTemplate="{StaticResource StateCell}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
                <WrapPanel Margin="0,10,0,0">
                  <Button x:Name="BtnUndoLast" Content="Undo newest run" Style="{StaticResource Primary}"/>
                  <Button x:Name="BtnUndoSel"  Content="Undo selected manifest"/>
                  <Button x:Name="BtnBackupsRefresh" Content="Refresh" Padding="10,7"/>
                  <Button x:Name="BtnOpenBackups" Content="Open folder" Padding="10,7"/>
                </WrapPanel>
              </StackPanel>
            </GroupBox>
            <GroupBox Header="System Restore">
              <WrapPanel>
                <Button x:Name="BtnRestorePoint" Content="Create restore point now"/>
                <Button x:Name="BtnOpenRstrui" Content="Open System Restore (rstrui)"/>
              </WrapPanel>
            </GroupBox>
            <GroupBox Header="Logs &amp; reports">
              <WrapPanel>
                <Button x:Name="BtnOpenLogs" Content="Open log folder"/>
                <Button x:Name="BtnOpenTemp" Content="Open engine logs (%TEMP%)"/>
              </WrapPanel>
            </GroupBox>
          </StackPanel>
        </ScrollViewer>

        <!-- SCHEDULE -->
        <ScrollViewer x:Name="PageSchedule" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,8,0">
            <TextBlock Style="{StaticResource H1}" Text="Schedule"/>
            <TextBlock Style="{StaticResource Sub}" Text="Register recurring maintenance in Task Scheduler (weekly cleanup + monthly health check). Runs as SYSTEM, unattended, no restore point, no Dangerous tier."/>
            <TextBlock x:Name="LblSchedInfo" Margin="0,0,0,12" TextWrapping="Wrap" Foreground="{StaticResource Muted}"/>
            <TextBlock x:Name="LblSchedule" Margin="0,0,0,12" TextWrapping="Wrap"/>
            <WrapPanel>
              <Button x:Name="BtnSchedInstall" Content="Install scheduled tasks" Style="{StaticResource Primary}"/>
              <Button x:Name="BtnSchedRemove"  Content="Remove scheduled tasks"/>
              <Button x:Name="BtnSchedRefresh" Content="Refresh" Padding="10,7"/>
              <Button x:Name="BtnSchedOpen" Content="Open Task Scheduler" Padding="10,7"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- ABOUT -->
        <ScrollViewer x:Name="PageAbout" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,8,0">
            <TextBlock Style="{StaticResource H1}" Text="About"/>
            <TextBlock x:Name="LblAbout" TextWrapping="Wrap" Foreground="{StaticResource Muted}" LineHeight="20"/>
            <WrapPanel Margin="0,14,0,0">
              <Button x:Name="BtnOpenRepo" Content="GitHub repository"/>
              <Button x:Name="BtnOpenConsole" Content="Open console menu (WinSenior.ps1)"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <GridSplitter Grid.Row="1" Height="6" HorizontalAlignment="Stretch" Background="{StaticResource Line}" ResizeBehavior="PreviousAndNext"/>

      <!-- LOG -->
      <DockPanel Grid.Row="2" Margin="22,6,22,14">
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <Button x:Name="BtnCancel" Content="Cancel" Style="{StaticResource Danger}" IsEnabled="False" Padding="10,5"/>
            <Button x:Name="BtnLogSave"  Content="Save log" Padding="10,5"/>
            <Button x:Name="BtnLogClear" Content="Clear" Padding="10,5" Margin="0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Log" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <ProgressBar x:Name="Prog" Width="200" Height="8" Minimum="0" Maximum="100" Visibility="Hidden" IsIndeterminate="True"
                         Foreground="{StaticResource Accent}" Background="{StaticResource Panel2}" BorderThickness="0"/>
            <TextBlock x:Name="LblStatus" Text="Ready." VerticalAlignment="Center" Margin="12,0,0,0" Foreground="{StaticResource Muted}"/>
          </StackPanel>
        </DockPanel>
        <TextBox x:Name="TxtLog" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="12" Background="#131417" Foreground="#D6D6DA"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" AcceptsReturn="True"/>
      </DockPanel>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$Win = [System.Windows.Markup.XamlReader]::Load($reader)
$script:Win = $Win

# Every x:Name'd element becomes $W.<Name>
$W = @{}
([xml]$xaml).SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($n) { $W[$n] = $Win.FindName($n) }
}

# Safety net: an exception inside any event handler must not kill the window
# (the console is hidden, so the app would just vanish). Log it and carry on.
$Win.Dispatcher.Add_UnhandledException({
    $e = $args[1]
    $e.Handled = $true
    $file = Write-CrashLog $e.Exception 'UI event'
    try {
        Add-Log ("[x] Unexpected error: {0}   (details: {1})" -f (Get-WsErrorText $e.Exception), $file)
        Set-Status 'An unexpected error occurred - see the log.'
    } catch { Write-Verbose 'log panel unavailable' }
})

# =====================================================================
# LOG + STATUS
# =====================================================================
$script:LogChars = 0
$script:LogLimit = 3000000

function Write-LogText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $W.TxtLog.AppendText($Text)
    $script:LogChars += $Text.Length
    if ($script:LogChars -gt $script:LogLimit) {
        # A huge TextBox gets sluggish; keep the tail. The full capture stays on disk.
        $all = $W.TxtLog.Text
        $keep = $all.Substring([Math]::Max(0, $all.Length - [int]($script:LogLimit / 3)))
        $note = "[... earlier output trimmed - full engine output is in $script:LogDir ...]`r`n"
        $W.TxtLog.Text = $note + $keep
        $script:LogChars = $W.TxtLog.Text.Length
    }
    $W.TxtLog.ScrollToEnd()
}

function Add-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    if (-not $Text.EndsWith("`n")) { $Text += "`r`n" }
    Write-LogText $Text
}
function Set-Status { param([string]$Text) $W.LblStatus.Text = $Text }

$script:BusyButtons = @('BtnScan', 'BtnClean', 'BtnOptPreview', 'BtnOptApply', 'BtnOptRefresh', 'BtnRepScan',
    'BtnUndoLast', 'BtnUndoSel', 'BtnRestorePoint', 'BtnSchedInstall', 'BtnSchedRemove')

function Set-Busy {
    param([bool]$On, [string]$Text = '')
    $script:Busy = $On
    $W.Prog.Visibility = if ($On) { 'Visible' } else { 'Hidden' }
    $W.BtnCancel.IsEnabled = $On
    foreach ($b in $script:BusyButtons) { $W[$b].IsEnabled = -not $On }
    if ($On) { $W.BtnRepFix.IsEnabled = $false; $W.BtnRepFixAll.IsEnabled = $false }
    else { $W.BtnRepFix.IsEnabled = [bool]$script:RepScanned; $W.BtnRepFixAll.IsEnabled = [bool]$script:RepScanned }
    if ($Text) { Set-Status $Text }
}

function Set-Progress {
    param([int]$Done, [int]$Total, [string]$Name)
    if ($Total -le 0) { $W.Prog.IsIndeterminate = $true; return }
    $W.Prog.IsIndeterminate = $false
    $W.Prog.Value = [Math]::Min(100, [Math]::Round(100.0 * $Done / $Total, 1))
    $shown = [Math]::Min($Done, $Total)
    if ($Name) { Set-Status ("{0} {1}/{2}: {3}" -f $script:RunVerb, $shown, $Total, $Name) }
    else { Set-Status ("{0} {1}/{2}..." -f $script:RunVerb, $shown, $Total) }
}

# =====================================================================
# CHILD PROCESS RUNNER (engine output tails into the log)
# =====================================================================
$script:Busy       = $false
$script:Proc       = $null
$script:OutFile    = $null
$script:OutPos     = 0
$script:OnDone     = $null
$script:ReportTmp  = $null
$script:Decoder    = $null
$script:Pending    = ''
$script:Cancelled  = $false
$script:ProgTotal  = 0
$script:ProgDone   = 0
$script:ProgNames  = @()
$script:RunVerb    = 'Running'

# Engines emit UTF-8 when redirected (WinSenior.Common.ps1). ONE decoder per run
# keeps a multi-byte character that straddles two reads intact.
function Read-ChildOutput {
    param([switch]$Final)
    if (-not $script:OutFile -or -not (Test-Path -LiteralPath $script:OutFile)) { return }
    $text = ''
    try {
        $fs = [System.IO.File]::Open($script:OutFile, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -gt $script:OutPos) {
                $fs.Position = $script:OutPos
                $buf = New-Object byte[] ([int]($fs.Length - $script:OutPos))
                $n = $fs.Read($buf, 0, $buf.Length)
                $script:OutPos += $n
                $chars = New-Object char[] ($n + 8)
                $c = $script:Decoder.GetChars($buf, 0, $n, $chars, 0, [bool]$Final)
                $text = New-Object string ($chars, 0, $c)
            }
            elseif ($Final) {
                $chars = New-Object char[] 8
                $c = $script:Decoder.GetChars((New-Object byte[] 0), 0, 0, $chars, 0, $true)
                $text = New-Object string ($chars, 0, $c)
            }
        } finally { $fs.Dispose() }
    } catch { Write-Verbose "output read: $($_.Exception.Message)" }

    $split = Split-WsLogChunk $script:Pending $text
    $script:Pending = $split.Rest
    $lines = @($split.Lines)
    if ($Final -and $script:Pending) { $lines += $script:Pending; $script:Pending = '' }
    if (-not $lines.Count) { return }

    $sb = New-Object System.Text.StringBuilder
    $step = $null
    foreach ($line in $lines) {
        if ($script:ProgTotal -gt 0) {
            $name = Get-WsStepName -Line $line -Names $script:ProgNames
            if ($name) { $script:ProgDone++; $step = $name }
        }
        [void]$sb.Append((Format-WsEngineLine $line)).Append("`r`n")
    }
    Write-LogText $sb.ToString()
    if ($step) { Set-Progress -Done $script:ProgDone -Total $script:ProgTotal -Name $step }
}

function Start-Engine {
    param(
        [string]$Script,
        [string[]]$Arguments = @(),
        # Alternative to -Script: a small PowerShell command, sent -EncodedCommand
        # (no temp file, no quoting problems).
        [string]$Command,
        [string]$Status = 'Running...',
        [string]$Verb = 'Running',
        [scriptblock]$OnDone,
        [switch]$WantReport,
        [int]$ProgressTotal = 0,
        [string[]]$ProgressNames = @()
    )
    if ($script:Busy) { Set-Status 'Another operation is still running.'; return }
    Save-GuiSettings
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $script:OutFile   = Join-Path $script:LogDir "gui-$stamp.out.log"
    $script:OutPos    = 0
    $script:Decoder   = [System.Text.Encoding]::UTF8.GetDecoder()
    $script:Pending   = ''
    $script:OnDone    = $OnDone
    $script:ReportTmp = $null
    $script:Cancelled = $false
    $script:ProgTotal = $ProgressTotal
    $script:ProgDone  = 0
    $script:ProgNames = @($ProgressNames)
    $script:RunVerb   = $Verb
    $Arguments = @($Arguments)
    if ($WantReport) {
        $script:ReportTmp = Join-Path $env:TEMP "winsenior-gui-$stamp.json"
        $Arguments += @('-ReportPath', $script:ReportTmp)
    }
    $base = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')
    if ($Command) {
        $argLine = ($base + @('-EncodedCommand', [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command)))) -join ' '
        $shown = $Status
    }
    else {
        $argLine = ((@($base + @('-File', $Script) + $Arguments) | ForEach-Object { ConvertTo-WsCmdArg ([string]$_) }) -join ' ')
        $shown = '{0} {1}' -f (Split-Path $Script -Leaf), ($Arguments -join ' ')
    }
    Add-Log ("`r`n===== {0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $shown)
    Set-Busy $true $Status
    Set-Progress -Done 0 -Total $ProgressTotal -Name ''
    if ($ProgressTotal -le 0) { Set-Status $Status }
    try {
        $script:Proc = Start-Process -FilePath $script:HostExe -ArgumentList $argLine -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $script:OutFile -RedirectStandardError "$script:OutFile.err"
        # Touch the handle now: Windows PowerShell 5.1 otherwise loses ExitCode once the child exits.
        $null = $script:Proc.Handle
    } catch {
        Add-Log "Failed to start: $(Get-WsErrorText $_)"
        $script:Proc = $null; $script:OnDone = $null
        Set-Busy $false 'Failed to start.'
        return
    }
    $script:Timer.Start()
}

function Complete-Engine {
    $script:Timer.Stop()
    Read-ChildOutput -Final
    $errFile = "$script:OutFile.err"
    if (Test-Path -LiteralPath $errFile) {
        $e = $null
        try { $e = [System.IO.File]::ReadAllText($errFile) } catch { $e = $null }
        if ($e -and $e.Trim()) { Add-Log ("[stderr] " + ($e.Trim() -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', '')) }
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    $code = $null
    if ($script:Proc) { try { $code = $script:Proc.ExitCode } catch { $code = $null } }
    $cancelled = $script:Cancelled
    $report = $null
    if ($script:ReportTmp -and (Test-Path -LiteralPath $script:ReportTmp)) {
        if (-not $cancelled) {
            try { $report = Get-Content -LiteralPath $script:ReportTmp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $report = $null }
            if ($report) { Save-RunReport -Source $script:ReportTmp -Report $report }
        }
        Remove-Item -LiteralPath $script:ReportTmp -Force -ErrorAction SilentlyContinue
    }
    # Capture the continuation, clear the shared state, THEN run it - so a handler
    # that starts the next engine (Fix -> re-scan) keeps its own OnDone.
    $handler = $script:OnDone
    $script:OnDone = $null
    $script:Proc = $null
    $script:ReportTmp = $null
    if ($cancelled) {
        Add-Log '--- cancelled by user ---'
        Set-Busy $false 'Cancelled.'
        return
    }
    $W.Prog.IsIndeterminate = $false; $W.Prog.Value = 100
    $codeText = if ($null -eq $code) { '?' } else { [string]$code }
    Set-Busy $false ("Done (exit code {0})." -f $codeText)
    if ($handler) {
        try { & $handler $report $code } catch { Add-Log "post-processing error: $(Get-WsErrorText $_)" }
    }
}

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:Timer.Add_Tick({
    try {
        Read-ChildOutput
        if ($script:Proc -and $script:Proc.HasExited) { Complete-Engine }
    }
    catch {
        # Never leave the window stuck in "busy" because post-processing failed.
        $script:Timer.Stop()
        $f = Write-CrashLog $_ 'engine completion'
        Add-Log "[x] Error while finishing the run: $(Get-WsErrorText $_)   (details: $f)"
        $script:Proc = $null; $script:OnDone = $null
        Set-Busy $false 'Finished with an error - see the log.'
    }
})

function Stop-Engine {
    if ($script:Proc -and -not $script:Proc.HasExited) {
        $script:Cancelled = $true
        Set-Status 'Cancelling...'
        & taskkill.exe /PID $script:Proc.Id /T /F *>$null
    }
}
$W.BtnCancel.Add_Click({ Stop-Engine })

# Keep a copy of every run's report for the History page.
function Save-RunReport {
    param([string]$Source, $Report)
    try {
        $engine = ([string]$Report.Engine).ToLowerInvariant()
        if (-not $engine) { $engine = 'run' }
        $dest = Join-Path $script:ReportDir ("gui-{0}-{1}.json" -f $engine, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        Copy-Item -LiteralPath $Source -Destination $dest -Force
        Get-ChildItem -LiteralPath $script:ReportDir -Filter 'gui-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 300 |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $script:HistoryDirty = $true
    } catch { Add-Log "Could not keep the report for History: $(Get-WsErrorText $_)" }
}

# =====================================================================
# LIST HELPERS: filter box, sortable headers, selection over visible rows
# =====================================================================
# The comma keeps the pipeline from enumerating the view into its items.
function Get-WsView { param($List) , [System.Windows.Data.CollectionViewSource]::GetDefaultView($List.ItemsSource) }

function Set-WsListFilter {
    param($List, [string]$Text)
    $view = Get-WsView $List
    if ($null -eq $view) { return }
    $words = @(([string]$Text).Trim() -split '\s+' | Where-Object { $_ })
    if (-not $words.Count) { $view.Filter = $null; return }
    $view.Filter = [Predicate[object]]({
        param($o)
        $hay = '{0} {1} {2} {3} {4} {5}' -f $o.Name, $o.Id, $o.Group, $o.Detail, $o.Info, $o.Risk
        foreach ($w in $words) { if ($hay.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false } }
        $true
    }.GetNewClosure())
}

function Get-WsVisibleRow { param($List) $v = Get-WsView $List; if ($null -ne $v) { @($v) } else { @() } }

$script:ArrowUp   = [string][char]0x25B2
$script:ArrowDown = [string][char]0x25BC
$script:SortMap = @{
    '' = 'Selected'; 'Task' = 'Name'; 'Tweak' = 'Name'; 'Check' = 'Name'; 'Name' = 'Name'; 'Date' = 'Name'
    'Category' = 'Group'; 'Area' = 'Group'; 'Scope' = 'Group'; 'Engine' = 'Group'
    'Risk' = 'Rank'; 'Fix' = 'Rank'; 'Would free' = 'Bytes'; 'Id' = 'Id'
    'State' = 'State'; 'Status' = 'State'; 'Errors' = 'State'
    'Detail' = 'Detail'; 'Location' = 'Detail'; 'Mode' = 'Detail'
    'Command' = 'Info'; 'Source' = 'Info'; 'Result' = 'Size'
}
$script:SortState = @{}

function Invoke-WsHeaderSort {
    param($List, $Header)
    if (-not $Header -or -not $Header.Column) { return }
    $label = ([string]$Header.Column.Header) -replace (' [' + $script:ArrowUp + $script:ArrowDown + ']$'), ''
    $prop = $script:SortMap[$label]
    if (-not $prop) { return }
    $key = $List.Name
    $prev = $script:SortState[$key]
    $dir = if ($prev -and $prev.Prop -eq $prop) {
        if ($prev.Dir -eq 'Ascending') { 'Descending' } else { 'Ascending' }
    } elseif ($prop -in 'Bytes', 'Rank', 'Selected') { 'Descending' } else { 'Ascending' }
    $script:SortState[$key] = @{ Prop = $prop; Dir = $dir }
    $view = Get-WsView $List
    $view.SortDescriptions.Clear()
    $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($prop, $dir)))
    foreach ($col in $List.View.Columns) {
        if ($col.Header -is [string]) {
            $col.Header = ($col.Header -replace (' [' + $script:ArrowUp + $script:ArrowDown + ']$'), '')
        }
    }
    if ($label) {
        $Header.Column.Header = $label + ' ' + $(if ($dir -eq 'Ascending') { $script:ArrowUp } else { $script:ArrowDown })
    }
}

function Register-WsList {
    param($List, $FilterBox)
    $List.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{ param($src, $e) Invoke-WsHeaderSort -List $src -Header $e.OriginalSource })
    if ($FilterBox) {
        $FilterBox.Add_TextChanged({
            param($src)
            Set-WsListFilter -List $script:FilterTargets[$src.Name] -Text $src.Text
            Update-AllStatus
        })
        $script:FilterTargets[$FilterBox.Name] = $List
    }
}
$script:FilterTargets = @{}

function Set-RowSelection {
    param($List, [scriptblock]$Predicate)
    foreach ($r in (Get-WsVisibleRow $List)) { if ($r.Enabled) { $r.Selected = [bool](& $Predicate $r) } }
}

function Format-NameList {
    param($Rows, [int]$Max = 10)
    $a = @($Rows)
    $lines = @($a | Select-Object -First $Max | ForEach-Object { "   - $($_.Name)" })
    if ($a.Count -gt $Max) { $lines += "   ... and $($a.Count - $Max) more" }
    $lines -join "`n"
}

# Debounced status refresh: property changes (Select all = 100 events) restart a
# short timer instead of recomputing the whole status each time.
function New-DebounceTimer {
    param([scriptblock]$Action, [int]$Ms = 120)
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($Ms)
    $t.Tag = $Action
    $t.Add_Tick({ param($src) $src.Stop(); & $src.Tag })
    $t
}
function Restart-Timer { param($Timer) $Timer.Stop(); $Timer.Start() }

# =====================================================================
# CLEANUP PAGE
# =====================================================================
$settings = Get-GuiSettings
$script:Settings = $settings
$script:CleanReg = Get-CleanupTaskRegistry
$defaultClean = @(Resolve-CleanupSelection -Registry $script:CleanReg | ForEach-Object Id)
$script:CleanRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:CleanById = @{}
$cleanSaved = ($null -ne $settings.CleanOn)
foreach ($t in $script:CleanReg) {
    $r = New-Object WinSenior.Row
    $r.Id = $t.Id; $r.Name = $t.Name; $r.Group = $t.Category; $r.Risk = $t.Risk; $r.Rank = [int]$script:RiskRank[[string]$t.Risk]
    $r.Selected = if ($cleanSaved) { @($settings.CleanOn) -contains $t.Id } else { $defaultClean -contains $t.Id }
    $tip = New-Object System.Collections.Generic.List[string]
    $tip.Add($t.Name)
    $tip.Add(("{0} / {1}{2}" -f $t.Category, $t.Risk, $(if ($t.DefaultOn) { '   (on by default)' } else { '   (off by default)' })))
    $explain = if ($t.PSObject.Properties['Explain']) { [string]$t.Explain } else { '' }
    if ($explain) { $tip.Add($explain) }
    if ($t.Risk -eq 'Dangerous') { $tip.Add('IRREVERSIBLE - only runs when ticked by hand.') }
    if ([int]$t.AgeDays -gt 0) { $tip.Add("Only files older than $($t.AgeDays) days.") }
    if ($t.PSObject.Properties['Processes'] -and $t.Processes) { $tip.Add("Needs closed: $(@($t.Processes) -join ', ')") }
    if ($t.PSObject.Properties['StopServices'] -and $t.StopServices) { $tip.Add("Stops services while cleaning: $(@($t.StopServices) -join ', ')") }
    if ($t.Paths) {
        $tip.Add('Paths:')
        $p = @($t.Paths)
        foreach ($x in ($p | Select-Object -First 14)) { $tip.Add("   $x") }
        if ($p.Count -gt 14) { $tip.Add("   ... and $($p.Count - 14) more") }
    }
    elseif ($t.Action) { $tip.Add('Runs a scripted action (tool-driven cleanup, measured before/after).') }
    $r.Tip = $tip -join "`n"
    $script:CleanRows.Add($r)
    $script:CleanById[$t.Id] = $t
}
$W.LvClean.ItemsSource = $script:CleanRows
$W.ChkCurrentUser.IsChecked  = [bool]$settings.CurrentUserOnly
$W.ChkRestore.IsChecked      = [bool]$settings.RestorePoint
$W.ChkDefer.IsChecked        = [bool]$settings.DeferLocked
$W.ChkSkipOpt.IsChecked      = [bool]$settings.SkipOptimization
$W.ChkCloseApps.IsChecked    = [bool]$settings.CloseApps
$W.ChkConservative.IsChecked = [bool]$settings.Conservative
$W.ChkOptRestore.IsChecked   = [bool]$settings.OptRestorePoint
$savedAge = Get-WsMaxAge ([string]$settings.MaxAgeDays)
$W.TxtMaxAge.Text = [string]$(if ($null -eq $savedAge) { 0 } else { $savedAge })

# Fixed drives for drive-level tasks (all ticked = engine default "every local disk").
$script:DriveChecks = New-Object System.Collections.Generic.List[object]
$savedDrives = @($settings.Drives | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\').TrimEnd(':').ToUpperInvariant() })
foreach ($drv in ([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' })) {
    $letter = $drv.Name.Substring(0, 1).ToUpperInvariant()
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = "${letter}:"
    $cb.Tag = $letter
    $cb.Margin = '0,0,10,0'
    try { if ($drv.IsReady) { $cb.ToolTip = "{0}   {1} free of {2}" -f $drv.VolumeLabel, (Format-FileSize $drv.AvailableFreeSpace), (Format-FileSize $drv.TotalSize) } } catch { $cb.ToolTip = $null }
    $cb.IsChecked = (-not $savedDrives.Count) -or ($savedDrives -contains $letter)
    $cb.Add_Click({ Update-CleanStatus })
    [void]$W.PanelDrives.Children.Add($cb)
    $script:DriveChecks.Add($cb)
}

function Get-CleanEffectiveRow {
    $skipOpt = [bool]$W.ChkSkipOpt.IsChecked
    $cons    = [bool]$W.ChkConservative.IsChecked
    @($script:CleanRows | Where-Object {
        $_.Selected -and
        (-not $skipOpt -or $_.Group -ne 'Optimization') -and
        (-not $cons -or $_.Risk -in 'Safe', 'Moderate')
    })
}

function Get-CleanDriveArg {
    $all = $script:DriveChecks.ToArray()
    $on = @($all | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    if (-not $all.Count -or $on.Count -eq $all.Count) { return @() }
    @('-Drives', ($on -join ','))
}

function Update-CleanStatus {
    $sel = @($script:CleanRows | Where-Object Selected)
    $eff = @(Get-CleanEffectiveRow)
    $txt = "Selected {0} of {1} tasks" -f $sel.Count, $script:CleanRows.Count
    if ($eff.Count -ne $sel.Count) { $txt += "   |   will run {0} ({1} held back by the options above)" -f $eff.Count, ($sel.Count - $eff.Count) }
    $bytes = [int64](($eff | Measure-Object Bytes -Sum).Sum)
    if ($bytes -gt 0) { $txt += "   |   estimated: " + (Format-FileSize $bytes) }
    $danger = @($eff | Where-Object Risk -eq 'Dangerous').Count
    if ($danger) { $txt += "   |   $danger DANGEROUS" }
    if ($W.TxtCleanFilter.Text) { $txt += "   |   showing {0}" -f (Get-WsVisibleRow $W.LvClean).Count }
    if (-not @($script:DriveChecks | Where-Object { $_.IsChecked }).Count -and $script:DriveChecks.Count) { $txt += '   |   no drive ticked' }
    $W.LblCleanStatus.Text = $txt
}
$script:CleanStatusTimer = New-DebounceTimer { Update-CleanStatus }
$script:CleanRows | ForEach-Object {
    $_.Add_PropertyChanged({ if ($args[1].PropertyName -in 'Selected', 'Bytes') { Restart-Timer $script:CleanStatusTimer } })
}
foreach ($c in 'ChkSkipOpt', 'ChkConservative') { $W[$c].Add_Click({ Update-CleanStatus }) }
Update-CleanStatus

$W.TxtMaxAge.Add_TextChanged({
    if ($null -eq (Get-WsMaxAge $W.TxtMaxAge.Text)) {
        $W.TxtMaxAge.BorderBrush = [System.Windows.Media.Brushes]::IndianRed
        $W.TxtMaxAge.ToolTip = 'Enter whole days from 0 to 3650 (0 = no age filter).'
    } else {
        $W.TxtMaxAge.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
        $W.TxtMaxAge.ToolTip = '0 = no age filter. Whole days, 0 to 3650.'
    }
})

# Validates the options; returns $null (and says why) when a run must not start.
function Test-CleanOption {
    if ($null -eq (Get-WsMaxAge $W.TxtMaxAge.Text)) {
        Set-Status 'The "older than" box needs whole days from 0 to 3650.'; $W.TxtMaxAge.Focus() | Out-Null; return $false
    }
    if ($script:DriveChecks.Count -and -not @($script:DriveChecks | Where-Object { $_.IsChecked }).Count) {
        Set-Status 'Tick at least one drive.'; return $false
    }
    if (-not @(Get-CleanEffectiveRow).Count) {
        Set-Status 'Nothing to run - no task is ticked (or the options hold them all back).'; return $false
    }
    $true
}

function Get-CleanupArgs {
    param([bool]$Preview)
    $allIds = @($script:CleanRows | ForEach-Object Id)
    $onIds  = @(Get-CleanEffectiveRow | ForEach-Object Id)
    $a = @(Get-WsSelectionArg -AllIds $allIds -OnIds $onIds)
    $a += '-Unattended'
    if ($Preview) { $a += '-WhatIf' }
    if ($W.ChkCurrentUser.IsChecked) { $a += '-CurrentUserOnly' }
    if (-not $W.ChkRestore.IsChecked -or $Preview) { $a += '-NoRestorePoint' }
    if ($W.ChkDefer.IsChecked -and -not $Preview) { $a += '-DeferLocked' }
    if ($W.ChkSkipOpt.IsChecked) { $a += '-SkipOptimization' }
    if ($W.ChkConservative.IsChecked) { $a += '-Conservative' }
    if ($W.ChkCloseApps.IsChecked) { $a += '-CloseApps' }
    $age = Get-WsMaxAge $W.TxtMaxAge.Text
    if ($age -gt 0) { $a += @('-MaxAgeDays', [string]$age) }
    $a += @(Get-CleanDriveArg)
    if (@(Get-CleanEffectiveRow | Where-Object Risk -eq 'Dangerous').Count) { $a += '-IncludeDangerous' }
    $a
}

function Get-CleanProgressTotal {
    $ids = @(Get-CleanEffectiveRow | ForEach-Object Id)
    $n = $ids.Count
    # The engine drops wu-cache when wu-full runs too (same folder, one service bounce).
    if (($ids -contains 'wu-full') -and ($ids -contains 'wu-cache')) { $n-- }
    $n
}

# Running processes (this machine) that lock files of the given rows' tasks.
function Get-BlockingProcess {
    param($Rows)
    $names = @($Rows | ForEach-Object { $t = $script:CleanById[$_.Id]; if ($t -and $t.PSObject.Properties['Processes']) { $t.Processes } } |
        Where-Object { $_ } | Sort-Object -Unique)
    if (-not $names.Count) { return @() }
    @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object ProcessName | Sort-Object -Unique)
}

function Confirm-CleanRun {
    $eff = @(Get-CleanEffectiveRow)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("Clean {0} task(s) now?" -f $eff.Count))
    $lines.Add('')
    $scanned = @($eff | Where-Object { $_.Size -and $_.Size -notlike 'freed*' })
    if ($scanned.Count) {
        $est = [int64](($scanned | Measure-Object Bytes -Sum).Sum)
        $lines.Add(("Estimated space: {0}  (last scan covered {1} of these {2} tasks)" -f (Format-FileSize $est), $scanned.Count, $eff.Count))
    } else { $lines.Add('No size estimate yet - press "Scan (dry run)" first to see what would be freed.') }
    $lines.Add(("Restore point first: {0}" -f $(if ($W.ChkRestore.IsChecked) { 'yes' } else { 'NO' })))
    $age = Get-WsMaxAge $W.TxtMaxAge.Text
    if ($age -gt 0) { $lines.Add("Only files older than $age days.") }
    $drv = @(Get-CleanDriveArg)
    if ($drv.Count) { $lines.Add("Drive-level tasks limited to: $($drv[1])") }
    $blocking = @(Get-BlockingProcess ($eff | Where-Object Group -eq 'Browsers'))
    if ($W.ChkCloseApps.IsChecked) {
        if ($blocking.Count) { $lines.Add("Running browsers WILL BE CLOSED first: $($blocking -join ', ') - save your work.") }
        elseif (@($eff | Where-Object Group -eq 'Browsers').Count) { $lines.Add('Browsers still running at that point will be closed first.') }
    } elseif ($blocking.Count) {
        $lines.Add("Caches of running browsers are SKIPPED: $($blocking -join ', ') (tick 'Close running browsers first' to include them).")
    }
    $aggr = @($eff | Where-Object Risk -eq 'Aggressive')
    $dang = @($eff | Where-Object Risk -eq 'Dangerous')
    if ($aggr.Count) { $lines.Add(''); $lines.Add("Aggressive ($($aggr.Count)):"); $lines.Add((Format-NameList $aggr)) }
    if ($dang.Count) { $lines.Add(''); $lines.Add("DANGEROUS - IRREVERSIBLE ($($dang.Count)):"); $lines.Add((Format-NameList $dang)) }
    $icon = if ($dang.Count -or $aggr.Count) { 'Warning' } else { 'Question' }
    (Show-WsMessage -Text ($lines -join "`n") -Title 'Confirm cleanup' -Buttons 'YesNo' -Icon $icon) -eq 'Yes'
}

$applyReport = {
    param($report)
    if (-not $report) { return }
    $map = @{}
    foreach ($i in @($report.Items)) { if ($i.Task) { $map[[string]$i.Task] = $i } }
    $live = ($report.Mode -ne 'DryRun')
    $ran = @($script:LastCleanIds)
    foreach ($r in $script:CleanRows) {
        if ($map.ContainsKey($r.Id)) {
            $i = $map[$r.Id]
            $b = [int64]$i.Bytes
            $skipped = if ($i.PSObject.Properties['Skipped'] -and $i.Skipped) { [string]$i.Skipped } else { '' }
            if ($skipped) { $r.Bytes = 0; $r.Size = "skipped ($skipped)"; continue }
            $sz = if ($b -gt 0) { Format-FileSize $b } elseif ([int]$i.Files -gt 0) { "$($i.Files) items" } else { '-' }
            if ($live) { $r.Bytes = 0; $r.Size = "freed $sz" } else { $r.Bytes = $b; $r.Size = $sz }
        }
        elseif ($ran -contains $r.Id) { $r.Size = '-' }
    }
    Update-CleanStatus
    $verb = if ($report.Mode -eq 'DryRun') { 'Would free' } else { 'Reclaimed' }
    Set-Status ("{0}: {1}   ({2} items, {3} errors)" -f $verb, $report.Summary.TotalFreed, $report.Summary.TotalFiles, $report.Summary.TotalErrors)
}

function Start-CleanRun {
    param([bool]$Preview)
    $script:LastCleanIds = @(Get-CleanEffectiveRow | ForEach-Object Id)
    if ($Preview) { foreach ($r in $script:CleanRows) { if ($script:LastCleanIds -contains $r.Id) { $r.Size = ''; $r.Bytes = 0 } } }
    $status = if ($Preview) { 'Scanning (dry run)...' } else { 'Cleaning...' }
    $verb = if ($Preview) { 'Scanning' } else { 'Cleaning' }
    Start-Engine -Script $script:CleanupScript -Arguments (Get-CleanupArgs $Preview) -Status $status -Verb $verb `
        -WantReport -OnDone $applyReport -ProgressTotal (Get-CleanProgressTotal)
}

$W.BtnScan.Add_Click({
    if (-not (Test-CleanOption)) { return }
    Start-CleanRun -Preview $true
})
$W.BtnClean.Add_Click({
    if (-not (Test-CleanOption)) { return }
    if (-not (Confirm-CleanRun)) { Set-Status 'Cleanup cancelled.'; return }
    Start-CleanRun -Preview $false
})
$W.BtnCleanAll.Add_Click({  Set-RowSelection $W.LvClean { param($r) $r.Risk -ne 'Dangerous' } })
$W.BtnCleanSafe.Add_Click({ Set-RowSelection $W.LvClean { param($r) $r.Risk -eq 'Safe' } })
$W.BtnCleanDef.Add_Click({  Set-RowSelection $W.LvClean { param($r) $defaultClean -contains $r.Id } })
$W.BtnCleanNone.Add_Click({ Set-RowSelection $W.LvClean { $false } })

# =====================================================================
# OPTIMIZE PAGE
# =====================================================================
$script:OptReg = Get-OptimizationTweakRegistry
$defaultOpt = @(Resolve-TweakSelection -Registry $script:OptReg | ForEach-Object Id)
$script:OptRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:OptById = @{}
$optSaved = ($null -ne $settings.OptOn)

function Get-TweakTip {
    param($Tweak)
    $tip = New-Object System.Collections.Generic.List[string]
    $tip.Add($Tweak.Name)
    $tip.Add(("{0} / {1}{2}" -f $Tweak.Area, $Tweak.Risk, $(if ($Tweak.DefaultOn) { '   (on by default)' } else { '   (off by default)' })))
    if ($Tweak.Explain) { $tip.Add([string]$Tweak.Explain) }
    try {
        switch ($Tweak.Type) {
            'Registry' {
                $vals = @($Tweak.Spec.Values | ForEach-Object { "$($_.Name) = $($_.Value)" }) -join ', '
                $tip.Add("Registry: $($Tweak.Spec.Path)")
                if ($vals) { $tip.Add("   $vals") }
            }
            'Service' { $tip.Add("Service: $($Tweak.Spec.Service) -> $($Tweak.Spec.Startup)") }
            'ScheduledTask' {
                $tip.Add('Scheduled tasks disabled:')
                foreach ($x in @($Tweak.Spec.Tasks | Select-Object -First 8)) { $tip.Add("   $($x.Path)$($x.Name)") }
            }
            default { $tip.Add('Scripted tweak (backed up and reverted by its own undo step).') }
        }
    } catch { Write-Verbose 'tweak details unavailable' }
    $tip -join "`n"
}

foreach ($t in $script:OptReg) {
    $r = New-Object WinSenior.Row
    $r.Id = $t.Id; $r.Name = $t.Name; $r.Group = $t.Area; $r.Risk = $t.Risk; $r.Explain = [string]$t.Explain
    $r.Rank = [int]$script:RiskRank[[string]$t.Risk]
    $r.Selected = if ($optSaved) { @($settings.OptOn) -contains $t.Id } else { $defaultOpt -contains $t.Id }
    $r.Tip = Get-TweakTip $t
    $script:OptRows.Add($r)
    $script:OptById[$t.Id] = $r
}
$W.LvOpt.ItemsSource = $script:OptRows

function Update-OptStatus {
    $on = @($script:OptRows | Where-Object Selected).Count
    $applied = @($script:OptRows | Where-Object State -eq 'applied').Count
    $txt = "Selected {0} of {1} tweaks   |   currently applied: {2}" -f $on, $script:OptRows.Count, $applied
    if ($W.TxtOptFilter.Text) { $txt += "   |   showing {0}" -f (Get-WsVisibleRow $W.LvOpt).Count }
    $W.LblOptStatus.Text = $txt
}
function Update-OptState {
    Set-Status 'Reading current tweak state...'
    $Win.Dispatcher.Invoke([action]{}, 'Background')
    foreach ($t in $script:OptReg) {
        $row = $script:OptById[$t.Id]
        $st = $null
        try { $st = Test-TweakApplied -Tweak $t } catch { $st = $null }
        $row.State = if ($st -eq $true) { 'applied' } elseif ($st -eq $false) { 'not applied' } else { '?' }
    }
    $script:OptStateLoaded = $true
    Update-OptStatus
    Set-Status 'Ready.'
}
$script:OptStatusTimer = New-DebounceTimer { Update-OptStatus }
$script:OptRows | ForEach-Object {
    $_.Add_PropertyChanged({ if ($args[1].PropertyName -in 'Selected', 'State') { Restart-Timer $script:OptStatusTimer } })
}
Update-OptStatus

function Get-OptArgs {
    param([bool]$Preview)
    $a = @(Get-WsSelectionArg -AllIds @($script:OptRows | ForEach-Object Id) -OnIds @($script:OptRows | Where-Object Selected | ForEach-Object Id))
    $a += '-Unattended'
    if ($Preview) { $a += '-WhatIf' }
    if (-not $W.ChkOptRestore.IsChecked -or $Preview) { $a += '-NoRestorePoint' }
    if ($script:OptRows | Where-Object { $_.Selected -and $_.Risk -eq 'Dangerous' }) { $a += '-IncludeDangerous' }
    $a
}

function Confirm-OptRun {
    $sel = @($script:OptRows | Where-Object Selected)
    $already = @($sel | Where-Object State -eq 'applied')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("Apply {0} tweak(s) now?" -f $sel.Count))
    $lines.Add('')
    if ($already.Count) { $lines.Add("$($already.Count) of them are already applied and will be skipped.") }
    $lines.Add('Every change is backed up first and can be reverted from Undo & restore.')
    $lines.Add(("Restore point first: {0}" -f $(if ($W.ChkOptRestore.IsChecked) { 'yes' } else { 'NO' })))
    $aggr = @($sel | Where-Object Risk -eq 'Aggressive')
    $dang = @($sel | Where-Object Risk -eq 'Dangerous')
    if ($aggr.Count) { $lines.Add(''); $lines.Add("Aggressive ($($aggr.Count)):"); $lines.Add((Format-NameList $aggr)) }
    if ($dang.Count) { $lines.Add(''); $lines.Add("DANGEROUS - IRREVERSIBLE ($($dang.Count)):"); $lines.Add((Format-NameList $dang)) }
    $icon = if ($dang.Count -or $aggr.Count) { 'Warning' } else { 'Question' }
    (Show-WsMessage -Text ($lines -join "`n") -Title 'Confirm tweaks' -Buttons 'YesNo' -Icon $icon) -eq 'Yes'
}

$W.BtnOptPreview.Add_Click({
    $sel = @($script:OptRows | Where-Object Selected)
    if (-not $sel.Count) { Set-Status 'Nothing selected.'; return }
    Start-Engine -Script $script:OptimizeScript -Arguments (Get-OptArgs $true) -Status 'Previewing tweaks...' -Verb 'Previewing' `
        -WantReport -ProgressTotal $sel.Count -ProgressNames @($sel | ForEach-Object Name)
})
$W.BtnOptApply.Add_Click({
    $sel = @($script:OptRows | Where-Object Selected)
    if (-not $sel.Count) { Set-Status 'Nothing selected.'; return }
    if (-not (Confirm-OptRun)) { Set-Status 'Cancelled - nothing applied.'; return }
    $todo = @($sel | Where-Object State -ne 'applied')
    Start-Engine -Script $script:OptimizeScript -Arguments (Get-OptArgs $false) -Status 'Applying tweaks...' -Verb 'Applying' `
        -WantReport -ProgressTotal $todo.Count -ProgressNames @($todo | ForEach-Object Name) -OnDone { Update-OptState; Update-Backups }
})
$W.BtnOptRefresh.Add_Click({ Update-OptState })
$W.BtnOptAll.Add_Click({  Set-RowSelection $W.LvOpt { param($r) $r.Risk -ne 'Dangerous' } })
$W.BtnOptDef.Add_Click({  Set-RowSelection $W.LvOpt { param($r) $defaultOpt -contains $r.Id } })
$W.BtnOptNone.Add_Click({ Set-RowSelection $W.LvOpt { $false } })

# =====================================================================
# TROUBLESHOOT PAGE
# =====================================================================
$script:RepReg = Get-DiagnosticCheckRegistry
$script:RepRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:RepById = @{}
$script:RepScanned = $false

function Get-CheckTip {
    param($Check, [string]$Detail)
    $tip = New-Object System.Collections.Generic.List[string]
    $tip.Add($Check.Name)
    $tip.Add("Category: $($Check.Category)")
    if ($Check.Fix) {
        $tip.Add(("Fix: {0}   [{1}]" -f $Check.FixLabel, $Check.FixRisk))
        if ($Check.Reboot) { $tip.Add('The fix needs a reboot to finish.') }
    } else { $tip.Add('Report only - no automatic fix.') }
    if ($Detail) { $tip.Add("Last result: $Detail") }
    $tip -join "`n"
}

foreach ($c in $script:RepReg) {
    $r = New-Object WinSenior.Row
    $r.Id = $c.Id; $r.Name = $c.Name; $r.Group = $c.Category; $r.Risk = $(if ($c.Fix) { $c.FixRisk } else { '' })
    $r.Rank = $(if ($c.Fix) { [int]$script:RiskRank[[string]$c.FixRisk] } else { -1 })
    $r.State = ''; $r.Detail = 'not scanned'; $r.Enabled = $false
    $r.Tip = Get-CheckTip $c ''
    $script:RepRows.Add($r)
    $script:RepById[$c.Id] = $c
}
$W.LvRep.ItemsSource = $script:RepRows

$applyScan = {
    param($report)
    if (-not $report) { return }
    foreach ($i in @($report.Items)) {
        $row = $script:RepRows | Where-Object Id -eq $i.Id | Select-Object -First 1
        if (-not $row) { continue }
        $row.State = [string]$i.Status; $row.Detail = [string]$i.Detail
        $fixable = [bool]$i.HasFix -and ($i.Status -in 'Warn', 'Fail')
        $row.Enabled = $fixable
        $row.Selected = $fixable -and ($i.FixRisk -in 'Safe', 'Moderate')
        $check = $script:RepById[[string]$i.Id]
        if ($check) { $row.Tip = Get-CheckTip $check ([string]$i.Detail) }
    }
    $fail = @($script:RepRows | Where-Object State -eq 'Fail').Count
    $warn = @($script:RepRows | Where-Object State -eq 'Warn').Count
    $script:RepScanned = $true
    $W.BtnRepFix.IsEnabled = -not $script:Busy; $W.BtnRepFixAll.IsEnabled = -not $script:Busy
    $W.LblRepStatus.Text = "Scan complete: {0} failing, {1} warnings. Fixable problems are pre-ticked (Safe + Moderate)." -f $fail, $warn
}
function Start-RepairScan {
    Start-Engine -Script $script:RepairScript -Arguments @('-ScanOnly', '-Unattended') -Status 'Scanning for problems...' -Verb 'Scanning' -WantReport -OnDone $applyScan
}
$W.BtnRepScan.Add_Click({ Start-RepairScan })
$W.BtnRepFix.Add_Click({
    $sel = @($script:RepRows | Where-Object { $_.Selected -and $_.Enabled })
    if (-not $sel.Count) { Set-Status 'No fixes selected.'; return }
    $list = Format-NameList $sel 12
    if ((Show-WsMessage -Text "Repair these problem(s) now? A restore point is created first.`n`n$list" -Title 'Confirm repair' -Buttons 'YesNo' -Icon 'Question') -ne 'Yes') { return }
    $a = @('-FixAll', '-Unattended') + @(Get-WsSelectionArg -AllIds @($script:RepRows | ForEach-Object Id) -OnIds @($sel | ForEach-Object Id))
    if ($sel | Where-Object Risk -eq 'Aggressive') { $a += '-IncludeHeavy' }
    Start-Engine -Script $script:RepairScript -Arguments $a -Status 'Repairing...' -Verb 'Repairing' -WantReport -OnDone {
        param($report, $code)
        & $applyScan $report $code
        if ($report -and $report.Summary.Reboot) { Show-WsMessage -Text 'A reboot is required to finish the repair.' -Title 'Windows Senior' -Buttons 'OK' -Icon 'Information' | Out-Null }
        Start-RepairScan
    }
})
$W.BtnRepFixAll.Add_Click({
    $r = Show-WsMessage -Text 'Apply every available fix, including heavy ones (SFC, DISM, Windows Update reset, network stack)? A restore point is created first.' -Title 'Auto-fix everything' -Buttons 'YesNo' -Icon 'Question'
    if ($r -ne 'Yes') { return }
    Start-Engine -Script $script:RepairScript -Arguments @('-FixAll', '-IncludeHeavy', '-Unattended') -Status 'Auto-fixing...' -Verb 'Repairing' -WantReport -OnDone {
        param($report, $code)
        & $applyScan $report $code
        if ($report -and $report.Summary.Reboot) { Show-WsMessage -Text 'A reboot is required to finish the repair.' -Title 'Windows Senior' -Buttons 'OK' -Icon 'Information' | Out-Null }
    }
})

# =====================================================================
# STARTUP APPS PAGE
# =====================================================================
$script:StartupRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:StartupMap = @{}
$script:StartupLoading = $false
$W.LvStartup.ItemsSource = $script:StartupRows

function Update-StartupStatus {
    $all = @($script:StartupRows)
    $on = @($all | Where-Object Selected).Count
    $txt = "{0} entries   |   {1} enabled, {2} disabled" -f $all.Count, $on, ($all.Count - $on)
    $missing = @($all | Where-Object { $_.Tip -like '*TARGET FILE NOT FOUND*' }).Count
    if ($missing) { $txt += "   |   $missing point to a missing file" }
    if ($W.TxtStartupFilter.Text) { $txt += "   |   showing {0}" -f (Get-WsVisibleRow $W.LvStartup).Count }
    if (-not (Test-AdminPrivileges)) { $txt += '   |   not administrator: All-users entries cannot be changed' }
    $W.LblStartupStatus.Text = $txt
}

function Set-StartupRowState {
    param($Row)
    $item = $script:StartupMap[$Row.Id]
    if (-not $item) { return }
    $want = [bool]$Row.Selected
    try {
        Set-WinSeniorStartupItemState -Item $item -Enabled $want -Confirm:$false | Out-Null
        $Row.State = if ($want) { 'Enabled' } else { 'Disabled' }
        Add-Log ("Startup: {0} '{1}' ({2})" -f $(if ($want) { 'enabled' } else { 'disabled' }), $item.Name, $item.Location)
        Set-Status ("{0} {1}." -f $item.Name, $(if ($want) { 'will start with Windows again' } else { 'will no longer start with Windows' }))
    }
    catch {
        $msg = Get-WsErrorText $_
        Add-Log "[x] Startup: could not change '$($item.Name)': $msg"
        Set-Status "Could not change $($item.Name): $msg"
        $script:StartupLoading = $true
        try { $Row.Selected = -not $want } finally { $script:StartupLoading = $false }
    }
    Update-StartupStatus
}

function Update-Startup {
    if (-not $script:HasStartup) { $W.LblStartupStatus.Text = 'WinSenior.Startup.ps1 is missing - keep it next to WinSenior.Gui.ps1.'; return }
    $script:StartupLoading = $true
    try {
        $script:StartupRows.Clear(); $script:StartupMap = @{}
        foreach ($i in @(Get-WinSeniorStartupItem)) {
            $r = New-Object WinSenior.Row
            $r.Id = "$($i.Location)|$($i.Name)"
            $r.Name = $i.Name; $r.Group = $i.Scope; $r.Detail = $i.Location; $r.Info = [string]$i.Command
            $r.Selected = [bool]$i.Enabled
            $r.State = if ($i.Enabled) { 'Enabled' } else { 'Disabled' }
            $tip = @($i.Name, "Command: $($i.Command)", "Source: $($i.Source)", "State stored in: $($i.ApprovedKey)")
            if ($i.TargetExists -eq $false) { $tip += "TARGET FILE NOT FOUND: $($i.Target)" }
            $r.Tip = $tip -join "`n"
            $r.Add_PropertyChanged({
                param($src, $e)
                if ($e.PropertyName -eq 'Selected' -and -not $script:StartupLoading) { Set-StartupRowState $src }
            })
            $script:StartupRows.Add($r)
            $script:StartupMap[$r.Id] = $i
        }
    }
    catch { Add-Log "[x] Startup list: $(Get-WsErrorText $_)" }
    finally { $script:StartupLoading = $false }
    $script:StartupLoaded = $true
    Update-StartupStatus
}

$W.BtnStartupRefresh.Add_Click({ Update-Startup })
$W.BtnStartupTaskMgr.Add_Click({ Start-Process taskmgr.exe })
$W.BtnStartupOpen.Add_Click({
    $sel = $W.LvStartup.SelectedItem
    if (-not $sel) { Set-Status 'Select an entry first.'; return }
    $item = $script:StartupMap[$sel.Id]
    $path = if ($item.File) { $item.File } else { $item.Target }
    if ($path -and -not [System.IO.Path]::IsPathRooted($path)) {
        $cmd = Get-Command $path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $path = $cmd.Source }
    }
    if ($path -and (Test-Path -LiteralPath $path)) { Start-Process explorer.exe -ArgumentList ('/select,' + (ConvertTo-WsCmdArg $path)) }
    else { Set-Status "File not found: $path" }
})

# =====================================================================
# HISTORY PAGE
# =====================================================================
$script:HistRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$W.LvHistory.ItemsSource = $script:HistRows
$script:HistoryDirty = $true

function Update-History {
    $script:HistRows.Clear()
    $files = @(foreach ($d in $script:ReportDirs) {
        if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue }
    }) | Sort-Object LastWriteTime -Descending | Select-Object -First 400
    [int64]$total = 0; $runs = 0; $bad = 0
    foreach ($f in $files) {
        $rep = $null
        try { $rep = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $rep = $null }
        if (-not $rep -or -not $rep.Engine) { $bad++; continue }
        $h = Get-WsHistoryEntry -Report $rep -Path $f.FullName -FileTime $f.LastWriteTime
        $r = New-Object WinSenior.Row
        $r.Id = $f.FullName
        $r.Name = $h.Date.ToString('yyyy-MM-dd HH:mm')
        $r.Group = $h.Engine; $r.Detail = $h.Mode; $r.Size = $h.Result; $r.State = [string]$h.Errors
        $r.Info = $h.Source; $r.Bytes = $h.Bytes
        $r.Tip = "$($f.FullName)`nHost: $($rep.Host)   WinSenior $($rep.Version)   $($rep.DurationSec) s"
        $script:HistRows.Add($r)
        $total += $h.Bytes; $runs++
    }
    $W.LblHistTotal.Text = Format-FileSize $total
    $W.LblHistCounts.Text = "from {0} live cleanup run(s)   |   {1} report(s) in total" -f @($script:HistRows | Where-Object { $_.Group -eq 'Cleanup' -and $_.Detail -eq 'Live' }).Count, $runs
    $txt = "Reports: $($script:ReportDirs -join '; ')"
    if ($bad) { $txt += "   |   $bad unreadable file(s) skipped" }
    $W.LblHistStatus.Text = $txt
    $script:HistoryDirty = $false
}

function Get-HistorySelection {
    $sel = $W.LvHistory.SelectedItem
    if (-not $sel -and $script:HistRows.Count) { $sel = $script:HistRows[0] }
    $sel
}

$W.BtnHistRefresh.Add_Click({ Update-History })
$W.BtnHistFolder.Add_Click({ Start-Process explorer.exe -ArgumentList (ConvertTo-WsCmdArg $script:ReportDir) })
$W.BtnHistOpen.Add_Click({
    $sel = Get-HistorySelection
    if (-not $sel) { Set-Status 'No reports yet.'; return }
    Start-Process notepad.exe -ArgumentList (ConvertTo-WsCmdArg $sel.Id)
})
$W.LvHistory.Add_MouseDoubleClick({
    $sel = $W.LvHistory.SelectedItem
    if ($sel) { Start-Process notepad.exe -ArgumentList (ConvertTo-WsCmdArg $sel.Id) }
})
$W.BtnHistHtml.Add_Click({
    $sel = Get-HistorySelection
    if (-not $sel) { Set-Status 'No reports yet.'; return }
    $rep = Get-Content -LiteralPath $sel.Id -Raw -Encoding UTF8 | ConvertFrom-Json
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'HTML page (*.html)|*.html|All files|*.*'
    $dlg.FileName = "WinSenior-{0}-{1}.html" -f ([string]$rep.Engine).ToLowerInvariant(), ($sel.Name -replace '[^0-9]', '')
    if (-not $dlg.ShowDialog($Win)) { return }
    $html = ConvertTo-WsReportHtml -Report $rep -SourcePath $sel.Id
    [System.IO.File]::WriteAllText($dlg.FileName, $html, (New-Object System.Text.UTF8Encoding($true)))
    Set-Status "Exported $($dlg.FileName)"
    Start-Process -FilePath $dlg.FileName
})

# =====================================================================
# UNDO / RESTORE PAGE
# =====================================================================
$script:BackupDirPath = Join-Path $env:ProgramData 'WinSenior\backups'
$script:BackupRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$W.LvBackups.ItemsSource = $script:BackupRows
function Update-Backups {
    $script:BackupRows.Clear()
    if (-not (Test-Path $script:BackupDirPath)) { return }
    Get-ChildItem $script:BackupDirPath -Filter 'optimize-backup-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
            $r = New-Object WinSenior.Row
            $r.Id = $_.FullName; $r.Name = $_.Name; $r.Detail = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            $r.State = 'active'
            try {
                $j = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $r.Size = [string]@($j.Tweaks | Where-Object { $null -ne $_ }).Count
                $made = ConvertTo-WsDate $j.Timestamp
                if ($made) { $r.Detail = $made.ToString('yyyy-MM-dd HH:mm') }
                if ($j.PSObject.Properties['UndoneAt'] -and $j.UndoneAt) {
                    $u = ConvertTo-WsDate $j.UndoneAt
                    $r.State = 'undone'
                    $r.Tip = "Already reverted" + $(if ($u) { " on $($u.ToString('yyyy-MM-dd HH:mm'))" } else { '' })
                }
            } catch { $r.Size = '?'; $r.State = 'unreadable' }
            $script:BackupRows.Add($r)
        }
}
Update-Backups
$W.BtnUndoLast.Add_Click({
    $next = $script:BackupRows | Where-Object { $_.State -eq 'active' } | Select-Object -First 1
    if (-not $next) { Set-Status $(if ($script:BackupRows.Count) { 'Every backup has already been undone.' } else { 'No backups found.' }); return }
    if ((Show-WsMessage -Text "Revert the tweaks from $($next.Name) ($($next.Size) tweak(s), $($next.Detail))?" -Title 'Undo optimization' -Buttons 'YesNo' -Icon 'Question') -ne 'Yes') { return }
    Start-Engine -Script $script:OptimizeScript -Arguments @('-Undo', '-Unattended', '-BackupManifest', $next.Id) -Status 'Reverting newest run...' -Verb 'Reverting' -OnDone { Update-OptState; Update-Backups }
})
$W.BtnUndoSel.Add_Click({
    $sel = $W.LvBackups.SelectedItem
    if (-not $sel) { Set-Status 'Select a manifest first.'; return }
    $extra = if ($sel.State -eq 'undone') { "`n`nThis manifest was already undone once." } else { '' }
    if ((Show-WsMessage -Text "Revert the tweaks from $($sel.Name)?$extra" -Title 'Undo optimization' -Buttons 'YesNo' -Icon 'Question') -ne 'Yes') { return }
    Start-Engine -Script $script:OptimizeScript -Arguments @('-Undo', '-Unattended', '-BackupManifest', $sel.Id) -Status 'Reverting selected manifest...' -Verb 'Reverting' -OnDone { Update-OptState; Update-Backups }
})
$W.BtnBackupsRefresh.Add_Click({ Update-Backups })
$W.BtnOpenBackups.Add_Click({ if (-not (Test-Path $script:BackupDirPath)) { New-Item -ItemType Directory $script:BackupDirPath -Force | Out-Null }; Start-Process explorer.exe -ArgumentList (ConvertTo-WsCmdArg $script:BackupDirPath) })
$W.BtnRestorePoint.Add_Click({
    # Date computed here; the child only dot-sources the shared library (no temp script).
    $desc = 'WinSenior manual ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $lib = $script:CommonScript -replace "'", "''"
    $cmd = ". '$lib'; `$r = New-WinSeniorRestorePoint -Description '$desc' -LogAction { param(`$m, `$l) Write-WsLog -Message `$m -Level `$l }; if (`$r -eq 'Created') { exit 0 } else { exit 1 }"
    Start-Engine -Command $cmd -Status 'Creating restore point...' -Verb 'Creating' -OnDone {
        $code = $args[1]
        Set-Status $(if ($code -eq 0) { 'Restore point created.' } else { 'Restore point NOT created - see the log (System Protection may be off).' })
    }
})
$W.BtnOpenRstrui.Add_Click({ Start-Process rstrui.exe })
$W.BtnOpenLogs.Add_Click({ Start-Process explorer.exe -ArgumentList (ConvertTo-WsCmdArg $script:LogDir) })
$W.BtnOpenTemp.Add_Click({ Start-Process explorer.exe -ArgumentList (ConvertTo-WsCmdArg $env:TEMP) })

# =====================================================================
# SCHEDULE PAGE
# =====================================================================
$script:InstallRoot = Get-WinSeniorInstallRoot
$W.LblSchedInfo.Text = "Install copies the engine scripts to $script:InstallRoot (writable by administrators only) and the tasks run from there - never from this folder. Remove deletes that copy. Reports: $env:ProgramData\WinSenior\reports (see History)."
function Update-Schedule {
    $tasks = @(Get-ScheduledTask -TaskPath '\WinSenior\' -ErrorAction SilentlyContinue)
    if (-not $tasks) { $W.LblSchedule.Text = 'Not installed.'; return }
    $lines = foreach ($t in $tasks) {
        $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        $line = "{0}  -  {1}   next: {2}   last: {3}" -f $t.TaskName, $t.State, $info.NextRunTime, $info.LastRunTime
        $argText = [string](@($t.Actions)[0].Arguments)
        if ($argText -and $argText.IndexOf($script:InstallRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $line += "`n    runs scripts from an old location - press Install again to move them to $script:InstallRoot"
        }
        $line
    }
    $W.LblSchedule.Text = ($lines -join "`n")
}
Update-Schedule
$W.BtnSchedInstall.Add_Click({ Start-Engine -Script $script:MenuScript -Arguments @('-InstallSchedule', '-NoElevate') -Status 'Installing scheduled tasks...' -OnDone { Update-Schedule } })
$W.BtnSchedRemove.Add_Click({  Start-Engine -Script $script:MenuScript -Arguments @('-RemoveSchedule', '-NoElevate')  -Status 'Removing scheduled tasks...'   -OnDone { Update-Schedule } })
$W.BtnSchedRefresh.Add_Click({ Update-Schedule })
$W.BtnSchedOpen.Add_Click({ Start-Process taskschd.msc })

# =====================================================================
# ABOUT / NAV / LOG BUTTONS
# =====================================================================
$ver = Get-WinSeniorVersion
$W.LblVersion.Text = "v$ver"
$W.LblAdmin.Text = if (Test-AdminPrivileges) { 'Administrator: yes' } else { 'Administrator: NO - most actions will fail' }
$W.LblHost.Text  = "PowerShell $($PSVersionTable.PSVersion)"
$W.LblAbout.Text = @"
Windows Senior v$ver - registry-driven Windows cleaner, optimizer and troubleshooter.

Cleanup tasks: $($script:CleanReg.Count)    Optimization tweaks: $($script:OptReg.Count)    Diagnostic checks: $($script:RepReg.Count)

This window drives the same PowerShell engines as the console menu and the command line, so every action keeps
the engines' real -WhatIf dry run, the delete safety guard, System Restore points and per-tweak undo.
Startup apps are switched the way Task Manager does it (reversible); History keeps every run's report.

Settings: $script:SettingsFile
Run reports: $script:ReportDir
Engine logs: $env:TEMP\WindowsCleanup.log, WindowsOptimize.log, WindowsRepair.log
Backups: $script:BackupDirPath

MIT License - https://github.com/denfry/WindowsCleaner
"@
$W.BtnOpenRepo.Add_Click({ Start-Process 'https://github.com/denfry/WindowsCleaner' })
$W.BtnOpenConsole.Add_Click({
    Start-Process -FilePath $script:HostExe -ArgumentList ((@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:MenuScript, '-NoElevate') | ForEach-Object { ConvertTo-WsCmdArg $_ }) -join ' ')
})

function Update-AllStatus {
    Update-CleanStatus; Update-OptStatus
    if ($script:StartupLoaded) { Update-StartupStatus }
}

Register-WsList $W.LvClean   $W.TxtCleanFilter
Register-WsList $W.LvOpt     $W.TxtOptFilter
Register-WsList $W.LvRep     $W.TxtRepFilter
Register-WsList $W.LvStartup $W.TxtStartupFilter
Register-WsList $W.LvHistory $null

$pages = @{ NavClean = 'PageClean'; NavOpt = 'PageOpt'; NavRepair = 'PageRepair'; NavStartup = 'PageStartup'; NavHistory = 'PageHistory'
            NavUndo = 'PageUndo'; NavSchedule = 'PageSchedule'; NavAbout = 'PageAbout' }
foreach ($nav in $pages.Keys) {
    $W[$nav].Tag = $pages[$nav]
    $W[$nav].Add_Checked({
        param($src)
        foreach ($p in $pages.Values) { $W[$p].Visibility = 'Collapsed' }
        $W[$src.Tag].Visibility = 'Visible'
        switch ($src.Tag) {
            'PageOpt'     { if (-not $script:OptStateLoaded) { Update-OptState } }
            'PageStartup' { if (-not $script:StartupLoaded) { Update-Startup } }
            'PageHistory' { if ($script:HistoryDirty) { Update-History } }
        }
    })
}
if (-not $script:HasStartup) { $W.NavStartup.IsEnabled = $false; $W.NavStartup.ToolTip = 'WinSenior.Startup.ps1 not found' }

$W.BtnLogClear.Add_Click({ $W.TxtLog.Clear(); $script:LogChars = 0 })
$W.BtnLogSave.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Log files (*.log)|*.log|All files|*.*'
    $dlg.FileName = "WinSenior-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
    if ($dlg.ShowDialog($Win)) { Set-Content -Path $dlg.FileName -Value $W.TxtLog.Text -Encoding UTF8; Set-Status "Saved $($dlg.FileName)" }
})

$Win.Add_Closing({
    $e = $args[1]
    if ($script:Busy -and -not $script:AutoClosing) {
        $r = Show-WsMessage -Text 'An operation is still running. Cancel it and quit?' -Title 'Windows Senior' -Buttons 'YesNo' -Icon 'Warning'
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
    }
    if ($script:Proc -and -not $script:Proc.HasExited) {
        & taskkill.exe /PID $script:Proc.Id /T /F *>$null
        try { [void]$script:Proc.WaitForExit(3000) } catch { Write-Verbose 'child already gone' }
    }
    $script:Timer.Stop()
    foreach ($tmp in @($script:ReportTmp, $(if ($script:OutFile) { "$script:OutFile.err" }))) {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    Save-GuiSettings
    if ($env:WINSENIOR_GUI_SMOKELOG) {
        try {
            $smoke = $W.TxtLog.Text + "`r`nSTATUS: " + $W.LblStatus.Text + "`r`n"
            [System.IO.File]::WriteAllText($env:WINSENIOR_GUI_SMOKELOG, $smoke, [System.Text.Encoding]::UTF8)
        } catch { Write-Verbose 'smoke log not written' }
    }
})

Add-Log "Windows Senior v$ver ready. $($script:CleanReg.Count) cleanup tasks, $($script:OptReg.Count) tweaks, $($script:RepReg.Count) checks."
if (-not (Test-AdminPrivileges)) { Add-Log 'WARNING: not running as Administrator - most actions will fail.' }

# =====================================================================
# AUTOMATION HOOKS (smoke tests) - see the header for the variables
# =====================================================================
if ($env:WINSENIOR_GUI_PAGE -and $W[$env:WINSENIOR_GUI_PAGE] -is [System.Windows.Controls.RadioButton]) {
    $Win.Add_ContentRendered({ $W[$env:WINSENIOR_GUI_PAGE].IsChecked = $true })
}
# Only read-only buttons may be pressed automatically - never Clean / Apply / Fix / Undo.
$script:SafeAutoRun = @('BtnScan', 'BtnOptPreview', 'BtnRepScan', 'BtnOptRefresh', 'BtnStartupRefresh', 'BtnHistRefresh', 'BtnBackupsRefresh', 'BtnSchedRefresh')
if ($env:WINSENIOR_GUI_AUTORUN) {
    if ($script:SafeAutoRun -contains $env:WINSENIOR_GUI_AUTORUN) {
        $Win.Add_ContentRendered({
            $W[$env:WINSENIOR_GUI_AUTORUN].RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        })
    } else { Add-Log "WINSENIOR_GUI_AUTORUN=$($env:WINSENIOR_GUI_AUTORUN) ignored (allowed: $($script:SafeAutoRun -join ', '))" }
}
# WINSENIOR_GUI_AUTOCANCEL=<s> presses Cancel that many seconds after the window shows.
if ($env:WINSENIOR_GUI_AUTOCANCEL) {
    $script:CancelTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:CancelTimer.Interval = [TimeSpan]::FromSeconds([double]$env:WINSENIOR_GUI_AUTOCANCEL)
    $script:CancelTimer.Add_Tick({ $script:CancelTimer.Stop(); Stop-Engine })
    $Win.Add_ContentRendered({ $script:CancelTimer.Start() })
}
if ($env:WINSENIOR_GUI_AUTOCLOSE) {
    $script:AutoStarted = Get-Date
    $script:AutoMaxWait = 600
    if ($env:WINSENIOR_GUI_MAXWAIT) { $script:AutoMaxWait = [double]$env:WINSENIOR_GUI_MAXWAIT }
    $script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AutoTimer.Interval = [TimeSpan]::FromSeconds([double]$env:WINSENIOR_GUI_AUTOCLOSE)
    $script:AutoTimer.Add_Tick({
        # Let a running engine finish (up to WINSENIOR_GUI_MAXWAIT seconds) before closing.
        if ($script:Busy -and ((Get-Date) - $script:AutoStarted).TotalSeconds -lt $script:AutoMaxWait) {
            $script:AutoTimer.Interval = [TimeSpan]::FromSeconds(1); return
        }
        $script:AutoTimer.Stop()
        if ($env:WINSENIOR_GUI_SCREENSHOT) {
            try {
                $Win.UpdateLayout()
                $root = $Win.Content
                $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]$root.ActualWidth), ([int]$root.ActualHeight), 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
                $bmp.Render($root)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
                $fs = [System.IO.File]::Create($env:WINSENIOR_GUI_SCREENSHOT)
                try { $enc.Save($fs) } finally { $fs.Dispose() }
            } catch { Add-Log "screenshot failed: $(Get-WsErrorText $_)" }
        }
        $script:AutoClosing = $true
        $Win.Close()
    })
    $script:AutoTimer.Start()
}

try {
    [void]$Win.ShowDialog()
}
catch {
    $crash = Write-CrashLog $_ 'window'
    try {
        [System.Windows.MessageBox]::Show(("Windows Senior stopped because of an unexpected error:`n`n{0}`n`nDetails were written to:`n{1}" -f (Get-WsErrorText $_), $crash),
            'Windows Senior', 'OK', 'Error') | Out-Null
    } catch { Write-Verbose 'no message box' }
}
finally {
    if ($script:Proc -and -not $script:Proc.HasExited) { & taskkill.exe /PID $script:Proc.Id /T /F *>$null }
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { Write-Verbose 'mutex not owned' }; $script:Mutex.Dispose() }
}
