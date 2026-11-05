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
$script:DriversScript  = Join-Path $script:Root 'WinSenior.Drivers.ps1'
$script:AppsScript     = Join-Path $script:Root 'WinSenior.Apps.ps1'
$script:MemoryScript   = Join-Path $script:Root 'WinSenior.Memory.ps1'
$script:InsightsScript = Join-Path $script:Root 'WinSenior.Insights.ps1'

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

# Uptime + dark window title bar (Windows 10 1809+ / 11).
try {
    if (-not ('WinSenior.GuiNative' -as [type])) {
        Add-Type -Namespace WinSenior -Name GuiNative -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
[DllImport("dwmapi.dll")]   public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@ -ErrorAction SilentlyContinue
    }
} catch { Write-Verbose 'native helpers unavailable' }

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
if (-not ('WinSenior.GuiRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace WinSenior {
    public class GuiRow : INotifyPropertyChanged {
        string _id="", _name="", _group="", _risk="", _size="", _state="", _detail="", _explain="", _tip="", _info="";
        string _groupLabel="", _riskLabel="", _stateLabel="";
        bool _selected, _enabled = true; long _bytes; int _rank, _order;
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
        // Display texts in the UI language; Group/Risk/State keep the raw values the styles key on.
        public string GroupLabel { get { return _groupLabel; } set { if (_groupLabel == S(value)) return; _groupLabel = S(value); On("GroupLabel"); } }
        public string RiskLabel  { get { return _riskLabel; }  set { if (_riskLabel == S(value)) return; _riskLabel = S(value); On("RiskLabel"); } }
        public string StateLabel { get { return _stateLabel; } set { if (_stateLabel == S(value)) return; _stateLabel = S(value); On("StateLabel"); } }
        public int    Order   { get { return _order; }   set { if (_order == value) return; _order = value; On("Order"); } }
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
        # An elevated run created gui-settings.json; ordinary users may only read it.
        $existing = Join-Path $script:SettingsDir 'gui-settings.json'
        if (Test-Path -LiteralPath $existing) { [System.IO.File]::Open($existing, 'Open', 'Write', 'ReadWrite').Dispose() }
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
        Language = 'auto'; LogOpen = $false; LogHeight = 220; CleanOptionsOpen = $false
        WinLeft = $null; WinTop = $null; WinWidth = $null; WinHeight = $null; WinMax = $false
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
    if (-not $script:CleanRows -or -not $script:OptRows) { return $false }
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
            Language         = [string]$script:LangSetting
            LogOpen          = [bool]$script:LogOpen
            LogHeight        = [int]$script:LogHeight
            CleanOptionsOpen = ($W.PanelCleanOptions.Visibility -eq 'Visible')
            WinLeft          = $null; WinTop = $null; WinWidth = $null; WinHeight = $null
            WinMax           = ($Win.WindowState -eq 'Maximized')
        }
        # Remember the normal (restored) window bounds, also when closed maximized.
        $b = $Win.RestoreBounds
        if (-not $b.IsEmpty -and $b.Width -gt 0) {
            $o.WinLeft = [int]$b.Left; $o.WinTop = [int]$b.Top; $o.WinWidth = [int]$b.Width; $o.WinHeight = [int]$b.Height
        }
        ($o | ConvertTo-Json -Depth 4) | Set-Content -Path $script:SettingsFile -Encoding UTF8
        return $true
    } catch { Write-Verbose "settings not saved: $($_.Exception.Message)"; return $false }
}

# =====================================================================
# LANGUAGE
# English is the source text and the key: T 'Scan' returns the translation from
# WinSenior.Gui.<lang>.json, or the English text when there is none. The JSON is
# read explicitly as UTF-8, so this script stays pure ASCII.
# =====================================================================
$script:Tr    = $null
$script:TrReg = @{}
$script:Lang  = 'en'

function T {
    param([string]$Text)
    if ($script:Tr -and $Text -and $script:Tr.ContainsKey($Text)) { return $script:Tr[$Text] }
    $Text
}

# Display text for a registry entry (tasks / tweaks / checks), English fallback.
function Get-WsRegText {
    param([string]$Kind, [string]$Id, [string]$Field, [string]$Default)
    $k = $script:TrReg[$Kind]
    if ($k -and $k.ContainsKey($Id)) {
        $v = $k[$Id]
        if ($v -and $v.PSObject.Properties[$Field] -and [string]$v.$Field) { return [string]$v.$Field }
    }
    $Default
}

# 'auto' follows the Windows display language; anything unknown falls back to English.
function Resolve-WsLanguage {
    param([string]$Setting, [string]$UiCulture)
    if ($Setting -in 'en', 'ru') { return $Setting }
    if ($UiCulture -match '^ru(-|$)') { return 'ru' }
    'en'
}

# Case-sensitive dictionaries: "None" (button) and "none" (group link) differ.
function Import-WsLanguage {
    param([string]$Path)
    $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $ui = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    if ($json.ui) { foreach ($p in $json.ui.PSObject.Properties) { $ui[$p.Name] = [string]$p.Value } }
    if ($json.groups) { foreach ($p in $json.groups.PSObject.Properties) { if (-not $ui.ContainsKey($p.Name)) { $ui[$p.Name] = [string]$p.Value } } }
    $reg = @{}
    foreach ($kind in 'tasks', 'tweaks', 'checks') {
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        if ($json.$kind) { foreach ($p in $json.$kind.PSObject.Properties) { $d[$p.Name] = $p.Value } }
        $reg[$kind] = $d
    }
    [pscustomobject]@{ Ui = $ui; Reg = $reg }
}

# Format-FileSize with the unit in the UI language (GB -> its translation).
function Format-WsSize {
    param([int64]$Bytes)
    $s = Format-FileSize $Bytes
    $m = [regex]::Match([string]$s, '^(?<n>.*) (?<u>B|KB|MB|GB|TB)$')
    if ($m.Success) { return ($m.Groups['n'].Value + ' ' + (T $m.Groups['u'].Value)) }
    $s
}

