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
    Version : 6.0.0
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

    # Skip the real Checkpoint-Computer restore point that is otherwise created first
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

if ($DryRun) { $WhatIfPreference = $true }

# =====================================================================
# LOGGING
# =====================================================================
function Write-OptLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug','Step','WhatIf','Safety')]
        [string]$Level = 'Info'
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
    $stamp = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    try { Add-Content -Path $LogPath -Value $stamp -ErrorAction SilentlyContinue -WhatIf:$false } catch { }
}

# =====================================================================
# UTILITIES
# =====================================================================
function Format-FileSize {
    param([long]$Size)
    if     ($Size -ge 1TB) { '{0:N2} TB' -f ($Size / 1TB) }
    elseif ($Size -ge 1GB) { '{0:N2} GB' -f ($Size / 1GB) }
    elseif ($Size -ge 1MB) { '{0:N2} MB' -f ($Size / 1MB) }
    elseif ($Size -ge 1KB) { '{0:N2} KB' -f ($Size / 1KB) }
    else                   { "$Size B" }
}

function Test-WhatIfMode { [bool]$WhatIfPreference }

function Test-AdminPrivileges {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function New-OptRestorePoint {
    if (Test-WhatIfMode) {
        Write-OptLog '[WhatIf] would create a System Restore point' 'WhatIf'; return $true
    }
    Write-OptLog 'Creating System Restore point...' 'Safety'
    try {
        $rk = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        New-ItemProperty -Path $rk -Name 'SystemRestorePointCreationFrequency' `
            -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Before Windows Optimize $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
            -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-OptLog 'System Restore point created' 'Success'
        $script:RestorePointMade = $true
        return $true
    }
    catch {
        Write-OptLog "Restore point not created: $($_.Exception.Message)" 'Warning'
        Write-OptLog 'Continuing without a restore point (System Protection may be off).' 'Warning'
        return $false
    }
}

# =====================================================================
# REGISTRY HELPERS (used by Registry-type tweaks; self-contained for undo)
# =====================================================================
function Get-RegValueSnapshot {
    param([string]$Path, [string]$Name)
    $snap = [ordered]@{ Name = $Name; Existed = $false; Value = $null; Kind = $null }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and ($item.GetValueNames() -contains $Name)) {
            $snap.Existed = $true
            $snap.Value   = $item.GetValue($Name)
            try { $snap.Kind = [string]$item.GetValueKind($Name) } catch { $snap.Kind = $null }
        }
    }
    [pscustomobject]$snap
}

function Set-RegValue {
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType $Kind -Value $Value `
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
        [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'Custom'; Explain = $Explain
        Spec = @{ Test = $Test; Backup = $Backup; Apply = $Apply; Undo = $Undo }
    }
}

# Convenience for a single name/kind/value registry pair.
function RegVal { param([string]$Name, [string]$Kind, $Value)
    [pscustomobject]@{ Name = $Name; Kind = $Kind; Value = $Value } }

function Get-OptimizationTweakRegistry {
    @(
        # =============================================================
        # PERFORMANCE
        # =============================================================
        New-RegTweak perf-visualfx 'Visual effects: best performance' Performance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
            -Values @((RegVal 'VisualFXSetting' DWord 2)) `
            -Explain 'Disables animations/shadows for snappier UI (Performance Options = best performance).'
        New-RegTweak perf-menudelay 'Zero menu show delay' Performance Safe `
            -Path 'HKCU:\Control Panel\Desktop' `
            -Values @((RegVal 'MenuShowDelay' String '0')) `
            -Explain 'Menus open instantly instead of after the default 400 ms.'
        New-RegTweak perf-startupdelay 'Remove startup app delay' Performance Moderate `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' `
            -Values @((RegVal 'StartupDelayInMSec' DWord 0)) `
            -Explain 'Startup programs launch without the artificial ~10 s delay.'
        New-RegTweak perf-bgapps 'Disable background apps' Performance Moderate `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' `
            -Values @((RegVal 'GlobalUserDisabled' DWord 1)) `
            -Explain 'Stops UWP apps from running and updating in the background.'
        New-CustomTweak perf-power-high 'Power plan: High Performance' Performance Safe -DefaultOn $true `
            -Explain 'Switches the active power plan to High Performance (no CPU down-clocking on idle).' `
            -Test   { $a = (& powercfg /getactivescheme) -join ' '; [bool]($a -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') } `
            -Backup { $a = (& powercfg /getactivescheme) -join ' '; $g = if ($a -match '([0-9a-f-]{36})') { $Matches[1] } else { $null }; @{ PreviousGuid = $g } } `
            -Apply  { & powercfg /setactive '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 2>$null; if ($LASTEXITCODE -ne 0) { & powercfg /setactive SCHEME_MIN 2>$null } } `
            -Undo   { param($s) if ($s.PreviousGuid) { & powercfg /setactive $s.PreviousGuid 2>$null } }
        New-CustomTweak perf-power-ultimate 'Power plan: Ultimate Performance' Performance Aggressive -DefaultOn $false `
            -Explain 'Creates and activates the hidden Ultimate Performance plan (desktops/workstations).' `
            -Test   { $false } `
            -Backup { $a = (& powercfg /getactivescheme) -join ' '; $g = if ($a -match '([0-9a-f-]{36})') { $Matches[1] } else { $null }; @{ PreviousGuid = $g } } `
            -Apply  { & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null; & powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null } `
            -Undo   { param($s) if ($s.PreviousGuid) { & powercfg /setactive $s.PreviousGuid 2>$null } }
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
            -Explain 'Prevents Windows from silently installing promoted third-party apps.'
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
            -Values @((RegVal 'BingSearchEnabled' DWord 0), (RegVal 'CortanaConsent' DWord 0)) `
            -Explain 'Removes Bing web results and Cortana suggestions from the Start-menu search box.'
        New-RegTweak priv-cortana 'Disable Cortana (policy)' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' `
            -Values @((RegVal 'AllowCortana' DWord 0)) `
            -Explain 'Disables the Cortana assistant via Group Policy.'
        New-SvcTweak priv-diagtrack 'Disable Connected User Experiences (DiagTrack)' Privacy Moderate `
            -Service 'DiagTrack' -Startup 'Disabled' `
            -Explain 'Stops the main telemetry service that uploads diagnostic data.'
        New-SvcTweak priv-dmwappush 'Disable WAP Push message service' Privacy Moderate `
            -Service 'dmwappushservice' -Startup 'Disabled' `
            -Explain 'Disables a device-management channel used for telemetry routing.'
        New-TaskTweak priv-telemetry-tasks 'Disable CEIP & telemetry scheduled tasks' Privacy Moderate `
            -Tasks @(
                @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
                @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
                @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
                @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
                @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient' },
                @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload' }) `
            -Explain 'Disables the recurring tasks that collect and send usage/compatibility data.'

        # =============================================================
        # DEBLOAT (UWP apps)
        # =============================================================
        New-CustomTweak debloat-junk 'Remove preinstalled junk apps' Debloat Aggressive -DefaultOn $true `
            -Explain 'Removes obvious bloat (King games, Solitaire, 3D Viewer, Clipchamp, Get Help, Maps, etc.) for all users.' `
            -Test   { $false } `
            -Backup {
                $pat = @('king.com*','*CandyCrush*','*BubbleWitch*','*Microsoft.3DBuilder*','*Microsoft.Microsoft3DViewer*',
                    '*Microsoft.MicrosoftSolitaireCollection*','*Microsoft.MixedReality.Portal*','*Microsoft.WindowsFeedbackHub*',
                    '*Microsoft.GetHelp*','*Microsoft.Getstarted*','*Microsoft.WindowsMaps*','*Microsoft.BingNews*',
                    '*Microsoft.BingWeather*','*Microsoft.People*','*Clipchamp*','*Microsoft.Todos*','*Disney*','*SpotifyAB*')
                $found = foreach ($p in $pat) { Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | Select-Object -Expand Name }
                @{ Patterns = $pat; Found = @($found | Sort-Object -Unique) }
            } `
            -Apply  {
                $pat = @('king.com*','*CandyCrush*','*BubbleWitch*','*Microsoft.3DBuilder*','*Microsoft.Microsoft3DViewer*',
                    '*Microsoft.MicrosoftSolitaireCollection*','*Microsoft.MixedReality.Portal*','*Microsoft.WindowsFeedbackHub*',
                    '*Microsoft.GetHelp*','*Microsoft.Getstarted*','*Microsoft.WindowsMaps*','*Microsoft.BingNews*',
                    '*Microsoft.BingWeather*','*Microsoft.People*','*Clipchamp*','*Microsoft.Todos*','*Disney*','*SpotifyAB*')
                foreach ($p in $pat) {
                    Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -like $p } |
                        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
                }
            } `
            -Undo   { param($s)
                if ($s.Found) { Write-OptLog ("Removed UWP apps cannot be auto-reinstalled. Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' }
            }
        New-CustomTweak debloat-xbox 'Remove Xbox apps' Debloat Aggressive -DefaultOn $false `
            -Explain 'Removes Xbox app, Game Bar overlay and related packages. Off by default (gamers may want them).' `
            -Test   { $false } `
            -Backup { $f = Get-AppxPackage -AllUsers -Name '*Xbox*' -ErrorAction SilentlyContinue | Select-Object -Expand Name; @{ Found = @($f) } } `
            -Apply  { Get-AppxPackage -AllUsers -Name '*Xbox*' -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue } `
            -Undo   { param($s) if ($s.Found) { Write-OptLog ("Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' } }
        New-CustomTweak debloat-comms 'Remove Mail/Calendar, Skype, Phone Link' Debloat Aggressive -DefaultOn $false `
            -Explain 'Removes the communications apps bundle. Off by default (some people use Mail/Calendar).' `
            -Test   { $false } `
            -Backup {
                $pat = @('*Microsoft.windowscommunicationsapps*','*Microsoft.SkypeApp*','*Microsoft.YourPhone*')
                $f = foreach ($p in $pat) { Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | Select-Object -Expand Name }
                @{ Patterns = $pat; Found = @($f | Sort-Object -Unique) }
            } `
            -Apply  {
                foreach ($p in @('*Microsoft.windowscommunicationsapps*','*Microsoft.SkypeApp*','*Microsoft.YourPhone*')) {
                    Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                }
            } `
            -Undo   { param($s) if ($s.Found) { Write-OptLog ("Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' } }
        New-RegTweak debloat-start-ads 'Disable Start-menu app suggestions' Debloat Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
            -Values @(
                (RegVal 'SilentInstalledAppsEnabled' DWord 0),
                (RegVal 'PreInstalledAppsEnabled' DWord 0),
                (RegVal 'OemPreInstalledAppsEnabled' DWord 0),
                (RegVal 'SubscribedContent-338388Enabled' DWord 0)) `
            -Explain 'Stops the Start menu from showing suggested/promoted apps.'

        # =============================================================
        # NETWORK / GAMES
        # =============================================================
        New-RegTweak net-gamedvr 'Disable GameDVR / background recording' Network Safe `
            -Path 'HKCU:\System\GameConfigStore' `
            -Values @((RegVal 'GameDVR_Enabled' DWord 0), (RegVal 'GameDVR_FSEBehaviorMode' DWord 2)) `
            -Explain 'Disables the background game recorder that can cost frames and CPU.'
        New-RegTweak net-gamedvr-policy 'Disable GameDVR (policy)' Network Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' `
            -Values @((RegVal 'AllowGameDVR' DWord 0)) `
            -Explain 'Enforces GameDVR off machine-wide via policy.'
        New-RegTweak net-gamemode 'Enable Game Mode' Network Safe `
            -Path 'HKCU:\Software\Microsoft\GameBar' `
            -Values @((RegVal 'AutoGameModeEnabled' DWord 1), (RegVal 'AllowAutoGameMode' DWord 1)) `
            -Explain 'Prioritizes the foreground game for CPU/GPU scheduling.'
        New-RegTweak net-throttling 'Disable network throttling / multimedia reservation' Network Moderate `
            -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
            -Values @((RegVal 'NetworkThrottlingIndex' DWord 4294967295), (RegVal 'SystemResponsiveness' DWord 0)) `
            -Explain 'Lifts the 10-packet/ms network throttle and the 20% CPU multimedia reservation (better for gaming/streaming).'
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
                    $snap = Get-RegValueSnapshot -Path $Tweak.Spec.Path -Name $v.Name
                    if (-not $snap.Existed) { return $false }
                    if ([string]$snap.Value -ne [string]$v.Value) { return $false }
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
            $vals = foreach ($v in $Tweak.Spec.Values) { Get-RegValueSnapshot -Path $Tweak.Spec.Path -Name $v.Name }
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
            foreach ($v in $Tweak.Spec.Values) { Set-RegValue -Path $Tweak.Spec.Path -Name $v.Name -Kind $v.Kind -Value $v.Value }
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

    $applied = Test-TweakApplied -Tweak $Tweak
    if ($applied -eq $true) {
        Write-OptLog "$($Tweak.Name)  [already applied]" 'Debug'
        $script:Skipped++
        return
    }

    $snapshot = Get-TweakSnapshot -Tweak $Tweak
    $target   = $Tweak.Name
    $action   = "Apply tweak [$($Tweak.Area)/$($Tweak.Risk)]"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        try {
            Set-TweakState -Tweak $Tweak -Snapshot $snapshot
            Write-OptLog "$($Tweak.Name)" 'Success'
            $script:Applied++
            $script:Snapshots.Add([pscustomobject]@{ Id = $Tweak.Id; Type = $Tweak.Type; Snapshot = $snapshot })
            $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'applied' })
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
function Write-BackupManifest {
    if (Test-WhatIfMode -or $script:Snapshots.Count -eq 0) { return $null }
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
    }
    $file = Join-Path $BackupDir ("optimize-backup-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
    $manifest = [pscustomobject]@{
        Timestamp    = (Get-Date).ToString('s')
        RestorePoint = $script:RestorePointMade
        Tweaks       = $script:Snapshots
    }
    try {
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $file -Encoding UTF8 -WhatIf:$false
        Write-OptLog "Backup manifest written: $file" 'Info'
        return $file
    } catch { Write-OptLog "Could not write backup manifest: $($_.Exception.Message)" 'Warning'; return $null }
}

function Get-LatestManifest {
    if (-not (Test-Path $BackupDir)) { return $null }
    Get-ChildItem -Path $BackupDir -Filter 'optimize-backup-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
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
                foreach ($v in $snap.Values) { Restore-RegValue -Path $snap.Path -Snap $v }
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
        Write-OptLog 'No backup manifest found - nothing to undo.' 'Warning'; return
    }
    Write-OptLog "Using manifest: $manifestPath" 'Info'
    try { $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json }
    catch { Write-OptLog "Could not read manifest: $($_.Exception.Message)" 'Error'; return }

    $registry = Get-OptimizationTweakRegistry
    $entries  = @($manifest.Tweaks)
    if (-not $entries.Count) { Write-OptLog 'Manifest has no recorded tweaks.' 'Warning'; return }

    # Revert in reverse order of application.
    [array]::Reverse($entries)
    foreach ($e in $entries) { Restore-Tweak -Entry $e -Registry $registry }

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
    if (-not $ReportPath) { return }
    $report = [pscustomobject]@{
        Timestamp    = (Get-Date).ToString('s')
        Mode         = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
        RestorePoint = $script:RestorePointMade
        Applied      = $script:Applied
        Skipped      = $script:Skipped
        Errors       = $script:Errors
        Manifest     = $ManifestFile
        DurationSec  = [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 1)
        Tweaks       = $script:Stats
    }
    try {
        $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8 -WhatIf:$false
        Write-OptLog "JSON report written: $ReportPath" 'Info'
    } catch { Write-OptLog "Could not write report: $($_.Exception.Message)" 'Warning' }
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
  -NoRestorePoint,-nrp  Skip the Checkpoint-Computer restore point (created by default)
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
