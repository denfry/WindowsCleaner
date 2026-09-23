<#
.SYNOPSIS
    Windows optimization engine - registry-driven tweaks with full per-tweak undo.

.DESCRIPTION
    A declarative, single-file Windows 10/11 optimization tool. Every tweak is one entry
    in a tweak registry; a small engine resolves which tweaks to run, snapshots the prior
    state into a backup manifest, and applies through PowerShell's ShouldProcess so -WhatIf
    is real. -Undo reverts everything from the newest (or a named) manifest.

    Four areas: Performance, Privacy, Debloat, Network. Aggressive but reversible: Safe +
    Moderate + Aggressive tiers are selectable by default, but debatable tweaks ship off
    until you turn them on. A real System Restore point is created first unless -NoRestorePoint.

    It never disables Defender real-time protection, never breaks Windows Update or the
    network stack wholesale, and never removes Edge or the Store.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.3.0
    Requires: PowerShell 5.1+ (Windows). Administrator rights.

.EXAMPLE
    .\Optimize-Windows-Senior.ps1 -WhatIf
    Preview every tweak that would be applied, change nothing.

.EXAMPLE
    .\Optimize-Windows-Senior.ps1 -Area Privacy,Performance
    Apply only the privacy and performance tweaks (default-on set).

.EXAMPLE
    .\Optimize-Windows-Senior.ps1 -Undo
    Revert the most recent optimization run from its backup manifest.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    # Limit to these areas: Performance, Privacy, Debloat, Network
    [string[]]$Area,

    # Force these tweak ids on (overrides default-off, area and risk cap)
    [string[]]$Include,

    # Force these tweak ids off (wins over everything)
    [string[]]$Exclude,

    # Also apply the irreversible Dangerous tier
    [switch]$IncludeDangerous,

    # Cap at Safe + Moderate (skip the Aggressive tier)
    [Alias('SafeMode')]
    [switch]$Conservative,

    # Revert a previous run from its backup manifest (newest unless -BackupManifest given)
    [switch]$Undo,

    # Specific backup manifest to undo (default: newest in -BackupDir)
    [string]$BackupManifest,

    # Preview alias for -WhatIf
    [Alias('dr')]
    [switch]$DryRun,

    # Non-interactive: no prompts, used for automation
    [Alias('Force','f')]
    [switch]$Unattended,

    # Skip the real System Restore point that is otherwise created first
    [Alias('nrp')]
    [switch]$NoRestorePoint,

    # Where per-tweak backup manifests are written
    [string]$BackupDir = "$env:ProgramData\WinSenior\backups",

    [string]$LogPath = "$env:TEMP\WindowsOptimize.log",

    # Optional path for a machine-readable JSON report
    [string]$ReportPath,

    # Print the tweak registry and exit
    [switch]$ListTweaks,

    [switch]$Help
)

# =====================================================================
# SCRIPT STATE
# =====================================================================
$script:StartTime       = Get-Date
$script:Stats           = New-Object System.Collections.Generic.List[object]
$script:Snapshots       = New-Object System.Collections.Generic.List[object]
$script:Applied         = 0
$script:Skipped         = 0
$script:Errors          = 0
$script:RestorePointMade = $false
$script:ManifestFile    = $null
$script:AppxReady       = $null

if ($DryRun) { $WhatIfPreference = $true }

# Split comma-joined id lists. A caller using -File (the desktop app) passes
# -Include 'a,b,c' as ONE string, which would never match a tweak id.
function ConvertTo-OptIdList {
    param([string[]]$Value)
    @($Value | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$Area    = ConvertTo-OptIdList -Value $Area
$Include = ConvertTo-OptIdList -Value $Include
$Exclude = ConvertTo-OptIdList -Value $Exclude

# =====================================================================
# SHARED LIBRARY (admin / restore-point / logging / format helpers)
# =====================================================================
. (Join-Path $PSScriptRoot 'WinSenior.Common.ps1')

# =====================================================================
# LOGGING
# =====================================================================
function Write-OptLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug','Step','WhatIf','Safety')]
        [string]$Level = 'Info'
    )
    Write-WsLog -Message $Message -Level $Level -LogPath $LogPath
}

# =====================================================================
# UTILITIES
# =====================================================================
function New-OptRestorePoint {
    $st = New-WinSeniorRestorePoint `
        -Description "Before Windows Optimize $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        -LogAction { param($m, $l) Write-OptLog $m $l }
    if ($st -eq 'Created') { $script:RestorePointMade = $true }
    return ($st -ne 'Failed')
}

# =====================================================================
# REGISTRY HELPERS (used by Registry-type tweaks; self-contained for undo)
# =====================================================================
function Get-RegValueSnapshot {
    param([string]$Path, [string]$Name)
    $snap = [ordered]@{ Path = $Path; Name = $Name; Existed = $false; Value = $null; Kind = $null }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and ($item.GetValueNames() -contains $Name)) {
            $snap.Existed = $true
            # Keep REG_EXPAND_SZ data unexpanded so a restore writes back the original text.
            $snap.Value   = $item.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            try { $snap.Kind = [string]$item.GetValueKind($Name) } catch { $snap.Kind = $null }
        }
    }
    [pscustomobject]$snap
}

# Coerce a value to what New-ItemProperty expects for the given kind. Needed on
# restore, where a manifest round-trip turns byte[] / string[] into object[].
function ConvertTo-RegData {
    param([string]$Kind, $Value)
    if ($null -eq $Value -and $Kind -eq 'Binary') { return ,([byte[]]@()) }
    switch ($Kind) {
        'Binary'      { return ,([byte[]]@($Value | ForEach-Object { [byte]$_ })) }
        'MultiString' { return ,([string[]]@($Value | ForEach-Object { [string]$_ })) }
        default       { return $Value }
    }
}

function Set-RegValue {
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    $data = ConvertTo-RegData -Kind $Kind -Value $Value
    New-ItemProperty -Path $Path -Name $Name -PropertyType $Kind -Value $data `
        -Force -ErrorAction Stop | Out-Null
}

# Restore a single registry value from a snapshot object (used by -Undo).
function Restore-RegValue {
    param([string]$Path, [object]$Snap)
    if ($Snap.Existed) {
        $kind = if ($Snap.Kind) { $Snap.Kind } else { 'String' }
        Set-RegValue -Path $Path -Name $Snap.Name -Kind $kind -Value $Snap.Value
    }
    elseif (Test-Path -LiteralPath $Path) {
        Remove-ItemProperty -Path $Path -Name $Snap.Name -Force -ErrorAction SilentlyContinue
    }
}

# Comparable text for a registry value: arrays (Binary/MultiString) join with ',',
# and DWORD/QWORD compare as unsigned so 0xFFFFFFFF matches 4294967295.
function ConvertTo-RegCompareText {
    param([string]$Kind, $Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [array]) { return ((@($Value) | ForEach-Object { [string]$_ }) -join ',') }
    if ($Kind -eq 'DWord') {
        $n = [int64]$Value
        if ($n -lt 0) { $n += 4294967296 }
        return [string]$n
    }
    [string]$Value
}

# A RegVal may carry its own -Path; otherwise it lives under the tweak's Spec.Path.
function Get-RegValuePath {
    param([object]$Tweak, [object]$Value)
    if ($Value.Path) { [string]$Value.Path } else { [string]$Tweak.Spec.Path }
}

# =====================================================================
# NATIVE-TOOL HELPERS (powercfg / DISM exit codes, locale-safe parsing)
# =====================================================================
# Run a read-only probe with -WhatIf lifted. Modules imported on demand (Appx,
# Dism, CimCmdlets) take WhatIf from the script scope, so under -WhatIf their own
# alias/proxy setup is suppressed (flooding the preview and half-loading Appx).
function Invoke-OptReadOnly {
    param([scriptblock]$Script)
    $saved = $script:WhatIfPreference
    try {
        $script:WhatIfPreference = $false
        & $Script
    }
    finally { $script:WhatIfPreference = $saved }
}