$script:LangSetting = [string](Get-GuiSettings).Language
if (-not $script:LangSetting) { $script:LangSetting = 'auto' }
$script:Lang = Resolve-WsLanguage -Setting $script:LangSetting -UiCulture ([System.Globalization.CultureInfo]::CurrentUICulture.Name)
if ($script:Lang -ne 'en') {
    $langFile = Join-Path $script:Root "WinSenior.Gui.$($script:Lang).json"
    try {
        $pack = Import-WsLanguage $langFile
        $script:Tr = $pack.Ui; $script:TrReg = $pack.Reg
    } catch {
        Write-Verbose "language pack not loaded: $($_.Exception.Message)"
        $script:Lang = 'en'
    }
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
            $freed = Format-WsSize $b
            $result = if ($dry) { (T 'Would free {0}') -f $freed } else { (T 'Freed {0}') -f $freed }
            if ($s -and $null -ne $s.TotalFiles) { $result += (T ' ({0} items)') -f $s.TotalFiles }
            if (-not $dry) { $bytes = $b }
            if ($s -and $null -ne $s.TotalErrors) { $errors = [int]$s.TotalErrors }
        }
        'Optimize' {
            if ($dry) { $result = (T 'Would apply {0} tweak(s)') -f @($items | Where-Object { $_.Result -eq 'would-apply' }).Count }
            else {
                $result = (T 'Applied {0}, skipped {1}') -f [int]$s.Applied, [int]$s.Skipped
            }
            if ($s -and $null -ne $s.Errors) { $errors = [int]$s.Errors }
        }
        'Repair' {
            $fail = @($items | Where-Object { $_.Status -eq 'Fail' }).Count
            $warn = @($items | Where-Object { $_.Status -eq 'Warn' }).Count
            $result = (T '{0} failing, {1} warning') -f $fail, $warn
            if ($s -and [int]$s.Fixed -gt 0) { $result += (T ', fixed {0}') -f [int]$s.Fixed }
            if ($s -and $s.Reboot) { $result += (T ' (reboot needed)') }
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
        Title="Windows Senior" Width="1240" Height="820" MinWidth="980" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="#15161A" FontFamily="Segoe UI" FontSize="13"
        Foreground="#ECEDF0" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"         Color="#15161A"/>
    <SolidColorBrush x:Key="Side"       Color="#1B1C21"/>
    <SolidColorBrush x:Key="Card"       Color="#212228"/>
    <SolidColorBrush x:Key="Card2"      Color="#282930"/>
    <SolidColorBrush x:Key="Hover"      Color="#32333C"/>
    <SolidColorBrush x:Key="Line"       Color="#30323A"/>
    <SolidColorBrush x:Key="Line2"      Color="#25262D"/>
    <SolidColorBrush x:Key="Accent"     Color="#4C8DFF"/>
    <SolidColorBrush x:Key="AccentHi"   Color="#6EA3FF"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#1F3256"/>
    <SolidColorBrush x:Key="Text"       Color="#ECEDF0"/>
    <SolidColorBrush x:Key="Muted"      Color="#9AA0AB"/>
    <SolidColorBrush x:Key="Faint"      Color="#6B707B"/>
    <SolidColorBrush x:Key="Ok"         Color="#3DD68C"/>
    <SolidColorBrush x:Key="Warn"       Color="#F2B33D"/>
    <SolidColorBrush x:Key="Bad"        Color="#FF6B6B"/>
    <!-- Dark corner between two scroll bars (ScrollViewer paints it with ControlBrush). -->
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#212228"/>

    <!-- Strings used inside templates (set from code for the UI language). -->
    <system:String xmlns:system="clr-namespace:System;assembly=mscorlib" x:Key="S_GroupAll">select all</system:String>
    <system:String xmlns:system="clr-namespace:System;assembly=mscorlib" x:Key="S_GroupNone">select none</system:String>
    <system:String xmlns:system="clr-namespace:System;assembly=mscorlib" x:Key="S_NextRun">Next run</system:String>
    <system:String xmlns:system="clr-namespace:System;assembly=mscorlib" x:Key="S_LastRun">Last run</system:String>

    <Style x:Key="Ico" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>

    <!-- BUTTONS -->
    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Card2}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Hover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{StaticResource AccentHi}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource AccentHi}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="White"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#3A1F24"/>
      <Setter Property="BorderBrush" Value="#6A2C33"/>
      <Setter Property="Foreground" Value="#FF9A9A"/>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource AccentHi}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Margin" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource AccentSoft}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Clickable card (Home tiles). -->
    <Style x:Key="CardButton" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,12,0"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{StaticResource Card}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10" Padding="16,14">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Top" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Card2}"/>
                <Setter TargetName="B" Property="BorderBrush" Value="#3C3F49"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- NAVIGATION (Tag = icon glyph) -->
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Padding="12,9" Margin="10,1" CornerRadius="7" Background="Transparent">
              <DockPanel>
                <Border x:Name="Bar" Width="3" Height="16" CornerRadius="2" Background="{StaticResource Accent}" Margin="-12,0,9,0" Visibility="Hidden"/>
                <TextBlock x:Name="Ico" Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="15" Width="20" VerticalAlignment="Center"/>
                <ContentPresenter VerticalAlignment="Center" Margin="10,0,0,0" RecognizesAccessKey="False"/>
              </DockPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Card2}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource AccentSoft}"/>
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Ico" Property="Foreground" Value="{StaticResource AccentHi}"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavSection" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Faint}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="24,14,0,6"/>
    </Style>
    <!-- Segmented choice (language). -->
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Padding="14,7" CornerRadius="6" Background="Transparent" Margin="2">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Hover}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- CHECKBOX + SWITCH -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#5A5E69" Background="Transparent" VerticalAlignment="Center">
                <TextBlock x:Name="Mark" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="White"
                           HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter x:Name="CP" Grid.Column="1" Margin="9,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentHi}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="White"/></Trigger>
              <Trigger Property="Content" Value="{x:Null}"><Setter TargetName="CP" Property="Margin" Value="0"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="38" Height="20" CornerRadius="10" Background="Transparent" BorderBrush="#6B707B" BorderThickness="1.5">
              <Ellipse x:Name="Knob" Width="11" Height="11" Fill="#9AA0AB" HorizontalAlignment="Left" Margin="4,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,4,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Track" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- TEXT INPUT -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Card2}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="7,5"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Search box: magnifier + Tag as a hint while empty. -->
    <Style x:Key="FilterBox" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="Width" Value="280"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7">
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{StaticResource Faint}" VerticalAlignment="Center" Margin="10,0,0,0"/>
                <Grid>
                  <ScrollViewer x:Name="PART_ContentHost" Margin="4,6,6,6" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Hint" Text="{TemplateBinding Tag}" Foreground="{StaticResource Faint}" Margin="7,0,0,0"
                             VerticalAlignment="Center" IsHitTestVisible="False" Visibility="Collapsed" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </DockPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value=""><Setter TargetName="Hint" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- SCROLL BARS -->
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb"><Border x:Name="T" Background="#454852" CornerRadius="4"/>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="#5D616D"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="12"/>
      <Setter Property="MinWidth" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="{TemplateBinding Background}">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}" Margin="3,2"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="12"/>
          <Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="{TemplateBinding Background}">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}" Margin="2,3"/></Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- PROGRESS / METER (indeterminate pulses) -->
    <Style x:Key="Meter" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="#30323B"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="3" Background="{TemplateBinding Background}"/>
              <Border x:Name="PART_Indicator" CornerRadius="3" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsIndeterminate" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard x:Name="Pulse">
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="PART_Indicator" Storyboard.TargetProperty="Opacity"
                                       From="1" To="0.25" Duration="0:0:0.8" AutoReverse="True" RepeatBehavior="Forever"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions><StopStoryboard BeginStoryboardName="Pulse"/></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="MaxWidth" Value="620"/>
      <Setter Property="Background" Value="#2A2B33"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="#454852"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="ContentTemplate">
        <Setter.Value>
          <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap"/></DataTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- LISTS -->
    <Style TargetType="ListView">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="VirtualizingPanel.IsVirtualizingWhenGrouping" Value="True"/>
      <Setter Property="VirtualizingPanel.ScrollUnit" Value="Pixel"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListView">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="1">
              <ScrollViewer Style="{DynamicResource {x:Static GridView.GridViewScrollViewerStyleKey}}" Focusable="False">
                <ItemsPresenter/>
              </ScrollViewer>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Padding" Value="2,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="ToolTip" Value="{Binding Tip}"/>
      <Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="ToolTipService.InitialShowDelay" Value="500"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{StaticResource Line2}" BorderThickness="0,0,0,1" Padding="{TemplateBinding Padding}">
              <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Tip}" Value=""><Setter Property="ToolTip" Value="{x:Null}"/></DataTrigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#272830"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{StaticResource AccentSoft}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,9"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center" RecognizesAccessKey="False"/>
              </Border>
              <Thumb x:Name="PART_HeaderGripper" HorizontalAlignment="Right" Width="9" Margin="0,0,-5,0" Cursor="SizeWE">
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb"><Border Background="Transparent"><Rectangle Width="1" Fill="{StaticResource Line}" Margin="0,9"/></Border></ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource Card2}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Category groups: collapsible header with "all / none". -->
    <Style x:Key="GroupExpander" TargetType="Expander">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <DockPanel>
              <ToggleButton DockPanel.Dock="Top" Cursor="Hand" Focusable="False" Content="{TemplateBinding Header}"
                            IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Hd" Background="#1C1D23" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="10,6">
                      <DockPanel>
                        <TextBlock x:Name="Chev" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="{StaticResource Muted}"/>
                        <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Stretch" RecognizesAccessKey="False"/>
                      </DockPanel>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsChecked" Value="False"><Setter TargetName="Chev" Property="Text" Value="&#xE76C;"/></Trigger>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hd" Property="Background" Value="#22232A"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="Body" Visibility="Collapsed"/>
            </DockPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True"><Setter TargetName="Body" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <GroupStyle x:Key="Groups">
      <GroupStyle.ContainerStyle>
        <Style TargetType="GroupItem">
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="GroupItem">
                <Expander IsExpanded="True" Style="{StaticResource GroupExpander}">
                  <Expander.Header>
                    <DockPanel>
                      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                        <Button Style="{StaticResource Link}" Tag="grp-all"  Content="{DynamicResource S_GroupAll}"  Padding="6,1" FontSize="12"/>
                        <Button Style="{StaticResource Link}" Tag="grp-none" Content="{DynamicResource S_GroupNone}" Padding="6,1" FontSize="12"/>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                        <Border Background="{StaticResource Card2}" CornerRadius="8" Padding="7,0" Margin="9,0,0,0" VerticalAlignment="Center">
                          <TextBlock Text="{Binding ItemCount}" FontSize="11" Foreground="{StaticResource Muted}"/>
                        </Border>
                      </StackPanel>
                    </DockPanel>
                  </Expander.Header>
                  <ItemsPresenter/>
                </Expander>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
      </GroupStyle.ContainerStyle>
    </GroupStyle>

    <!-- Static-page card (Undo / Settings). -->
    <Style TargetType="GroupBox">
      <Setter Property="Margin" Value="0,0,0,14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GroupBox">
            <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10" Padding="18,14,18,16">
              <DockPanel>
                <ContentPresenter DockPanel.Dock="Top" ContentSource="Header" Margin="0,0,0,10" RecognizesAccessKey="False"
                                  TextElement.FontSize="15" TextElement.FontWeight="SemiBold" TextElement.Foreground="{StaticResource Text}"/>
                <ContentPresenter/>
              </DockPanel>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="16,14"/>
    </Style>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="24"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="Margin" Value="0,0,0,14"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Faint}"/><Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Big" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,4,0,2"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="Sep" TargetType="Border">
      <Setter Property="Width" Value="1"/><Setter Property="Height" Value="22"/><Setter Property="Background" Value="{StaticResource Line}"/>
      <Setter Property="Margin" Value="4,0,12,0"/><Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- CELLS -->
    <DataTemplate x:Key="RiskCell">
      <Border CornerRadius="9" Padding="8,1" HorizontalAlignment="Left">
        <Border.Style>
          <Style TargetType="Border">
            <Setter Property="Background" Value="#30323B"/>
            <Style.Triggers>
              <DataTrigger Binding="{Binding Risk}" Value="Safe"><Setter Property="Background" Value="#17392A"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Moderate"><Setter Property="Background" Value="#3B3217"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Aggressive"><Setter Property="Background" Value="#43281A"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Dangerous"><Setter Property="Background" Value="#4A1E23"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value=""><Setter Property="Background" Value="Transparent"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </Border.Style>
        <TextBlock Text="{Binding RiskLabel}" FontSize="11.5">
          <TextBlock.Style>
            <Style TargetType="TextBlock">
              <Setter Property="Foreground" Value="{StaticResource Muted}"/>
              <Style.Triggers>
                <DataTrigger Binding="{Binding Risk}" Value="Safe"><Setter Property="Foreground" Value="#5BE3A0"/></DataTrigger>
                <DataTrigger Binding="{Binding Risk}" Value="Moderate"><Setter Property="Foreground" Value="#F2C14E"/></DataTrigger>
                <DataTrigger Binding="{Binding Risk}" Value="Aggressive"><Setter Property="Foreground" Value="#FF9F5A"/></DataTrigger>
                <DataTrigger Binding="{Binding Risk}" Value="Dangerous"><Setter Property="Foreground" Value="#FF7A7A"/></DataTrigger>
              </Style.Triggers>
            </Style>
          </TextBlock.Style>
        </TextBlock>
      </Border>
    </DataTemplate>
    <DataTemplate x:Key="StateCell">
      <StackPanel Orientation="Horizontal">
        <Ellipse x:Name="Dot" Width="8" Height="8" Margin="0,0,7,0" VerticalAlignment="Center" Fill="Transparent"/>
        <TextBlock x:Name="Txt" Text="{Binding StateLabel}" Foreground="{StaticResource Muted}"/>
      </StackPanel>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding State}" Value="OK"><Setter TargetName="Dot" Property="Fill" Value="#3DD68C"/><Setter TargetName="Txt" Property="Foreground" Value="#3DD68C"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="Warn"><Setter TargetName="Dot" Property="Fill" Value="#F2B33D"/><Setter TargetName="Txt" Property="Foreground" Value="#F2B33D"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="Fail"><Setter TargetName="Dot" Property="Fill" Value="#FF6B6B"/><Setter TargetName="Txt" Property="Foreground" Value="#FF6B6B"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="applied"><Setter TargetName="Dot" Property="Fill" Value="#3DD68C"/><Setter TargetName="Txt" Property="Foreground" Value="#3DD68C"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="not applied"><Setter TargetName="Dot" Property="Fill" Value="#5A5E69"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="Enabled"><Setter TargetName="Dot" Property="Fill" Value="#3DD68C"/><Setter TargetName="Txt" Property="Foreground" Value="#3DD68C"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="Disabled"><Setter TargetName="Dot" Property="Fill" Value="#5A5E69"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="Ready"><Setter TargetName="Dot" Property="Fill" Value="#3DD68C"/><Setter TargetName="Txt" Property="Foreground" Value="#3DD68C"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="Running"><Setter TargetName="Dot" Property="Fill" Value="#4C8DFF"/><Setter TargetName="Txt" Property="Foreground" Value="#6EA3FF"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="undone"><Setter TargetName="Dot" Property="Fill" Value="#5A5E69"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="Skip"><Setter TargetName="Dot" Property="Fill" Value="#5A5E69"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="active"><Setter TargetName="Dot" Property="Fill" Value="#3DD68C"/><Setter TargetName="Txt" Property="Foreground" Value="#3DD68C"/></DataTrigger>
        <DataTrigger Binding="{Binding State}" Value="unreadable"><Setter TargetName="Dot" Property="Fill" Value="#FF6B6B"/></DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>
    <DataTemplate x:Key="CheckCell">
      <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding Enabled}" Margin="4,0,0,0"/>
    </DataTemplate>
    <DataTemplate x:Key="SwitchCell">
      <CheckBox Style="{StaticResource Switch}" IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding Enabled}" Margin="4,0,0,0"/>
    </DataTemplate>
    <DataTemplate x:Key="NameCell">
      <TextBlock Text="{Binding Name}" TextTrimming="CharacterEllipsis"/>
    </DataTemplate>
    <DataTemplate x:Key="SizeCell">
      <TextBlock Text="{Binding Size}" TextAlignment="Right" Foreground="{StaticResource Text}" Margin="0,0,6,0"/>
    </DataTemplate>
    <DataTemplate x:Key="DetailCell">
      <TextBlock Text="{Binding Detail}" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis"/>
    </DataTemplate>
    <DataTemplate x:Key="InfoCell">
      <TextBlock Text="{Binding Info}" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis"/>
    </DataTemplate>
  </Window.Resources>

  <Grid Background="{StaticResource Bg}">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="228"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- SIDEBAR -->
    <Border Grid.Column="0" Background="{StaticResource Side}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="22,22,16,14">
          <Border Width="36" Height="36" CornerRadius="9" Background="{StaticResource Accent}">
            <TextBlock Text="&#xEA18;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Windows Senior" FontSize="16" FontWeight="Bold"/>
            <TextBlock x:Name="LblVersion" Text="v" Foreground="{StaticResource Faint}" FontSize="11"/>
          </StackPanel>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="14,0,14,16">
          <Border x:Name="AdminChip" CornerRadius="8" Padding="10,8" Background="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="AdminDot" Width="8" Height="8" Fill="#3DD68C" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock x:Name="LblAdmin" Text="" FontSize="12" TextWrapping="Wrap"/>
              </StackPanel>
              <TextBlock x:Name="LblHost" Text="" FontSize="11" Foreground="{StaticResource Faint}" Margin="16,2,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <RadioButton x:Name="NavHome"     Style="{StaticResource Nav}" Tag="&#xE80F;" Content="Overview" IsChecked="True" Margin="0,4,0,0"/>
            <TextBlock Style="{StaticResource NavSection}" Text="MAINTENANCE"/>
            <RadioButton x:Name="NavClean"    Style="{StaticResource Nav}" Tag="&#xE74D;" Content="Disk cleanup"/>
            <RadioButton x:Name="NavOpt"      Style="{StaticResource Nav}" Tag="&#xE945;" Content="Optimize"/>
            <RadioButton x:Name="NavRepair"   Style="{StaticResource Nav}" Tag="&#xE90F;" Content="Troubleshoot"/>
            <RadioButton x:Name="NavStartup"  Style="{StaticResource Nav}" Tag="&#xE7E8;" Content="Startup apps"/>
            <TextBlock Style="{StaticResource NavSection}" Text="TOOLS"/>
            <RadioButton x:Name="NavDrivers"  Style="{StaticResource Nav}" Tag="&#xE772;" Content="Drivers"/>
            <RadioButton x:Name="NavApps"     Style="{StaticResource Nav}" Tag="&#xE71D;" Content="Apps"/>
            <RadioButton x:Name="NavMemory"   Style="{StaticResource Nav}" Tag="&#xE964;" Content="Smart memory"/>
            <RadioButton x:Name="NavInsights" Style="{StaticResource Nav}" Tag="&#xE9D9;" Content="Insights"/>
            <TextBlock Style="{StaticResource NavSection}" Text="SAFETY &amp; HISTORY"/>
            <RadioButton x:Name="NavHistory"  Style="{StaticResource Nav}" Tag="&#xE81C;" Content="History"/>
            <RadioButton x:Name="NavUndo"     Style="{StaticResource Nav}" Tag="&#xE7A7;" Content="Undo &amp; restore"/>
            <RadioButton x:Name="NavSchedule" Style="{StaticResource Nav}" Tag="&#xE787;" Content="Schedule"/>
            <TextBlock Style="{StaticResource NavSection}" Text="APPLICATION"/>
            <RadioButton x:Name="NavAbout"    Style="{StaticResource Nav}" Tag="&#xE713;" Content="Settings &amp; about"/>
          </StackPanel>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- MAIN -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*" MinHeight="220"/>
        <RowDefinition x:Name="SplitRow" Height="0"/>
        <RowDefinition x:Name="LogRow" Height="0"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Not-admin banner -->
      <Border x:Name="BannerAdmin" Grid.Row="0" Background="#3A2E14" BorderBrush="#5C4A1E" BorderThickness="0,0,0,1" Padding="26,10" Visibility="Collapsed">
        <DockPanel>
          <Button x:Name="BtnElevate" DockPanel.Dock="Right" Style="{StaticResource Primary}" Margin="0" Padding="12,6">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xEA18;" FontSize="12"/><TextBlock Text="Restart as administrator"/></StackPanel>
          </Button>
          <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Warn}" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock Text="Running without administrator rights - cleaning system folders, tweaks and repairs will fail." VerticalAlignment="Center" TextWrapping="Wrap" Foreground="#F5D58A" Margin="0,0,12,0"/>
        </DockPanel>
      </Border>

      <!-- Result banner (after a run) -->
      <Border x:Name="BannerResult" Grid.Row="1" Margin="26,16,26,0" CornerRadius="9" Padding="14,10" BorderThickness="1" Visibility="Collapsed"
              Background="#16332A" BorderBrush="#245A45">
        <DockPanel>
          <Button x:Name="BtnBannerClose" DockPanel.Dock="Right" Style="{StaticResource Link}" Foreground="{StaticResource Muted}" ToolTip="Dismiss">
            <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="11"/>
          </Button>
          <Button x:Name="BtnBannerLog" DockPanel.Dock="Right" Style="{StaticResource Link}" Content="Show log" Margin="0,0,6,0"/>
          <TextBlock x:Name="BannerIcon" Text="&#xE930;" FontFamily="Segoe MDL2 Assets" FontSize="16" VerticalAlignment="Center" Margin="0,0,12,0" Foreground="{StaticResource Ok}"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="LblBanner" Text="" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock x:Name="LblBannerSub" Text="" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid Grid.Row="2" Margin="26,18,26,12">
        <!-- HOME -->
        <ScrollViewer x:Name="PageHome" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource H1}" Text="Overview"/>
            <TextBlock x:Name="LblHomeSub" Style="{StaticResource Sub}" Text=""/>

            <!-- Smart scan hero -->
            <Border Style="{StaticResource Panel}" Padding="22,20" Margin="0,0,0,14">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#1F2A44" Offset="0"/>
                  <GradientStop Color="#212228" Offset="0.75"/>
                </LinearGradientBrush>
              </Border.Background>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,18,0">
                  <TextBlock x:Name="LblHeroTitle" Text="Check this PC" FontSize="19" FontWeight="SemiBold"/>
                  <TextBlock x:Name="LblHeroSub" Style="{StaticResource Sub}" Margin="0,4,0,0"
                             Text="Smart scan measures the junk the cleanup would remove and runs the read-only health checks. Nothing is changed until you confirm."/>
                </StackPanel>
                <Button x:Name="BtnHomeScan" Grid.Column="1" Style="{StaticResource Primary}" Padding="22,12" Margin="0" VerticalAlignment="Center" FontSize="14">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE721;"/><TextBlock Text="Smart scan"/></StackPanel>
                </Button>
              </Grid>
            </Border>

            <!-- Scan results -->
            <Grid x:Name="PanelHomeResults" Margin="0,0,0,14" Visibility="Collapsed">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Border Style="{StaticResource Panel}" Margin="0,0,7,0">
                <DockPanel>
                  <Button x:Name="BtnHomeClean" DockPanel.Dock="Right" Style="{StaticResource Primary}" Margin="12,0,0,0" VerticalAlignment="Center" IsEnabled="False">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE74D;"/><TextBlock Text="Clean now"/></StackPanel>
                  </Button>
                  <StackPanel>
                    <TextBlock Style="{StaticResource Label}" Text="JUNK FOUND"/>
                    <TextBlock x:Name="LblHomeJunk" Style="{StaticResource Big}" Text="-"/>
                    <TextBlock x:Name="LblHomeJunkSub" Style="{StaticResource Hint}" Text=""/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Panel}" Margin="7,0,0,0">
                <DockPanel>
                  <Button x:Name="BtnHomeReview" DockPanel.Dock="Right" Margin="12,0,0,0" VerticalAlignment="Center" IsEnabled="False">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE90F;"/><TextBlock Text="Review"/></StackPanel>
                  </Button>
                  <StackPanel>
                    <TextBlock Style="{StaticResource Label}" Text="SYSTEM HEALTH"/>
                    <TextBlock x:Name="LblHomeHealth" Style="{StaticResource Big}" Text="-"/>
                    <TextBlock x:Name="LblHomeHealthSub" Style="{StaticResource Hint}" Text=""/>
                  </StackPanel>
                </DockPanel>
              </Border>
            </Grid>

            <!-- Status tiles -->
            <UniformGrid Columns="4" Margin="0,0,-12,14">
              <Button x:Name="BtnCardDrives" Style="{StaticResource CardButton}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xEDA2;" Foreground="{StaticResource AccentHi}"/><TextBlock Style="{StaticResource Label}" Text="DRIVES"/></StackPanel>
                  <StackPanel x:Name="PanelHomeDrives" Margin="0,8,0,0"/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnCardClean" Style="{StaticResource CardButton}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE74D;" Foreground="{StaticResource AccentHi}"/><TextBlock Style="{StaticResource Label}" Text="LAST CLEANUP"/></StackPanel>
                  <TextBlock x:Name="LblHomeClean" Style="{StaticResource Big}" Text="-"/>
                  <TextBlock x:Name="LblHomeCleanSub" Style="{StaticResource Hint}" Text=""/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnCardOpt" Style="{StaticResource CardButton}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE945;" Foreground="{StaticResource AccentHi}"/><TextBlock Style="{StaticResource Label}" Text="OPTIMIZATION"/></StackPanel>
                  <TextBlock x:Name="LblHomeOpt" Style="{StaticResource Big}" Text="-"/>
                  <TextBlock x:Name="LblHomeOptSub" Style="{StaticResource Hint}" Text=""/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnCardStartup" Style="{StaticResource CardButton}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE7E8;" Foreground="{StaticResource AccentHi}"/><TextBlock Style="{StaticResource Label}" Text="AUTOSTART"/></StackPanel>
                  <TextBlock x:Name="LblHomeStartup" Style="{StaticResource Big}" Text="-"/>
                  <TextBlock x:Name="LblHomeStartupSub" Style="{StaticResource Hint}" Text=""/>
                </StackPanel>
              </Button>
            </UniformGrid>

            <!-- Recent activity -->
            <Border Style="{StaticResource Panel}">
              <StackPanel>
                <DockPanel Margin="0,0,0,8">
                  <Button x:Name="BtnHomeHistory" DockPanel.Dock="Right" Style="{StaticResource Link}" Content="All history"/>
                  <TextBlock Text="Recent activity" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
                </DockPanel>
                <TextBlock x:Name="LblHomeNoRecent" Style="{StaticResource Hint}" Text="No runs yet. Reports of every scan, cleanup and repair will show up here." Margin="0,2,0,4"/>
                <ItemsControl x:Name="IcHomeRecent">
                  <ItemsControl.ItemTemplate>
                    <DataTemplate>
                      <Border BorderBrush="{StaticResource Line2}" BorderThickness="0,1,0,0" Padding="0,8">
                        <Grid>
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="140"/><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/>
                          </Grid.ColumnDefinitions>
                          <TextBlock Text="{Binding Name}" Foreground="{StaticResource Muted}"/>
                          <TextBlock Grid.Column="1" Text="{Binding GroupLabel}" FontWeight="SemiBold"/>
                          <TextBlock Grid.Column="2" Text="{Binding Size}" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                      </Border>
                    </DataTemplate>
                  </ItemsControl.ItemTemplate>
                </ItemsControl>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- CLEANUP -->
        <DockPanel x:Name="PageClean" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Disk cleanup"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Scan measures what each task would free - nothing is deleted. Clean removes the ticked tasks. Hover a task to see exactly which folders it touches."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <Button x:Name="BtnScan">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE721;"/><TextBlock Text="Scan"/></StackPanel>
            </Button>
            <Button x:Name="BtnClean" Style="{StaticResource Primary}">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE74D;"/><TextBlock Text="Clean now"/></StackPanel>
            </Button>
            <Border Style="{StaticResource Sep}"/>
            <Button x:Name="BtnCleanOptions">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE713;"/><TextBlock Text="Options"/></StackPanel>
            </Button>
          </WrapPanel>

          <Border x:Name="PanelCleanOptions" DockPanel.Dock="Top" Style="{StaticResource Panel}" Margin="0,0,0,10" Visibility="Collapsed">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <StackPanel Margin="0,0,14,12">
                  <CheckBox x:Name="ChkRestore" Content="Restore point first" IsChecked="True"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="27,2,0,0" Text="A System Restore snapshot before anything is deleted."/>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="0,0,14,12">
                  <CheckBox x:Name="ChkCloseApps" Content="Close running browsers first" IsChecked="True"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="27,2,0,0" Text="Unticked: caches of running browsers are skipped."/>
                </StackPanel>
                <StackPanel Grid.Column="2" Margin="0,0,0,12">
                  <CheckBox x:Name="ChkDefer" Content="Delete locked files at reboot" IsChecked="True"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="27,2,0,0" Text="Files in use are queued and removed on the next restart."/>
                </StackPanel>
                <StackPanel Grid.Row="1" Margin="0,0,14,4">
                  <CheckBox x:Name="ChkConservative" Content="Conservative mode"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="27,2,0,0" Text="Only Safe and Moderate tasks run, even if others are ticked."/>
                </StackPanel>
                <StackPanel Grid.Row="1" Grid.Column="1" Margin="0,0,14,4">
                  <CheckBox x:Name="ChkCurrentUser" Content="Current user only"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="27,2,0,0" Text="Leave other Windows accounts untouched."/>
                </StackPanel>
                <StackPanel Grid.Row="1" Grid.Column="2" Margin="0,0,0,4">
                  <CheckBox x:Name="ChkSkipOpt" Content="Skip SFC / DISM"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="27,2,0,0" Text="Leave out the slow component-store tasks."/>
                </StackPanel>
              </Grid>
              <Border Height="1" Background="{StaticResource Line}" Margin="0,10,0,12"/>
              <WrapPanel>
                <TextBlock Text="Only files older than" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,0,8,0"/>
                <TextBox x:Name="TxtMaxAge" Width="56" Text="0" ToolTip="0 = no age filter. Whole days, 0 to 3650." HorizontalContentAlignment="Center"/>
                <TextBlock Text="days" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="8,0,28,0"/>
                <TextBlock Text="Drives:" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,0,10,0"/>
                <WrapPanel x:Name="PanelDrives" VerticalAlignment="Center"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <TextBox x:Name="TxtCleanFilter" DockPanel.Dock="Right" Style="{StaticResource FilterBox}" Tag="Search tasks"/>
            <WrapPanel VerticalAlignment="Center">
              <TextBlock Text="Select:" Style="{StaticResource Label}" VerticalAlignment="Center" Margin="2,0,4,0"/>
              <Button x:Name="BtnCleanDef"  Style="{StaticResource Link}" Content="Recommended"/>
              <Button x:Name="BtnCleanSafe" Style="{StaticResource Link}" Content="Safe only"/>
              <Button x:Name="BtnCleanAll"  Style="{StaticResource Link}" Content="All"/>
              <Button x:Name="BtnCleanNone" Style="{StaticResource Link}" Content="None"/>
            </WrapPanel>
          </DockPanel>
          <Border DockPanel.Dock="Bottom" Style="{StaticResource Panel}" Margin="0,10,0,0" Padding="16,10">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Estimated:" Style="{StaticResource Label}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock x:Name="LblCleanEstimate" Text="-" FontSize="18" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </StackPanel>
              <TextBlock x:Name="LblCleanStatus" VerticalAlignment="Center" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
            </DockPanel>
          </Border>
          <ListView x:Name="LvClean">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="40" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Task" Width="420" CellTemplate="{StaticResource NameCell}"/>
                <GridViewColumn Header="Risk" Width="120" CellTemplate="{StaticResource RiskCell}"/>
                <GridViewColumn Header="Would free" Width="140" CellTemplate="{StaticResource SizeCell}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- OPTIMIZE -->
        <DockPanel x:Name="PageOpt" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Optimize Windows"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Performance, privacy, debloat and network tweaks. Every change is backed up first and can be reverted from Undo &amp; restore."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <Button x:Name="BtnOptPreview">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE7B3;"/><TextBlock Text="Preview"/></StackPanel>
            </Button>
            <Button x:Name="BtnOptApply" Style="{StaticResource Primary}">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE945;"/><TextBlock Text="Apply tweaks"/></StackPanel>
            </Button>
            <Button x:Name="BtnOptRefresh" ToolTip="Re-read which tweaks are currently applied">
              <TextBlock Style="{StaticResource Ico}" Text="&#xE72C;" Margin="0"/>
            </Button>
          </WrapPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <TextBox x:Name="TxtOptFilter" DockPanel.Dock="Right" Style="{StaticResource FilterBox}" Tag="Search tweaks"/>
            <WrapPanel VerticalAlignment="Center">
              <TextBlock Text="Select:" Style="{StaticResource Label}" VerticalAlignment="Center" Margin="2,0,4,0"/>
              <Button x:Name="BtnOptDef"  Style="{StaticResource Link}" Content="Recommended"/>
              <Button x:Name="BtnOptAll"  Style="{StaticResource Link}" Content="All"/>
              <Button x:Name="BtnOptNone" Style="{StaticResource Link}" Content="None"/>
            </WrapPanel>
          </DockPanel>
          <Border DockPanel.Dock="Bottom" Style="{StaticResource Panel}" Margin="0,10,0,0" Padding="16,10">
            <DockPanel>
              <CheckBox x:Name="ChkOptRestore" DockPanel.Dock="Right" Content="Restore point first" IsChecked="True" Margin="12,0,0,0"/>
              <TextBlock x:Name="LblOptStatus" Foreground="{StaticResource Muted}" TextWrapping="Wrap" VerticalAlignment="Center"/>
            </DockPanel>
          </Border>
          <ListView x:Name="LvOpt">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="40" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Tweak" Width="420" CellTemplate="{StaticResource NameCell}"/>
                <GridViewColumn Header="Risk" Width="120" CellTemplate="{StaticResource RiskCell}"/>
                <GridViewColumn Header="State" Width="140" CellTemplate="{StaticResource StateCell}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- TROUBLESHOOT -->
        <DockPanel x:Name="PageRepair" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Troubleshoot"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="The scan is read-only. Afterwards tick the problems you want repaired and press Fix. Heavy repairs (SFC, DISM, Windows Update reset, network stack) may need a reboot."/>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <TextBox x:Name="TxtRepFilter" DockPanel.Dock="Right" Style="{StaticResource FilterBox}" Tag="Search checks"/>
            <WrapPanel>
              <Button x:Name="BtnRepScan" Style="{StaticResource Primary}">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE721;"/><TextBlock Text="Scan"/></StackPanel>
              </Button>
              <Button x:Name="BtnRepFix" IsEnabled="False">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE90F;"/><TextBlock Text="Fix selected"/></StackPanel>
              </Button>
              <Button x:Name="BtnRepFixAll" IsEnabled="False" Content="Fix everything (incl. heavy)"/>
            </WrapPanel>
          </DockPanel>
          <UniformGrid x:Name="PanelRepSummary" DockPanel.Dock="Top" Columns="3" Margin="0,0,-10,10" Visibility="Collapsed">
            <Border Style="{StaticResource Panel}" Margin="0,0,10,0" Padding="14,10">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="10" Height="10" Fill="{StaticResource Bad}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock x:Name="LblRepFail" Text="0" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <TextBlock Text="problems" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="8,2,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,10,0" Padding="14,10">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="10" Height="10" Fill="{StaticResource Warn}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock x:Name="LblRepWarn" Text="0" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <TextBlock Text="warnings" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="8,2,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,10,0" Padding="14,10">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="10" Height="10" Fill="{StaticResource Ok}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock x:Name="LblRepOk" Text="0" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <TextBlock Text="healthy" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="8,2,0,0"/>
              </StackPanel>
            </Border>
          </UniformGrid>
          <Border DockPanel.Dock="Bottom" Style="{StaticResource Panel}" Margin="0,10,0,0" Padding="16,10">
            <TextBlock x:Name="LblRepStatus" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Text="Not scanned yet - press Scan."/>
          </Border>
          <ListView x:Name="LvRep">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="40" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Check" Width="320" CellTemplate="{StaticResource NameCell}"/>
                <GridViewColumn Header="Status" Width="110" CellTemplate="{StaticResource StateCell}"/>
                <GridViewColumn Header="Detail" Width="330" CellTemplate="{StaticResource DetailCell}"/>
                <GridViewColumn Header="Fix" Width="120" CellTemplate="{StaticResource RiskCell}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- STARTUP APPS -->
        <DockPanel x:Name="PageStartup" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Startup apps"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Programs that start with Windows. Switch one off to disable it the way Task Manager does - the entry is kept, so switching it on restores it exactly."/>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <TextBox x:Name="TxtStartupFilter" DockPanel.Dock="Right" Style="{StaticResource FilterBox}" Tag="Search apps"/>
            <WrapPanel>
              <Button x:Name="BtnStartupRefresh">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE72C;"/><TextBlock Text="Refresh"/></StackPanel>
              </Button>
              <Button x:Name="BtnStartupOpen">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE838;"/><TextBlock Text="Open file location"/></StackPanel>
              </Button>
              <Button x:Name="BtnStartupTaskMgr" Content="Task Manager"/>
            </WrapPanel>
          </DockPanel>
          <Border DockPanel.Dock="Bottom" Style="{StaticResource Panel}" Margin="0,10,0,0" Padding="16,10">
            <TextBlock x:Name="LblStartupStatus" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
          </Border>
          <ListView x:Name="LvStartup">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="58" CellTemplate="{StaticResource SwitchCell}"/>
                <GridViewColumn Header="Name" Width="230" CellTemplate="{StaticResource NameCell}"/>
                <GridViewColumn Header="Scope" Width="120" DisplayMemberBinding="{Binding GroupLabel}"/>
                <GridViewColumn Header="Location" Width="170" CellTemplate="{StaticResource DetailCell}"/>
                <GridViewColumn Header="Command" Width="380" CellTemplate="{StaticResource InfoCell}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- HISTORY -->
        <DockPanel x:Name="PageHistory" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="History"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Every run's report - from this app and from the scheduled tasks. Double-click a run to open it, or export it as a web page."/>
          <UniformGrid DockPanel.Dock="Top" Columns="3" Margin="0,0,-12,12">
            <Border Style="{StaticResource Panel}" Margin="0,0,12,0">
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="FREED ALL TIME"/>
                <TextBlock x:Name="LblHistTotal" Style="{StaticResource Big}" Text="0 B"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,12,0">
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="CLEANUPS"/>
                <TextBlock x:Name="LblHistRuns" Style="{StaticResource Big}" Text="0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,12,0">
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="REPORTS"/>
                <TextBlock x:Name="LblHistCounts" Style="{StaticResource Big}" Text="0"/>
              </StackPanel>
            </Border>
          </UniformGrid>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="BtnHistHtml" Style="{StaticResource Primary}">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE8A7;"/><TextBlock Text="Export as web page"/></StackPanel>
            </Button>
            <Button x:Name="BtnHistOpen" Content="Open raw report"/>
            <Button x:Name="BtnHistFolder">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE838;"/><TextBlock Text="Open folder"/></StackPanel>
            </Button>
            <Button x:Name="BtnHistRefresh" ToolTip="Refresh">
              <TextBlock Style="{StaticResource Ico}" Text="&#xE72C;" Margin="0"/>
            </Button>
          </WrapPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblHistStatus" Margin="2,8,0,0" Style="{StaticResource Hint}"/>
          <Grid>
            <ListView x:Name="LvHistory">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="Date" Width="150" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="Engine" Width="120" DisplayMemberBinding="{Binding GroupLabel}"/>
                  <GridViewColumn Header="Mode" Width="110" CellTemplate="{StaticResource DetailCell}"/>
                  <GridViewColumn Header="Result" Width="340" DisplayMemberBinding="{Binding Size}"/>
                  <GridViewColumn Header="Errors" Width="70" DisplayMemberBinding="{Binding State}"/>
                  <GridViewColumn Header="Source" Width="100" CellTemplate="{StaticResource InfoCell}"/>
                </GridView>
              </ListView.View>
            </ListView>
            <StackPanel x:Name="PanelHistEmpty" VerticalAlignment="Center" HorizontalAlignment="Center" IsHitTestVisible="False">
              <TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" FontSize="34" Foreground="{StaticResource Faint}" HorizontalAlignment="Center"/>
              <TextBlock Text="No runs yet" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,10,0,4"/>
              <TextBlock Text="Run a scan or a cleanup - its report will appear here." Foreground="{StaticResource Muted}" HorizontalAlignment="Center"/>
            </StackPanel>
          </Grid>
        </DockPanel>

        <!-- UNDO / RESTORE -->
        <ScrollViewer x:Name="PageUndo" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource H1}" Text="Undo &amp; restore"/>
            <TextBlock Style="{StaticResource Sub}" Text="Safety nets: revert an optimization run from its backup, or create a System Restore point right now."/>
            <GroupBox Header="Optimization backups">
              <StackPanel>
                <TextBlock Style="{StaticResource Hint}" Margin="0,-4,0,10" Text="Each Apply run saves the previous values of everything it changes. Undo puts them back."/>
                <ListView x:Name="LvBackups" Height="200">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="Backup" Width="330" CellTemplate="{StaticResource NameCell}"/>
                      <GridViewColumn Header="Created" Width="150" DisplayMemberBinding="{Binding Detail}"/>
                      <GridViewColumn Header="Tweaks" Width="80" DisplayMemberBinding="{Binding Size}"/>
                      <GridViewColumn Header="Status" Width="160" CellTemplate="{StaticResource StateCell}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
                <WrapPanel Margin="0,12,0,0">
                  <Button x:Name="BtnUndoLast" Style="{StaticResource Primary}">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE7A7;"/><TextBlock Text="Undo newest run"/></StackPanel>
                  </Button>
                  <Button x:Name="BtnUndoSel" Content="Undo selected"/>
                  <Button x:Name="BtnOpenBackups">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE838;"/><TextBlock Text="Open folder"/></StackPanel>
                  </Button>
                  <Button x:Name="BtnBackupsRefresh" ToolTip="Refresh">
                    <TextBlock Style="{StaticResource Ico}" Text="&#xE72C;" Margin="0"/>
                  </Button>
                </WrapPanel>
              </StackPanel>
            </GroupBox>
            <GroupBox Header="System Restore">
              <StackPanel>
                <TextBlock Style="{StaticResource Hint}" Margin="0,-4,0,10" Text="A restore point lets Windows roll back system files, drivers and the registry to this moment."/>
                <WrapPanel>
                  <Button x:Name="BtnRestorePoint">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE710;"/><TextBlock Text="Create restore point now"/></StackPanel>
                  </Button>
                  <Button x:Name="BtnOpenRstrui" Content="Open System Restore"/>
                </WrapPanel>
              </StackPanel>
            </GroupBox>
            <GroupBox Header="Logs">
              <WrapPanel>
                <Button x:Name="BtnOpenLogs">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE838;"/><TextBlock Text="App log folder"/></StackPanel>
                </Button>
                <Button x:Name="BtnOpenTemp" Content="Engine logs (%TEMP%)"/>
              </WrapPanel>
            </GroupBox>
          </StackPanel>
        </ScrollViewer>

        <!-- SCHEDULE -->
        <ScrollViewer x:Name="PageSchedule" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource H1}" Text="Schedule"/>
            <TextBlock Style="{StaticResource Sub}" Text="Automatic maintenance in Task Scheduler: a weekly cleanup and a monthly health check. They run as SYSTEM, unattended, without a restore point and never touch the Dangerous tier."/>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <DockPanel Margin="0,0,0,6">
                  <TextBlock x:Name="LblSchedule" DockPanel.Dock="Right" Text="" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
                  <TextBlock Text="Scheduled tasks" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
                </DockPanel>
                <ItemsControl x:Name="IcSchedule">
                  <ItemsControl.ItemTemplate>
                    <DataTemplate>
                      <Border BorderBrush="{StaticResource Line2}" BorderThickness="0,1,0,0" Padding="0,10">
                        <Grid>
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/><ColumnDefinition Width="130"/><ColumnDefinition Width="190"/><ColumnDefinition Width="190"/>
                          </Grid.ColumnDefinitions>
                          <StackPanel>
                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold"/>
                            <TextBlock Text="{Binding Tip}" Foreground="{StaticResource Faint}" FontSize="12" TextWrapping="Wrap"/>
                          </StackPanel>
                          <ContentControl Grid.Column="1" Content="{Binding}" ContentTemplate="{StaticResource StateCell}" VerticalAlignment="Center"/>
                          <StackPanel Grid.Column="2" VerticalAlignment="Center">
                            <TextBlock Text="{DynamicResource S_NextRun}" Foreground="{StaticResource Faint}" FontSize="11"/>
                            <TextBlock Text="{Binding Detail}"/>
                          </StackPanel>
                          <StackPanel Grid.Column="3" VerticalAlignment="Center">
                            <TextBlock Text="{DynamicResource S_LastRun}" Foreground="{StaticResource Faint}" FontSize="11"/>
                            <TextBlock Text="{Binding Info}"/>
                          </StackPanel>
                        </Grid>
                      </Border>
                    </DataTemplate>
                  </ItemsControl.ItemTemplate>
                </ItemsControl>
                <WrapPanel Margin="0,12,0,0">
                  <Button x:Name="BtnSchedInstall" Style="{StaticResource Primary}">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE787;"/><TextBlock Text="Install scheduled tasks"/></StackPanel>
                  </Button>
                  <Button x:Name="BtnSchedRemove" Content="Remove"/>
                  <Button x:Name="BtnSchedOpen" Content="Task Scheduler"/>
                  <Button x:Name="BtnSchedRefresh" ToolTip="Refresh">
                    <TextBlock Style="{StaticResource Ico}" Text="&#xE72C;" Margin="0"/>
                  </Button>
                </WrapPanel>
              </StackPanel>
            </Border>
            <TextBlock x:Name="LblSchedInfo" Style="{StaticResource Hint}"/>
          </StackPanel>
        </ScrollViewer>

        <!-- DRIVERS -->
        <ScrollViewer x:Name="PageDrivers" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource H1}" Text="Drivers"/>
            <TextBlock Style="{StaticResource Sub}" Text="Official sources only: Microsoft Update for chipset, network, audio and the rest; the GPU vendor's own driver for graphics. Results appear in the log below."/>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Check and update" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Hint}" Text="Shows your graphics card and how old its driver is, devices with errors, and every driver update Microsoft Update offers. The first search can take a few minutes."/>
                <WrapPanel Margin="0,12,0,0">
                  <Button x:Name="BtnDrvCheck" Style="{StaticResource Primary}">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE721;"/><TextBlock Text="Check drivers"/></StackPanel>
                  </Button>
                  <Button x:Name="BtnDrvInstall" Content="Install updates (except GPU)"/>
                  <Button x:Name="BtnDrvHideGpu" Content="Hide GPU updates from Windows Update"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Backup" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Hint}" Text="Exports every third-party driver (pnputil) to Documents\WinSenior\DriverBackup - handy before a Windows reinstall."/>
                <WrapPanel Margin="0,12,0,0">
                  <Button x:Name="BtnDrvBackup" Content="Back up drivers"/>
                  <Button x:Name="BtnDrvBackupOpen" Content="Open backup folder"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <TextBlock Style="{StaticResource Hint}" Text="Why not Windows Update for the graphics card? For games, NVIDIA / AMD / Intel drivers are newer than the ones Windows Update ships and include the game profiles."/>
          </StackPanel>
        </ScrollViewer>

        <!-- APPS -->
        <ScrollViewer x:Name="PageApps" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource H1}" Text="Apps"/>
            <TextBlock Style="{StaticResource Sub}" Text="Uninstall, update and install programs without hunting for installers: winget downloads from the vendors' own sites and checks the hash. Results appear in the log below."/>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Installed apps and updates" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <WrapPanel Margin="0,8,0,0">
                  <Button x:Name="BtnAppsList" Content="List installed apps"/>
                  <Button x:Name="BtnAppsUpdates" Style="{StaticResource Primary}">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE895;"/><TextBlock Text="Check for updates"/></StackPanel>
                  </Button>
                  <Button x:Name="BtnAppsUpdateAll" Content="Update everything"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Uninstall" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Hint}" Text="Type the name exactly as the list shows it. Silent where the installer allows it; afterwards leftover folders and registry keys with a confident match are removed."/>
                <DockPanel Margin="0,10,0,0">
                  <Button x:Name="BtnAppsUninstall" DockPanel.Dock="Right" Style="{StaticResource Danger}" Content="Uninstall" Margin="8,0,0,0"/>
                  <TextBox x:Name="TxtAppName" MinWidth="260"/>
                </DockPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Install" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Hint}" Text="Comma-separated winget ids, e.g. Mozilla.Firefox, 7zip.7zip, VideoLAN.VLC. 'Show catalog' lists 50+ popular apps with their ids."/>
                <DockPanel Margin="0,10,0,0">
                  <Button x:Name="BtnAppsInstall" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Install" Margin="8,0,0,0"/>
                  <Button x:Name="BtnAppsCatalog" DockPanel.Dock="Right" Content="Show catalog" Margin="8,0,0,0"/>
                  <TextBox x:Name="TxtAppIds" MinWidth="260"/>
                </DockPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- MEMORY -->
        <ScrollViewer x:Name="PageMemory" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource H1}" Text="Smart memory"/>
            <TextBlock Style="{StaticResource Sub}" Text="Frees RAM held by processes that outlived their job - Gradle / Kotlin / Maven daemons after a build, MSBuild nodes, orphaned language servers, a Minecraft JVM without a window, the WSL VM. A process is stopped only when it is idle, has no window and no working child."/>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Now" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <WrapPanel Margin="0,8,0,0">
                  <Button x:Name="BtnMemCheck" Content="Check memory"/>
                  <Button x:Name="BtnMemReclaim" Style="{StaticResource Primary}">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE945;"/><TextBlock Text="Free leftover RAM"/></StackPanel>
                  </Button>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Keep it that way" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Hint}" Text="'Fix the cause' makes Gradle daemons exit after 15 idle minutes and lets WSL hand cached memory back to Windows. Automatic mode checks every 10 minutes in the background (no window, no admin rights)."/>
                <WrapPanel Margin="0,12,0,0">
                  <Button x:Name="BtnMemPrevent" Content="Fix the cause"/>
                  <Button x:Name="BtnMemAutoOn" Content="Automatic mode on"/>
                  <Button x:Name="BtnMemAutoOff" Content="Automatic mode off"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <TextBlock Style="{StaticResource Hint}" Text="Why no 'RAM booster'? Emptying working sets or the standby list only makes the number drop - the same data is then read back from disk. Standby memory is cache Windows hands out instantly."/>
          </StackPanel>
        </ScrollViewer>

        <!-- INSIGHTS -->
        <ScrollViewer x:Name="PageInsights" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource H1}" Text="Insights"/>
            <TextBlock Style="{StaticResource Sub}" Text="Measured, not guessed. Results appear in the log below."/>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Boot time and disk forecast" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Hint}" Text="Compares the boots before your last optimization with the boots after it (Mann-Whitney test): faster, slower or no measurable effect. Lists what slows startup down and forecasts when each disk runs out of space."/>
                <WrapPanel Margin="0,12,0,0">
                  <Button x:Name="BtnInsRun" Style="{StaticResource Primary}">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE9D9;"/><TextBlock Text="Analyze"/></StackPanel>
                  </Button>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Panel}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Free a set amount of space" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Hint}" Text="Picks the cleanup tasks that reach the target with the least side effects (exact knapsack over the last scan). Irreversible tasks are never chosen."/>
                <WrapPanel Margin="0,10,0,0">
                  <TextBox x:Name="TxtPlanGb" Width="80" Text="10"/>
                  <TextBlock Text="GB" VerticalAlignment="Center" Margin="6,0,12,0"/>
                  <Button x:Name="BtnInsPlan" Content="Show the plan"/>
                  <Button x:Name="BtnInsApply" Content="Free it now"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- SETTINGS & ABOUT -->
        <ScrollViewer x:Name="PageAbout" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource H1}" Text="Settings &amp; about"/>
            <TextBlock Style="{StaticResource Sub}" Text="Language, where things are kept, and links."/>
            <GroupBox Header="Language">
              <StackPanel>
                <Border Background="{StaticResource Card2}" CornerRadius="8" HorizontalAlignment="Left" Padding="2">
                  <StackPanel Orientation="Horizontal">
                    <RadioButton x:Name="RbLangAuto" Style="{StaticResource Seg}" GroupName="Lang" Content="System default"/>
                    <RadioButton x:Name="RbLangEn"   Style="{StaticResource Seg}" GroupName="Lang" Content="English"/>
                    <RadioButton x:Name="RbLangRu"   Style="{StaticResource Seg}" GroupName="Lang" Content="&#x0420;&#x0443;&#x0441;&#x0441;&#x043A;&#x0438;&#x0439;"/>
                  </StackPanel>
                </Border>
                <TextBlock x:Name="LblLangHint" Style="{StaticResource Hint}" Margin="0,8,0,0" Text="The window restarts to switch the language. Engine log lines stay in English."/>
              </StackPanel>
            </GroupBox>
            <GroupBox Header="Windows Senior">
              <StackPanel>
                <TextBlock x:Name="LblAbout" TextWrapping="Wrap" Foreground="{StaticResource Muted}" LineHeight="21"/>
                <WrapPanel Margin="0,14,0,0">
                  <Button x:Name="BtnOpenRepo">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE8A7;"/><TextBlock Text="GitHub"/></StackPanel>
                  </Button>
                  <Button x:Name="BtnOpenReleases" Content="Check for updates"/>
                  <Button x:Name="BtnOpenConsole" Content="Console menu"/>
                </WrapPanel>
              </StackPanel>
            </GroupBox>
            <GroupBox Header="Files">
              <TextBlock x:Name="LblPaths" TextWrapping="Wrap" Foreground="{StaticResource Muted}" LineHeight="21" FontSize="12"/>
            </GroupBox>
            <GroupBox Header="Keyboard shortcuts">
              <TextBlock x:Name="LblKeys" TextWrapping="Wrap" Foreground="{StaticResource Muted}" LineHeight="21"
                         Text="Ctrl+1 ... Ctrl+9 - switch pages     Ctrl+F - search     F5 - scan / refresh the page     Ctrl+L - show or hide the log     Esc - clear search"/>
            </GroupBox>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <GridSplitter x:Name="LogSplitter" Grid.Row="3" Height="6" HorizontalAlignment="Stretch" Background="{StaticResource Line}" ResizeBehavior="PreviousAndNext" Visibility="Collapsed"/>

      <!-- LOG DRAWER -->
      <DockPanel x:Name="LogPanel" Grid.Row="4" Margin="26,8,26,6" Visibility="Collapsed">
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <Button x:Name="BtnLogSave" Style="{StaticResource Link}" Content="Save log" Margin="0,0,4,0"/>
            <Button x:Name="BtnLogClear" Style="{StaticResource Link}" Content="Clear"/>
          </StackPanel>
          <TextBlock Text="Log" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBox x:Name="TxtLog" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="12" Background="#101114" Foreground="#D2D4D9"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" AcceptsReturn="True" VerticalContentAlignment="Top"/>
      </DockPanel>

      <!-- STATUS BAR -->
      <Border Grid.Row="5" Background="{StaticResource Side}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="26,8">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <Button x:Name="BtnCancel" Style="{StaticResource Danger}" Padding="12,5" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Ico}" Text="&#xE711;" FontSize="11"/><TextBlock Text="Cancel"/></StackPanel>
            </Button>
            <Button x:Name="BtnLogToggle" Padding="12,5" Margin="0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Ico}" Text="&#xE756;" FontSize="12"/>
                <TextBlock Text="Log"/>
                <TextBlock x:Name="LogChevron" Style="{StaticResource Ico}" Text="&#xE70E;" FontSize="9" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
          </StackPanel>
          <ProgressBar x:Name="Prog" Style="{StaticResource Meter}" Width="180" Minimum="0" Maximum="100" Visibility="Collapsed" Margin="0,0,14,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="LblStatus" Text="Ready." VerticalAlignment="Center" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
      </Border>
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
        Set-Status (T 'An unexpected error occurred - see the log.')
    } catch { Write-Verbose 'log panel unavailable' }
})

