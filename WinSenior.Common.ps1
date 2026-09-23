<#
.SYNOPSIS
    Shared library for the WinSenior engines (cleanup / optimize / repair).

.DESCRIPTION
    Dot-sourced by every engine and by the WinSenior menu. Holds the helpers that
    were previously copy-pasted into each engine: the admin check, the WhatIf probe,
    byte formatting, the console+file logger, and the System Restore point routine.
    Keeping them in one place means a fix to the restore-point logic or the log
    format lands everywhere at once instead of drifting between three copies.

    Source stays pure ASCII (no box glyphs, no Cyrillic) so it loads identically
    under Windows PowerShell 5.1 regardless of file encoding.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.3.0
#>

# When an engine's stdout is redirected (desktop app, scheduler, CI) emit UTF-8
# instead of the OEM code page, so non-English text (paths, localized errors)
# survives the round-trip. An interactive console keeps its own code page.
try {
    if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) }
} catch { Write-Verbose "OutputEncoding: $($_.Exception.Message)" }

# =====================================================================
# ENVIRONMENT PROBES
# =====================================================================
function Test-AdminPrivileges {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Test-WhatIfMode { [bool]$WhatIfPreference }

# =====================================================================
# FORMATTING
# =====================================================================
function Format-FileSize {
    param([long]$Size)
    if     ($Size -ge 1TB) { '{0:N2} TB' -f ($Size / 1TB) }
    elseif ($Size -ge 1GB) { '{0:N2} GB' -f ($Size / 1GB) }
    elseif ($Size -ge 1MB) { '{0:N2} MB' -f ($Size / 1MB) }
    elseif ($Size -ge 1KB) { '{0:N2} KB' -f ($Size / 1KB) }
    else                   { "$Size B" }
}

# =====================================================================
# LOGGING
#   Canonical logger. Each engine keeps a thin Write-<Engine>Log wrapper
#   that forwards here with its own -LogPath, so call sites are unchanged.
# =====================================================================
function Write-WsLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug','Step','WhatIf','Safety')]
        [string]$Level = 'Info',
        [string]$LogPath
    )
    $tag = switch ($Level) {
        'Success' { '[+]' } 'Warning' { '[!]' } 'Error' { '[x]' }
        'Step'    { '==>' } 'WhatIf'  { '[~]' } 'Safety' { '[#]' }
        'Debug'   { '   ' } default   { '[i]' }
    }
    $color = switch ($Level) {
        'Success' { 'Green' } 'Warning' { 'Yellow' } 'Error' { 'Red' }
        'Step'    { 'Cyan' }  'WhatIf'  { 'Cyan' }   'Safety' { 'Magenta' }
        'Debug'   { 'DarkGray' } default { 'Gray' }
    }
    if ($Level -ne 'Debug' -or $VerbosePreference -ne 'SilentlyContinue') {
        Write-Host "$tag $Message" -ForegroundColor $color
    }
    # Logging is infrastructure, not a cleanup action: never let -WhatIf suppress it.
    if ($LogPath) {
        $stamp = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
        try { Add-Content -Path $LogPath -Value $stamp -ErrorAction SilentlyContinue -WhatIf:$false } catch { }
    }
}

