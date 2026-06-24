<#
.SYNOPSIS
    Windows System Cleaner and Optimizer - registry-driven cleanup engine.

.DESCRIPTION
    A declarative, single-file cleanup tool for Windows 10/11. Every cleanup
    operation is one entry in a task registry; a small engine resolves which
    tasks to run, measures reclaimed space honestly, and deletes through
    PowerShell's ShouldProcess so that -WhatIf is real.

    Aggressive by default: Safe + Moderate + Aggressive tiers run out of the box.
    Irreversible operations (event-log clearing, patch cache, Windows.old) live
    in the Dangerous tier and require -IncludeDangerous. A real System Restore
    point (Checkpoint-Computer) is created by default unless -NoRestorePoint.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.1.0
    Requires: PowerShell 5.1+ (Windows). Administrator rights for most tasks.

.EXAMPLE
    .\Cleanup-Windows-Senior.ps1 -WhatIf
    Preview everything that would be removed, change nothing.

.EXAMPLE
    .\Cleanup-Windows-Senior.ps1 -Category Browsers,DevTools
    Clean only browser and developer-tool caches.

.EXAMPLE
    .\Cleanup-Windows-Senior.ps1 -Unattended -NoRestorePoint -SkipOptimization
    Fast non-interactive run for scheduled tasks / GPO / SCCM / Intune.

.EXAMPLE
    .\Cleanup-Windows-Senior.ps1 -IncludeDangerous -ReportPath C:\Logs\clean.json
    Full cleanup including irreversible tiers, write a JSON report.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    # Limit to these categories: Browsers, DevTools, Apps, System, Logs, Updates, Optimization
    [string[]]$Category,

    # Force these task ids on (overrides default-off, category and risk cap)
    [string[]]$Include,

    # Force these task ids off (wins over everything)
    [string[]]$Exclude,

    # Also run the irreversible Dangerous tier (event logs, patch cache, Windows.old)
    [switch]$IncludeDangerous,

    # Cap at Safe + Moderate (skip the Aggressive tier)
    [Alias('SafeMode')]
    [switch]$Conservative,

    # Clean only the current user instead of every profile (default = all users)
    [Alias('cu')]
    [switch]$CurrentUserOnly,

    # Local fixed drives to include for drive-level cleanup (default = all local disks).
    # e.g. -Drives C,D   Accepts 'C', 'C:', or 'C:\'.
    [string[]]$Drives,

    # Preview alias for -WhatIf
    [Alias('dr')]
    [switch]$DryRun,

    # Non-interactive: no prompts, no GUI, used for automation
    [Alias('Force','f')]
    [switch]$Unattended,

    # Skip the real Checkpoint-Computer restore point that is otherwise created first
    [Alias('nrp')]
    [switch]$NoRestorePoint,

    # Skip the slow Optimization category (SFC / DISM)
    [Alias('so')]
    [switch]$SkipOptimization,

    # Only delete files older than N days (0 = no age filter). Per-task minimums still apply.
    [int]$MaxAgeDays = 0,

    [string]$LogPath = "$env:TEMP\WindowsCleanup.log",

    # Optional path for a machine-readable JSON report
    [string]$ReportPath,

    # Print the task registry and exit
    [switch]$ListTasks,

    [switch]$Help
)

# =====================================================================
# SCRIPT STATE
# =====================================================================
$script:IsPS7Plus       = $PSVersionTable.PSVersion.Major -ge 7
$script:StartTime       = Get-Date
$script:Stats           = New-Object System.Collections.Generic.List[object]
$script:TotalBytes      = [int64]0
$script:TotalFiles      = 0
$script:TotalErrors     = 0
$script:RestorePointMade = $false

# -DryRun is a friendly alias for -WhatIf. Setting the preference here makes it
# flow into every ShouldProcess call below (and into nested helper functions).
if ($DryRun) { $WhatIfPreference = $true }