# =====================================================================
# UI LANGUAGE: translate the static texts of the loaded tree
# =====================================================================
function Convert-WsUiText {
    param($Node)
    if ($null -eq $Node -or -not ($Node -is [System.Windows.DependencyObject])) { return }
    if ($Node -is [System.Windows.Controls.TextBlock]) {
        if ($Node.Text) { $Node.Text = T $Node.Text }
    }
    elseif ($Node -is [System.Windows.Controls.TextBox]) {
        if ($Node.Tag -is [string]) { $Node.Tag = T $Node.Tag }
    }
    if ($Node -is [System.Windows.Controls.HeaderedContentControl] -and $Node.Header -is [string]) { $Node.Header = T $Node.Header }
    if ($Node -is [System.Windows.Controls.ContentControl] -and $Node.Content -is [string]) { $Node.Content = T $Node.Content }
    if ($Node -is [System.Windows.FrameworkElement] -and $Node.ToolTip -is [string]) { $Node.ToolTip = T $Node.ToolTip }
    if ($Node -is [System.Windows.Controls.ListView] -and $Node.View -is [System.Windows.Controls.GridView]) {
        foreach ($c in $Node.View.Columns) { if ($c.Header -is [string] -and $c.Header) { $c.Header = T $c.Header } }
    }
    foreach ($child in @([System.Windows.LogicalTreeHelper]::GetChildren($Node))) { Convert-WsUiText $child }
}
$Win.Resources['S_GroupAll']  = T 'select all'
$Win.Resources['S_GroupNone'] = T 'select none'
$Win.Resources['S_NextRun']   = T 'Next run'
$Win.Resources['S_LastRun']   = T 'Last run'
if ($script:Tr) { Convert-WsUiText $Win }