function Invoke-OptNative {
    param([string]$FilePath, [string[]]$Arguments, [int[]]$OkCodes = @(0))
    $out = & $FilePath @Arguments 2>&1
    if ($OkCodes -notcontains $LASTEXITCODE) {
        $msg = (@($out) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join ' '
        throw ("{0} {1} failed (exit {2}) {3}" -f $FilePath, ($Arguments -join ' '), $LASTEXITCODE, $msg)
    }
    $out
}

# All power-scheme GUIDs from `powercfg /list`. Parses GUIDs only (output is localized).
function Get-OptPowerSchemeList {
    $text = (& powercfg /list 2>$null) -join "`n"
    $rx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    @([regex]::Matches($text, $rx) | ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
}

function Get-OptActiveSchemeGuid {
    $text = (& powercfg /getactivescheme 2>$null) -join ' '
    $m = [regex]::Match($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { $m.Value.ToLowerInvariant() } else { $null }
}

# Current AC/DC index of one power setting. `powercfg /q` prints the AC index then the
# DC index as the last two 0x######## tokens (range settings print min/max before them).
function Get-OptPowerSettingIndex {
    param([string]$Scheme = 'SCHEME_CURRENT', [string]$SubGroup, [string]$Setting)
    $text = (& powercfg /q $Scheme $SubGroup $Setting 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $null }
    $hex = @([regex]::Matches($text, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }
    [pscustomobject]@{
        AC = [Convert]::ToInt64($hex[$hex.Count - 2].Substring(2), 16)
        DC = [Convert]::ToInt64($hex[$hex.Count - 1].Substring(2), 16)
    }
}

# Why High Performance should be skipped on this machine, or $null to proceed.
function Get-OptPowerHighSkipReason {
    if ((Get-OptPowerSchemeList) -notcontains '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') {
        return 'High Performance plan is not available here (Modern Standby devices only expose Balanced)'
    }
    $bat = @()
    try { $bat = @(Invoke-OptReadOnly -Script { Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop }) } catch { $bat = @() }
    if ($bat.Count) { return 'a battery is present (laptop or UPS) - High Performance would drain it; left unchanged' }
    $null
}

# =====================================================================
# APPX HELPERS
#   Under pwsh 7 the Appx module often fails to load natively ("Operation is
#   not supported on this platform", 0x80131539), and -ErrorAction on the
#   cmdlet does not catch a module-load failure. Fall back to the Windows
#   PowerShell compatibility session; report a real error if both fail.
# =====================================================================
function Initialize-OptAppx {
    if ($null -ne $script:AppxReady) { return $script:AppxReady }
    $script:AppxReady = $false
    # Module loading is read-only; without this, -WhatIf suppresses the module's own
    # alias/proxy setup (and floods the preview with it), leaving Appx half-loaded.
    Invoke-OptReadOnly -Script {
        try {
            Import-Module Appx -ErrorAction Stop -WarningAction SilentlyContinue
            $null = Get-AppxPackage -Name 'WinSenior.Probe.None' -ErrorAction Stop
            $script:AppxReady = $true
        }
        catch {
            if ($PSVersionTable.PSEdition -eq 'Core') {
                try {
                    Remove-Module Appx -Force -ErrorAction SilentlyContinue
                    Import-Module Appx -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
                    $null = Get-AppxPackage -Name 'WinSenior.Probe.None' -ErrorAction Stop
                    $script:AppxReady = $true
                } catch { $script:AppxReady = $false }
            }
        }
    }
    $script:AppxReady
}

function Get-OptAppxPattern {
    param([ValidateSet('junk','xbox','comms','copilot')][string]$Set)
    switch ($Set) {
        'junk' {
            @('king.com*','*CandyCrush*','*BubbleWitch*','*Microsoft.3DBuilder*','*Microsoft.Microsoft3DViewer*',
              '*Microsoft.MicrosoftSolitaireCollection*','*Microsoft.MixedReality.Portal*','*Microsoft.WindowsFeedbackHub*',
              '*Microsoft.Getstarted*','*Microsoft.WindowsMaps*','*Microsoft.BingNews*',
              '*Microsoft.BingWeather*','*Microsoft.People*','*Clipchamp*','*Microsoft.Todos*','*Disney*','*SpotifyAB*')
        }
        'xbox'    { @('*Xbox*') }
        'comms'   { @('*Microsoft.windowscommunicationsapps*','*Microsoft.SkypeApp*','*Microsoft.YourPhone*') }
        'copilot' { @('Microsoft.Copilot') }
    }
}

# Installed packages matching the patterns. Throws when Appx is unusable.
function Get-OptAppxMatch {
    param([string[]]$Pattern, [switch]$AllUsers)
    if (-not (Initialize-OptAppx)) { throw 'The Appx module cannot be loaded in this PowerShell session.' }
    # One enumeration filtered locally: a Get-AppxPackage call per pattern costs seconds each.
    $all = if ($AllUsers) { @(Get-AppxPackage -AllUsers -ErrorAction Stop) } else { @(Get-AppxPackage -ErrorAction Stop) }
    $pk = foreach ($p in $Pattern) { $all | Where-Object { $_ -and ([string]$_.Name -like $p) } }
    @($pk |
        ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; FullName = [string]$_.PackageFullName } } |
        Sort-Object FullName -Unique)
}

# Remove matching packages (and optionally their provisioned copies). Logs each
# failure; throws when packages were found but none could be removed.
function Invoke-OptAppxRemoval {
    param([string[]]$Pattern, [switch]$AllUsers, [switch]$Provisioned)
    $found   = @(Get-OptAppxMatch -Pattern $Pattern -AllUsers:$AllUsers)
    $removed = 0
    $failed  = @()
    foreach ($x in $found) {
        try {
            if ($AllUsers) { Remove-AppxPackage -Package $x.FullName -AllUsers -ErrorAction Stop }
            else           { Remove-AppxPackage -Package $x.FullName -ErrorAction Stop }
            $removed++
        }
        catch {
            $failed += $x.Name
            Write-OptLog ("  could not remove {0}: {1}" -f $x.Name, $_.Exception.Message) 'Warning'
        }
    }
    if ($Provisioned) {
        try {
            $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
            foreach ($p in $Pattern) {
                foreach ($pp in ($prov | Where-Object { $_.DisplayName -like $p })) {
                    try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null }
                    catch { Write-OptLog ("  could not deprovision {0}: {1}" -f $pp.DisplayName, $_.Exception.Message) 'Warning' }
                }
            }
        }
        catch { Write-OptLog "  provisioned packages unavailable: $($_.Exception.Message)" 'Warning' }
    }
    if ($failed.Count -and -not $removed) { throw ("could not remove: {0}" -f ($failed -join ', ')) }
}

# =====================================================================
# TWEAK REGISTRY  (the single source of truth)
# =====================================================================
function New-RegTweak {
    param(
        [string]$Id, [string]$Name, [string]$Area, [string]$Risk,
        [bool]$DefaultOn = $true, [string]$Path, [object[]]$Values, [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'Registry'; Explain = $Explain
        Spec = @{ Path = $Path; Values = $Values }
    }
}
function New-SvcTweak {
    param(
        [string]$Id, [string]$Name, [string]$Area, [string]$Risk,
        [bool]$DefaultOn = $true, [string]$Service, [string]$Startup = 'Disabled',
        [bool]$StopNow = $true, [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'Service'; Explain = $Explain
        Spec = @{ Service = $Service; Startup = $Startup; StopNow = $StopNow }
    }
}
function New-TaskTweak {
    param(
        [string]$Id, [string]$Name, [string]$Area, [string]$Risk,
        [bool]$DefaultOn = $true, [object[]]$Tasks, [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'ScheduledTask'; Explain = $Explain
        Spec = @{ Tasks = $Tasks }
    }
}
function New-CustomTweak {
    param(
        [string]$Id, [string]$Name, [string]$Area, [string]$Risk,
        [bool]$DefaultOn = $true,
        [scriptblock]$Test, [scriptblock]$Backup, [scriptblock]$Apply, [scriptblock]$Undo,
        # Optional: returns a reason string when the tweak does not apply to this machine.
        [scriptblock]$SkipIf,
        [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'Custom'; Explain = $Explain
        Spec = @{ Test = $Test; Backup = $Backup; Apply = $Apply; Undo = $Undo; SkipIf = $SkipIf }
    }
}

# Convenience for a single name/kind/value registry pair. -Path overrides the
# tweak's Spec.Path for this one value (lets one tweak span several keys).
function RegVal { param([string]$Name, [string]$Kind, $Value, [string]$Path)
    [pscustomobject]@{ Name = $Name; Kind = $Kind; Value = $Value; Path = $Path } }

function Get-OptimizationTweakRegistry {
    @(
        # =============================================================
        # PERFORMANCE
        # =============================================================
        New-RegTweak perf-visualfx 'Visual effects: performance, keep font smoothing' Performance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
            -Values @(
                (RegVal 'VisualFXSetting' DWord 3),
                (RegVal 'UserPreferencesMask' Binary ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Path 'HKCU:\Control Panel\Desktop'),
                (RegVal 'FontSmoothing' String '2' -Path 'HKCU:\Control Panel\Desktop'),
                (RegVal 'MinAnimate' String '0' -Path 'HKCU:\Control Panel\Desktop\WindowMetrics'),
                (RegVal 'TaskbarAnimations' DWord 0 -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'),
                (RegVal 'ListviewAlphaSelect' DWord 0 -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced')) `
            -Explain 'Custom Performance Options: animations, fades and shadows off, but ClearType font smoothing and window contents while dragging kept. Takes full effect after sign-out.'
        New-RegTweak perf-menudelay 'Zero menu show delay' Performance Safe `
            -Path 'HKCU:\Control Panel\Desktop' `
            -Values @((RegVal 'MenuShowDelay' String '0')) `
            -Explain 'Menus open instantly instead of after the default 400 ms.'
        New-RegTweak perf-startupdelay 'Remove startup app delay' Performance Moderate `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' `
            -Values @((RegVal 'StartupDelayInMSec' DWord 0)) `
            -Explain 'Startup programs launch without the artificial ~10 s delay.'
        New-RegTweak perf-bgapps 'Disable background apps' Performance Moderate -DefaultOn $false `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' `
            -Values @((RegVal 'GlobalUserDisabled' DWord 1)) `
            -Explain 'Stops UWP apps from running and updating in the background. Off by default: breaks Phone Link, Mail/Calendar and Alarms notifications; negligible gain on modern builds.'
        New-RegTweak perf-faststartup 'Disable Fast Startup (hybrid boot)' Performance Moderate -DefaultOn $false `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Values @((RegVal 'HiberbootEnabled' DWord 0)) `
            -Explain 'Ensures a clean full shutdown (fixes dual-boot clock/filesystem issues). Off by default; slightly slower cold boot.'
        New-CustomTweak perf-power-high 'Power plan: High Performance' Performance Safe -DefaultOn $true `
            -Explain 'Switches the active power plan to High Performance (no CPU down-clocking on idle). Skipped automatically when a battery is present or on Modern Standby devices that do not expose the plan.' `
            -SkipIf { Get-OptPowerHighSkipReason } `
            -Test   { (Get-OptActiveSchemeGuid) -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' } `
            -Backup { @{ PreviousGuid = (Get-OptActiveSchemeGuid) } } `
            -Apply  { Invoke-OptNative -FilePath powercfg -Arguments @('/setactive', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') | Out-Null } `
            -Undo   { param($s) if ($s.PreviousGuid) { Invoke-OptNative -FilePath powercfg -Arguments @('/setactive', $s.PreviousGuid) | Out-Null } }
        New-CustomTweak perf-power-ultimate 'Power plan: Ultimate Performance' Performance Aggressive -DefaultOn $false `
            -Explain 'Creates (once, under a fixed GUID) and activates the hidden Ultimate Performance plan. Desktops/workstations only; higher idle power draw. Undo re-activates the previous plan and deletes the plan it created.' `
            -Test   { (Get-OptActiveSchemeGuid) -eq '57a1e0de-6d0f-4c1b-9e2a-5e0f5e0ed001' } `
            -Backup { @{ PreviousGuid = (Get-OptActiveSchemeGuid)
                         Existed = ((Get-OptPowerSchemeList) -contains '57a1e0de-6d0f-4c1b-9e2a-5e0f5e0ed001') } } `
            -Apply  {
                if ((Get-OptPowerSchemeList) -notcontains '57a1e0de-6d0f-4c1b-9e2a-5e0f5e0ed001') {
                    Invoke-OptNative -FilePath powercfg -Arguments @('/duplicatescheme', 'e9a42b02-d5df-448d-aa00-03f14749eb61', '57a1e0de-6d0f-4c1b-9e2a-5e0f5e0ed001') | Out-Null
                }
                Invoke-OptNative -FilePath powercfg -Arguments @('/setactive', '57a1e0de-6d0f-4c1b-9e2a-5e0f5e0ed001') | Out-Null
            } `
            -Undo   { param($s)
                $fixed = '57a1e0de-6d0f-4c1b-9e2a-5e0f5e0ed001'
                $prev  = if ($s.PreviousGuid -and $s.PreviousGuid -ne $fixed) { $s.PreviousGuid } else { '381b4222-f694-41f0-9685-ff5bb260df2e' }
                if ((Get-OptActiveSchemeGuid) -eq $fixed) { Invoke-OptNative -FilePath powercfg -Arguments @('/setactive', $prev) | Out-Null }
                if (-not $s.Existed -and ((Get-OptPowerSchemeList) -contains $fixed)) { Invoke-OptNative -FilePath powercfg -Arguments @('/delete', $fixed) | Out-Null }
            }
        New-CustomTweak perf-usb-suspend 'Disable USB selective suspend (AC power)' Performance Moderate -DefaultOn $false `
            -Explain 'Stops Windows powering down idle USB ports while plugged in (fixes dropouts of USB audio, mice and hubs). Battery (DC) behaviour is unchanged. Off by default; slightly higher idle power.' `
            -Test   { $i = Get-OptPowerSettingIndex -SubGroup '2a737441-1930-4402-8d77-b2bebba308a3' -Setting '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; ($null -ne $i) -and ($i.AC -eq 0) } `
            -Backup {
                $g = Get-OptActiveSchemeGuid
                $i = Get-OptPowerSettingIndex -Scheme $(if ($g) { $g } else { 'SCHEME_CURRENT' }) -SubGroup '2a737441-1930-4402-8d77-b2bebba308a3' -Setting '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
                @{ Scheme = $g; AC = $(if ($i) { $i.AC } else { $null }) }
            } `
            -Apply  { param($s)
                $sch = if ($s.Scheme) { $s.Scheme } else { 'SCHEME_CURRENT' }
                Invoke-OptNative -FilePath powercfg -Arguments @('/setacvalueindex', $sch, '2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', '0') | Out-Null
                Invoke-OptNative -FilePath powercfg -Arguments @('/setactive', 'SCHEME_CURRENT') | Out-Null
            } `
            -Undo   { param($s)
                if ($s.Scheme -and $null -ne $s.AC) {
                    Invoke-OptNative -FilePath powercfg -Arguments @('/setacvalueindex', $s.Scheme, '2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', [string]$s.AC) | Out-Null
                    Invoke-OptNative -FilePath powercfg -Arguments @('/setactive', 'SCHEME_CURRENT') | Out-Null
                }
                else { Write-OptLog 'USB selective suspend: no prior value recorded; leaving as is.' 'Warning' }
            }
        New-RegTweak perf-powerthrottling 'Disable Power Throttling (EcoQoS)' Performance Moderate -DefaultOn $false `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' `
            -Values @((RegVal 'PowerThrottlingOff' DWord 1)) `
            -Explain 'Stops Windows from throttling background processes to efficiency mode. Off by default: costs battery life on laptops; little gain on desktops.'
        New-RegTweak perf-hags 'Enable hardware-accelerated GPU scheduling' Performance Moderate -DefaultOn $false `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' `
            -Values @((RegVal 'HwSchMode' DWord 2)) `
            -Explain 'Lets the GPU manage its own memory scheduling (HAGS). Needs a WDDM 2.7+ driver and a reboot; ignored otherwise. Off by default: can cause stutter or capture issues with some drivers.'
        New-RegTweak perf-wu-latest 'Do not get updates as soon as available' Performance Safe `
            -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' `
            -Values @((RegVal 'IsContinuousInnovationOptedIn' DWord 0)) `
            -Explain 'Turns off "Get the latest updates as soon as they are available" (early feature drops). Security and monthly updates are unaffected.'
        New-RegTweak perf-edge-bg 'Stop Edge preloading and running in background' Performance Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' `
            -Values @((RegVal 'StartupBoostEnabled' DWord 0), (RegVal 'BackgroundModeEnabled' DWord 0)) `
            -Explain 'Disables Edge Startup Boost and background mode so Edge does not sit in memory when closed. Edge will show "Your browser is managed by your organization" (harmless policy notice).'
        New-CustomTweak perf-reserved-storage 'Disable Reserved Storage' Performance Moderate -DefaultOn $false `
            -Explain 'Frees the ~7 GB Windows reserves for updates. Off by default: low-space devices may then fail feature updates. Cannot be changed while an update is pending (Windows 10 2004+).' `
            -Test   { try { [string](Invoke-OptReadOnly -Script { Get-WindowsReservedStorageState -ErrorAction Stop }).ReservedStorageState -eq 'Disabled' } catch { $false } } `
            -Backup {
                $st = $null
                try { $st = [string](Invoke-OptReadOnly -Script { Get-WindowsReservedStorageState -ErrorAction Stop }).ReservedStorageState } catch { $st = $null }
                @{ Was = $st }
            } `
            -Apply  { Invoke-OptNative -FilePath "$env:SystemRoot\System32\dism.exe" -Arguments @('/Online', '/Set-ReservedStorageState', '/State:Disabled') -OkCodes @(0, 3010) | Out-Null } `
            -Undo   { param($s)
                if ($s.Was -ne 'Disabled') {
                    Invoke-OptNative -FilePath "$env:SystemRoot\System32\dism.exe" -Arguments @('/Online', '/Set-ReservedStorageState', '/State:Enabled') -OkCodes @(0, 3010) | Out-Null
                }
            }
        New-SvcTweak perf-sysmain 'Disable SysMain (Superfetch)' Performance Aggressive -DefaultOn $false `
            -Service 'SysMain' -Startup 'Disabled' `
            -Explain 'Frees RAM/disk activity. Helpful on SSDs; can slow app launches on HDDs. Off by default.'
        New-SvcTweak perf-wsearch 'Disable Windows Search indexing' Performance Aggressive -DefaultOn $false `
            -Service 'WSearch' -Startup 'Disabled' `
            -Explain 'Stops the indexer (less disk/CPU) but makes Start/Explorer search slower. Off by default.'
        New-CustomTweak perf-hibernate 'Disable hibernation (remove hiberfil.sys)' Performance Aggressive -DefaultOn $false `
            -Explain 'Reclaims several GB of hiberfil.sys and disables Fast Startup. Off by default.' `
            -Test   { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled -eq 0 } `
            -Backup { @{ Was = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled } } `
            -Apply  { & powercfg /hibernate off 2>$null } `
            -Undo   { param($s) if ($s.Was -ne 0) { & powercfg /hibernate on 2>$null } }

        # =============================================================
        # PRIVACY / TELEMETRY
        # =============================================================
        New-RegTweak priv-telemetry 'Minimize telemetry (policy)' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Values @((RegVal 'AllowTelemetry' DWord 0), (RegVal 'DoNotShowFeedbackNotifications' DWord 1)) `
            -Explain 'Sets diagnostic data to the lowest level the edition allows and hides feedback prompts.'
        New-RegTweak priv-adid 'Disable advertising ID' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' `
            -Values @((RegVal 'Enabled' DWord 0)) `
            -Explain 'Stops apps from using a per-user advertising identifier.'
        New-RegTweak priv-consumer 'Disable consumer features / auto-installed apps' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Values @((RegVal 'DisableWindowsConsumerFeatures' DWord 1), (RegVal 'DisableSoftLanding' DWord 1)) `
            -Explain 'Consumer-features policy (Enterprise/Education only; ignored on Home/Pro). On Home/Pro the per-user ContentDeliveryManager switches in debloat-start-ads and priv-tips are what stop promoted app installs.'
        New-RegTweak priv-tips 'Disable tips, suggestions & spotlight' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
            -Values @(
                (RegVal 'SystemPaneSuggestionsEnabled' DWord 0),
                (RegVal 'SoftLandingEnabled' DWord 0),
                (RegVal 'SubscribedContent-338389Enabled' DWord 0),
                (RegVal 'SubscribedContent-310093Enabled' DWord 0),
                (RegVal 'RotatingLockScreenOverlayEnabled' DWord 0)) `
            -Explain 'Turns off Windows tips, lock-screen spotlight facts and Settings suggestions.'
        New-RegTweak priv-activity 'Disable activity feed / Timeline' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Values @(
                (RegVal 'EnableActivityFeed' DWord 0),
                (RegVal 'PublishUserActivities' DWord 0),
                (RegVal 'UploadUserActivities' DWord 0)) `
            -Explain 'Stops Windows from collecting and uploading the activity history / Timeline.'
        New-RegTweak priv-websearch 'Disable web search in Start' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' `
            -Values @(
                (RegVal 'BingSearchEnabled' DWord 0),
                (RegVal 'CortanaConsent' DWord 0),
                (RegVal 'DisableSearchBoxSuggestions' DWord 1 -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'),
                (RegVal 'EnableDynamicContentInWSB' DWord 0 -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search')) `
            -Explain 'Removes Bing web results, web suggestions and "search highlights" from Start/taskbar search. Side effect: the suggestions policy also hides recent Explorer search entries.'
        New-RegTweak priv-cortana 'Disable Cortana (policy)' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' `
            -Values @((RegVal 'AllowCortana' DWord 0)) `
            -Explain 'Disables the Cortana assistant via Group Policy.'
        New-SvcTweak priv-diagtrack 'Disable Connected User Experiences (DiagTrack)' Privacy Moderate `
            -Service 'DiagTrack' -Startup 'Disabled' `
            -Explain 'Stops the main telemetry service that uploads diagnostic data.'
        New-SvcTweak priv-dmwappush 'Disable WAP Push message service' Privacy Moderate -DefaultOn $false `
            -Service 'dmwappushservice' -Startup 'Disabled' `
            -Explain 'Disables a device-management push channel also used for telemetry routing. Off by default: breaks Intune/MDM policy sync on work-managed PCs.'
        New-TaskTweak priv-telemetry-tasks 'Disable CEIP & telemetry scheduled tasks' Privacy Moderate `
            -Tasks @(
                @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
                @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
                @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
                @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
                @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient' },
                @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload' }) `
            -Explain 'Disables the recurring tasks that collect and send usage/compatibility data. Note: with the Compatibility Appraiser off, Windows Update may be slower to offer the next feature update (eligibility is re-evaluated at upgrade time).'
        New-RegTweak priv-recall 'Disable Recall & Click-to-Do (AI screen analysis)' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' `
            -Values @((RegVal 'DisableAIDataAnalysis' DWord 1), (RegVal 'DisableClickToDo' DWord 1)) `
            -Explain 'Blocks Windows Recall snapshots and Click-to-Do AI screen scraping (Win11 24H2+; harmless no-op on older builds).'
        New-RegTweak priv-recall-remove 'Remove the Recall component (policy)' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' `
            -Values @((RegVal 'AllowRecallEnablement' DWord 0)) `
            -Explain 'Makes Windows uninstall the Recall optional feature (Win11 24H2 build 26100.3915+; no-op elsewhere). Takes effect after a reboot; undo removes the policy so Recall can be re-added.'
        New-RegTweak priv-copilot 'Disable Windows Copilot (legacy policy)' Privacy Safe `
            -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' `
            -Values @((RegVal 'TurnOffWindowsCopilot' DWord 1)) `
            -Explain 'Turns off the built-in Copilot sidebar via user policy. Deprecated: only effective on Windows 10 and Windows 11 23H2 and earlier; the newer Copilot app ignores it (see debloat-copilot-app).'
        New-RegTweak priv-ai-paint 'Disable AI features in Paint' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' `
            -Values @(
                (RegVal 'DisableCocreator' DWord 1),
                (RegVal 'DisableGenerativeFill' DWord 1),
                (RegVal 'DisableImageCreator' DWord 1)) `
            -Explain 'Turns off Cocreator, Generative fill and Image Creator in Paint (Win11). No effect on older Paint versions.'
        New-RegTweak priv-ai-notepad 'Disable AI features in Notepad' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\WindowsNotepad' `
            -Values @((RegVal 'DisableAIFeatures' DWord 1)) `
            -Explain 'Hides Copilot rewrite/summarize in Notepad (Win11 Notepad 11.2410+). No effect on older Notepad.'
        New-RegTweak priv-chrome-ai 'Stop Chrome downloading its on-device AI model' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' `
            -Values @((RegVal 'GenAILocalFoundationalModelSettings' DWord 1)) `
            -Explain 'Prevents Chrome from downloading the ~4 GB Gemini Nano on-device model; on-device AI features stop working. Chrome will show "managed by your organization". Harmless if Chrome is not installed.'
        New-RegTweak priv-tailored 'Disable tailored experiences (ads from diagnostics)' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' `
            -Values @((RegVal 'TailoredExperiencesWithDiagnosticDataEnabled' DWord 0)) `
            -Explain 'Stops Windows from using your diagnostic data to show personalized tips and ads.'
        New-RegTweak priv-spotlight 'Disable Windows Spotlight lock-screen rotation' Privacy Safe `
            -Path 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' `
            -Values @(
                (RegVal 'DisableWindowsSpotlightFeatures' DWord 1),
                (RegVal 'RotatingLockScreenEnabled' DWord 0 -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'),
                (RegVal 'SubscribedContent-338387Enabled' DWord 0 -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager')) `
            -Explain 'Stops Spotlight picture/ad rotation and "fun facts" on the lock screen; the lock screen keeps a static picture. The user policy value is Enterprise/Education only; the ContentDeliveryManager values cover Home/Pro.'
        New-RegTweak priv-settings-ads 'Disable suggested content in Settings' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
            -Values @(
                (RegVal 'SubscribedContent-338393Enabled' DWord 0),
                (RegVal 'SubscribedContent-353694Enabled' DWord 0),
                (RegVal 'SubscribedContent-353696Enabled' DWord 0)) `
            -Explain 'Hides the promoted/suggested content cards in the Settings app.'
        New-RegTweak priv-suggested-actions 'Disable suggested actions on copy' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard' `
            -Values @((RegVal 'Disabled' DWord 1)) `
            -Explain 'Stops the pop-up that suggests actions (call, add to calendar) when you copy a phone number or date (Win11 22H2+).'
        New-RegTweak priv-langlist 'Hide language list from websites' Privacy Safe `
            -Path 'HKCU:\Control Panel\International\User Profile' `
            -Values @((RegVal 'HttpAcceptLanguageOptOut' DWord 1)) `
            -Explain 'Websites can no longer read your installed language list to serve locally relevant content (fingerprinting reduction).'
        New-RegTweak priv-trackprogs 'Do not track app launches' Privacy Moderate -DefaultOn $false `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'Start_TrackProgs' DWord 0)) `
            -Explain 'Stops Windows recording which apps you launch. Off by default: empties the Start "Most used" list and Run-dialog history.'
        New-RegTweak priv-findmydevice 'Disable Find My Device' Privacy Moderate -DefaultOn $false `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' `
            -Values @((RegVal 'AllowFindMyDevice' DWord 0)) `
            -Explain 'Stops periodic location reporting for Find My Device. Off by default: you lose the ability to locate or lock a lost laptop.'
        New-RegTweak priv-location 'Block app access to location (policy)' Privacy Moderate -DefaultOn $false `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' `
            -Values @((RegVal 'LetAppsAccessLocation' DWord 2)) `
            -Explain 'Force-denies location to all apps. Off by default: breaks automatic time zone, Weather, Maps and Find My Device location.'
        New-RegTweak priv-input 'Stop inking & typing personalization' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' `
            -Values @(
                (RegVal 'RestrictImplicitInkCollection' DWord 1),
                (RegVal 'RestrictImplicitTextCollection' DWord 1),
                (RegVal 'AllowInputPersonalization' DWord 0)) `
            -Explain 'Stops sampling of keystrokes/handwriting for personalization. Local dictation still works.'
        New-RegTweak priv-typing 'Stop sending typing/inking data to Microsoft' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Input\TIPC' `
            -Values @((RegVal 'Enabled' DWord 0)) `
            -Explain 'Disables the typing-insights upload channel.'
        New-RegTweak priv-speech 'Decline online speech recognition' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' `
            -Values @((RegVal 'HasAccepted' DWord 0)) `
            -Explain 'Opts out of cloud-based voice processing. Offline dictation is unaffected.'
        New-RegTweak priv-ceip 'Disable Customer Experience Improvement Program' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows' `
            -Values @(
                (RegVal 'CEIPEnable' DWord 0),
                (RegVal 'CEIPEnable' DWord 0 -Path 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows')) `
            -Explain 'Turns off the CEIP master switch and its policy equivalent (complements the CEIP scheduled-task tweak).'
        New-RegTweak priv-appcompat 'Disable application-compatibility telemetry' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' `
            -Values @((RegVal 'DisableInventory' DWord 1), (RegVal 'AITEnable' DWord 0)) `
            -Explain 'Stops the Application Compatibility Appraiser inventory that feeds telemetry.'
        New-RegTweak priv-wer 'Disable Windows Error Reporting upload' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' `
            -Values @((RegVal 'Disabled' DWord 1)) `
            -Explain 'Blocks crash-report upload to Microsoft. Local crash logs are still created.'
        New-RegTweak priv-feedback 'Never ask for Windows feedback' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Siuf\Rules' `
            -Values @((RegVal 'NumberOfSIUFInPeriod' DWord 0)) `
            -Explain 'Stops the periodic "rate your experience" feedback prompts.'
        New-RegTweak priv-deliveryopt 'Disable Delivery Optimization P2P upload' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' `
            -Values @((RegVal 'DODownloadMode' DWord 0)) `
            -Explain 'Stops seeding update payloads to other PCs over the internet (HTTP-only; does not disable Windows Update).'
        New-RegTweak priv-onedrive 'Block OneDrive network traffic before sign-in' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Microsoft\OneDrive' `
            -Values @((RegVal 'PreventNetworkTrafficPreUserSignIn' DWord 1)) `
            -Explain 'Stops OneDrive contacting the network before a user signs in. Does not disable OneDrive.'
        New-RegTweak priv-clipboard 'Disable cloud clipboard sync' Privacy Moderate -DefaultOn $false `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Values @((RegVal 'AllowCrossDeviceClipboard' DWord 0)) `
            -Explain 'Stops clipboard contents syncing to your Microsoft account across devices. Off by default.'

        # =============================================================
        # DEBLOAT (UWP apps)
        # =============================================================
        New-CustomTweak debloat-junk 'Remove preinstalled junk apps' Debloat Aggressive -DefaultOn $true `
            -Explain 'Removes obvious bloat (King games, Solitaire, 3D Viewer, Clipchamp, Maps, News/Weather, etc.) for all users. Get Help is kept (Win11 troubleshooters run through it). Reinstall from the Store.' `
            -Test   { try { -not (Get-OptAppxMatch -Pattern (Get-OptAppxPattern -Set junk) -AllUsers) } catch { $false } } `
            -Backup {
                $pat = Get-OptAppxPattern -Set junk
                $found = @()
                try { $found = @(Get-OptAppxMatch -Pattern $pat -AllUsers | ForEach-Object { $_.Name } | Sort-Object -Unique) } catch { $found = @() }
                @{ Patterns = $pat; Found = $found }
            } `
            -Apply  { Invoke-OptAppxRemoval -Pattern (Get-OptAppxPattern -Set junk) -AllUsers -Provisioned } `
            -Undo   { param($s)
                if ($s.Found) { Write-OptLog ("Removed UWP apps cannot be auto-reinstalled. Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' }
            }
        New-CustomTweak debloat-xbox 'Remove Xbox apps' Debloat Aggressive -DefaultOn $false `
            -Explain 'Removes Xbox app, Game Bar overlay and related packages. Off by default (gamers may want them). Reinstall from the Store.' `
            -Test   { try { -not (Get-OptAppxMatch -Pattern (Get-OptAppxPattern -Set xbox) -AllUsers) } catch { $false } } `
            -Backup {
                $f = @()
                try { $f = @(Get-OptAppxMatch -Pattern (Get-OptAppxPattern -Set xbox) -AllUsers | ForEach-Object { $_.Name } | Sort-Object -Unique) } catch { $f = @() }
                @{ Found = $f }
            } `
            -Apply  { Invoke-OptAppxRemoval -Pattern (Get-OptAppxPattern -Set xbox) -AllUsers } `
            -Undo   { param($s) if ($s.Found) { Write-OptLog ("Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' } }
        New-CustomTweak debloat-comms 'Remove Mail/Calendar, Skype, Phone Link' Debloat Aggressive -DefaultOn $false `
            -Explain 'Removes the communications apps bundle. Off by default (some people use Mail/Calendar). Reinstall from the Store.' `
            -Test   { try { -not (Get-OptAppxMatch -Pattern (Get-OptAppxPattern -Set comms) -AllUsers) } catch { $false } } `
            -Backup {
                $pat = Get-OptAppxPattern -Set comms
                $f = @()
                try { $f = @(Get-OptAppxMatch -Pattern $pat -AllUsers | ForEach-Object { $_.Name } | Sort-Object -Unique) } catch { $f = @() }
                @{ Patterns = $pat; Found = $f }
            } `
            -Apply  { Invoke-OptAppxRemoval -Pattern (Get-OptAppxPattern -Set comms) -AllUsers } `
            -Undo   { param($s) if ($s.Found) { Write-OptLog ("Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' } }
        New-CustomTweak debloat-copilot-app 'Remove the Copilot app (current user)' Debloat Aggressive -DefaultOn $false `
            -Explain 'Uninstalls the Microsoft.Copilot Store app for the current user (Win11 24H2+ ships Copilot as an app the legacy policy no longer controls). Off by default. Reinstall from the Store.' `
            -Test   { try { -not (Get-OptAppxMatch -Pattern (Get-OptAppxPattern -Set copilot)) } catch { $false } } `
            -Backup {
                $f = @()
                try { $f = @(Get-OptAppxMatch -Pattern (Get-OptAppxPattern -Set copilot) | ForEach-Object { $_.Name } | Sort-Object -Unique) } catch { $f = @() }
                @{ Found = $f }
            } `
            -Apply  { Invoke-OptAppxRemoval -Pattern (Get-OptAppxPattern -Set copilot) } `
            -Undo   { param($s) if ($s.Found) { Write-OptLog ("Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' } }
        New-RegTweak debloat-start-ads 'Disable Start-menu app suggestions' Debloat Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
            -Values @(
                (RegVal 'SilentInstalledAppsEnabled' DWord 0),
                (RegVal 'PreInstalledAppsEnabled' DWord 0),
                (RegVal 'OemPreInstalledAppsEnabled' DWord 0),
                (RegVal 'SubscribedContent-338388Enabled' DWord 0)) `
            -Explain 'Stops the Start menu from showing suggested/promoted apps.'
        New-RegTweak debloat-taskbar-ads 'Hide taskbar/Start/Explorer ad surfaces' Debloat Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @(
                (RegVal 'TaskbarMn' DWord 0),
                (RegVal 'Start_IrisRecommendations' DWord 0),
                (RegVal 'Start_AccountNotifications' DWord 0),
                (RegVal 'ShowSyncProviderNotifications' DWord 0)) `
            -Explain 'Hides the Start "Recommended" tips/account-ad rows, Explorer sync-provider ads and the Win11 22H2 Chat button (no-op on 23H2+). The Widgets button is handled by debloat-widgets-policy (the UCPD driver blocks TaskbarDa writes on current Win11).'
        New-RegTweak debloat-widgets-policy 'Disable Widgets (policy)' Debloat Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' `
            -Values @((RegVal 'AllowNewsAndInterests' DWord 0)) `
            -Explain 'Turns off the Win11 Widgets board and removes its taskbar button machine-wide (works where TaskbarDa is blocked). Sign-out or Explorer restart needed.'
        New-RegTweak debloat-feeds-w10 'Disable News and Interests (Win10)' Debloat Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' `
            -Values @((RegVal 'EnableFeeds' DWord 0)) `
            -Explain 'Removes the Windows 10 taskbar weather/news feed. No effect on Windows 11.'
        New-RegTweak debloat-meetnow 'Hide Meet Now button (Win10)' Debloat Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
            -Values @((RegVal 'HideSCAMeetNow' DWord 1)) `
            -Explain 'Hides the Skype "Meet Now" tray icon on Windows 10. No effect on Windows 11.'
        New-RegTweak debloat-edge 'Remove Edge sidebar, shopping and recommendations' Debloat Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' `
            -Values @(
                (RegVal 'HubsSidebarEnabled' DWord 0),
                (RegVal 'EdgeShoppingAssistantEnabled' DWord 0),
                (RegVal 'ShowRecommendationsEnabled' DWord 0)) `
            -Explain 'Hides the Edge sidebar (Copilot button), shopping coupons pop-ups and feature recommendations. Edge itself is untouched but will show "Your browser is managed by your organization".'
        New-RegTweak debloat-start-reco 'Hide Start "Recommended" section (policy)' Debloat Moderate -DefaultOn $false `
            -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' `
            -Values @((RegVal 'HideRecommendedSection' DWord 1)) `
            -Explain 'Removes the whole Recommended section from Win11 Start. Honoured only on Education/SE (and recent Enterprise) editions; a no-op on Home/Pro. Off by default.'
        New-RegTweak debloat-stickykeys 'Disable Sticky Keys shortcut (Shift x5)' Debloat Safe `
            -Path 'HKCU:\Control Panel\Accessibility\StickyKeys' `
            -Values @((RegVal 'Flags' String '506')) `
            -Explain 'Pressing Shift five times no longer pops up the Sticky Keys prompt (common in games). Sticky Keys can still be enabled in Settings.'
        New-RegTweak debloat-scoobe 'Disable post-update setup nag (SCOOBE)' Debloat Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' `
            -Values @((RegVal 'ScoobeSystemSettingEnabled' DWord 0)) `
            -Explain 'Stops the "Let''s finish setting up your device" full-screen prompt after updates.'
        New-RegTweak ux-fileext 'Show file extensions in Explorer' Debloat Safe -DefaultOn $false `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'HideFileExt' DWord 0)) `
            -Explain 'Shows known file extensions (security + usability). Off by default (preference).'
        New-CustomTweak ux-context-menu 'Restore classic Win10 right-click menu' Debloat Safe -DefaultOn $false `
            -Explain 'Brings back the full Windows 10 context menu on Windows 11. Off by default (preference); needs an Explorer restart.' `
            -Test   { Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' } `
            -Backup { @{ Existed = (Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32') } } `
            -Apply  {
                New-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Force | Out-Null
                Set-ItemProperty -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Name '(Default)' -Value ''
            } `
            -Undo   { param($s)
                # Only remove the key if this tweak created it; a pre-existing key belongs to the user.
                if (-not $s.Existed) { Remove-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue }
            }
        New-CustomTweak ux-explorer-home-gallery 'Hide Home and Gallery in Explorer' Debloat Safe -DefaultOn $false `
            -Explain 'Removes the Home and Gallery entries from the Win11 Explorer navigation pane. Off by default (preference); needs an Explorer restart. Pair with ux-launch-thispc.' `
            -Test   {
                $bad = foreach ($c in '{f874310e-b6b7-47dc-bc84-b9e6b38f5903}', '{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}') {
                    $sn = Get-RegValueSnapshot -Path "HKCU:\Software\Classes\CLSID\$c" -Name 'System.IsPinnedToNameSpaceTree'
                    if (-not $sn.Existed -or [string]$sn.Value -ne '0') { $c }
                }
                -not $bad
            } `
            -Backup {
                $keys = foreach ($c in '{f874310e-b6b7-47dc-bc84-b9e6b38f5903}', '{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}') {
                    $k = "HKCU:\Software\Classes\CLSID\$c"
                    @{ Key = $k; KeyExisted = (Test-Path -LiteralPath $k)
                       Snap = (Get-RegValueSnapshot -Path $k -Name 'System.IsPinnedToNameSpaceTree') }
                }
                @{ Keys = @($keys) }
            } `
            -Apply  {
                foreach ($c in '{f874310e-b6b7-47dc-bc84-b9e6b38f5903}', '{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}') {
                    Set-RegValue -Path "HKCU:\Software\Classes\CLSID\$c" -Name 'System.IsPinnedToNameSpaceTree' -Kind DWord -Value 0
                }
            } `
            -Undo   { param($s)
                foreach ($e in @($s.Keys)) {
                    if (-not $e.KeyExisted) {
                        if (Test-Path -LiteralPath $e.Key) { Remove-Item -LiteralPath $e.Key -Recurse -Force -ErrorAction Stop }
                    }
                    else { Restore-RegValue -Path $e.Key -Snap $e.Snap }
                }
            }
        New-RegTweak ux-launch-thispc 'Open Explorer to This PC' Debloat Safe -DefaultOn $false `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'LaunchTo' DWord 1)) `
            -Explain 'File Explorer opens on This PC instead of Home/Quick access. Off by default (preference).'
        New-RegTweak ux-hidden 'Show hidden files in Explorer' Debloat Safe -DefaultOn $false `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'Hidden' DWord 1)) `
            -Explain 'Shows hidden files and folders (protected OS files stay hidden). Off by default (preference).'
        New-RegTweak ux-endtask 'Add "End task" to taskbar right-click' Debloat Safe -DefaultOn $false `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' `
            -Values @((RegVal 'TaskbarEndTask' DWord 1)) `
            -Explain 'Adds an End task entry to taskbar app menus (Win11 23H2+). Off by default (preference).'
        New-RegTweak ux-mouseaccel 'Disable mouse acceleration' Debloat Safe -DefaultOn $false `
            -Path 'HKCU:\Control Panel\Mouse' `
            -Values @(
                (RegVal 'MouseSpeed' String '0'),
                (RegVal 'MouseThreshold1' String '0'),
                (RegVal 'MouseThreshold2' String '0')) `
            -Explain 'Turns off "Enhance pointer precision" for 1:1 pointer movement (gaming). Off by default (preference); applies after sign-out.'

        # =============================================================
        # NETWORK / GAMES
        # =============================================================
        New-RegTweak net-gamedvr 'Disable GameDVR / background recording' Network Safe `
            -Path 'HKCU:\System\GameConfigStore' `
            -Values @(
                (RegVal 'GameDVR_Enabled' DWord 0),
                (RegVal 'AppCaptureEnabled' DWord 0 -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR')) `
            -Explain 'Disables the background game recorder / app capture that can cost frames and CPU. Fullscreen optimizations are left alone.'
        New-RegTweak net-gamedvr-policy 'Disable GameDVR (policy)' Network Safe -DefaultOn $false `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' `
            -Values @((RegVal 'AllowGameDVR' DWord 0)) `
            -Explain 'Enforces GameDVR off machine-wide via policy. Off by default: also greys out Game Bar capture settings for every user (net-gamedvr covers the per-user switch).'
        New-RegTweak net-gamemode 'Enable Game Mode' Network Safe `
            -Path 'HKCU:\Software\Microsoft\GameBar' `
            -Values @((RegVal 'AutoGameModeEnabled' DWord 1), (RegVal 'AllowAutoGameMode' DWord 1)) `
            -Explain 'Prioritizes the foreground game for CPU/GPU scheduling.'
        New-RegTweak net-throttling 'Disable network throttling / multimedia reservation' Network Moderate -DefaultOn $false `
            -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
            -Values @((RegVal 'NetworkThrottlingIndex' DWord 4294967295), (RegVal 'SystemResponsiveness' DWord 10)) `
            -Explain 'Lifts the MMCSS network throttle and lowers the CPU share kept for low-priority tasks during multimedia playback from 20% to 10% (MMCSS clamps values under 10 back to 20). Off by default: only affects MMCSS-registered audio/video streams; placebo for most games.'
        New-RegTweak net-teredo 'Disable Teredo IPv6 tunneling' Network Moderate -DefaultOn $false `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TCPIP\v6Transition' `
            -Values @((RegVal 'Teredo_State' String 'Disabled')) `
            -Explain 'Disables only the Teredo transition tunnel via policy (other IPv6 transition settings untouched). Off by default; can affect Xbox party chat / some P2P NAT traversal.'
        New-SvcTweak net-ndu 'Disable Network Data Usage monitor (NDU)' Network Aggressive -DefaultOn $false `
            -Service 'Ndu' -Startup 'Disabled' `
            -Explain 'Stops the NDU driver that can cause high memory use. Off by default; removes per-app data usage stats.'
        New-CustomTweak net-nagle 'Disable Nagle algorithm (lower latency)' Network Aggressive -DefaultOn $false `
            -Explain 'Sets TcpAckFrequency=1 / TCPNoDelay=1 on active interfaces for lower gaming latency. Off by default.' `
            -Test   { $false } `
            -Backup {
                $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
                $snaps = @()
                foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                    $p = $k.PSPath
                    if ((Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties.Name -match 'DhcpIPAddress|IPAddress') {
                        foreach ($n in 'TcpAckFrequency','TCPNoDelay') {
                            $cur = (Get-ItemProperty $p -Name $n -ErrorAction SilentlyContinue).$n
                            $snaps += @{ Path = $p; Name = $n; Existed = ($null -ne $cur); Value = $cur; Kind = 'DWord' }
                        }
                    }
                }
                @{ Values = $snaps }
            } `
            -Apply  {
                $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
                foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                    $p = $k.PSPath
                    if ((Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties.Name -match 'DhcpIPAddress|IPAddress') {
                        New-ItemProperty $p -Name 'TcpAckFrequency' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                        New-ItemProperty $p -Name 'TCPNoDelay'      -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            } `
            -Undo   { param($s)
                foreach ($v in $s.Values) {
                    if ($v.Existed) { New-ItemProperty $v.Path -Name $v.Name -PropertyType DWord -Value $v.Value -Force -ErrorAction SilentlyContinue | Out-Null }
                    else { Remove-ItemProperty $v.Path -Name $v.Name -Force -ErrorAction SilentlyContinue }
                }
            }
    )
}

# =====================================================================
# SELECTION
# =====================================================================
function Resolve-TweakSelection {
    param(
        [object[]]$Registry,
        [string[]]$Area, [string[]]$Include, [string[]]$Exclude,
        [bool]$Conservative, [bool]$IncludeDangerous
    )
    $rank = @{ Safe = 0; Moderate = 1; Aggressive = 2; Dangerous = 3 }
    $maxRisk = if ($IncludeDangerous) { 3 } elseif ($Conservative) { 1 } else { 2 }

    foreach ($t in $Registry) {
        $on = $t.DefaultOn
        if ($Area -and ($t.Area -notin $Area)) { $on = $false }
        if ($rank[$t.Risk] -gt $maxRisk) { $on = $false }
        if (($Include -contains $t.Id) -or ($Include -contains $t.Name)) { $on = $true }
        if (($Exclude -contains $t.Id) -or ($Exclude -contains $t.Name)) { $on = $false }
        if ($on) { $t }
    }
}

# =====================================================================
# STATE  (is a tweak currently applied?)  - used by the menu display
# =====================================================================
function Test-TweakApplied {
    param([object]$Tweak)
    try {
        switch ($Tweak.Type) {
            'Registry' {
                foreach ($v in $Tweak.Spec.Values) {
                    $snap = Get-RegValueSnapshot -Path (Get-RegValuePath -Tweak $Tweak -Value $v) -Name $v.Name
                    if (-not $snap.Existed) { return $false }
                    if ((ConvertTo-RegCompareText -Kind $v.Kind -Value $snap.Value) -ne
                        (ConvertTo-RegCompareText -Kind $v.Kind -Value $v.Value)) { return $false }
                }
                return $true
            }
            'Service' {
                $svc = Get-Service -Name $Tweak.Spec.Service -ErrorAction SilentlyContinue
                if (-not $svc) { return $null }
                return ([string]$svc.StartType -eq $Tweak.Spec.Startup)
            }
            'ScheduledTask' {
                if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
                foreach ($t in $Tweak.Spec.Tasks) {
                    $st = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
                    if ($st -and $st.State -ne 'Disabled') { return $false }
                }
                return $true
            }
            'Custom' {
                if ($Tweak.Spec.Test) { return [bool](& $Tweak.Spec.Test) }
                return $null
            }
        }
    } catch { return $null }
    $null
}

# =====================================================================
# APPLY  (snapshot prior state, then change via ShouldProcess)
# =====================================================================
function Get-TweakSnapshot {
    param([object]$Tweak)
    switch ($Tweak.Type) {
        'Registry' {
            $vals = foreach ($v in $Tweak.Spec.Values) { Get-RegValueSnapshot -Path (Get-RegValuePath -Tweak $Tweak -Value $v) -Name $v.Name }
            return @{ Path = $Tweak.Spec.Path; Values = @($vals) }
        }
        'Service' {
            $svc = Get-Service -Name $Tweak.Spec.Service -ErrorAction SilentlyContinue
            return @{ Service = $Tweak.Spec.Service
                     Found = [bool]$svc
                     StartType = if ($svc) { [string]$svc.StartType } else { $null }
                     Status = if ($svc) { [string]$svc.Status } else { $null } }
        }
        'ScheduledTask' {
            $states = @()
            if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
                foreach ($t in $Tweak.Spec.Tasks) {
                    $st = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
                    $states += @{ Path = $t.Path; Name = $t.Name; State = if ($st) { [string]$st.State } else { $null } }
                }
            }
            return @{ Tasks = $states }
        }
        'Custom'  { return [hashtable](& $Tweak.Spec.Backup) }
    }
    @{}
}

function Set-TweakState {
    param([object]$Tweak, [object]$Snapshot)
    switch ($Tweak.Type) {
        'Registry' {
            # One blocked value (e.g. UCPD-protected keys on Win11) must not abort the rest.
            $failed = @()
            foreach ($v in $Tweak.Spec.Values) {
                $p = Get-RegValuePath -Tweak $Tweak -Value $v
                try { Set-RegValue -Path $p -Name $v.Name -Kind $v.Kind -Value $v.Value }
                catch {
                    $failed += $v.Name
                    Write-OptLog ("  {0}\{1}: {2}" -f $p, $v.Name, $_.Exception.Message) 'Warning'
                }
            }
            if ($failed.Count -and $failed.Count -ge @($Tweak.Spec.Values).Count) {
                throw ("no value could be written ({0})" -f ($failed -join ', '))
            }
        }
        'Service' {
            Set-Service -Name $Tweak.Spec.Service -StartupType $Tweak.Spec.Startup -ErrorAction Stop
            if ($Tweak.Spec.StopNow -and $Snapshot.Status -eq 'Running') {
                Stop-Service -Name $Tweak.Spec.Service -Force -ErrorAction SilentlyContinue
            }
        }
        'ScheduledTask' {
            foreach ($t in $Tweak.Spec.Tasks) {
                Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue | Out-Null
            }
        }
        'Custom' { & $Tweak.Spec.Apply $Snapshot }
    }
}

function Invoke-Tweak {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Tweak)

    if ($Tweak.Type -eq 'Custom' -and $Tweak.Spec.SkipIf) {
        $why = $null
        try { $why = & $Tweak.Spec.SkipIf } catch { $why = $null }
        if ($why) {
            Write-OptLog "$($Tweak.Name)  [skipped: $why]" 'Info'
            $script:Skipped++
            $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'skipped' })
            return
        }
    }

    $applied = Test-TweakApplied -Tweak $Tweak
    if ($applied -eq $true) {
        Write-OptLog "$($Tweak.Name)  [already applied]" 'Debug'
        $script:Skipped++
        return
    }

    try { $snapshot = Get-TweakSnapshot -Tweak $Tweak }
    catch {
        $script:Errors++
        Write-OptLog "  $($Tweak.Name): could not record prior state, not applied - $($_.Exception.Message)" 'Error'
        $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'error' })
        return
    }
    $target   = $Tweak.Name
    $action   = "Apply tweak [$($Tweak.Area)/$($Tweak.Risk)]"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        try {
            Set-TweakState -Tweak $Tweak -Snapshot $snapshot
            Write-OptLog "$($Tweak.Name)" 'Success'
            $script:Applied++
            $script:Snapshots.Add([pscustomobject]@{ Id = $Tweak.Id; Type = $Tweak.Type; Snapshot = $snapshot })
            $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'applied' })
            # Persist after every tweak so a cancelled run still leaves an undo record.
            Write-BackupManifest | Out-Null
        }
        catch {
            $script:Errors++
            Write-OptLog "  $($Tweak.Name): $($_.Exception.Message)" 'Error'
            $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'error' })
        }
    }
    elseif (Test-WhatIfMode) {
        $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'would-apply' })
    }
}

# =====================================================================
# BACKUP MANIFEST
# =====================================================================
# Written (and rewritten) after every applied tweak; one file per run.
function Write-BackupManifest {
    if ((Test-WhatIfMode) -or ($script:Snapshots.Count -eq 0)) { return $null }
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
    }
    $first = -not $script:ManifestFile
    if ($first) {
        $script:ManifestFile = Join-Path $BackupDir ("optimize-backup-{0:yyyyMMdd-HHmmss}.json" -f $script:StartTime)
    }
    $manifest = [pscustomobject]@{
        Timestamp    = $script:StartTime.ToString('s')
        RestorePoint = $script:RestorePointMade
        Tweaks       = $script:Snapshots
    }
    try {
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $script:ManifestFile -Encoding UTF8 -WhatIf:$false
        if ($first) { Write-OptLog "Backup manifest: $($script:ManifestFile)" 'Info' }
        return $script:ManifestFile
    } catch { Write-OptLog "Could not write backup manifest: $($_.Exception.Message)" 'Warning'; return $null }
}

# Newest manifest that has not been reverted yet (UndoneAt is stamped by -Undo).
function Get-LatestManifest {
    if (-not (Test-Path $BackupDir)) { return $null }
    $files = Get-ChildItem -Path $BackupDir -Filter 'optimize-backup-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($f in $files) {
        try { $j = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $j.UndoneAt) { return $f.FullName }
    }
    $null
}

# =====================================================================
# UNDO
# =====================================================================
function Restore-Tweak {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Entry, [object[]]$Registry)

    $def = $Registry | Where-Object { $_.Id -eq $Entry.Id } | Select-Object -First 1
    $name = if ($def) { $def.Name } else { $Entry.Id }
    $snap = $Entry.Snapshot

    if (-not $PSCmdlet.ShouldProcess($name, 'Revert tweak')) { return }
    try {
        switch ($Entry.Type) {
            'Registry' {
                $failed = @()
                foreach ($v in @($snap.Values)) {
                    $p = if ($v.Path) { [string]$v.Path } else { [string]$snap.Path }
                    try { Restore-RegValue -Path $p -Snap $v }
                    catch { $failed += $v.Name; Write-OptLog ("  {0}\{1}: {2}" -f $p, $v.Name, $_.Exception.Message) 'Warning' }
                }
                if ($failed.Count) { throw ("could not restore: {0}" -f ($failed -join ', ')) }
            }
            'Service' {
                if ($snap.Found) {
                    if ($snap.StartType) { Set-Service -Name $snap.Service -StartupType $snap.StartType -ErrorAction SilentlyContinue }
                    if ($snap.Status -eq 'Running') { Start-Service -Name $snap.Service -ErrorAction SilentlyContinue }
                }
            }
            'ScheduledTask' {
                if (Get-Command Enable-ScheduledTask -ErrorAction SilentlyContinue) {
                    foreach ($t in $snap.Tasks) {
                        if ($t.State -and $t.State -ne 'Disabled') {
                            Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue | Out-Null
                        }
                    }
                }
            }
            'Custom' {
                if ($def -and $def.Spec.Undo) { & $def.Spec.Undo $snap }
                else { Write-OptLog "No undo available for '$name'." 'Warning' }
            }
        }
        Write-OptLog "Reverted: $name" 'Success'
        $script:Applied++
    }
    catch { $script:Errors++; Write-OptLog "  revert $name : $($_.Exception.Message)" 'Error' }
}

function Start-WindowsUndo {
    Write-OptLog 'Windows Optimize - UNDO' 'Step'
    $manifestPath = if ($BackupManifest) { $BackupManifest } else { Get-LatestManifest }
    if (-not $manifestPath -or -not (Test-Path $manifestPath)) {
        Write-OptLog 'No un-reverted backup manifest found - nothing to undo.' 'Warning'; return
    }
    Write-OptLog "Using manifest: $manifestPath" 'Info'
    try { $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json }
    catch { Write-OptLog "Could not read manifest: $($_.Exception.Message)" 'Error'; return }
    if ($manifest.UndoneAt) { Write-OptLog "This manifest was already reverted at $($manifest.UndoneAt); reverting again." 'Warning' }

    $registry = Get-OptimizationTweakRegistry
    $entries  = @($manifest.Tweaks)
    if (-not $entries.Count) { Write-OptLog 'Manifest has no recorded tweaks.' 'Warning'; return }

    # Revert in reverse order of application.
    [array]::Reverse($entries)
    foreach ($e in $entries) { Restore-Tweak -Entry $e -Registry $registry }

    # Stamp a clean revert so "undo newest run" moves on to the previous manifest.
    if (-not (Test-WhatIfMode) -and $script:Errors -eq 0) {
        try {
            $manifest | Add-Member -NotePropertyName UndoneAt -NotePropertyValue ((Get-Date).ToString('s')) -Force
            $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8 -WhatIf:$false
        } catch { Write-OptLog "Could not mark manifest as reverted: $($_.Exception.Message)" 'Warning' }
    }

    Write-OptLog '' 'Info'
    Write-OptLog ("Reverted {0} tweak(s), {1} error(s)." -f $script:Applied, $script:Errors) 'Success'
}

# =====================================================================
# REPORT / SUMMARY
# =====================================================================
function Show-OptSummary {
    param([string]$ManifestFile)
    $dur  = (Get-Date) - $script:StartTime
    $mode = if (Test-WhatIfMode) { 'DRY RUN' } else { 'OPTIMIZE' }
    Write-OptLog '' 'Info'
    Write-OptLog "===== $mode SUMMARY =====" 'Step'
    $byArea = $script:Stats | Group-Object Area | Sort-Object Name
    foreach ($g in $byArea) {
        Write-OptLog ("  {0,-12} {1} tweak(s)" -f $g.Name, $g.Count) 'Info'
    }
    $verb = if (Test-WhatIfMode) { 'Would apply' } else { 'Applied' }
    Write-OptLog '' 'Info'
    if (Test-WhatIfMode) {
        $would = @($script:Stats | Where-Object Result -eq 'would-apply').Count
        Write-OptLog ("{0}: {1} tweak(s)" -f $verb, $would) 'Success'
    }
    else {
        Write-OptLog ("{0}: {1} tweak(s), skipped {2} already-applied, {3} error(s)" -f `
            $verb, $script:Applied, $script:Skipped, $script:Errors) 'Success'
        if ($ManifestFile) { Write-OptLog "Undo with:  .\Optimize-Windows-Senior.ps1 -Undo" 'Info' }
    }
    Write-OptLog ("Duration: {0:N1}s   Log: {1}" -f $dur.TotalSeconds, $LogPath) 'Info'
}

function Write-OptReport {
    param([string]$ManifestFile)
    Write-WinSeniorReport -ReportPath $ReportPath -Engine 'Optimize' `
        -RestorePoint $script:RestorePointMade -StartTime $script:StartTime `
        -Summary @{
            Applied  = $script:Applied
            Skipped  = $script:Skipped
            Errors   = $script:Errors
            Manifest = $ManifestFile
        } `
        -Items $script:Stats `
        -LogAction { param($m, $l) Write-OptLog $m $l }
}

# =====================================================================
# UI: help / list
# =====================================================================
function Show-TweakList {
    Write-Host ''
    Write-Host 'Optimization tweak registry:' -ForegroundColor Cyan
    Get-OptimizationTweakRegistry |
        Sort-Object Area, @{ E = { @{Safe=0;Moderate=1;Aggressive=2;Dangerous=3}[$_.Risk] } } |
        Format-Table @{ L='Id'; E={$_.Id}; W=22 },
                     @{ L='Area'; E={$_.Area}; W=12 },
                     @{ L='Risk'; E={$_.Risk}; W=11 },
                     @{ L='Default'; E={ if($_.DefaultOn){'on'}else{'off'} }; W=8 },
                     @{ L='Tweak'; E={$_.Name} } -AutoSize
    Write-Host 'Safe + Moderate + Aggressive selectable by default; debatable tweaks ship off (toggle or -Include).' -ForegroundColor DarkGray
    Write-Host ''
}

function Show-OptUsageHelp {
@'
Windows Optimization engine v6.0  (registry-driven, full undo)

USAGE
  .\Optimize-Windows-Senior.ps1 [options]

SELECTION
  -Area <names>         Limit to: Performance, Privacy, Debloat, Network
  -Include <ids>        Force tweaks on  (see -ListTweaks for ids)
  -Exclude <ids>        Force tweaks off
  -IncludeDangerous     Also apply the irreversible Dangerous tier
  -Conservative         Cap at Safe + Moderate (skip Aggressive)

UNDO
  -Undo                 Revert the most recent run from its backup manifest
  -BackupManifest <p>   Undo a specific manifest file
  -BackupDir <path>     Where manifests live (default %ProgramData%\WinSenior\backups)

SAFETY
  -WhatIf / -DryRun,-dr Preview only, change nothing (real ShouldProcess)
  -NoRestorePoint,-nrp  Skip the System Restore point (created by default)
  -Unattended,-Force,-f No prompts - for automation

OUTPUT
  -LogPath <path>       Text log (default: %TEMP%\WindowsOptimize.log)
  -ReportPath <path>    Machine-readable JSON report
  -ListTweaks           Print the tweak registry and exit
  -Help                 Show this help

EXAMPLES
  .\Optimize-Windows-Senior.ps1 -WhatIf
  .\Optimize-Windows-Senior.ps1 -Area Privacy,Performance
  .\Optimize-Windows-Senior.ps1 -Undo
'@ | Write-Host
}

# =====================================================================
# MAIN
# =====================================================================
function Start-WindowsOptimize {
    $modeText = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
    Write-OptLog 'Windows Optimization v6.0' 'Step'
    Write-OptLog ("PowerShell {0} | Mode: {1}" -f $PSVersionTable.PSVersion, $modeText) 'Info'

    if (-not (Test-AdminPrivileges)) {
        Write-OptLog 'Administrator privileges are required. Re-run as Administrator.' 'Error'
        exit 2
    }

    $registry  = Get-OptimizationTweakRegistry
    $selection = Resolve-TweakSelection -Registry $registry -Area $Area `
        -Include $Include -Exclude $Exclude -Conservative:$Conservative.IsPresent `
        -IncludeDangerous:$IncludeDangerous.IsPresent

    if (-not $selection) { Write-OptLog 'No tweaks selected - nothing to do.' 'Warning'; return }

    $dangerous = $selection | Where-Object { $_.Risk -eq 'Dangerous' }
    Write-OptLog ("Selected {0} tweak(s){1}." -f @($selection).Count,
        $(if ($dangerous) { ", including $($dangerous.Count) DANGEROUS" } else { '' })) 'Info'

    if ($dangerous -and -not (Test-WhatIfMode) -and -not $Unattended) {
        Write-OptLog 'Dangerous (irreversible) tweaks selected:' 'Safety'
        $dangerous | ForEach-Object { Write-OptLog "   - $($_.Name)" 'Safety' }
        $answer = Read-Host 'Proceed with these? (yes/No)'
        if ($answer -notmatch '^(y|yes)$') {
            $selection = $selection | Where-Object { $_.Risk -ne 'Dangerous' }
            Write-OptLog 'Skipping the Dangerous tier by your choice.' 'Info'
        }
    }

    if (-not $NoRestorePoint -and -not (Test-WhatIfMode)) { New-OptRestorePoint | Out-Null }

    $order = 'Performance','Privacy','Debloat','Network'
    foreach ($a in $order) {
        foreach ($tweak in ($selection | Where-Object { $_.Area -eq $a })) {
            Invoke-Tweak -Tweak $tweak
        }
    }

    $manifest = Write-BackupManifest
    Show-OptSummary -ManifestFile $manifest
    Write-OptReport -ManifestFile $manifest
}

# =====================================================================
# ENTRY POINT
# =====================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ($Help)       { Show-OptUsageHelp; exit 0 }
    if ($ListTweaks) { Show-TweakList;    exit 0 }
    if ($Undo)       { Start-WindowsUndo; exit 0 }
    Start-WindowsOptimize
}