# Paths the engine must never operate on, no matter what a task or env var says.
$script:DenyList = @(
    ($env:SystemDrive + '\'),
    $env:WINDIR,
    "$env:WINDIR\System32",
    "$env:SystemDrive\Users",
    $env:USERPROFILE,
    $env:ProgramData,
    ${env:ProgramFiles},
    ${env:ProgramFiles(x86)}
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }

# =====================================================================
# SHARED LIBRARY (admin / restore-point / logging / format helpers)
# =====================================================================
. (Join-Path $PSScriptRoot 'WinSenior.Common.ps1')

# =====================================================================
# LOGGING
# =====================================================================
function Write-CleanupLog {
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
function Get-ItemSize {
    param([System.IO.FileSystemInfo]$Item)
    if ($Item.PSIsContainer) {
        $sum = (Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($sum) { [int64]$sum } else { [int64]0 }
    }
    else { [int64]$Item.Length }
}

function Get-ItemFileCount {
    param([System.IO.FileSystemInfo]$Item)
    if ($Item.PSIsContainer) {
        (Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object).Count
    }
    else { 1 }
}

function Test-SafeToDelete {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $false }
    $p = $FullPath.TrimEnd('\')
    if ($p.Length -le 3) { return $false }                       # drive root like C:\
    $key = $p.ToLowerInvariant()
    if ($script:DenyList -contains $key) { return $false }       # exact protected root
    if (($p -split '\\').Count -lt 3) { return $false }          # shallower than X:\a\b
    return $true
}

# =====================================================================
# USER / PATH RESOLUTION
# =====================================================================
function Get-UserProfiles {
    if ($CurrentUserOnly) {
        return ,([pscustomobject]@{ Name = $env:USERNAME; FullName = $env:USERPROFILE })
    }
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName } }
}

# Local fixed disks ('C:\','D:\',...). Filtered by -Drives when supplied.
function Get-LocalDrives {
    $all = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
             ForEach-Object { $_.DeviceID + '\' })
    if (-not $all) { $all = @($env:SystemDrive + '\') }
    if ($Drives) {
        $want = $Drives | ForEach-Object { $_.TrimEnd('\').TrimEnd(':').ToUpperInvariant() }
        $all = $all | Where-Object { $want -contains $_.Substring(0, 1).ToUpperInvariant() }
    }
    $all
}

function Expand-TaskPath {
    param([string[]]$Raw)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Raw) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry)
        if ($expanded -like '*<USER>*') {
            foreach ($prof in (Get-UserProfiles)) {
                $out.Add($expanded.Replace('<USER>', $prof.FullName))
            }
        }
        elseif ($expanded -like '*<DRIVE>*') {
            foreach ($d in (Get-LocalDrives)) {
                $out.Add($expanded.Replace('<DRIVE>', $d))
            }
        }
        else { $out.Add($expanded) }
    }
    $out
}

# =====================================================================
# CORE: PATH CLEANUP (honest accounting + real ShouldProcess)
# =====================================================================
function Invoke-PathCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Path,
        [int]$AgeDays = 0,
        [string]$Description = 'items'
    )

    $files = 0; [int64]$bytes = 0; $errors = 0
    $cutoff = if ($AgeDays -gt 0) { (Get-Date).AddDays(-$AgeDays) } else { $null }

    foreach ($spec in $Path) {
        # A bare directory path (no wildcard) means "empty this directory".
        $container = if ($spec -match '[\*\?]') { Split-Path $spec -Parent } else { $spec }
        if (-not (Test-Path -Path $container -ErrorAction SilentlyContinue)) { continue }

        $items = Get-ChildItem -Path $spec -Force -ErrorAction SilentlyContinue
        if ($cutoff) { $items = $items | Where-Object { $_.LastWriteTime -lt $cutoff } }

        foreach ($item in $items) {
            $full = $item.FullName
            if (-not (Test-SafeToDelete $full)) {
                Write-CleanupLog "refusing unsafe path: $full" 'Warning'
                continue
            }
            $size  = Get-ItemSize $item
            $count = Get-ItemFileCount $item

            if ($PSCmdlet.ShouldProcess($full, "Remove ($Description)")) {
                try {
                    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
                    if (-not (Test-Path -LiteralPath $full)) { $files += $count; $bytes += $size }
                }
                catch {
                    $errors++
                    Write-CleanupLog "  $full : $($_.Exception.Message)" 'Debug'
                }
            }
            elseif (Test-WhatIfMode) {
                # -WhatIf: count what would be freed (ShouldProcess already printed the preview)
                $files += $count; $bytes += $size
            }
        }
    }

    [pscustomobject]@{ Files = $files; Bytes = $bytes; Errors = $errors }
}

# Stop a set of services, run a body, then restart whatever was running.
function Use-StoppedService {
    param([string[]]$Name, [scriptblock]$Body)
    $restart = @()
    if (-not (Test-WhatIfMode)) {
        foreach ($n in $Name) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
                $restart += $n
            }
        }
    }
    try { & $Body }
    finally {
        foreach ($n in $restart) { Start-Service -Name $n -ErrorAction SilentlyContinue }
    }
}

# Run a native command unless in WhatIf mode.
function Invoke-NativeStep {
    param([string]$Caption, [scriptblock]$Body)
    if (Test-WhatIfMode) {
        Write-CleanupLog "[WhatIf] would run: $Caption" 'WhatIf'
        return $true
    }
    try { & $Body; Write-CleanupLog $Caption 'Success'; return $true }
    catch { Write-CleanupLog "$Caption failed: $($_.Exception.Message)" 'Error'; return $false }
}

# Remove a top-level folder that needs ownership first (Windows.old etc.).
function Remove-ProtectedFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$FullPath, [string]$Description)
    if (-not (Test-Path -LiteralPath $FullPath)) { return $null }
    if (-not (Test-SafeToDelete $FullPath)) {
        Write-CleanupLog "refusing unsafe path: $FullPath" 'Warning'; return $null
    }
    $size  = Get-ItemSize (Get-Item -LiteralPath $FullPath -Force)
    if ($PSCmdlet.ShouldProcess($FullPath, "Remove ($Description)")) {
        & takeown.exe /F "$FullPath" /R /D Y *>$null
        & icacls.exe "$FullPath" /grant "*S-1-5-32-544:F" /T /C *>$null
        Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $FullPath)) {
            return [pscustomobject]@{ Files = 0; Bytes = $size; Errors = 0 }
        }
        return [pscustomobject]@{ Files = 0; Bytes = 0; Errors = 1 }
    }
    elseif (Test-WhatIfMode) {
        return [pscustomobject]@{ Files = 0; Bytes = $size; Errors = 0 }
    }
    $null
}