# Display labels for the raw values the styles key on.
$script:RiskLabels  = @{ Safe = 'Safe'; Moderate = 'Moderate'; Aggressive = 'Aggressive'; Dangerous = 'Dangerous' }
$script:StateLabels = @{
    'applied' = 'Applied'; 'not applied' = 'Not applied'; '?' = 'Unknown'
    'OK' = 'OK'; 'Warn' = 'Warning'; 'Fail' = 'Problem'; 'Skip' = 'Skipped'
    'Enabled' = 'Enabled'; 'Disabled' = 'Disabled'; 'Ready' = 'Ready'; 'Running' = 'Running'
    'active' = 'Active'; 'undone' = 'Undone'; 'unreadable' = 'Unreadable'; 'Not installed' = 'Not installed'
}
function Set-RowRisk  { param($Row, [string]$Risk)  $Row.Risk = $Risk; $Row.RiskLabel = $(if ($Risk -and $script:RiskLabels[$Risk]) { T $script:RiskLabels[$Risk] } else { T $Risk }) }
function Set-RowState { param($Row, [string]$State) $Row.State = $State; $Row.StateLabel = $(if ($State -and $script:StateLabels[$State]) { T $script:StateLabels[$State] } else { T $State }) }

# =====================================================================
# THEMED DIALOG (replaces the grey MessageBox inside the app)
# =====================================================================
$script:DialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" SizeToContent="Height" Width="540" AllowsTransparency="True"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="Transparent"
        FontFamily="Segoe UI" FontSize="13" Foreground="#ECEDF0" UseLayoutRounding="True">
  <Border Background="#1E1F25" BorderBrush="#3A3C46" BorderThickness="1" CornerRadius="12" Margin="14">
    <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
    <DockPanel Margin="24,20,24,20">
      <StackPanel x:Name="DlgButtons" DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,-8,0"/>
      <DockPanel DockPanel.Dock="Top" Margin="0,0,0,12">
        <TextBlock x:Name="DlgIcon" FontFamily="Segoe MDL2 Assets" FontSize="20" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <TextBlock x:Name="DlgTitle" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/>
      </DockPanel>
      <StackPanel>
        <TextBlock x:Name="DlgText" TextWrapping="Wrap" Foreground="#C9CCD3" LineHeight="20"/>
        <Border x:Name="DlgListBox" Background="#17181C" CornerRadius="8" Padding="12,9" Margin="0,12,0,0" Visibility="Collapsed">
          <ScrollViewer MaxHeight="230" VerticalScrollBarVisibility="Auto">
            <TextBlock x:Name="DlgList" TextWrapping="Wrap" Foreground="#A9AEB8" LineHeight="19"/>
          </ScrollViewer>
        </Border>
      </StackPanel>
    </DockPanel>
  </Border>
</Window>
'@

# Buttons: array of @{ Text; Result; Kind = 'Primary'|'Danger'|''; Default; Cancel }. Returns the Result of the
# pressed button (Esc / closing = the Cancel button's result).
function Show-WsDialog {
    param([string]$Title, [string]$Text, [string]$List = '', [ValidateSet('info', 'question', 'warn', 'danger', 'ok')][string]$Kind = 'info',
          [object[]]$Buttons = @(@{ Text = (T 'OK'); Result = 'ok'; Kind = 'Primary'; Default = $true; Cancel = $true }))
    if (-not ($script:Win -and $script:Win.IsLoaded)) {
        $mbButtons = if ($Buttons.Count -gt 1) { 'YesNo' } else { 'OK' }
        $r = Show-WsMessage -Text ($Text + $(if ($List) { "`n`n$List" } else { '' })) -Title $Title -Buttons $mbButtons
        if ($Buttons.Count -gt 1) { return $(if ($r -eq 'Yes') { ($Buttons | Where-Object { -not $_.Cancel } | Select-Object -First 1).Result } else { ($Buttons | Where-Object { $_.Cancel } | Select-Object -First 1).Result }) }
        return $Buttons[0].Result
    }
    $dlg = [System.Windows.Markup.XamlReader]::Parse($script:DialogXaml)
    $dlg.Resources.MergedDictionaries.Add($script:Win.Resources)
    $dlg.Owner = $script:Win
    $dlg.Title = $Title
    $icons = @{ info = @([char]0xE946, '#6EA3FF'); question = @([char]0xE9CE, '#6EA3FF'); warn = @([char]0xE7BA, '#F2B33D')
                danger = @([char]0xE7BA, '#FF6B6B'); ok = @([char]0xE930, '#3DD68C') }
    $ic = $icons[$Kind]
    $dlg.FindName('DlgIcon').Text = [string]$ic[0]
    $dlg.FindName('DlgIcon').Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($ic[1])
    $dlg.FindName('DlgTitle').Text = $Title
    $dlg.FindName('DlgText').Text = $Text
    if ($List) { $dlg.FindName('DlgList').Text = $List; $dlg.FindName('DlgListBox').Visibility = 'Visible' }
    $script:DialogResult = $null
    $cancelResult = ($Buttons | Where-Object { $_.Cancel } | Select-Object -First 1).Result
    $panel = $dlg.FindName('DlgButtons')
    foreach ($b in $Buttons) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $b.Text
        $btn.Tag = $b.Result
        $btn.MinWidth = 96
        if ($b.Kind -eq 'Primary') { $btn.Style = $script:Win.FindResource('Primary') }
        elseif ($b.Kind -eq 'Danger') { $btn.Style = $script:Win.FindResource('Danger') }
        if ($b.Default) { $btn.IsDefault = $true }
        if ($b.Cancel) { $btn.IsCancel = $true }
        $btn.Add_Click({ param($src) $script:DialogResult = [string]$src.Tag; [System.Windows.Window]::GetWindow($src).Close() })
        [void]$panel.Children.Add($btn)
    }
    $dlg.Add_MouseLeftButtonDown({ param($src) try { $src.DragMove() } catch { Write-Verbose 'no drag' } })
    $dlg.Add_ContentRendered({ param($src) $d = @($src.FindName('DlgButtons').Children | Where-Object { $_.IsDefault }); if ($d) { [void]$d[0].Focus() } })
    [void]$dlg.ShowDialog()
    if ($null -eq $script:DialogResult) { return $cancelResult }
    $script:DialogResult
}

function Confirm-WsAction {
    param([string]$Title, [string]$Text, [string]$List = '', [string]$Ok = (T 'Continue'), [string]$Kind = 'question', [switch]$DangerButton)
    $okKind = if ($DangerButton) { 'Danger' } else { 'Primary' }
    $r = Show-WsDialog -Title $Title -Text $Text -List $List -Kind $Kind -Buttons @(
        @{ Text = (T 'Cancel'); Result = 'no'; Cancel = $true },
        @{ Text = $Ok; Result = 'yes'; Kind = $okKind; Default = $true })
    $r -eq 'yes'
}

# =====================================================================
# LOG + STATUS + RESULT BANNER
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

$script:BannerKinds = @{
    ok   = @{ Bg = '#16332A'; Bd = '#245A45'; Fg = '#3DD68C'; Icon = 0xE930 }
    info = @{ Bg = '#1B2945'; Bd = '#2B4475'; Fg = '#6EA3FF'; Icon = 0xE946 }
    warn = @{ Bg = '#3A2E14'; Bd = '#5C4A1E'; Fg = '#F2B33D'; Icon = 0xE7BA }
    bad  = @{ Bg = '#3A1C20'; Bd = '#6A2C33'; Fg = '#FF6B6B'; Icon = 0xEA39 }
}
function Show-ResultBanner {
    param([ValidateSet('ok', 'info', 'warn', 'bad')][string]$Kind, [string]$Title, [string]$Sub = '')
    $k = $script:BannerKinds[$Kind]
    $bc = New-Object System.Windows.Media.BrushConverter
    $W.BannerResult.Background  = $bc.ConvertFromString($k.Bg)
    $W.BannerResult.BorderBrush = $bc.ConvertFromString($k.Bd)
    $W.BannerIcon.Foreground    = $bc.ConvertFromString($k.Fg)
    $W.BannerIcon.Text = [string][char]$k.Icon
    $W.LblBanner.Text = $Title
    $W.LblBannerSub.Text = $Sub
    $W.LblBannerSub.Visibility = if ($Sub) { 'Visible' } else { 'Collapsed' }
    $W.BannerResult.Visibility = 'Visible'
}
$W.BtnBannerClose.Add_Click({ $W.BannerResult.Visibility = 'Collapsed' })
$W.BtnBannerLog.Add_Click({ Set-LogOpen $true })

# Collapsible log drawer above the status bar.
$script:LogOpen = $false
$script:LogHeight = 220
function Set-LogOpen {
    param([bool]$Open)
    if (-not $Open -and $script:LogOpen -and $W.LogRow.ActualHeight -gt 80) { $script:LogHeight = [int]$W.LogRow.ActualHeight }
    $script:LogOpen = $Open
    if ($Open) {
        $W.LogRow.MinHeight = 90
        $cap = if ($Win.ActualHeight -gt 0) { [Math]::Max(140, [int]($Win.ActualHeight / 2) - 60) } else { 320 }
        $W.LogRow.Height = New-Object System.Windows.GridLength ([Math]::Min($cap, [Math]::Max(120, $script:LogHeight)))
        $W.SplitRow.Height = New-Object System.Windows.GridLength 6
        $W.LogPanel.Visibility = 'Visible'; $W.LogSplitter.Visibility = 'Visible'
        $W.LogChevron.Text = [string][char]0xE70D
        $W.TxtLog.ScrollToEnd()
    } else {
        $W.LogRow.MinHeight = 0
        $W.LogRow.Height = New-Object System.Windows.GridLength 0
        $W.SplitRow.Height = New-Object System.Windows.GridLength 0
        $W.LogPanel.Visibility = 'Collapsed'; $W.LogSplitter.Visibility = 'Collapsed'
        $W.LogChevron.Text = [string][char]0xE70E
    }
}
$W.BtnLogToggle.Add_Click({ Set-LogOpen (-not $script:LogOpen) })

$script:BusyButtons = @('BtnScan', 'BtnClean', 'BtnOptPreview', 'BtnOptApply', 'BtnOptRefresh', 'BtnRepScan', 'BtnHomeScan',
    'BtnUndoLast', 'BtnUndoSel', 'BtnRestorePoint', 'BtnSchedInstall', 'BtnSchedRemove',
    'BtnDrvCheck', 'BtnDrvInstall', 'BtnDrvHideGpu', 'BtnDrvBackup', 'BtnAppsList', 'BtnAppsUpdates', 'BtnAppsUpdateAll',
    'BtnAppsUninstall', 'BtnAppsCatalog', 'BtnAppsInstall', 'BtnMemCheck', 'BtnMemReclaim', 'BtnMemPrevent', 'BtnMemAutoOn',
    'BtnMemAutoOff', 'BtnInsRun', 'BtnInsPlan', 'BtnInsApply')

function Set-Busy {
    param([bool]$On, [string]$Text = '')
    $script:Busy = $On
    $W.Prog.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    $W.BtnCancel.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    foreach ($b in $script:BusyButtons) { $W[$b].IsEnabled = -not $On }
    if ($On) { $W.BtnRepFix.IsEnabled = $false; $W.BtnRepFixAll.IsEnabled = $false; $W.BtnHomeClean.IsEnabled = $false }
    else {
        $W.BtnRepFix.IsEnabled = [bool]$script:RepScanned; $W.BtnRepFixAll.IsEnabled = [bool]$script:RepScanned
        $W.BtnHomeClean.IsEnabled = [bool]$script:HomeCanClean
    }
    if ($Win.TaskbarItemInfo) {
        $Win.TaskbarItemInfo.ProgressState = if ($On) { 'Indeterminate' } else { 'None' }
    }
    if ($Text) { Set-Status $Text }
}

function Set-Progress {
    param([int]$Done, [int]$Total, [string]$Name)
    if ($Total -le 0) { $W.Prog.IsIndeterminate = $true; return }
    $W.Prog.IsIndeterminate = $false
    $pct = [Math]::Min(100, [Math]::Round(100.0 * $Done / $Total, 1))
    $W.Prog.Value = $pct
    if ($Win.TaskbarItemInfo) { $Win.TaskbarItemInfo.ProgressState = 'Normal'; $Win.TaskbarItemInfo.ProgressValue = $pct / 100.0 }
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
$script:RunStarted = Get-Date

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
    if ($step) { Set-Progress -Done $script:ProgDone -Total $script:ProgTotal -Name (Get-WsDisplayName $step) }
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
    if ($script:Busy) { Set-Status (T 'Another operation is still running.'); return $false }
    [void](Save-GuiSettings)
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
    $script:RunStarted = Get-Date
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
    $W.BannerResult.Visibility = 'Collapsed'
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
        Set-Busy $false (T 'Failed to start.')
        Show-ResultBanner -Kind bad -Title (T 'The operation could not start.') -Sub (Get-WsErrorText $_)
        return $false
    }
    $script:Timer.Start()
    $true
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
        Set-Busy $false (T 'Cancelled.')
        Show-ResultBanner -Kind warn -Title (T 'Cancelled.') -Sub (T 'The operation was stopped. Whatever finished before that stays done.')
        return
    }
    $W.Prog.IsIndeterminate = $false; $W.Prog.Value = 100
    $secs = [int]((Get-Date) - $script:RunStarted).TotalSeconds
    if ($code -eq 0) { Set-Busy $false ((T 'Done in {0} s.') -f $secs) }
    else {
        $codeText = if ($null -eq $code) { '?' } else { [string]$code }
        Set-Busy $false ((T 'Finished with exit code {0} - see the log.') -f $codeText)
        if ($code -eq 2) {
            Show-ResultBanner -Kind bad -Title (T 'Administrator rights are required for this.') -Sub (T 'Use "Restart as administrator" at the top of the window.')
        } else {
            Show-ResultBanner -Kind warn -Title ((T 'Finished with exit code {0}.') -f $codeText) -Sub (T 'Open the log to see what went wrong.')
        }
    }
    if ($handler) {
        try { & $handler $report $code } catch { Add-Log "post-processing error: $(Get-WsErrorText $_)" }
    }
    if ($script:HistoryDirty -and -not $script:Busy) {
        try { Update-History; Update-HomeHistory } catch { Add-Log "history refresh: $(Get-WsErrorText $_)" }
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
        Set-Busy $false (T 'Finished with an error - see the log.')
    }
})

function Stop-Engine {
    if ($script:Proc -and -not $script:Proc.HasExited) {
        $script:Cancelled = $true
        Set-Status (T 'Cancelling...')
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
# LIST HELPERS: grouping, filter box, sortable headers, fill column
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
        $hay = '{0} {1} {2} {3} {4} {5} {6} {7}' -f $o.Name, $o.Id, $o.Group, $o.GroupLabel, $o.Detail, $o.Info, $o.Risk, $o.RiskLabel
        foreach ($w in $words) { if ($hay.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false } }
        $true
    }.GetNewClosure())
}

function Get-WsVisibleRow { param($List) $v = Get-WsView $List; if ($null -ne $v) { @($v) } else { @() } }

# Collapsible category groups (rows carry GroupLabel + Order = category position).
$script:Grouped = @{}
function Set-WsGrouping {
    param($List)
    $view = Get-WsView $List
    $view.GroupDescriptions.Clear()
    $view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'GroupLabel'))
    $List.GroupStyle.Clear()
    $List.GroupStyle.Add($Win.FindResource('Groups'))
    $script:Grouped[$List.Name] = $true
}
function Set-WsRowOrder {
    param($Rows)
    $seen = @{}
    foreach ($r in $Rows) { if (-not $seen.ContainsKey($r.GroupLabel)) { $seen[$r.GroupLabel] = $seen.Count }; $r.Order = $seen[$r.GroupLabel] }
}