# =====================================================================
# SYSTEM RESTORE POINT
#   Returns 'WhatIf' | 'Created' | 'Failed'. The caller owns its own
#   $script:RestorePointMade flag (set it only on 'Created'). Logging is
#   delegated through -LogAction so each engine logs in its own voice.
# =====================================================================
# Checkpoint-Computer / Enable-ComputerRestore do not exist in PowerShell 7, and the
# desktop app prefers pwsh - so go through the SystemRestore WMI class, which both
# runtimes have. Thin wrappers so tests can mock them.
function Enable-WsSystemRestore {
    param([string]$Drive)
    try {
        Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName Enable `
            -Arguments @{ Drive = $Drive } -ErrorAction Stop | Out-Null
    } catch { Write-Verbose "SystemRestore.Enable: $($_.Exception.Message)" }
}

function Invoke-WsCheckpoint {
    param([string]$Description)
    # RestorePointType 12 = MODIFY_SETTINGS, EventType 100 = BEGIN_SYSTEM_CHANGE
    $r = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint `
        -Arguments @{ Description = $Description; RestorePointType = [uint32]12; EventType = [uint32]100 } `
        -ErrorAction Stop
    if ($r.ReturnValue -ne 0) {
        throw ("SystemRestore.CreateRestorePoint returned 0x{0:X8} (System Protection may be off)" -f [uint32]$r.ReturnValue)
    }
}

function New-WinSeniorRestorePoint {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$LogAction
    )
    if (Test-WhatIfMode) {
        & $LogAction '[WhatIf] would create a System Restore point' 'WhatIf'
        return 'WhatIf'
    }
    & $LogAction 'Creating System Restore point...' 'Safety'
    # Lift the 24-hour throttle for this one checkpoint, then put the user's setting
    # back exactly as it was (value or absence) so the system default is not changed.
    $throttle = Set-WsRestoreThrottle -Value 0
    try {
        Enable-WsSystemRestore -Drive "$env:SystemDrive\"
        Invoke-WsCheckpoint -Description $Description
        & $LogAction 'System Restore point created' 'Success'
        return 'Created'
    }
    catch {
        & $LogAction "Restore point not created: $($_.Exception.Message)" 'Warning'
        & $LogAction 'Continuing without a restore point (System Protection may be off).' 'Warning'
        return 'Failed'
    }
    finally { Set-WsRestoreThrottle -Restore $throttle | Out-Null }
}

# Set (-Value) or restore (-Restore <previous>) SystemRestorePointCreationFrequency.
# Returns the previous value ($null = was absent). Uses the .NET registry API so the
# restore path can delete the value without Remove-ItemProperty.
function Set-WsRestoreThrottle {
    param([Nullable[int]]$Value, [object]$Restore = 'none')
    $sub = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, $true)
        if (-not $key) { return $null }
        try {
            $prev = $key.GetValue($name, $null)
            if ($Restore -ne 'none') {
                if ($null -eq $Restore) { $key.DeleteValue($name, $false) }
                else { $key.SetValue($name, [int]$Restore, [Microsoft.Win32.RegistryValueKind]::DWord) }
            }
            elseif ($null -ne $Value) { $key.SetValue($name, [int]$Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
            return $prev
        } finally { $key.Close() }
    } catch { Write-Verbose "restore throttle: $($_.Exception.Message)"; return $null }
}

# =====================================================================
# REPORTING
#   One envelope for every engine so a parser reads them all the same.
#   Common top level: Tool/Version/Engine/Host/Timestamp/Mode/RestorePoint/
#   DurationSec; engine-specific counters go in Summary, the per-unit list
#   in Items. No-op without -ReportPath.
# =====================================================================
function Get-WinSeniorVersion { '6.3.0' }

function Write-WinSeniorReport {
    param(
        [string]$ReportPath,
        [Parameter(Mandatory)][ValidateSet('Cleanup', 'Optimize', 'Repair')][string]$Engine,
        [hashtable]$Summary = @{},
        $Items = @(),
        [bool]$RestorePoint,
        [datetime]$StartTime,
        [scriptblock]$LogAction
    )
    if (-not $ReportPath) { return }
    # '{timestamp}' in the path gives every run its own file (scheduled runs keep a
    # history instead of overwriting one report). Resolved once per process so an
    # engine that rewrites its report (Repair: after scan, again after fixes) keeps
    # a single file. Only the newest 60 files of that pattern are kept.
    if ($ReportPath -like '*{timestamp}*') {
        if (-not $script:WsReportStamp) { $script:WsReportStamp = (Get-Date).ToString('yyyyMMdd-HHmmss') }
        $pattern    = [IO.Path]::GetFileName($ReportPath).Replace('{timestamp}', '*')
        $ReportPath = $ReportPath.Replace('{timestamp}', $script:WsReportStamp)
        $dir = [IO.Path]::GetDirectoryName($ReportPath)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
        }
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            Get-ChildItem -LiteralPath $dir -Filter $pattern -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -Skip 59 |
                ForEach-Object { try { [IO.File]::Delete($_.FullName) } catch { Write-Verbose "prune: $($_.Exception.Message)" } }
        }
    }
    # Normalise to a flat array. Note: @() throws "Argument types do not match"
    # on a Generic.List[object] (which is exactly what the engines pass), so cast.
    $itemArr = if ($null -eq $Items) { @() } else { [object[]]$Items }
    $report = [ordered]@{
        Tool         = 'WinSenior'
        Version      = (Get-WinSeniorVersion)
        Engine       = $Engine
        Host         = $env:COMPUTERNAME
        Timestamp    = (Get-Date).ToString('s')
        Mode         = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
        RestorePoint = [bool]$RestorePoint
        DurationSec  = if ($StartTime) { [math]::Round(((Get-Date) - $StartTime).TotalSeconds, 1) } else { $null }
        Summary      = $Summary
        Items        = $itemArr
    }
    try {
        ($report | ConvertTo-Json -Depth 6) | Set-Content -Path $ReportPath -Encoding UTF8 -WhatIf:$false
        if ($LogAction) { & $LogAction "JSON report written: $ReportPath" 'Info' }
    }
    catch {
        if ($LogAction) { & $LogAction "Could not write report: $($_.Exception.Message)" 'Warning' }
    }
}