# =====================================================================
# SAFETY / ENVIRONMENT
# =====================================================================
function New-CleanupRestorePoint {
    $st = New-WinSeniorRestorePoint `
        -Description "Before Windows Cleanup $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        -LogAction { param($m, $l) Write-CleanupLog $m $l }
    if ($st -eq 'Created') { $script:RestorePointMade = $true }
    return ($st -ne 'Failed')
}

function Stop-BrowserProcesses {
    $names = 'chrome','msedge','firefox','opera','browser','brave'
    if (Test-WhatIfMode) {
        Write-CleanupLog '[WhatIf] would close running browsers' 'WhatIf'; return
    }
    foreach ($n in $names) {
        $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($procs) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-CleanupLog "Closed $($procs.Count) $n process(es)" 'Debug'
        }
    }
}

# =====================================================================
# TASK REGISTRY  (the single source of truth)
# =====================================================================
function New-CleanupTask {
    param(
        [string]$Id, [string]$Name, [string]$Category, [string]$Risk,
        [bool]$DefaultOn = $true, [int]$AgeDays = 0,
        [string[]]$Paths, [scriptblock]$Action, [string[]]$StopServices
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Category = $Category; Risk = $Risk
        DefaultOn = $DefaultOn; AgeDays = $AgeDays
        Paths = $Paths; Action = $Action; StopServices = $StopServices
    }
}

function Get-CleanupTaskRegistry {
    @(
        # ---------------- Browsers (Safe) ----------------
        New-CleanupTask chrome 'Chrome cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Cache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Service Worker\CacheStorage\*')
        New-CleanupTask edge 'Edge cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Cache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Service Worker\CacheStorage\*')
        New-CleanupTask firefox 'Firefox cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\cache2\*',
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\startupCache\*',
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\thumbnails\*')
        New-CleanupTask opera 'Opera cache' Browsers Safe -Paths @(
            '<USER>\AppData\Roaming\Opera Software\Opera Stable\Cache\*',
            '<USER>\AppData\Roaming\Opera Software\Opera Stable\GPUCache\*',
            '<USER>\AppData\Local\Opera Software\Opera Stable\Cache\*')
        New-CleanupTask yandex 'Yandex cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\*\Cache\*',
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\*\GPUCache\*')
        New-CleanupTask brave 'Brave cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Cache\*',
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\GPUCache\*')

        # ---------------- DevTools (Safe) ----------------
        New-CleanupTask npm 'npm cache' DevTools Safe -Paths @('<USER>\AppData\Local\npm-cache\*')
        New-CleanupTask pip 'pip cache' DevTools Safe -Paths @('<USER>\AppData\Local\pip\Cache\*')
        New-CleanupTask nuget 'NuGet http cache' DevTools Safe -Paths @(
            '<USER>\AppData\Local\NuGet\v3-cache\*',
            '<USER>\AppData\Local\NuGet\plugins-cache\*')
        New-CleanupTask yarn 'Yarn cache' DevTools Safe -Paths @('<USER>\AppData\Local\Yarn\Cache\*')
        New-CleanupTask gradle 'Gradle cache' DevTools Safe -Paths @('<USER>\.gradle\caches\*')
        New-CleanupTask vscode 'VS Code cache' DevTools Safe -Paths @(
            '<USER>\AppData\Roaming\Code\Cache\*',
            '<USER>\AppData\Roaming\Code\CachedData\*',
            '<USER>\AppData\Roaming\Code\Code Cache\*',
            '<USER>\AppData\Roaming\Code\GPUCache\*')
        New-CleanupTask jetbrains 'JetBrains IDE caches, logs & temp' DevTools Safe -Paths @(
            '<USER>\AppData\Local\JetBrains\*\caches\*',
            '<USER>\AppData\Local\JetBrains\*\log\*',
            '<USER>\AppData\Local\JetBrains\*\tmp\*')
        New-CleanupTask nuitka 'Nuitka build cache' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Nuitka\*')
        New-CleanupTask docker 'Docker dangling images & build cache' DevTools Safe -Action {
            if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
                Write-CleanupLog 'Docker not installed - skipped' 'Debug'; return $null
            }
            Invoke-NativeStep 'docker system prune -f' { & docker system prune -f *>$null } | Out-Null
            $null
        }
        New-CleanupTask pnpm 'pnpm store (prune unreferenced)' DevTools Safe -Action {
            if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
                Write-CleanupLog 'pnpm not installed - skipped' 'Debug'; return $null
            }
            # Blunt-deleting the store breaks hardlinks into existing node_modules and frees
            # nothing for in-use packages; prune only removes unreferenced content.
            Invoke-NativeStep 'pnpm store prune' { & pnpm store prune *>$null } | Out-Null
            $null
        }
        New-CleanupTask pkgmgr 'Package-manager & build caches (winget/choco/scoop/conda/cargo/go/pub)' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\WinGet\Cache\*',
            '%ProgramData%\chocolatey\cache\*',
            '<USER>\scoop\cache\*',
            '<USER>\.conda\pkgs\*',
            '<USER>\.cargo\registry\cache\*',
            '<USER>\go\pkg\mod\cache\download\*',
            '<USER>\AppData\Local\go-build\*',
            '<USER>\AppData\Local\Pub\Cache\*')
        New-CleanupTask ps-modulecache 'PowerShell module analysis cache' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\PowerShell\ModuleAnalysisCache',
            '<USER>\AppData\Local\Microsoft\Windows\PowerShell\StartupProfileData-*')

        # ---------------- Apps / messengers (Safe) ----------------
        New-CleanupTask appcache 'Windows app cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\AppCache\*',
            '<USER>\AppData\Local\ConnectedDevicesPlatform\*',
            '<USER>\AppData\Local\Packages\*\AC\INetCache\*',
            '<USER>\AppData\Local\Packages\*\AC\Temp\*')
        New-CleanupTask teams 'Microsoft Teams cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Microsoft\Teams\Cache\*',
            '<USER>\AppData\Roaming\Microsoft\Teams\GPUCache\*',
            '<USER>\AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage\*',
            '<USER>\AppData\Local\Packages\MSTeams_*\LocalCache\Microsoft\MSTeams\*Cache\*')
        New-CleanupTask discord 'Discord cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\discord\Cache\*',
            '<USER>\AppData\Roaming\discord\Code Cache\*',
            '<USER>\AppData\Roaming\discord\GPUCache\*')
        New-CleanupTask slack 'Slack cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Slack\Cache\*',
            '<USER>\AppData\Roaming\Slack\Service Worker\CacheStorage\*')
        New-CleanupTask spotify 'Spotify cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Spotify\Storage\*',
            '<USER>\AppData\Local\Spotify\Data\*')
        # Moderate: the Office document cache can hold not-yet-uploaded changes.
        New-CleanupTask office 'Office document & web cache' Apps Moderate -Paths @(
            '<USER>\AppData\Local\Microsoft\Office\*\OfficeFileCache\*',
            '<USER>\AppData\Local\Microsoft\Office\*\Wef\*',
            '<USER>\AppData\Local\Microsoft\Windows\INetCache\Content.Outlook\*')
        New-CleanupTask onedrive 'OneDrive logs' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\OneDrive\logs\*',
            '<USER>\AppData\Local\Microsoft\OneDrive\setup\logs\*')
        New-CleanupTask adobe-media 'Adobe media & Camera Raw cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Adobe\Common\Media Cache\*',
            '<USER>\AppData\Roaming\Adobe\Common\Media Cache Files\*',
            '<USER>\AppData\Local\Adobe\CameraRaw\Cache\*')
        New-CleanupTask rdp-cache 'Remote Desktop client bitmap cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Terminal Server Client\Cache\*')

        # ---------------- Games (launcher caches, Safe) ----------------
        New-CleanupTask game-caches 'Game launcher caches (Steam/Epic/Battle.net/GOG)' Games Safe -Paths @(
            '%ProgramFiles(x86)%\Steam\appcache\httpcache\*',
            '%ProgramFiles(x86)%\Steam\config\htmlcache\*',
            '%ProgramFiles(x86)%\Steam\steamapps\shadercache\*',
            '<USER>\AppData\Local\EpicGamesLauncher\Saved\webcache\*',
            '<USER>\AppData\Local\Battle.net\Cache\*',
            '%ProgramData%\Battle.net\Agent\data\cache\*',
            '<USER>\AppData\Local\GOG.com\Galaxy\webcache\*')

        # ---------------- System (Safe / Moderate / Aggressive) ----------------
        New-CleanupTask temp-user 'User temp files' System Safe -Paths @(
            '<USER>\AppData\Local\Temp\*')
        New-CleanupTask temp-windows 'Windows temp files' System Safe -Paths @('%WINDIR%\Temp\*')
        New-CleanupTask inetcache 'Internet Explorer/WinINet cache' System Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\INetCache\*',
            '<USER>\AppData\Local\Microsoft\Windows\Temporary Internet Files\*')
        New-CleanupTask thumbnails 'Thumbnail & icon cache' System Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db',
            '<USER>\AppData\Local\Microsoft\Windows\Explorer\iconcache_*.db',
            '<USER>\AppData\Local\IconCache.db')
        New-CleanupTask shadercache 'GPU shader / D3D cache' System Safe -Paths @(
            '<USER>\AppData\Local\D3DSCache\*',
            '<USER>\AppData\Local\NVIDIA\DXCache\*',
            '<USER>\AppData\Local\NVIDIA\GLCache\*',
            '<USER>\AppData\Local\NVIDIA\OptixCache\*',
            '<USER>\AppData\Local\NVIDIA Corporation\NV_Cache\*',
            '<USER>\AppData\Local\AMD\DxCache\*')
        New-CleanupTask win-caches 'Windows per-user app caches' System Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\Caches\*')
        New-CleanupTask gpu-leftovers 'GPU driver installer leftovers (NVIDIA/AMD)' System Safe -Paths @(
            '<DRIVE>NVIDIA\*',
            '<DRIVE>AMD\*',
            '%ProgramData%\NVIDIA Corporation\Downloader\*',
            '%ProgramData%\NVIDIA Corporation\NV_Cache\*')
        New-CleanupTask webcache 'WinINet WebCache database' System Moderate -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\WebCache\*')
        New-CleanupTask deliveryopt 'Delivery Optimization cache' System Safe -Paths @(
            '%WINDIR%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\*',
            '%ProgramData%\Microsoft\Windows\DeliveryOptimization\*')
        New-CleanupTask recent 'Recent items & jump lists' System Moderate -DefaultOn $true -Paths @(
            '<USER>\AppData\Roaming\Microsoft\Windows\Recent\*')
        New-CleanupTask fontcache 'Font cache' System Moderate -StopServices @('FontCache') -Paths @(
            '%WINDIR%\ServiceProfiles\LocalService\AppData\Local\FontCache\*')
        New-CleanupTask winlogs 'Windows log files' System Moderate -Paths @('%WINDIR%\Logs\*')
        New-CleanupTask prefetch 'Prefetch (rebuilt by Windows)' System Aggressive -Paths @(
            '%WINDIR%\Prefetch\*')
        New-CleanupTask old-drivers 'Remove superseded driver packages (pnputil)' System Dangerous -Action {
            # Enumeration is read-only, but loading the DISM module (triggered by Get-Command
            # or Get-WindowsDriver) runs Set-Alias under the GLOBAL WhatIf preference. Toggle
            # it off around the whole module-touching region so dry-runs stay quiet.
            $prevWhatIf = $global:WhatIfPreference
            try {
                $global:WhatIfPreference = $false
                if (-not (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue)) {
                    Write-CleanupLog 'Get-WindowsDriver (DISM module) unavailable - skipped' 'Warning'; return $null
                }
                $pkgs = @(Get-WindowsDriver -Online -ErrorAction Stop)
            }
            catch { Write-CleanupLog "Driver enumeration failed: $($_.Exception.Message)" 'Warning'; return $null }
            finally { $global:WhatIfPreference = $prevWhatIf }

            # Group third-party packages by original .inf name; keep the newest version of
            # each, mark older duplicates. Never touch boot-critical drivers.
            $stale = foreach ($g in ($pkgs | Where-Object { -not $_.BootCritical -and $_.OriginalFileName } |
                        Group-Object { [System.IO.Path]::GetFileName([string]$_.OriginalFileName).ToLowerInvariant() })) {
                if ($g.Count -lt 2) { continue }
                $g.Group |
                    Sort-Object @{ E = { try { [version]$_.Version } catch { [version]'0.0' } } }, Date -Descending |
                    Select-Object -Skip 1
            }
            $stale = @($stale)
            if (-not $stale.Count) { Write-CleanupLog 'No superseded driver duplicates found' 'Success'; return $null }

            if (Test-WhatIfMode) {
                foreach ($d in $stale) {
                    Write-CleanupLog ("[WhatIf] would run: pnputil /delete-driver {0}  ({1} v{2})" -f `
                        $d.Driver, [System.IO.Path]::GetFileName([string]$d.OriginalFileName), $d.Version) 'WhatIf'
                }
                return [pscustomobject]@{ Files = $stale.Count; Bytes = 0; Errors = 0 }
            }

            $removed = 0; $kept = 0
            foreach ($d in $stale) {
                # No /force: pnputil refuses to remove a driver currently bound to a device.
                & pnputil.exe /delete-driver $d.Driver 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $removed++
                    Write-CleanupLog ("Removed old driver {0} ({1} v{2})" -f `
                        $d.Driver, [System.IO.Path]::GetFileName([string]$d.OriginalFileName), $d.Version) 'Success'
                }
                else { $kept++ }
            }
            Write-CleanupLog "Old drivers removed: $removed, kept (in use): $kept" 'Info'
            [pscustomobject]@{ Files = $removed; Bytes = 0; Errors = $kept }
        }

        # ---------------- Disks (every local fixed drive) ----------------
        # Recycle Bins on every drive are emptied by the 'recyclebin' task (Clear-RecycleBin
        # spans all drives). These add drive-level scratch/junk on C:, D:, E: ...
        New-CleanupTask disk-temp 'Drive-level temp folders (all local disks)' Disks Moderate -Paths @(
            '<DRIVE>Temp\*',
            '<DRIVE>tmp\*')
        New-CleanupTask disk-chkdsk 'CHKDSK recovered fragments (FOUND.*)' Disks Safe -Paths @(
            '<DRIVE>FOUND.*\*')

        # ---------------- Logs / dumps ----------------
        New-CleanupTask wer 'Windows Error Reporting' Logs Safe -Paths @(
            '%ProgramData%\Microsoft\Windows\WER\ReportQueue\*',
            '%ProgramData%\Microsoft\Windows\WER\ReportArchive\*',
            '<USER>\AppData\Local\Microsoft\Windows\WER\*')
        New-CleanupTask extra-logs 'Setup logs & Defender scan history' Logs Safe -Paths @(
            '%WINDIR%\Panther\*',
            '%WINDIR%\inf\setupapi.dev*.log',
            '%WINDIR%\inf\setupapi.setup*.log',
            '%ProgramData%\Microsoft\Windows Defender\Scans\History\Results\*')
        New-CleanupTask livekernel 'Live kernel crash dumps (driver/GPU TDR)' Logs Safe -Paths @(
            '%WINDIR%\LiveKernelReports\*.dmp')
        New-CleanupTask srum-db 'Network/app usage telemetry DB (SRUM)' Logs Moderate `
            -StopServices @('DPS') -Paths @('%WINDIR%\System32\sru\*')
        New-CleanupTask eventtranscript 'Diagnostic telemetry database (EventTranscript)' Logs Moderate `
            -StopServices @('DiagTrack') -Paths @(
            '%ProgramData%\Microsoft\Diagnosis\EventTranscript\*')
        New-CleanupTask crashdumps 'Crash & memory dumps' Logs Moderate -Paths @(
            '%WINDIR%\Minidump\*',
            '%WINDIR%\MEMORY.DMP',
            '<USER>\AppData\Local\CrashDumps\*')
        New-CleanupTask iislogs 'Old IIS logs (>14 days)' Logs Moderate -DefaultOn $true -AgeDays 14 -Paths @(
            '%WINDIR%\System32\LogFiles\W3SVC*\*.log',
            '%WINDIR%\System32\LogFiles\HTTPERR\*.log')
        New-CleanupTask recyclebin 'Recycle Bin' Logs Moderate -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would empty the Recycle Bin' 'WhatIf'; return $null }
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                Write-CleanupLog 'Recycle Bin emptied' 'Success'
            } catch {
                Write-CleanupLog "Recycle Bin: $($_.Exception.Message)" 'Warning'
            }
            $null
        }
        New-CleanupTask eventlogs 'Clear event logs (archived first)' Logs Dangerous -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would archive & clear Application/System/Setup logs' 'WhatIf'; return $null }
            $archive = Join-Path $env:TEMP "EventLogBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            New-Item -ItemType Directory -Path $archive -Force -ErrorAction SilentlyContinue | Out-Null
            foreach ($log in 'Application','System','Setup') {
                $dest = Join-Path $archive "$log.evtx"
                & wevtutil.exe export-log $log "$dest" /overwrite:true 2>$null
                & wevtutil.exe clear-log $log 2>$null
                Write-CleanupLog "Archived & cleared '$log' (backup: $dest)" 'Success'
            }
            $null
        }

        # ---------------- Updates ----------------
        New-CleanupTask wu-cache 'Windows Update download cache' Updates Moderate `
            -StopServices @('wuauserv','bits','cryptsvc') -Paths @(
            '%WINDIR%\SoftwareDistribution\Download\*',
            '%WINDIR%\System32\catroot2\*')
        New-CleanupTask wu-full 'Full SoftwareDistribution reset' Updates Aggressive -DefaultOn $true `
            -StopServices @('wuauserv','bits','cryptsvc') -Paths @(
            '%WINDIR%\SoftwareDistribution\*')
        New-CleanupTask patchcache 'Windows Installer patch cache' Updates Dangerous -Paths @(
            '%WINDIR%\Installer\$PatchCache$\*',
            '%WINDIR%\Installer\*.tmp')
        New-CleanupTask windows-old 'Windows.old & upgrade leftovers' Updates Dangerous -Action {
            $total = [pscustomobject]@{ Files = 0; Bytes = 0; Errors = 0 }
            foreach ($folder in @(
                    "$env:SystemDrive\Windows.old",
                    "$env:SystemDrive\`$Windows.~BT",
                    "$env:SystemDrive\`$Windows.~WS",
                    "$env:SystemDrive\`$WinREAgent",
                    "$env:WINDIR\Downloaded Program Files")) {
                $r = Remove-ProtectedFolder -FullPath $folder -Description 'upgrade leftovers'
                if ($r) { $total.Bytes += $r.Bytes; $total.Errors += $r.Errors }
            }
            $total
        }

        # ---------------- Optimization (slow; skipped by -SkipOptimization) ----------------
        New-CleanupTask dism-analyze 'Analyze component store (report only)' Optimization Safe -DefaultOn $true -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would run DISM /AnalyzeComponentStore' 'WhatIf'; return $null }
            $out = & dism.exe /online /Cleanup-Image /AnalyzeComponentStore 2>&1
            $out | Where-Object { $_ -match ':' } | ForEach-Object { Write-CleanupLog "  $_" 'Debug' }
            Write-CleanupLog 'Component store analyzed' 'Success'; $null
        }
        New-CleanupTask component-task 'Run StartComponentCleanup scheduled task' Optimization Moderate -Action {
            Invoke-NativeStep 'schtasks StartComponentCleanup' {
                & schtasks.exe /Run /TN '\Microsoft\Windows\Servicing\StartComponentCleanup' *>$null
            } | Out-Null
            $null
        }
        New-CleanupTask dism-cleanup 'DISM component cleanup' Optimization Moderate -Action {
            Invoke-NativeStep 'DISM /StartComponentCleanup' {
                & dism.exe /online /Cleanup-Image /StartComponentCleanup /Quiet *>$null
            } | Out-Null
            $null
        }
        New-CleanupTask dism-resetbase 'DISM reset base + remove superseded' Optimization Aggressive -DefaultOn $true -Action {
            Invoke-NativeStep 'DISM /SPSuperseded' {
                & dism.exe /online /Cleanup-Image /SPSuperseded *>$null
            } | Out-Null
            Invoke-NativeStep 'DISM /StartComponentCleanup /ResetBase' {
                & dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet *>$null
            } | Out-Null
            $null
        }
        New-CleanupTask dism-logs 'DISM logs' Optimization Safe -Paths @('%WINDIR%\Logs\DISM\*')
        New-CleanupTask sfc 'System File Checker (sfc /scannow)' Optimization Moderate -DefaultOn $true -Action {
            Invoke-NativeStep 'sfc /scannow' { & sfc.exe /scannow | Out-Null } | Out-Null
            $null
        }
    )
}

# =====================================================================
# SELECTION
# =====================================================================
function Resolve-CleanupSelection {
    param(
        [object[]]$Registry,
        [string[]]$Category, [string[]]$Include, [string[]]$Exclude,
        [bool]$Conservative, [bool]$IncludeDangerous, [bool]$SkipOptimization
    )
    $rank = @{ Safe = 0; Moderate = 1; Aggressive = 2; Dangerous = 3 }
    $maxRisk = if ($IncludeDangerous) { 3 } elseif ($Conservative) { 1 } else { 2 }

    foreach ($t in $Registry) {
        $on = $t.DefaultOn
        if ($Category -and ($t.Category -notin $Category)) { $on = $false }
        if ($SkipOptimization -and $t.Category -eq 'Optimization') { $on = $false }
        if ($rank[$t.Risk] -gt $maxRisk) { $on = $false }
        if (($Include -contains $t.Id) -or ($Include -contains $t.Name)) { $on = $true }
        if (($Exclude -contains $t.Id) -or ($Exclude -contains $t.Name)) { $on = $false }
        if ($on) { $t }
    }
}

# =====================================================================
# EXECUTION
# =====================================================================
function Invoke-CleanupTask {
    param([object]$Task)
    Write-CleanupLog "$($Task.Name)  [$($Task.Category)/$($Task.Risk)]" 'Step'

    $result = $null
    if ($Task.Action) {
        $result = & $Task.Action
    }
    else {
        $paths  = Expand-TaskPath $Task.Paths
        $effAge = [Math]::Max($MaxAgeDays, $Task.AgeDays)
        if ($Task.StopServices) {
            $result = Use-StoppedService -Name $Task.StopServices -Body {
                Invoke-PathCleanup -Path $paths -AgeDays $effAge -Description $Task.Name
            }
        }
        else {
            $result = Invoke-PathCleanup -Path $paths -AgeDays $effAge -Description $Task.Name
        }
    }

    if ($result -and ($result.PSObject.Properties.Name -contains 'Bytes')) {
        $script:TotalBytes  += [int64]$result.Bytes
        $script:TotalFiles  += [int]$result.Files
        $script:TotalErrors += [int]$result.Errors
        $script:Stats.Add([pscustomobject]@{
            Task = $Task.Id; Category = $Task.Category
            Files = [int]$result.Files; Bytes = [int64]$result.Bytes; Errors = [int]$result.Errors
        })
        if ($result.Bytes -gt 0 -or $result.Files -gt 0) {
            $verb = if (Test-WhatIfMode) { 'would free' } else { 'freed' }
            if ($result.Bytes -gt 0) {
                Write-CleanupLog ("  {0} {1} ({2} items)" -f $verb, (Format-FileSize $result.Bytes), $result.Files) 'Success'
            }
            else {
                # space-less ops (e.g. driver packages) report item counts only
                Write-CleanupLog ("  {0} {1} item(s)" -f $verb, $result.Files) 'Success'
            }
        }
    }
}

function Show-CleanupSummary {
    $dur = (Get-Date) - $script:StartTime
    $mode = if (Test-WhatIfMode) { 'DRY RUN' } else { 'CLEANUP' }
    Write-CleanupLog '' 'Info'
    Write-CleanupLog "===== $mode SUMMARY =====" 'Step'

    $byCat = $script:Stats | Group-Object Category | Sort-Object Name
    foreach ($g in $byCat) {
        $b = ($g.Group | Measure-Object Bytes -Sum).Sum
        if (-not $b) { $b = 0 }
        Write-CleanupLog ("  {0,-13} {1}" -f $g.Name, (Format-FileSize $b)) 'Info'
    }

    $verb = if (Test-WhatIfMode) { 'Would free' } else { 'Reclaimed' }
    Write-CleanupLog '' 'Info'
    Write-CleanupLog ("{0}: {1}  ({2} items)" -f $verb, (Format-FileSize $script:TotalBytes), $script:TotalFiles) 'Success'
    if ($script:TotalErrors -gt 0) {
        Write-CleanupLog "Errors (locked/in-use items): $script:TotalErrors" 'Warning'
    }
    Write-CleanupLog ("Duration: {0:N1}s   Log: {1}" -f $dur.TotalSeconds, $LogPath) 'Info'
}

function Write-CleanupReport {
    Write-WinSeniorReport -ReportPath $ReportPath -Engine 'Cleanup' `
        -RestorePoint $script:RestorePointMade -StartTime $script:StartTime `
        -Summary @{
            TotalBytes  = $script:TotalBytes
            TotalFreed  = (Format-FileSize $script:TotalBytes)
            TotalFiles  = $script:TotalFiles
            TotalErrors = $script:TotalErrors
        } `
        -Items $script:Stats `
        -LogAction { param($m, $l) Write-CleanupLog $m $l }
}

# =====================================================================
# UI: help / list
# =====================================================================
function Show-TaskList {
    Write-Host ''
    Write-Host 'Cleanup task registry:' -ForegroundColor Cyan
    Get-CleanupTaskRegistry |
        Sort-Object Category, @{ E = { @{Safe=0;Moderate=1;Aggressive=2;Dangerous=3}[$_.Risk] } } |
        Format-Table @{ L='Id'; E={$_.Id}; W=16 },
                     @{ L='Category'; E={$_.Category}; W=13 },
                     @{ L='Risk'; E={$_.Risk}; W=11 },
                     @{ L='Default'; E={ if($_.DefaultOn){'on'}else{'off'} }; W=8 },
                     @{ L='Description'; E={$_.Name} } -AutoSize
    Write-Host 'Risk tiers: Safe + Moderate + Aggressive run by default; Dangerous needs -IncludeDangerous.' -ForegroundColor DarkGray
    Write-Host ''
}

function Show-UsageHelp {
@'
Windows System Cleaner and Optimizer v6.0  (registry-driven engine)

USAGE
  .\Cleanup-Windows-Senior.ps1 [options]

SELECTION
  -Category <names>     Limit to: Browsers, DevTools, Apps, Games, System, Disks, Logs, Updates, Optimization
  -Include  <ids>       Force tasks on  (see -ListTasks for ids)
  -Exclude  <ids>       Force tasks off
  -IncludeDangerous     Also run irreversible tier (event logs, patch cache, Windows.old, old drivers)
  -Conservative         Cap at Safe + Moderate (skip Aggressive)
  -CurrentUserOnly,-cu  Clean only the current profile (default: all users)
  -Drives <letters>     Local disks for drive-level cleanup, e.g. -Drives C,D (default: all local disks)
  -SkipOptimization,-so Skip the slow SFC/DISM category
  -MaxAgeDays <n>       Only delete files older than n days

SAFETY
  -WhatIf / -DryRun,-dr Preview only, change nothing (real ShouldProcess)
  -NoRestorePoint,-nrp  Skip the Checkpoint-Computer restore point (created by default)
  -Unattended,-Force,-f No prompts / no GUI - for scheduled tasks, GPO, SCCM, Intune

OUTPUT
  -LogPath <path>       Text log (default: %TEMP%\WindowsCleanup.log)
  -ReportPath <path>    Machine-readable JSON report
  -ListTasks            Print the task registry and exit
  -Help                 Show this help

EXAMPLES
  .\Cleanup-Windows-Senior.ps1 -WhatIf
  .\Cleanup-Windows-Senior.ps1 -Category Browsers,DevTools
  .\Cleanup-Windows-Senior.ps1 -Unattended -NoRestorePoint -SkipOptimization
  .\Cleanup-Windows-Senior.ps1 -IncludeDangerous -ReportPath C:\Logs\clean.json
'@ | Write-Host
}

# =====================================================================
# MAIN
# =====================================================================
function Start-WindowsCleanup {
    $modeText  = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
    $scopeText = if ($CurrentUserOnly) { 'current user' } else { 'all users' }
    Write-CleanupLog 'Windows System Cleaner v6.0' 'Step'
    Write-CleanupLog ("PowerShell {0} | Mode: {1} | Scope: {2}" -f $PSVersionTable.PSVersion, $modeText, $scopeText) 'Info'

    if (-not (Test-AdminPrivileges)) {
        Write-CleanupLog 'Administrator privileges are required. Re-run as Administrator.' 'Error'
        exit 2
    }

    $registry  = Get-CleanupTaskRegistry
    $selection = Resolve-CleanupSelection -Registry $registry -Category $Category `
        -Include $Include -Exclude $Exclude -Conservative:$Conservative.IsPresent `
        -IncludeDangerous:$IncludeDangerous.IsPresent -SkipOptimization:$SkipOptimization.IsPresent

    if (-not $selection) { Write-CleanupLog 'No tasks selected - nothing to do.' 'Warning'; return }

    # wu-full wipes everything wu-cache would, so drop the redundant double service bounce.
    if (($selection.Id -contains 'wu-full') -and ($selection.Id -contains 'wu-cache')) {
        $selection = $selection | Where-Object { $_.Id -ne 'wu-cache' }
    }

    $dangerous = $selection | Where-Object { $_.Risk -eq 'Dangerous' }
    Write-CleanupLog ("Selected {0} task(s){1}." -f $selection.Count,
        $(if ($dangerous) { ", including $($dangerous.Count) DANGEROUS" } else { '' })) 'Info'

    # Single grouped confirmation for the irreversible tier (interactive runs only).
    if ($dangerous -and -not (Test-WhatIfMode) -and -not $Unattended) {
        Write-CleanupLog 'Dangerous (irreversible) tasks selected:' 'Safety'
        $dangerous | ForEach-Object { Write-CleanupLog "   - $($_.Name)" 'Safety' }
        $answer = Read-Host 'Proceed with these irreversible operations? (yes/No)'
        if ($answer -notmatch '^(y|yes)$') {
            $selection = $selection | Where-Object { $_.Risk -ne 'Dangerous' }
            Write-CleanupLog 'Skipping the Dangerous tier by your choice.' 'Info'
        }
    }

    # Real restore point first (unless previewing or opted out).
    if (-not $NoRestorePoint -and -not (Test-WhatIfMode)) { New-CleanupRestorePoint | Out-Null }

    if ($selection | Where-Object { $_.Category -eq 'Browsers' }) { Stop-BrowserProcesses }

    $order = 'Browsers','DevTools','Apps','Games','System','Disks','Logs','Updates','Optimization'
    foreach ($cat in $order) {
        foreach ($task in ($selection | Where-Object { $_.Category -eq $cat })) {
            Invoke-CleanupTask -Task $task
        }
    }

    Show-CleanupSummary
    Write-CleanupReport
}

# =====================================================================
# ENTRY POINT
# =====================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ($Help)      { Show-UsageHelp; exit 0 }
    if ($ListTasks) { Show-TaskList;  exit 0 }
    Start-WindowsCleanup
}