$script:ArrowUp   = [string][char]0x25B2
$script:ArrowDown = [string][char]0x25BC
$script:SortMap = @{}
foreach ($kv in @{
    'Task' = 'Name'; 'Tweak' = 'Name'; 'Check' = 'Name'; 'Name' = 'Name'; 'Date' = 'Name'
    'Scope' = 'GroupLabel'; 'Engine' = 'GroupLabel'
    'Risk' = 'Rank'; 'Fix' = 'Rank'; 'Would free' = 'Bytes'
    'State' = 'State'; 'Status' = 'State'; 'Errors' = 'Rank'
    'Detail' = 'Detail'; 'Location' = 'Detail'; 'Mode' = 'Detail'
    'Command' = 'Info'; 'Source' = 'Info'; 'Result' = 'Size'
}.GetEnumerator()) { $script:SortMap[(T $kv.Key)] = $kv.Value }
$script:SortMap[''] = 'Selected'
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
    # Grouped lists keep their categories in place and sort inside each one.
    if ($script:Grouped[$key]) { $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Order', 'Ascending'))) }
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

# Clicks inside a list: column header -> sort, group header "all/none" -> select that group.
function Invoke-WsListClick {
    param($List, $Source)
    if ($Source -is [System.Windows.Controls.GridViewColumnHeader]) { Invoke-WsHeaderSort -List $List -Header $Source; return }
    if ($Source -is [System.Windows.Controls.Button] -and ([string]$Source.Tag) -like 'grp-*') {
        $group = $Source.DataContext
        if (-not $group -or -not $group.Items) { return }
        $on = ($Source.Tag -eq 'grp-all')
        foreach ($r in @($group.Items)) { if ($r.Enabled) { $r.Selected = $on -and ($r.Risk -ne 'Dangerous') } }
    }
}

function Register-WsList {
    param($List, $FilterBox, [int]$FillColumn = -1)
    $List.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{ param($src, $e) Invoke-WsListClick -List $src -Source $e.OriginalSource })
    if ($FilterBox) {
        $FilterBox.Add_TextChanged({
            param($src)
            Set-WsListFilter -List $script:FilterTargets[$src.Name] -Text $src.Text
            Update-AllStatus
        })
        $script:FilterTargets[$FilterBox.Name] = $List
    }
    if ($FillColumn -ge 0) {
        $script:FillColumns[$List.Name] = $FillColumn
        $List.Add_SizeChanged({ param($src) Update-WsFillColumn $src })
    }
}
$script:FilterTargets = @{}
$script:FillColumns = @{}

# One column (the name / detail) takes whatever width the others leave.
function Update-WsFillColumn {
    param($List)
    $i = $script:FillColumns[$List.Name]
    if ($null -eq $i -or -not $List.View) { return }
    $cols = $List.View.Columns
    $other = 0.0
    for ($k = 0; $k -lt $cols.Count; $k++) { if ($k -ne $i) { $other += $cols[$k].ActualWidth } }
    $w = $List.ActualWidth - $other - 36
    if ($w -gt 180) { $cols[$i].Width = $w }
}

function Set-RowSelection {
    param($List, [scriptblock]$Predicate)
    foreach ($r in (Get-WsVisibleRow $List)) { if ($r.Enabled) { $r.Selected = [bool](& $Predicate $r) } }
}

