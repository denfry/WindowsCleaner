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
    Version : 6.0.0
#>

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
    try {
        # Clear the 24-hour throttle so a back-to-back run still gets a point.
        $rk = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        New-ItemProperty -Path $rk -Name 'SystemRestorePointCreationFrequency' `
            -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description `
            -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        & $LogAction 'System Restore point created' 'Success'
        return 'Created'
    }
    catch {
        & $LogAction "Restore point not created: $($_.Exception.Message)" 'Warning'
        & $LogAction 'Continuing without a restore point (System Protection may be off).' 'Warning'
        return 'Failed'
    }
}