function Format-NameList {
    param($Rows, [int]$Max = 12)
    $a = @($Rows)
    $lines = @($a | Select-Object -First $Max | ForEach-Object { [string][char]0x2022 + "  $($_.Name)" })
    if ($a.Count -gt $Max) { $lines += ((T '... and {0} more') -f ($a.Count - $Max)) }
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

# Translated name for an engine step line (the engines log English names).
$script:DisplayByName = @{}
function Get-WsDisplayName { param([string]$Name) if ($script:DisplayByName.ContainsKey($Name)) { $script:DisplayByName[$Name] } else { $Name } }

function Format-WsAgo {
    param([datetime]$Date)
    $days = ((Get-Date).Date - $Date.Date).Days
    if ($days -le 0) { return ((T 'today, {0}') -f $Date.ToString('HH:mm')) }
    if ($days -eq 1) { return ((T 'yesterday, {0}') -f $Date.ToString('HH:mm')) }
    (T '{0} days ago') -f $days
}


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
    $r = New-Object WinSenior.GuiRow
    $name = Get-WsRegText 'tasks' $t.Id 'name' $t.Name
    $r.Id = $t.Id; $r.Name = $name; $r.Group = $t.Category; $r.GroupLabel = T $t.Category
    Set-RowRisk $r $t.Risk
    $r.Rank = [int]$script:RiskRank[[string]$t.Risk]
    $r.Selected = if ($cleanSaved) { @($settings.CleanOn) -contains $t.Id } else { $defaultClean -contains $t.Id }
    $script:DisplayByName[[string]$t.Name] = $name
    $tip = New-Object System.Collections.Generic.List[string]
    $tip.Add($name)
    $tip.Add(("{0} / {1}{2}   [{3}]" -f $r.GroupLabel, $r.RiskLabel, $(if ($t.DefaultOn) { T '   (on by default)' } else { T '   (off by default)' }), $t.Id))
    $explain = if ($t.PSObject.Properties['Explain']) { [string]$t.Explain } else { '' }
    $explain = Get-WsRegText 'tasks' $t.Id 'explain' $explain
    if ($explain) { $tip.Add($explain) }
    if ($t.Risk -eq 'Dangerous') { $tip.Add((T 'IRREVERSIBLE - only runs when ticked by hand.')) }
    if ([int]$t.AgeDays -gt 0) { $tip.Add(((T 'Only files older than {0} days.') -f $t.AgeDays)) }
    if ($t.PSObject.Properties['Processes'] -and $t.Processes) { $tip.Add(((T 'Needs closed: {0}') -f (@($t.Processes) -join ', '))) }
    if ($t.PSObject.Properties['StopServices'] -and $t.StopServices) { $tip.Add(((T 'Stops services while cleaning: {0}') -f (@($t.StopServices) -join ', '))) }
    if ($t.Paths) {
        $tip.Add((T 'Paths:'))
        $p = @($t.Paths)
        foreach ($x in ($p | Select-Object -First 14)) { $tip.Add("   $x") }
        if ($p.Count -gt 14) { $tip.Add(("   " + ((T '... and {0} more') -f ($p.Count - 14)))) }
    }
    elseif ($t.Action) { $tip.Add((T 'Runs a scripted action (tool-driven cleanup, measured before/after).')) }
    $r.Tip = $tip -join "`n"
    $script:CleanRows.Add($r)
    $script:CleanById[$t.Id] = $t
}
Set-WsRowOrder $script:CleanRows
$W.LvClean.ItemsSource = $script:CleanRows
Set-WsGrouping $W.LvClean
$W.ChkCurrentUser.IsChecked  = [bool]$settings.CurrentUserOnly
$W.ChkRestore.IsChecked      = [bool]$settings.RestorePoint
$W.ChkDefer.IsChecked        = [bool]$settings.DeferLocked
$W.ChkSkipOpt.IsChecked      = [bool]$settings.SkipOptimization
$W.ChkCloseApps.IsChecked    = [bool]$settings.CloseApps
$W.ChkConservative.IsChecked = [bool]$settings.Conservative
$W.ChkOptRestore.IsChecked   = [bool]$settings.OptRestorePoint
$savedAge = Get-WsMaxAge ([string]$settings.MaxAgeDays)
$W.TxtMaxAge.Text = [string]$(if ($null -eq $savedAge) { 0 } else { $savedAge })
if ($settings.CleanOptionsOpen) { $W.PanelCleanOptions.Visibility = 'Visible' }
$W.BtnCleanOptions.Add_Click({
    $W.PanelCleanOptions.Visibility = if ($W.PanelCleanOptions.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
})

# Fixed drives for drive-level tasks (all ticked = engine default "every local disk").
$script:DriveChecks = New-Object System.Collections.Generic.List[object]
$savedDrives = @($settings.Drives | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\').TrimEnd(':').ToUpperInvariant() })
foreach ($drv in ([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' })) {
    $letter = $drv.Name.Substring(0, 1).ToUpperInvariant()
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = "${letter}:"
    $cb.Tag = $letter
    $cb.Margin = '0,0,16,0'
    try { if ($drv.IsReady) { $cb.ToolTip = (T '{0}   {1} free of {2}') -f $drv.VolumeLabel, (Format-WsSize $drv.AvailableFreeSpace), (Format-WsSize $drv.TotalSize) } } catch { $cb.ToolTip = $null }
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
    $sel = @($script:CleanRows | Where-Object { $_.Selected })
    $eff = @(Get-CleanEffectiveRow)
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(((T 'Selected {0} of {1} tasks') -f $sel.Count, $script:CleanRows.Count))
    if ($eff.Count -ne $sel.Count) { $parts.Add(((T '{0} held back by the options') -f ($sel.Count - $eff.Count))) }
    $aggr = @($eff | Where-Object { $_.Risk -eq 'Aggressive' }).Count
    if ($aggr) { $parts.Add(((T '{0} aggressive') -f $aggr)) }
    $danger = @($eff | Where-Object { $_.Risk -eq 'Dangerous' }).Count
    if ($danger) { $parts.Add(((T '{0} DANGEROUS') -f $danger)) }
    if ($W.TxtCleanFilter.Text) { $parts.Add(((T 'showing {0}') -f (Get-WsVisibleRow $W.LvClean).Count)) }
    if (-not @($script:DriveChecks | Where-Object { $_.IsChecked }).Count -and $script:DriveChecks.Count) { $parts.Add((T 'no drive ticked')) }
    $W.LblCleanStatus.Text = ($parts.ToArray() -join ('   ' + [char]0x00B7 + '   '))
    $bytes = [int64](($eff | Measure-Object Bytes -Sum).Sum)
    $W.LblCleanEstimate.Text = if ($bytes -gt 0) { Format-WsSize $bytes } else { '-' }
}
$script:CleanStatusTimer = New-DebounceTimer { Update-CleanStatus }
$script:CleanRows | ForEach-Object {
    $_.Add_PropertyChanged({ if ($args[1].PropertyName -in 'Selected', 'Bytes') { Restart-Timer $script:CleanStatusTimer } })
}
foreach ($c in 'ChkSkipOpt', 'ChkConservative') { $W[$c].Add_Click({ Update-CleanStatus }) }
Update-CleanStatus

$script:MaxAgeTip = T '0 = no age filter. Whole days, 0 to 3650.'
$W.TxtMaxAge.ToolTip = $script:MaxAgeTip
$W.TxtMaxAge.Add_TextChanged({
    if ($null -eq (Get-WsMaxAge $W.TxtMaxAge.Text)) {
        $W.TxtMaxAge.BorderBrush = [System.Windows.Media.Brushes]::IndianRed
        $W.TxtMaxAge.ToolTip = T 'Enter whole days from 0 to 3650 (0 = no age filter).'
    } else {
        $W.TxtMaxAge.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
        $W.TxtMaxAge.ToolTip = $script:MaxAgeTip
    }
})

# Validates the options; returns $false (and says why) when a run must not start.
function Test-CleanOption {
    if ($null -eq (Get-WsMaxAge $W.TxtMaxAge.Text)) {
        $W.PanelCleanOptions.Visibility = 'Visible'
        Set-Status (T 'The "older than" box needs whole days from 0 to 3650.'); $W.TxtMaxAge.Focus() | Out-Null; return $false
    }
    if ($script:DriveChecks.Count -and -not @($script:DriveChecks | Where-Object { $_.IsChecked }).Count) {
        $W.PanelCleanOptions.Visibility = 'Visible'
        Set-Status (T 'Tick at least one drive.'); return $false
    }
    if (-not @(Get-CleanEffectiveRow).Count) {
        Set-Status (T 'Nothing to run - no task is ticked (or the options hold them all back).'); return $false
    }
    $true
}

function Get-CleanupArgs {
    param([bool]$Preview)
    $allIds = @($script:CleanRows | ForEach-Object { $_.Id })
    $onIds  = @(Get-CleanEffectiveRow | ForEach-Object { $_.Id })
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
    if (@(Get-CleanEffectiveRow | Where-Object { $_.Risk -eq 'Dangerous' }).Count) { $a += '-IncludeDangerous' }
    $a
}

function Get-CleanProgressTotal {
    $ids = @(Get-CleanEffectiveRow | ForEach-Object { $_.Id })
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
    @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
}

function Confirm-CleanRun {
    $eff = @(Get-CleanEffectiveRow)
    $lines = New-Object System.Collections.Generic.List[string]
    $scanned = @($eff | Where-Object { $_.Size -and $_.Bytes -gt 0 })
    if ($scanned.Count) {
        $est = [int64](($scanned | Measure-Object Bytes -Sum).Sum)
        $lines.Add(((T 'About {0} will be freed (the last scan covered {1} of these {2} tasks).') -f (Format-WsSize $est), $scanned.Count, $eff.Count))
    } else { $lines.Add((T 'No size estimate yet - press Scan first to see what would be freed.')) }
    $lines.Add($(if ($W.ChkRestore.IsChecked) { T 'A restore point is created first.' } else { T 'NO restore point will be created.' }))
    $age = Get-WsMaxAge $W.TxtMaxAge.Text
    if ($age -gt 0) { $lines.Add(((T 'Only files older than {0} days.') -f $age)) }
    $drv = @(Get-CleanDriveArg)
    if ($drv.Count) { $lines.Add(((T 'Drive-level tasks limited to: {0}') -f $drv[1])) }
    $blocking = @(Get-BlockingProcess ($eff | Where-Object { $_.Group -eq 'Browsers' }))
    if ($W.ChkCloseApps.IsChecked) {
        if ($blocking.Count) { $lines.Add(((T 'Running browsers WILL BE CLOSED first: {0} - save your work.') -f ($blocking -join ', '))) }
    } elseif ($blocking.Count) {
        $lines.Add(((T 'Caches of running browsers are skipped: {0}.') -f ($blocking -join ', ')))
    }
    $aggr = @($eff | Where-Object { $_.Risk -eq 'Aggressive' })
    $dang = @($eff | Where-Object { $_.Risk -eq 'Dangerous' })
    $list = New-Object System.Collections.Generic.List[string]
    if ($dang.Count) { $list.Add(((T 'DANGEROUS - IRREVERSIBLE ({0}):') -f $dang.Count)); $list.Add((Format-NameList $dang)) }
    if ($aggr.Count) { if ($list.Count) { $list.Add('') }; $list.Add(((T 'Aggressive ({0}):') -f $aggr.Count)); $list.Add((Format-NameList $aggr)) }
    $kind = if ($dang.Count) { 'danger' } elseif ($aggr.Count -or $blocking.Count) { 'warn' } else { 'question' }
    Confirm-WsAction -Title ((T 'Clean {0} task(s) now?') -f $eff.Count) -Text ($lines -join "`n") -List ($list -join "`n") `
        -Ok (T 'Clean now') -Kind $kind -DangerButton:([bool]$dang.Count)
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
            if ($skipped) { $r.Bytes = 0; $r.Size = (T 'skipped ({0})') -f $skipped; continue }
            $sz = if ($b -gt 0) { Format-WsSize $b } elseif ([int]$i.Files -gt 0) { (T '{0} items') -f $i.Files } else { '-' }
            if ($live) { $r.Bytes = 0; $r.Size = (T '{0} freed') -f $sz } else { $r.Bytes = $b; $r.Size = $sz }
        }
        elseif ($ran -contains $r.Id) { $r.Size = '-' }
    }
    Update-CleanStatus
    $total = [int64]0; if ($null -ne $report.Summary.TotalBytes) { $total = [int64]$report.Summary.TotalBytes }
    $sizeText = Format-WsSize $total
    $sub = (T '{0} items, {1} errors, {2} s') -f $report.Summary.TotalFiles, $report.Summary.TotalErrors, [int]$report.DurationSec
    if ($live) {
        $deferred = if ($report.Summary.PSObject.Properties['TotalDeferred'] -and [int]$report.Summary.TotalDeferred -gt 0) { [int]$report.Summary.TotalDeferred } else { 0 }
        if ($deferred) { $sub += '   ' + [char]0x00B7 + '   ' + ((T '{0} locked file(s) will be removed at the next restart') -f $deferred) }
        $kind = if ([int]$report.Summary.TotalErrors -gt 0) { 'warn' } else { 'ok' }
        Show-ResultBanner -Kind $kind -Title ((T 'Cleanup finished - {0} freed.') -f $sizeText) -Sub $sub
        Set-Status ((T 'Freed {0}') -f $sizeText)
        $script:HomeCanClean = $false
        $W.LblHomeJunk.Text = (T 'Freed {0}') -f $sizeText
        $W.LblHomeJunkSub.Text = $sub
    } else {
        Show-ResultBanner -Kind info -Title ((T 'Scan finished - {0} can be freed.') -f $sizeText) -Sub ($sub + '   ' + [char]0x00B7 + '   ' + (T 'Nothing was deleted.'))
        Set-Status ((T 'Would free {0}') -f $sizeText)
        $script:HomeCanClean = ($total -gt 0)
        $W.LblHomeJunk.Text = $sizeText
        $W.LblHomeJunkSub.Text = (T '{0} tasks scanned - nothing deleted yet.') -f @($script:LastCleanIds).Count
    }
    $W.BtnHomeClean.IsEnabled = [bool]$script:HomeCanClean -and -not $script:Busy
    $script:HistoryDirty = $true
}

$script:CleanThen = $null
function Start-CleanRun {
    param([bool]$Preview, [scriptblock]$Then)
    $script:LastCleanIds = @(Get-CleanEffectiveRow | ForEach-Object { $_.Id })
    if ($Preview) { foreach ($r in $script:CleanRows) { if ($script:LastCleanIds -contains $r.Id) { $r.Size = ''; $r.Bytes = 0 } } }
    $status = if ($Preview) { T 'Scanning (dry run)...' } else { T 'Cleaning...' }
    $verb = if ($Preview) { T 'Scanning' } else { T 'Cleaning' }
    $script:CleanThen = $Then
    $ok = Start-Engine -Script $script:CleanupScript -Arguments (Get-CleanupArgs $Preview) -Status $status -Verb $verb `
        -WantReport -ProgressTotal (Get-CleanProgressTotal) -OnDone {
            param($report, $code)
            & $applyReport $report $code
            $next = $script:CleanThen; $script:CleanThen = $null
            if ($next -and $code -eq 0) { & $next }
            if ($script:HistoryDirty) { Update-History; Update-HomeHistory }
        }
    if (-not $ok) { $script:CleanThen = $null }
}

function Invoke-CleanNow {
    if (-not (Test-CleanOption)) { return }
    if (-not (Confirm-CleanRun)) { Set-Status (T 'Cleanup cancelled.'); return }
    Start-CleanRun -Preview $false
}
$W.BtnScan.Add_Click({
    if (-not (Test-CleanOption)) { return }
    Start-CleanRun -Preview $true
})
$W.BtnClean.Add_Click({ Invoke-CleanNow })
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
    param($Tweak, [string]$Name, [string]$Explain)
    $tip = New-Object System.Collections.Generic.List[string]
    $tip.Add($Name)
    $tip.Add(("{0} / {1}{2}   [{3}]" -f (T $Tweak.Area), (T $Tweak.Risk), $(if ($Tweak.DefaultOn) { T '   (on by default)' } else { T '   (off by default)' }), $Tweak.Id))
    if ($Explain) { $tip.Add($Explain) }
    try {
        switch ($Tweak.Type) {
            'Registry' {
                $vals = @($Tweak.Spec.Values | ForEach-Object { "$($_.Name) = $($_.Value)" }) -join ', '
                $tip.Add(((T 'Registry: {0}') -f $Tweak.Spec.Path))
                if ($vals) { $tip.Add("   $vals") }
            }
            'Service' { $tip.Add(((T 'Service: {0} -> {1}') -f $Tweak.Spec.Service, $Tweak.Spec.Startup)) }
            'ScheduledTask' {
                $tip.Add((T 'Scheduled tasks disabled:'))
                foreach ($x in @($Tweak.Spec.Tasks | Select-Object -First 8)) { $tip.Add("   $($x.Path)$($x.Name)") }
            }
            default { $tip.Add((T 'Scripted tweak (backed up and reverted by its own undo step).')) }
        }
    } catch { Write-Verbose 'tweak details unavailable' }
    $tip -join "`n"
}

foreach ($t in $script:OptReg) {
    $r = New-Object WinSenior.GuiRow
    $name = Get-WsRegText 'tweaks' $t.Id 'name' $t.Name
    $explain = Get-WsRegText 'tweaks' $t.Id 'explain' ([string]$t.Explain)
    $r.Id = $t.Id; $r.Name = $name; $r.Group = $t.Area; $r.GroupLabel = T $t.Area; $r.Explain = $explain
    Set-RowRisk $r $t.Risk
    $r.Rank = [int]$script:RiskRank[[string]$t.Risk]
    $r.Selected = if ($optSaved) { @($settings.OptOn) -contains $t.Id } else { $defaultOpt -contains $t.Id }
    $r.StateLabel = '...'
    $r.Tip = Get-TweakTip $t $name $explain
    $script:DisplayByName[[string]$t.Name] = $name
    $script:OptRows.Add($r)
    $script:OptById[$t.Id] = $r
}
Set-WsRowOrder $script:OptRows
$W.LvOpt.ItemsSource = $script:OptRows
Set-WsGrouping $W.LvOpt

function Update-OptStatus {
    $on = @($script:OptRows | Where-Object { $_.Selected }).Count
    $applied = @($script:OptRows | Where-Object { $_.State -eq 'applied' }).Count
    $parts = @(((T 'Selected {0} of {1} tweaks') -f $on, $script:OptRows.Count))
    if ($script:OptStateLoaded) { $parts += ((T 'applied right now: {0}') -f $applied) } else { $parts += (T 'reading the current state...') }
    if ($W.TxtOptFilter.Text) { $parts += ((T 'showing {0}') -f (Get-WsVisibleRow $W.LvOpt).Count) }
    $W.LblOptStatus.Text = $parts -join ('   ' + [char]0x00B7 + '   ')
    if ($script:OptStateLoaded) {
        $W.LblHomeOpt.Text = "$applied / $($script:OptRows.Count)"
        $W.LblHomeOptSub.Text = T 'tweaks applied'
    }
}

# Reading 77 tweak states takes seconds (the ScheduledTasks module alone loads ~3 s),
# so it runs in a background runspace and the window stays responsive.
$script:OptStateJob = $null
$script:OptStateLoaded = $false
function Start-OptStateRead {
    if ($script:OptStateJob) { $script:OptStateAgain = $true; return }
    $script:OptStateAgain = $false
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($common, $engine)
        . $common
        . $engine
        $h = @{}
        foreach ($t in Get-OptimizationTweakRegistry) {
            $st = $null
            try { $st = Test-TweakApplied -Tweak $t } catch { $st = $null }
            $h[$t.Id] = $st
        }
        $h
    }).AddArgument($script:CommonScript).AddArgument($script:OptimizeScript)
    $script:OptStateJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
    $W.BtnOptRefresh.IsEnabled = $false
    $script:OptStateTimer.Start()
}
$script:OptStateTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:OptStateTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:OptStateTimer.Add_Tick({
    $job = $script:OptStateJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $script:OptStateTimer.Stop()
    $states = $null
    try { $states = @($job.PS.EndInvoke($job.Handle)) | Where-Object { $_ -is [hashtable] } | Select-Object -First 1 }
    catch { Add-Log "[x] Could not read the tweak state: $(Get-WsErrorText $_)" }
    finally { $job.PS.Dispose(); $script:OptStateJob = $null }
    # Something changed the tweaks while this read ran - its result is stale.
    if ($script:OptStateAgain) { Start-OptStateRead; return }
    foreach ($r in $script:OptRows) {
        $st = if ($states -and $states.ContainsKey($r.Id)) { $states[$r.Id] } else { $null }
        Set-RowState $r $(if ($st -eq $true) { 'applied' } elseif ($st -eq $false) { 'not applied' } else { '?' })
    }
    $script:OptStateLoaded = $true
    $W.BtnOptRefresh.IsEnabled = -not $script:Busy
    Update-OptStatus
})

$script:OptStatusTimer = New-DebounceTimer { Update-OptStatus }
$script:OptRows | ForEach-Object {
    $_.Add_PropertyChanged({ if ($args[1].PropertyName -in 'Selected', 'State') { Restart-Timer $script:OptStatusTimer } })
}
Update-OptStatus

function Get-OptArgs {
    param([bool]$Preview)
    $a = @(Get-WsSelectionArg -AllIds @($script:OptRows | ForEach-Object { $_.Id }) -OnIds @($script:OptRows | Where-Object { $_.Selected } | ForEach-Object { $_.Id }))
    $a += '-Unattended'
    if ($Preview) { $a += '-WhatIf' }
    if (-not $W.ChkOptRestore.IsChecked -or $Preview) { $a += '-NoRestorePoint' }
    if ($script:OptRows | Where-Object { $_.Selected -and $_.Risk -eq 'Dangerous' }) { $a += '-IncludeDangerous' }
    $a
}

function Confirm-OptRun {
    $sel = @($script:OptRows | Where-Object { $_.Selected })
    $already = @($sel | Where-Object { $_.State -eq 'applied' })
    $lines = New-Object System.Collections.Generic.List[string]
    if ($already.Count) { $lines.Add(((T '{0} of them are already applied and will be skipped.') -f $already.Count)) }
    $lines.Add((T 'Every change is backed up first and can be reverted from Undo & restore.'))
    $lines.Add($(if ($W.ChkOptRestore.IsChecked) { T 'A restore point is created first.' } else { T 'NO restore point will be created.' }))
    $aggr = @($sel | Where-Object { $_.Risk -eq 'Aggressive' })
    $dang = @($sel | Where-Object { $_.Risk -eq 'Dangerous' })
    $list = New-Object System.Collections.Generic.List[string]
    if ($dang.Count) { $list.Add(((T 'DANGEROUS - IRREVERSIBLE ({0}):') -f $dang.Count)); $list.Add((Format-NameList $dang)) }
    if ($aggr.Count) { if ($list.Count) { $list.Add('') }; $list.Add(((T 'Aggressive ({0}):') -f $aggr.Count)); $list.Add((Format-NameList $aggr)) }
    $kind = if ($dang.Count) { 'danger' } elseif ($aggr.Count) { 'warn' } else { 'question' }
    Confirm-WsAction -Title ((T 'Apply {0} tweak(s) now?') -f $sel.Count) -Text ($lines -join "`n") -List ($list -join "`n") -Ok (T 'Apply') -Kind $kind -DangerButton:([bool]$dang.Count)
}

$optDone = {
    param($report, $code)
    Start-OptStateRead
    Update-Backups
    if (-not $report) { return }
    $s = $report.Summary
    if ($report.Mode -eq 'DryRun') {
        $n = @($report.Items | Where-Object { $_.Result -eq 'would-apply' }).Count
        Show-ResultBanner -Kind info -Title ((T 'Preview: {0} tweak(s) would change.') -f $n) -Sub (T 'Nothing was changed. The log lists every value.')
    } else {
        $kind = if ([int]$s.Errors -gt 0) { 'warn' } else { 'ok' }
        Show-ResultBanner -Kind $kind -Title ((T 'Applied {0} tweak(s).') -f [int]$s.Applied) `
            -Sub ((T 'Skipped {0}, errors {1}. Undo & restore can revert this run.') -f [int]$s.Skipped, [int]$s.Errors)
    }
}
$W.BtnOptPreview.Add_Click({
    $sel = @($script:OptRows | Where-Object { $_.Selected })
    if (-not $sel.Count) { Set-Status (T 'Nothing selected.'); return }
    [void](Start-Engine -Script $script:OptimizeScript -Arguments (Get-OptArgs $true) -Status (T 'Previewing tweaks...') -Verb (T 'Previewing') `
        -WantReport -ProgressTotal $sel.Count -ProgressNames @($sel | ForEach-Object { $script:OptReg | Where-Object Id -eq $_.Id | ForEach-Object { $_.Name } }) -OnDone $optDone)
})
$W.BtnOptApply.Add_Click({
    $sel = @($script:OptRows | Where-Object { $_.Selected })
    if (-not $sel.Count) { Set-Status (T 'Nothing selected.'); return }
    if (-not (Confirm-OptRun)) { Set-Status (T 'Cancelled - nothing applied.'); return }
    $todo = @($sel | Where-Object { $_.State -ne 'applied' })
    [void](Start-Engine -Script $script:OptimizeScript -Arguments (Get-OptArgs $false) -Status (T 'Applying tweaks...') -Verb (T 'Applying') `
        -WantReport -ProgressTotal $todo.Count -ProgressNames @($todo | ForEach-Object { $script:OptReg | Where-Object Id -eq $_.Id | ForEach-Object { $_.Name } }) -OnDone $optDone)
})
$W.BtnOptRefresh.Add_Click({ Start-OptStateRead })
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
    param($Check, [string]$Name, [string]$Detail)
    $tip = New-Object System.Collections.Generic.List[string]
    $tip.Add($Name)
    $tip.Add(("{0}   [{1}]" -f (T $Check.Category), $Check.Id))
    if ($Check.Fix) {
        $fixLabel = Get-WsRegText 'checks' $Check.Id 'fix' ([string]$Check.FixLabel)
        $tip.Add(((T 'Fix: {0}   [{1}]') -f $fixLabel, (T $Check.FixRisk)))
        if ($Check.Reboot) { $tip.Add((T 'The fix needs a reboot to finish.')) }
    } else { $tip.Add((T 'Report only - no automatic fix.')) }
    if ($Detail) { $tip.Add(((T 'Last result: {0}') -f $Detail)) }
    $tip -join "`n"
}

foreach ($c in $script:RepReg) {
    $r = New-Object WinSenior.GuiRow
    $name = Get-WsRegText 'checks' $c.Id 'name' $c.Name
    $r.Id = $c.Id; $r.Name = $name; $r.Group = $c.Category; $r.GroupLabel = T $c.Category
    Set-RowRisk $r $(if ($c.Fix) { $c.FixRisk } else { '' })
    if (-not $c.Fix) { $r.RiskLabel = T 'report only' }
    $r.Rank = $(if ($c.Fix) { [int]$script:RiskRank[[string]$c.FixRisk] } else { -1 })
    Set-RowState $r ''
    $r.StateLabel = '-'
    $r.Detail = T 'not scanned'; $r.Enabled = $false
    $r.Tip = Get-CheckTip $c $name ''
    $script:DisplayByName[[string]$c.Name] = $name
    $script:RepRows.Add($r)
    $script:RepById[$c.Id] = $c
}
Set-WsRowOrder $script:RepRows
$W.LvRep.ItemsSource = $script:RepRows
Set-WsGrouping $W.LvRep

$applyScan = {
    param($report)
    if (-not $report) { return }
    foreach ($i in @($report.Items)) {
        $row = $script:RepRows | Where-Object { $_.Id -eq $i.Id } | Select-Object -First 1
        if (-not $row) { continue }
        Set-RowState $row ([string]$i.Status)
        $row.Detail = [string]$i.Detail
        $fixable = [bool]$i.HasFix -and ($i.Status -in 'Warn', 'Fail')
        $row.Enabled = $fixable
        $row.Selected = $fixable -and ($i.FixRisk -in 'Safe', 'Moderate')
        $check = $script:RepById[[string]$i.Id]
        if ($check) { $row.Tip = Get-CheckTip $check $row.Name ([string]$i.Detail) }
    }
    $fail = @($script:RepRows | Where-Object { $_.State -eq 'Fail' }).Count
    $warn = @($script:RepRows | Where-Object { $_.State -eq 'Warn' }).Count
    $ok   = @($script:RepRows | Where-Object { $_.State -eq 'OK' }).Count
    $script:RepScanned = $true
    $W.BtnRepFix.IsEnabled = -not $script:Busy; $W.BtnRepFixAll.IsEnabled = -not $script:Busy
    $W.LblRepFail.Text = [string]$fail; $W.LblRepWarn.Text = [string]$warn; $W.LblRepOk.Text = [string]$ok
    $W.PanelRepSummary.Visibility = 'Visible'
    $fixable = @($script:RepRows | Where-Object { $_.Enabled }).Count
    $W.LblRepStatus.Text = if ($fixable) { (T 'Scan complete. {0} problem(s) can be fixed here - the Safe and Moderate fixes are pre-ticked.') -f $fixable } else { T 'Scan complete. Nothing here needs an automatic fix.' }
    Set-HomeHealth -Fail $fail -Warn $warn -When (Get-Date)
    if ($script:FixSummary) {
        $f = $script:FixSummary; $script:FixSummary = $null
        $now = if ($fail -or $warn) { (T 'Still open: {0} problem(s), {1} warning(s).') -f $fail, $warn } else { T 'The re-scan found no problems.' }
        Show-ResultBanner -Kind $f.Kind -Title $f.Title -Sub ($f.Sub + '   ' + [char]0x00B7 + '   ' + $now)
    }
    elseif (-not $script:RepFixRun) {
        $kind = if ($fail) { 'bad' } elseif ($warn) { 'warn' } else { 'ok' }
        $title = if ($fail -or $warn) { (T 'Health check: {0} problem(s), {1} warning(s).') -f $fail, $warn } else { T 'Health check: everything looks fine.' }
        Show-ResultBanner -Kind $kind -Title $title -Sub ((T '{0} checks passed.') -f $ok)
    }
}

$script:RepThen = $null
function Start-RepairScan {
    param([scriptblock]$Then)
    $script:RepThen = $Then
    $script:RepFixRun = $false
    $ok = Start-Engine -Script $script:RepairScript -Arguments @('-ScanOnly', '-Unattended') -Status (T 'Scanning for problems...') -Verb (T 'Scanning') -WantReport -OnDone {
        param($report, $code)
        & $applyScan $report $code
        $next = $script:RepThen; $script:RepThen = $null
        if ($next -and $code -eq 0) { & $next }
        if ($script:HistoryDirty) { Update-History; Update-HomeHistory }
    }
    if (-not $ok) { $script:RepThen = $null }
}
$repFixDone = {
    param($report, $code)
    $script:RepFixRun = $true
    & $applyScan $report $code
    if ($report) {
        $s = $report.Summary
        $kind = if ([int]$s.FixErrors -gt 0) { 'warn' } else { 'ok' }
        $sub = if ($s.Reboot) { T 'Restart Windows to finish the repair.' } else { T 'Checked again to confirm.' }
        $title = (T 'Repaired {0} problem(s), {1} failed.') -f [int]$s.Fixed, [int]$s.FixErrors
        Show-ResultBanner -Kind $kind -Title $title -Sub $sub
        # Shown again (with the fresh counts) once the confirming re-scan is done.
        $script:FixSummary = @{ Kind = $kind; Title = $title; Sub = $sub }
        if ($s.Reboot) {
            [void](Show-WsDialog -Title (T 'Restart needed') -Text (T 'A reboot is required to finish the repair. Save your work and restart Windows when convenient.') -Kind info)
        }
    }
}
$W.BtnRepScan.Add_Click({ Start-RepairScan })
$W.BtnRepFix.Add_Click({
    $sel = @($script:RepRows | Where-Object { $_.Selected -and $_.Enabled })
    if (-not $sel.Count) { Set-Status (T 'No fixes selected.'); return }
    if (-not (Confirm-WsAction -Title ((T 'Repair {0} problem(s) now?') -f $sel.Count) -Text (T 'A restore point is created first.') -List (Format-NameList $sel 14) -Ok (T 'Repair'))) { return }
    $a = @('-FixAll', '-Unattended') + @(Get-WsSelectionArg -AllIds @($script:RepRows | ForEach-Object { $_.Id }) -OnIds @($sel | ForEach-Object { $_.Id }))
    if ($sel | Where-Object { $_.Risk -eq 'Aggressive' }) { $a += '-IncludeHeavy' }
    [void](Start-Engine -Script $script:RepairScript -Arguments $a -Status (T 'Repairing...') -Verb (T 'Repairing') -WantReport -OnDone {
        param($report, $code)
        & $repFixDone $report $code
        Start-RepairScan
    })
})
$W.BtnRepFixAll.Add_Click({
    if (-not (Confirm-WsAction -Title (T 'Fix everything?') -Text (T 'Apply every available fix, including heavy ones (SFC, DISM, Windows Update reset, network stack). A restore point is created first. This can take a long time and may need a reboot.') -Ok (T 'Fix everything') -Kind warn)) { return }
    [void](Start-Engine -Script $script:RepairScript -Arguments @('-FixAll', '-IncludeHeavy', '-Unattended') -Status (T 'Auto-fixing...') -Verb (T 'Repairing') -WantReport -OnDone {
        param($report, $code)
        & $repFixDone $report $code
        Start-RepairScan
    })
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
    $on = @($all | Where-Object { $_.Selected }).Count
    $parts = @(((T '{0} entries') -f $all.Count), ((T '{0} enabled, {1} disabled') -f $on, ($all.Count - $on)))
    $missing = @($all | Where-Object { $_.Tip -like '*TARGET FILE NOT FOUND*' }).Count
    if ($missing) { $parts += ((T '{0} point to a missing file') -f $missing) }
    if ($W.TxtStartupFilter.Text) { $parts += ((T 'showing {0}') -f (Get-WsVisibleRow $W.LvStartup).Count) }
    if (-not (Test-AdminPrivileges)) { $parts += (T 'not administrator: All-users entries cannot be changed') }
    $W.LblStartupStatus.Text = $parts -join ('   ' + [char]0x00B7 + '   ')
    $W.LblHomeStartup.Text = [string]$on
    $W.LblHomeStartupSub.Text = (T 'of {0} start with Windows') -f $all.Count
}

function Set-StartupRowState {
    param($Row)
    $item = $script:StartupMap[$Row.Id]
    if (-not $item) { return }
    $want = [bool]$Row.Selected
    try {
        Set-WinSeniorStartupItemState -Item $item -Enabled $want -Confirm:$false | Out-Null
        Set-RowState $Row $(if ($want) { 'Enabled' } else { 'Disabled' })
        Add-Log ("Startup: {0} '{1}' ({2})" -f $(if ($want) { 'enabled' } else { 'disabled' }), $item.Name, $item.Location)
        Set-Status ((T $(if ($want) { '{0} will start with Windows again.' } else { '{0} will no longer start with Windows.' })) -f $item.Name)
    }
    catch {
        $msg = Get-WsErrorText $_
        Add-Log "[x] Startup: could not change '$($item.Name)': $msg"
        Set-Status ((T 'Could not change {0}: {1}') -f $item.Name, $msg)
        $script:StartupLoading = $true
        try { $Row.Selected = -not $want } finally { $script:StartupLoading = $false }
    }
    Update-StartupStatus
}

function Update-Startup {
    if (-not $script:HasStartup) { $W.LblStartupStatus.Text = T 'WinSenior.Startup.ps1 is missing - keep it next to WinSenior.Gui.ps1.'; return }
    $script:StartupLoading = $true
    try {
        $script:StartupRows.Clear(); $script:StartupMap = @{}
        foreach ($i in @(Get-WinSeniorStartupItem)) {
            $r = New-Object WinSenior.GuiRow
            $r.Id = "$($i.Location)|$($i.Name)"
            $r.Name = $i.Name; $r.Group = $i.Scope; $r.GroupLabel = T ([string]$i.Scope); $r.Detail = T ([string]$i.Location); $r.Info = [string]$i.Command
            $r.Selected = [bool]$i.Enabled
            Set-RowState $r $(if ($i.Enabled) { 'Enabled' } else { 'Disabled' })
            $tip = @($i.Name, ((T 'Command: {0}') -f $i.Command), ((T 'Source: {0}') -f $i.Source), ((T 'State stored in: {0}') -f $i.ApprovedKey))
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
    if (-not $sel) { Set-Status (T 'Select an entry first.'); return }
    $item = $script:StartupMap[$sel.Id]
    $path = if ($item.File) { $item.File } else { $item.Target }
    if ($path -and -not [System.IO.Path]::IsPathRooted($path)) {
        $cmd = Get-Command $path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $path = $cmd.Source }
    }
    if ($path -and (Test-Path -LiteralPath $path)) { Start-Process explorer.exe -ArgumentList ('/select,' + (ConvertTo-WsCmdArg $path)) }
    else { Set-Status ((T 'File not found: {0}') -f $path) }
})

# =====================================================================
# HISTORY PAGE
# =====================================================================
$script:HistRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:EngineLabels = @{ Cleanup = 'Cleanup'; Optimize = 'Optimization'; Repair = 'Diagnostics' }
$W.LvHistory.ItemsSource = $script:HistRows
$script:HistoryDirty = $true
$script:LastCleanEntry = $null
$script:LastRepairEntry = $null

function Update-History {
    $script:HistRows.Clear()
    $files = @(foreach ($d in $script:ReportDirs) {
        if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue }
    }) | Sort-Object LastWriteTime -Descending | Select-Object -First 400
    [int64]$total = 0; $runs = 0; $bad = 0; $cleanups = 0
    $script:LastCleanEntry = $null; $script:LastRepairEntry = $null
    foreach ($f in $files) {
        $rep = $null
        try { $rep = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $rep = $null }
        if (-not $rep -or -not $rep.Engine) { $bad++; continue }
        $h = Get-WsHistoryEntry -Report $rep -Path $f.FullName -FileTime $f.LastWriteTime
        $r = New-Object WinSenior.GuiRow
        $r.Id = $f.FullName
        $r.Name = $h.Date.ToString('yyyy-MM-dd HH:mm')
        $r.Group = $h.Engine; $r.GroupLabel = T $(if ($script:EngineLabels[$h.Engine]) { $script:EngineLabels[$h.Engine] } else { $h.Engine }); $r.Detail = T $h.Mode; $r.Size = $h.Result; $r.State = [string]$h.Errors
        $r.Info = T $h.Source; $r.Bytes = $h.Bytes; $r.Rank = [int]$h.Errors
        $r.Tip = "$($f.FullName)`nHost: $($rep.Host)   WinSenior $($rep.Version)   $($rep.DurationSec) s"
        $script:HistRows.Add($r)
        $total += $h.Bytes; $runs++
        if ($h.Engine -eq 'Cleanup' -and $h.Mode -eq 'Live') {
            $cleanups++
            if (-not $script:LastCleanEntry) { $script:LastCleanEntry = $h }
        }
        if ($h.Engine -eq 'Repair' -and -not $script:LastRepairEntry) { $script:LastRepairEntry = @{ Entry = $h; Report = $rep } }
    }
    $W.LblHistTotal.Text = Format-WsSize $total
    $W.LblHistRuns.Text = [string]$cleanups
    $W.LblHistCounts.Text = [string]$runs
    $W.PanelHistEmpty.Visibility = if ($runs) { 'Collapsed' } else { 'Visible' }
    $txt = (T 'Reports: {0}') -f ($script:ReportDirs -join '; ')
    if ($bad) { $txt += '   ' + [char]0x00B7 + '   ' + ((T '{0} unreadable file(s) skipped') -f $bad) }
    $W.LblHistStatus.Text = $txt
    $script:HistoryDirty = $false
}

function Get-HistorySelection {
    $sel = $W.LvHistory.SelectedItem
    if (-not $sel -and $script:HistRows.Count) { $sel = $script:HistRows[0] }
    $sel
}

function Export-HistoryHtml {
    param($Row)
    $rep = Get-Content -LiteralPath $Row.Id -Raw -Encoding UTF8 | ConvertFrom-Json
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = (T 'Web page') + ' (*.html)|*.html|' + (T 'All files') + '|*.*'
    $dlg.FileName = "WinSenior-{0}-{1}.html" -f ([string]$rep.Engine).ToLowerInvariant(), ($Row.Name -replace '[^0-9]', '')
    if (-not $dlg.ShowDialog($Win)) { return }
    $html = ConvertTo-WsReportHtml -Report $rep -SourcePath $Row.Id
    [System.IO.File]::WriteAllText($dlg.FileName, $html, (New-Object System.Text.UTF8Encoding($true)))
    Set-Status ((T 'Exported {0}') -f $dlg.FileName)
    Start-Process -FilePath $dlg.FileName
}

$W.BtnHistRefresh.Add_Click({ Update-History; Update-HomeHistory })
$W.BtnHistFolder.Add_Click({ Start-Process explorer.exe -ArgumentList (ConvertTo-WsCmdArg $script:ReportDir) })
$W.BtnHistOpen.Add_Click({
    $sel = Get-HistorySelection
    if (-not $sel) { Set-Status (T 'No reports yet.'); return }
    Start-Process notepad.exe -ArgumentList (ConvertTo-WsCmdArg $sel.Id)
})
$W.LvHistory.Add_MouseDoubleClick({
    $sel = $W.LvHistory.SelectedItem
    if ($sel) { Export-HistoryHtml $sel }
})
$W.BtnHistHtml.Add_Click({
    $sel = Get-HistorySelection
    if (-not $sel) { Set-Status (T 'No reports yet.'); return }
    Export-HistoryHtml $sel
})

# =====================================================================
# HOME (overview)
# =====================================================================
function Get-WsOsName {
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $name = [string]$cv.ProductName
        $build = [int]$cv.CurrentBuild
        # ProductName still says "Windows 10" on Windows 11.
        if ($build -ge 22000) { $name = $name -replace 'Windows 10', 'Windows 11' }
        $ver = if ($cv.DisplayVersion) { [string]$cv.DisplayVersion } else { [string]$cv.ReleaseId }
        return ("{0} {1} ({2}.{3})" -f $name, $ver, $build, $cv.UBR).Trim()
    } catch { return [string][Environment]::OSVersion.VersionString }
}

function Update-HomeSystem {
    $parts = @($env:COMPUTERNAME, (Get-WsOsName))
    try {
        $up = [TimeSpan]::FromMilliseconds([double][WinSenior.GuiNative]::GetTickCount64())
        $parts += $(if ($up.TotalDays -ge 1) { (T 'up {0} d {1} h') -f [int][Math]::Floor($up.TotalDays), $up.Hours } else { (T 'up {0} h {1} min') -f $up.Hours, $up.Minutes })
    } catch { Write-Verbose 'uptime unavailable' }
    $W.LblHomeSub.Text = $parts -join ('   ' + [char]0x00B7 + '   ')

    $W.PanelHomeDrives.Children.Clear()
    $bc = New-Object System.Windows.Media.BrushConverter
    foreach ($d in @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | Select-Object -First 4)) {
        $used = 100.0 * ([double]$d.TotalSize - [double]$d.AvailableFreeSpace) / [Math]::Max([double]1, [double]$d.TotalSize)
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Margin = '0,0,0,9'
        $head = New-Object System.Windows.Controls.DockPanel
        $free = New-Object System.Windows.Controls.TextBlock
        $free.Text = (T '{0} free') -f (Format-WsSize $d.AvailableFreeSpace)
        $free.Foreground = $Win.FindResource('Muted'); $free.FontSize = 12
        [System.Windows.Controls.DockPanel]::SetDock($free, 'Right')
        [void]$head.Children.Add($free)
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $d.Name.TrimEnd('\') + $(if ($d.VolumeLabel) { "  $($d.VolumeLabel)" } else { '' })
        $lbl.FontWeight = 'SemiBold'; $lbl.TextTrimming = 'CharacterEllipsis'
        [void]$head.Children.Add($lbl)
        [void]$row.Children.Add($head)
        $bar = New-Object System.Windows.Controls.ProgressBar
        $bar.Style = $Win.FindResource('Meter')
        $bar.Margin = '0,5,0,0'
        $bar.Value = $used
        $bar.Foreground = $bc.ConvertFromString($(if ($used -ge 90) { '#FF6B6B' } elseif ($used -ge 80) { '#F2B33D' } else { '#4C8DFF' }))
        $bar.ToolTip = (T '{0} used of {1}') -f (Format-WsSize ($d.TotalSize - $d.AvailableFreeSpace)), (Format-WsSize $d.TotalSize)
        [void]$row.Children.Add($bar)
        [void]$W.PanelHomeDrives.Children.Add($row)
    }
}

function Set-HomeHealth {
    param([int]$Fail, [int]$Warn, [datetime]$When)
    $W.LblHomeHealth.Text = if ($Fail) { (T 'Problems: {0}') -f $Fail } elseif ($Warn) { (T 'Warnings: {0}') -f $Warn } else { T 'All good' }
    $W.LblHomeHealth.Foreground = $Win.FindResource($(if ($Fail) { 'Bad' } elseif ($Warn) { 'Warn' } else { 'Ok' }))
    $sub = (T 'Last check: {0}') -f (Format-WsAgo $When)
    if ($Fail -and $Warn) { $sub = ((T 'Warnings: {0}') -f $Warn) + '   ' + [char]0x00B7 + '   ' + $sub }
    $W.LblHomeHealthSub.Text = $sub
    $W.BtnHomeReview.IsEnabled = $true
}

# Home tiles that come from History (last cleanup, last health check, recent runs).
function Update-HomeHistory {
    if ($script:LastCleanEntry) {
        $W.LblHomeClean.Text = Format-WsAgo $script:LastCleanEntry.Date
        $W.LblHomeCleanSub.Text = $script:LastCleanEntry.Result
    } else {
        $W.LblHomeClean.Text = T 'Never'
        $W.LblHomeCleanSub.Text = T 'No cleanup has run yet.'
    }
    if ($script:LastRepairEntry -and $W.LblHomeHealth.Text -eq '-') {
        $items = @($script:LastRepairEntry.Report.Items)
        Set-HomeHealth -Fail @($items | Where-Object { $_.Status -eq 'Fail' }).Count -Warn @($items | Where-Object { $_.Status -eq 'Warn' }).Count -When $script:LastRepairEntry.Entry.Date
    } elseif (-not $script:LastRepairEntry -and $W.LblHomeHealth.Text -eq '-') {
        $W.LblHomeHealthSub.Text = T 'Not checked yet - press Smart scan.'
    }
    $recent = @($script:HistRows | Select-Object -First 5)
    $W.IcHomeRecent.ItemsSource = $recent
    $W.LblHomeNoRecent.Visibility = if ($recent.Count) { 'Collapsed' } else { 'Visible' }
}

$W.LblHomeJunkSub.Text = T 'Press Smart scan to measure it.'
$W.BtnHomeScan.Add_Click({
    if (-not (Test-CleanOption)) { $W.NavClean.IsChecked = $true; return }
    $W.PanelHomeResults.Visibility = 'Visible'
    Start-CleanRun -Preview $true -Then {
        Start-RepairScan -Then {
            $junk = $W.LblHomeJunk.Text
            $fail = @($script:RepRows | Where-Object { $_.State -eq 'Fail' }).Count
            $warn = @($script:RepRows | Where-Object { $_.State -eq 'Warn' }).Count
            $kind = if ($fail) { 'warn' } else { 'ok' }
            Show-ResultBanner -Kind $kind -Title ((T 'Smart scan finished: {0} of junk, {1} problem(s), {2} warning(s).') -f $junk, $fail, $warn) `
                -Sub (T 'Nothing was changed. Press Clean now to free the space, or Review to see the problems.')
        }
    }
})
$W.BtnHomeClean.Add_Click({ Invoke-CleanNow })
$W.BtnHomeReview.Add_Click({ $W.NavRepair.IsChecked = $true })
$W.BtnHomeHistory.Add_Click({ $W.NavHistory.IsChecked = $true })
$W.BtnCardDrives.Add_Click({ $W.NavClean.IsChecked = $true })
$W.BtnCardClean.Add_Click({ $W.NavClean.IsChecked = $true })
$W.BtnCardOpt.Add_Click({ $W.NavOpt.IsChecked = $true })
$W.BtnCardStartup.Add_Click({ $W.NavStartup.IsChecked = $true })

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
            $r = New-Object WinSenior.GuiRow
            $r.Id = $_.FullName; $r.Name = $_.Name; $r.Detail = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Set-RowState $r 'active'
            try {
                $j = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $r.Size = [string]@($j.Tweaks | Where-Object { $null -ne $_ }).Count
                $made = ConvertTo-WsDate $j.Timestamp
                if ($made) { $r.Detail = $made.ToString('yyyy-MM-dd HH:mm') }
                if ($j.PSObject.Properties['UndoneAt'] -and $j.UndoneAt) {
                    $u = ConvertTo-WsDate $j.UndoneAt
                    Set-RowState $r 'undone'
                    $r.Tip = (T 'Already reverted') + $(if ($u) { " - $($u.ToString('yyyy-MM-dd HH:mm'))" } else { '' })
                }
            } catch { $r.Size = '?'; Set-RowState $r 'unreadable' }
            $script:BackupRows.Add($r)
        }
}
Update-Backups
$undoDone = {
    param($report, $code)
    Start-OptStateRead; Update-Backups
    if ($code -eq 0) { Show-ResultBanner -Kind ok -Title (T 'The optimization run was reverted.') -Sub (T 'Some changes take effect after signing out or restarting.') }
}
$W.BtnUndoLast.Add_Click({
    $next = $script:BackupRows | Where-Object { $_.State -eq 'active' } | Select-Object -First 1
    if (-not $next) { Set-Status $(if ($script:BackupRows.Count) { T 'Every backup has already been undone.' } else { T 'No backups found.' }); return }
    if (-not (Confirm-WsAction -Title (T 'Undo the newest optimization run?') -Text ((T 'Revert the {0} tweak(s) from {1} ({2}).') -f $next.Size, $next.Name, $next.Detail) -Ok (T 'Undo'))) { return }
    [void](Start-Engine -Script $script:OptimizeScript -Arguments @('-Undo', '-Unattended', '-BackupManifest', $next.Id) -Status (T 'Reverting newest run...') -Verb (T 'Reverting') -OnDone $undoDone)
})
$W.BtnUndoSel.Add_Click({
    $sel = $W.LvBackups.SelectedItem
    if (-not $sel) { Set-Status (T 'Select a backup first.'); return }
    $extra = if ($sel.State -eq 'undone') { "`n`n" + (T 'This backup was already undone once.') } else { '' }
    if (-not (Confirm-WsAction -Title (T 'Undo this optimization run?') -Text (((T 'Revert the tweaks from {0}.') -f $sel.Name) + $extra) -Ok (T 'Undo'))) { return }
    [void](Start-Engine -Script $script:OptimizeScript -Arguments @('-Undo', '-Unattended', '-BackupManifest', $sel.Id) -Status (T 'Reverting selected backup...') -Verb (T 'Reverting') -OnDone $undoDone)
})
$W.BtnBackupsRefresh.Add_Click({ Update-Backups })
$W.BtnOpenBackups.Add_Click({ if (-not (Test-Path $script:BackupDirPath)) { New-Item -ItemType Directory $script:BackupDirPath -Force | Out-Null }; Start-Process explorer.exe -ArgumentList (ConvertTo-WsCmdArg $script:BackupDirPath) })
$W.BtnRestorePoint.Add_Click({
    # Date computed here; the child only dot-sources the shared library (no temp script).
    $desc = 'WinSenior manual ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $lib = $script:CommonScript -replace "'", "''"
    $cmd = ". '$lib'; `$r = New-WinSeniorRestorePoint -Description '$desc' -LogAction { param(`$m, `$l) Write-WsLog -Message `$m -Level `$l }; if (`$r -eq 'Created') { exit 0 } else { exit 1 }"
    [void](Start-Engine -Command $cmd -Status (T 'Creating restore point...') -Verb (T 'Creating') -OnDone {
        $code = $args[1]
        if ($code -eq 0) { Show-ResultBanner -Kind ok -Title (T 'Restore point created.') -Sub $desc }
        else { Show-ResultBanner -Kind bad -Title (T 'The restore point was NOT created.') -Sub (T 'System Protection may be off for drive C:, or Windows allows one point per 24 hours. See the log.') }
    })
})
$W.BtnOpenRstrui.Add_Click({ Start-Process rstrui.exe })
$W.BtnOpenLogs.Add_Click({ Start-Process explorer.exe -ArgumentList (ConvertTo-WsCmdArg $script:LogDir) })
$W.BtnOpenTemp.Add_Click({ Start-Process explorer.exe -ArgumentList (ConvertTo-WsCmdArg $env:TEMP) })

# =====================================================================
# SCHEDULE PAGE
# =====================================================================
$script:InstallRoot = Get-WinSeniorInstallRoot
$W.LblSchedInfo.Text = (T 'Install copies the engine scripts to {0} (writable by administrators only) and the tasks run from there - never from this folder. Remove deletes that copy. Reports go to {1} and show up in History.') -f $script:InstallRoot, "$env:ProgramData\WinSenior\reports"
$script:SchedRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$W.IcSchedule.ItemsSource = $script:SchedRows

function Format-WsTaskTime {
    param($Value)
    if (-not $Value -or ([datetime]$Value).Year -lt 2000) { return (T 'not yet') }
    ([datetime]$Value).ToString('yyyy-MM-dd HH:mm')
}

function Update-Schedule {
    $script:SchedRows.Clear()
    $tasks = @(Get-ScheduledTask -TaskPath '\WinSenior\' -ErrorAction SilentlyContinue)
    $W.LblSchedule.Text = if ($tasks.Count) { (T '{0} installed') -f $tasks.Count } else { T 'Not installed' }
    $W.BtnSchedRemove.IsEnabled = ($tasks.Count -gt 0) -and -not $script:Busy
    if (-not $tasks.Count) {
        # Show what Install would set up.
        foreach ($p in @(@('WinSenior Weekly Cleanup', 'Every Sunday 03:00 - cleanup with the recommended tasks'),
                         @('WinSenior Monthly Health Scan', '1st of every month 03:30 - read-only health scan'))) {
            $r = New-Object WinSenior.GuiRow
            $r.Name = $p[0]; $r.Tip = T $p[1]; $r.Detail = '-'; $r.Info = '-'
            Set-RowState $r 'Not installed'
            $script:SchedRows.Add($r)
        }
    }
    foreach ($t in $tasks) {
        $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        $r = New-Object WinSenior.GuiRow
        $r.Name = $t.TaskName
        Set-RowState $r ([string]$t.State)
        $r.Detail = if ($info) { Format-WsTaskTime $info.NextRunTime } else { '?' }
        $last = if ($info) { Format-WsTaskTime $info.LastRunTime } else { '?' }
        if ($info -and $last -ne (T 'not yet')) {
            $res = [int64]$info.LastTaskResult
            $last += '  ' + $(if ($res -eq 0) { T '(OK)' } else { '(0x{0:X})' -f $res })
        }
        $r.Info = $last
        $desc = if ($t.TaskName -match 'Weekly') { T 'Every Sunday 03:00 - cleanup with the recommended tasks' }
                elseif ($t.TaskName -match 'Monthly') { T '1st of every month 03:30 - read-only health scan' } else { [string]$t.Description }
        $argText = [string](@($t.Actions)[0].Arguments)
        if ($argText -and $argText.IndexOf($script:InstallRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $desc += "`n" + ((T 'Runs scripts from an old location - press Install again to move them to {0}.') -f $script:InstallRoot)
        }
        $r.Tip = $desc
        $script:SchedRows.Add($r)
    }
}
# =====================================================================
# TOOLS PAGES (drivers / apps / memory / insights): each button runs its script
# as a child process; the output streams into the log panel, which is opened.
# =====================================================================
function Start-WsTool {
    param([string]$Script, [string[]]$Arguments = @(), [string]$Status, [string]$DoneTitle)
    if ($script:Busy) { Set-Status (T 'Another operation is still running.'); return }
    Set-LogOpen $true
    # Plain script variable, not GetNewClosure(): a closure runs in its own module
    # scope and cannot see this script's functions. Only one engine runs at a time.
    $script:ToolDoneTitle = $DoneTitle
    [void](Start-Engine -Script $Script -Arguments $Arguments -Status $Status -OnDone {
        if ($args[1] -eq 0 -and $script:ToolDoneTitle) { Show-ResultBanner -Kind ok -Title $script:ToolDoneTitle -Sub (T 'Details are in the log below.') }
    })
}

$W.BtnDrvCheck.Add_Click({ Start-WsTool $script:DriversScript @() (T 'Checking drivers (Microsoft Update can take a few minutes)...') (T 'Driver check finished.') })
$W.BtnDrvInstall.Add_Click({
    if (-not (Confirm-WsAction -Title (T 'Install driver updates?') -Text (T 'Every driver update from Microsoft Update except the graphics driver will be downloaded and installed. A restore point is created first; a reboot may be needed.'))) { return }
    Start-WsTool $script:DriversScript @('-Install', 'all') (T 'Installing driver updates...') (T 'Driver updates installed.')
})
$W.BtnDrvHideGpu.Add_Click({ Start-WsTool $script:DriversScript @('-HideGpuUpdates') (T 'Looking for GPU driver updates to hide...') (T 'GPU driver updates hidden from Windows Update.') })
$W.BtnDrvBackup.Add_Click({ Start-WsTool $script:DriversScript @('-Backup') (T 'Backing up drivers...') (T 'Drivers backed up.') })
$W.BtnDrvBackupOpen.Add_Click({
    $d = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WinSenior\DriverBackup'
    if (-not (Test-Path -LiteralPath $d)) { Set-Status (T 'No driver backup yet.'); return }
    Start-Process explorer.exe -ArgumentList "`"$d`""
})

$W.BtnAppsList.Add_Click({ Start-WsTool $script:AppsScript @('-List') (T 'Reading installed apps...') $null })
$W.BtnAppsUpdates.Add_Click({ Start-WsTool $script:AppsScript @('-Updates') (T 'Checking for app updates (winget)...') (T 'Update check finished.') })
$W.BtnAppsUpdateAll.Add_Click({
    if (-not (Confirm-WsAction -Title (T 'Update every app?') -Text (T 'winget will silently update every app that has a newer version. Close the apps you are using first.'))) { return }
    Start-WsTool $script:AppsScript @('-UpdateAll') (T 'Updating apps (winget)...') (T 'Apps updated.')
})
$W.BtnAppsUninstall.Add_Click({
    $n = $W.TxtAppName.Text.Trim()
    if (-not $n) { Set-Status (T 'Type the app name first.'); return }
    if (-not (Confirm-WsAction -Title (T 'Uninstall this app?') -Text $n -DangerButton -Ok (T 'Uninstall'))) { return }
    Start-WsTool $script:AppsScript @('-Uninstall', $n, '-RemoveLeftovers') (T 'Uninstalling...') (T 'Uninstall finished.')
})
$W.BtnAppsCatalog.Add_Click({ Start-WsTool $script:AppsScript @('-Catalog') (T 'Loading the catalog...') $null })
$W.BtnAppsInstall.Add_Click({
    $ids = @($W.TxtAppIds.Text -split '[\s,;]+' | Where-Object { $_ })
    if (-not $ids) { Set-Status (T 'Type one or more winget ids first.'); return }
    Start-WsTool $script:AppsScript @('-Install', ($ids -join ',')) (T 'Installing apps (winget)...') (T 'Installation finished.')
})

$W.BtnMemCheck.Add_Click({ Start-WsTool $script:MemoryScript @('-IncludeWsl') (T 'Checking memory...') $null })
$W.BtnMemReclaim.Add_Click({
    if (-not (Confirm-WsAction -Title (T 'Free leftover RAM?') -Text (T 'Idle build daemons and orphaned processes without a window will be stopped. They start again by themselves the next time they are needed.'))) { return }
    Start-WsTool $script:MemoryScript @('-Reclaim', '-Unattended') (T 'Freeing leftover RAM...') (T 'Leftover RAM freed.')
})
$W.BtnMemPrevent.Add_Click({ Start-WsTool $script:MemoryScript @('-Prevent', '-IncludeWsl') (T 'Applying settings...') (T 'Settings applied.') })
$W.BtnMemAutoOn.Add_Click({ Start-WsTool $script:MemoryScript @('-InstallAuto') (T 'Registering the background check...') (T 'Automatic mode is on.') })
$W.BtnMemAutoOff.Add_Click({ Start-WsTool $script:MemoryScript @('-RemoveAuto') (T 'Removing the background check...') (T 'Automatic mode is off.') })

$W.BtnInsRun.Add_Click({ Start-WsTool $script:InsightsScript @() (T 'Analyzing...') (T 'Analysis finished.') })
function Get-WsPlanGb {
    $v = 0.0
    $t = ($W.TxtPlanGb.Text.Trim() -replace ',', '.')
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -gt 0) { return $v }
    Set-Status (T 'Type how many GB to free.'); $null
}
$W.BtnInsPlan.Add_Click({
    $gb = Get-WsPlanGb; if (-not $gb) { return }
    Start-WsTool $script:InsightsScript @('-Plan', ([string]$gb).Replace(',', '.')) (T 'Building the plan (scans first if needed)...') $null
})
$W.BtnInsApply.Add_Click({
    $gb = Get-WsPlanGb; if (-not $gb) { return }
    if (-not (Confirm-WsAction -Title (T 'Free this space now?') -Text ((T 'The cleanup tasks with the least side effects that free {0} GB will run now. Irreversible tasks are never chosen.') -f $gb))) { return }
    Start-WsTool $script:InsightsScript @('-Plan', ([string]$gb).Replace(',', '.'), '-Apply') (T 'Freeing space...') (T 'Cleanup finished.')
})

$W.BtnSchedInstall.Add_Click({
    [void](Start-Engine -Script $script:MenuScript -Arguments @('-InstallSchedule', '-NoElevate') -Status (T 'Installing scheduled tasks...') -OnDone {
        Update-Schedule
        if ($args[1] -eq 0) { Show-ResultBanner -Kind ok -Title (T 'Scheduled maintenance is installed.') -Sub (T 'Weekly cleanup on Sundays at 03:00, health scan on the 1st of each month.') }
    })
})
$W.BtnSchedRemove.Add_Click({
    if (-not (Confirm-WsAction -Title (T 'Remove the scheduled tasks?') -Text (T 'Automatic maintenance stops. You can install it again at any time.') -Ok (T 'Remove'))) { return }
    [void](Start-Engine -Script $script:MenuScript -Arguments @('-RemoveSchedule', '-NoElevate') -Status (T 'Removing scheduled tasks...') -OnDone { Update-Schedule })
})
$W.BtnSchedRefresh.Add_Click({ Update-Schedule })
$W.BtnSchedOpen.Add_Click({ Start-Process taskschd.msc })

# =====================================================================
# SETTINGS / ABOUT / ADMIN
# =====================================================================
$ver = Get-WinSeniorVersion
$W.LblVersion.Text = "v$ver"
$script:IsAdmin = Test-AdminPrivileges
if ($script:IsAdmin) {
    $W.LblAdmin.Text = T 'Administrator'
} else {
    $W.LblAdmin.Text = T 'Limited rights'
    $W.AdminDot.Fill = $Win.FindResource('Warn')
    $W.BannerAdmin.Visibility = 'Visible'
}
$W.LblHost.Text  = "PowerShell $($PSVersionTable.PSVersion)"
$W.LblAbout.Text = ((T 'Windows Senior {0} - cleaner, optimizer and troubleshooter for Windows 10 and 11.') -f "v$ver") + "`n" +
    ((T '{0} cleanup tasks, {1} optimization tweaks, {2} diagnostic checks.') -f $script:CleanReg.Count, $script:OptReg.Count, $script:RepReg.Count) + "`n`n" +
    (T 'This window drives the same PowerShell engines as the console menu and the command line, so every action keeps the real dry run, the delete safety guard, System Restore points and per-tweak undo.') + "`n" +
    (T 'MIT License - free and open source.')
$W.LblPaths.Text = ((T 'Settings: {0}') -f $script:SettingsFile) + "`n" + ((T 'Run reports: {0}') -f $script:ReportDir) + "`n" +
    ((T 'Engine logs: {0}') -f "$env:TEMP\WindowsCleanup.log, WindowsOptimize.log, WindowsRepair.log") + "`n" + ((T 'Backups: {0}') -f $script:BackupDirPath)
$W.BtnOpenRepo.Add_Click({ Start-Process 'https://github.com/denfry/WindowsCleaner' })
$W.BtnOpenReleases.Add_Click({ Start-Process 'https://github.com/denfry/WindowsCleaner/releases/latest' })
$W.BtnOpenConsole.Add_Click({
    Start-Process -FilePath $script:HostExe -ArgumentList ((@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:MenuScript, '-NoElevate') | ForEach-Object { ConvertTo-WsCmdArg $_ }) -join ' ')
})

# Restart this window (language switch, elevation). The single-instance mutex is
# released first so the new window may start; on failure it is taken back.
$script:Restarting = $false
function Restart-WsApp {
    param([switch]$Elevate)
    if ($script:Busy) { Set-Status (T 'Wait for the running operation to finish first.'); return }
    if ($script:LogOpen -and $W.LogRow.ActualHeight -gt 80) { $script:LogHeight = [int]$W.LogRow.ActualHeight }
    [void](Save-GuiSettings)
    $argLine = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $PSCommandPath) + $(if ($Elevate) { @() } else { @('-NoElevate') }) |
        ForEach-Object { ConvertTo-WsCmdArg $_ }) -join ' '
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { Write-Verbose 'mutex not owned' } }
    try {
        if ($Elevate) { Start-Process -FilePath $script:HostExe -Verb RunAs -WindowStyle Hidden -ArgumentList $argLine -ErrorAction Stop }
        else { Start-Process -FilePath $script:HostExe -WindowStyle Hidden -ArgumentList $argLine -ErrorAction Stop }
    } catch {
        if ($script:Mutex) { try { [void]$script:Mutex.WaitOne(0) } catch { Write-Verbose 'mutex not retaken' } }
        Set-Status ((T 'Could not restart: {0}') -f (Get-WsErrorText $_))
        return
    }
    $script:Restarting = $true
    $Win.Close()
}
$W.BtnElevate.Add_Click({ Restart-WsApp -Elevate })

switch ($script:LangSetting) { 'en' { $W.RbLangEn.IsChecked = $true } 'ru' { $W.RbLangRu.IsChecked = $true } default { $W.RbLangAuto.IsChecked = $true } }
foreach ($rb in 'RbLangAuto', 'RbLangEn', 'RbLangRu') {
    $W[$rb].Add_Checked({
        param($src)
        if ($script:LangReverting) { return }
        $new = switch ($src.Name) { 'RbLangEn' { 'en' } 'RbLangRu' { 'ru' } default { 'auto' } }
        if ($new -eq $script:LangSetting) { return }
        if ($script:Busy) {
            $script:LangReverting = $true
            try { $W[$(switch ($script:LangSetting) { 'en' { 'RbLangEn' } 'ru' { 'RbLangRu' } default { 'RbLangAuto' } })].IsChecked = $true }
            finally { $script:LangReverting = $false }
            Set-Status (T 'Wait for the running operation to finish first.')
            return
        }
        $script:LangSetting = $new
        if (-not (Save-GuiSettings)) {
            Show-ResultBanner -Kind warn -Title (T 'The language could not be saved.') -Sub ((T 'No write access to {0}.') -f $script:SettingsFile)
            return
        }
        $target = Resolve-WsLanguage -Setting $new -UiCulture ([System.Globalization.CultureInfo]::CurrentUICulture.Name)
        if ($target -eq $script:Lang) { return }
        if (Confirm-WsAction -Title (T 'Restart to switch the language?') -Text (T 'The window closes and opens again in the new language. Nothing else changes.') -Ok (T 'Restart now')) {
            Restart-WsApp
        }
    })
}

# =====================================================================
# NAVIGATION, SHORTCUTS, LOG BUTTONS
# =====================================================================
function Update-AllStatus {
    Update-CleanStatus; Update-OptStatus
    if ($script:StartupLoaded) { Update-StartupStatus }
}

Register-WsList $W.LvClean   $W.TxtCleanFilter   1
Register-WsList $W.LvOpt     $W.TxtOptFilter     1
Register-WsList $W.LvRep     $W.TxtRepFilter     3
Register-WsList $W.LvStartup $W.TxtStartupFilter 4
Register-WsList $W.LvHistory $null               3
Register-WsList $W.LvBackups $null               0

$script:NavOrder = @('NavHome', 'NavClean', 'NavOpt', 'NavRepair', 'NavStartup', 'NavDrivers', 'NavApps', 'NavMemory', 'NavInsights',
                     'NavHistory', 'NavUndo', 'NavSchedule', 'NavAbout')
$script:PageOf = @{ NavHome = 'PageHome'; NavClean = 'PageClean'; NavOpt = 'PageOpt'; NavRepair = 'PageRepair'; NavStartup = 'PageStartup'
                    NavDrivers = 'PageDrivers'; NavApps = 'PageApps'; NavMemory = 'PageMemory'; NavInsights = 'PageInsights'
                    NavHistory = 'PageHistory'; NavUndo = 'PageUndo'; NavSchedule = 'PageSchedule'; NavAbout = 'PageAbout' }
$script:CurrentNav = 'NavHome'
foreach ($nav in $script:NavOrder) {
    $W[$nav].Add_Checked({
        param($src)
        foreach ($p in $script:PageOf.Values) { $W[$p].Visibility = 'Collapsed' }
        $script:CurrentNav = $src.Name
        $page = $script:PageOf[$src.Name]
        $W[$page].Visibility = 'Visible'
        switch ($page) {
            'PageOpt'      { if (-not $script:OptStateLoaded) { Start-OptStateRead } }
            'PageStartup'  { if (-not $script:StartupLoaded) { Update-Startup } }
            'PageHistory'  { if ($script:HistoryDirty) { Update-History; Update-HomeHistory } }
            'PageSchedule' { Update-Schedule }
            'PageHome'     { Update-HomeSystem }
        }
    })
}
if (-not $script:HasStartup) { $W.NavStartup.IsEnabled = $false; $W.NavStartup.ToolTip = T 'WinSenior.Startup.ps1 not found' }

$script:PageFilter = @{ NavClean = 'TxtCleanFilter'; NavOpt = 'TxtOptFilter'; NavRepair = 'TxtRepFilter'; NavStartup = 'TxtStartupFilter' }
$script:PageRefresh = @{ NavHome = 'BtnHomeScan'; NavClean = 'BtnScan'; NavOpt = 'BtnOptRefresh'; NavRepair = 'BtnRepScan'; NavStartup = 'BtnStartupRefresh'
                         NavHistory = 'BtnHistRefresh'; NavUndo = 'BtnBackupsRefresh'; NavSchedule = 'BtnSchedRefresh' }
$Win.Add_PreviewKeyDown({
    $e = $args[1]
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $key = $e.Key
    if ($ctrl -and $key -ge [System.Windows.Input.Key]::D1 -and $key -le [System.Windows.Input.Key]::D9) {
        $i = [int]$key - [int][System.Windows.Input.Key]::D1
        if ($i -lt $script:NavOrder.Count -and $W[$script:NavOrder[$i]].IsEnabled) { $W[$script:NavOrder[$i]].IsChecked = $true }
        $e.Handled = $true; return
    }
    if ($ctrl -and $key -eq 'F') {
        $f = $script:PageFilter[$script:CurrentNav]
        if ($f) { [void]$W[$f].Focus(); $W[$f].SelectAll() }
        $e.Handled = $true; return
    }
    if ($ctrl -and $key -eq 'L') { Set-LogOpen (-not $script:LogOpen); $e.Handled = $true; return }
    if ($key -eq 'F5') {
        $b = $script:PageRefresh[$script:CurrentNav]
        if ($b -and $W[$b].IsEnabled) { $W[$b].RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) }
        $e.Handled = $true; return
    }
    if ($key -eq 'Escape' -and $e.OriginalSource -is [System.Windows.Controls.TextBox] -and $e.OriginalSource.Text -and -not $e.OriginalSource.IsReadOnly) {
        $e.OriginalSource.Text = ''; $e.Handled = $true
    }
})

$W.BtnLogClear.Add_Click({ $W.TxtLog.Clear(); $script:LogChars = 0 })
$W.BtnLogSave.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = (T 'Log files') + ' (*.log)|*.log|' + (T 'All files') + '|*.*'
    $dlg.FileName = "WinSenior-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
    if ($dlg.ShowDialog($Win)) { Set-Content -Path $dlg.FileName -Value $W.TxtLog.Text -Encoding UTF8; Set-Status ((T 'Saved {0}') -f $dlg.FileName) }
})

# =====================================================================
# WINDOW: remembered size, dark title bar, taskbar progress, closing
# =====================================================================
$Win.Title = 'Windows Senior ' + "v$ver"
$Win.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
$script:LogOpen = [bool]$settings.LogOpen
$script:LogHeight = [Math]::Max(120, [int]$settings.LogHeight)
Set-LogOpen $script:LogOpen

if ($settings.WinWidth -and $settings.WinHeight) {
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
    $l = [double]$settings.WinLeft; $tp = [double]$settings.WinTop; $ww = [double]$settings.WinWidth; $wh = [double]$settings.WinHeight
    # Only when the saved window is still (mostly) on a connected screen.
    if ($ww -ge $Win.MinWidth -and $wh -ge $Win.MinHeight -and $l -ge ($vl - 40) -and $tp -ge ($vt - 40) -and ($l + 200) -le ($vl + $vw) -and ($tp + 120) -le ($vt + $vh)) {
        $Win.WindowStartupLocation = 'Manual'
        $Win.Left = $l; $Win.Top = $tp; $Win.Width = $ww; $Win.Height = $wh
    }
}
if ($settings.WinMax) { $Win.WindowState = 'Maximized' }

$Win.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Win).Handle
        $on = 1
        if ([WinSenior.GuiNative]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4) -ne 0) {
            [void][WinSenior.GuiNative]::DwmSetWindowAttribute($hwnd, 19, [ref]$on, 4)
        }
    } catch { Write-Verbose 'dark title bar unavailable' }
})

# First paint first, then the slower reads (history, startup apps, tweak state).
$Win.Add_ContentRendered({
    $Win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
        try {
            Update-History
            Update-HomeHistory
            if ($script:HasStartup -and -not $script:StartupLoaded) { Update-Startup }
            foreach ($lv in 'LvClean', 'LvOpt', 'LvRep', 'LvStartup', 'LvHistory', 'LvBackups') { Update-WsFillColumn $W[$lv] }
        } catch { Add-Log "[x] Startup read: $(Get-WsErrorText $_)" }
        Start-OptStateRead
    }) | Out-Null
})

$Win.Add_Closing({
    $e = $args[1]
    if ($script:Busy -and -not $script:AutoClosing) {
        if (-not (Confirm-WsAction -Title (T 'Quit Windows Senior?') -Text (T 'An operation is still running. Cancel it and quit?') -Ok (T 'Cancel and quit') -Kind warn -DangerButton)) { $e.Cancel = $true; return }
    }
    if ($script:Proc -and -not $script:Proc.HasExited) {
        & taskkill.exe /PID $script:Proc.Id /T /F *>$null
        try { [void]$script:Proc.WaitForExit(3000) } catch { Write-Verbose 'child already gone' }
    }
    $script:Timer.Stop()
    $script:OptStateTimer.Stop()
    if ($script:OptStateJob) { try { $script:OptStateJob.PS.Stop(); $script:OptStateJob.PS.Dispose() } catch { Write-Verbose 'state reader gone' } }
    foreach ($tmp in @($script:ReportTmp, $(if ($script:OutFile) { "$script:OutFile.err" }))) {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($script:LogOpen -and $W.LogRow.ActualHeight -gt 80) { $script:LogHeight = [int]$W.LogRow.ActualHeight }
    if (-not $script:Restarting) { [void](Save-GuiSettings) }
    if ($env:WINSENIOR_GUI_SMOKELOG) {
        try {
            $smoke = $W.TxtLog.Text + "`r`nSTATUS: " + $W.LblStatus.Text + "`r`n"
            [System.IO.File]::WriteAllText($env:WINSENIOR_GUI_SMOKELOG, $smoke, [System.Text.Encoding]::UTF8)
        } catch { Write-Verbose 'smoke log not written' }
    }
})

try { Update-HomeSystem } catch { Add-Log "[x] Overview: $(Get-WsErrorText $_)" }
Add-Log "Windows Senior v$ver ready. $($script:CleanReg.Count) cleanup tasks, $($script:OptReg.Count) tweaks, $($script:RepReg.Count) checks. UI language: $script:Lang."
if (-not $script:IsAdmin) { Add-Log 'WARNING: not running as Administrator - most actions will fail.' }
Set-Status (T 'Ready.')

# =====================================================================
# AUTOMATION HOOKS (smoke tests) - see the header for the variables
# =====================================================================
if ($env:WINSENIOR_GUI_PAGE -and $W[$env:WINSENIOR_GUI_PAGE] -is [System.Windows.Controls.RadioButton]) {
    $Win.Add_ContentRendered({ $W[$env:WINSENIOR_GUI_PAGE].IsChecked = $true })
}
# Only read-only buttons may be pressed automatically - never Clean / Apply / Fix / Undo.
$script:SafeAutoRun = @('BtnScan', 'BtnHomeScan', 'BtnOptPreview', 'BtnRepScan', 'BtnOptRefresh', 'BtnStartupRefresh', 'BtnHistRefresh', 'BtnBackupsRefresh', 'BtnSchedRefresh', 'BtnCleanOptions', 'BtnLogToggle',
                          'BtnMemCheck', 'BtnAppsList', 'BtnAppsCatalog', 'BtnInsRun', 'BtnDrvCheck')
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
        # Let a running engine (and the tweak-state reader) finish before closing.
        if (($script:Busy -or $script:OptStateJob) -and ((Get-Date) - $script:AutoStarted).TotalSeconds -lt $script:AutoMaxWait) {
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
    if ($script:Mutex) {
        if (-not $script:Restarting) { try { $script:Mutex.ReleaseMutex() } catch { Write-Verbose 'mutex not owned' } }
        $script:Mutex.Dispose()
    }
}
