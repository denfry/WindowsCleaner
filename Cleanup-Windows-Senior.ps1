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
    point (WMI SystemRestore) is created by default unless -NoRestorePoint.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.3.0
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

    # Skip the real System Restore point that is otherwise created first
    [Alias('nrp')]
    [switch]$NoRestorePoint,

    # Skip the slow Optimization category (SFC / DISM)
    [Alias('so')]
    [switch]$SkipOptimization,

    # Only delete files older than N days (0 = no age filter). Per-task minimums still apply.
    [int]$MaxAgeDays = 0,

    # Files that are locked/in use are scheduled for deletion at next reboot
    # (MoveFileEx MOVEFILE_DELAY_UNTIL_REBOOT) instead of being counted as errors.
    [Alias('dl')]
    [switch]$DeferLocked,

    # Close running browsers (current session only) instead of skipping their cache
    # tasks. Interactive runs close by default; -Unattended runs only with this switch.
    [switch]$CloseApps,

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
$script:TotalDeferred   = 0
$script:RestorePointMade = $false

# -DryRun is a friendly alias for -WhatIf. Setting the preference here makes it
# flow into every ShouldProcess call below (and into nested helper functions).
if ($DryRun) { $WhatIfPreference = $true }

# Callers that go through -File (desktop app, scheduler) pass 'a,b,c' as ONE string;
# split it so -Include/-Exclude match task ids either way.
$Include = @($Include | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Exclude = @($Exclude | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Drives  = @($Drives  | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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

# Files the engine itself is writing (its log, the report, the desktop app's
# output capture) live in %TEMP% - never delete them out from under the run.
$script:KeepPaths = @($LogPath, $ReportPath) | Where-Object { $_ } |
    ForEach-Object { [IO.Path]::GetFullPath($_).ToLowerInvariant() }
$script:KeepNamePatterns = @('winsenior-*', 'WindowsCleanup.log', 'WindowsOptimize.log', 'WindowsRepair.log')

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

# Junctions / symlinks (and cloud placeholders) are reparse points. Enumerating one
# by its own path walks the TARGET, so size accounting and delete-on-reboot must
# treat it as a zero-byte link and never recurse into it.
function Test-ReparsePoint {
    param([System.IO.FileSystemInfo]$Item)
    [bool]($Item -and ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint))
}

# Size + file count in a single enumeration (the old pair walked every folder twice).
function Measure-FsItem {
    param([System.IO.FileSystemInfo]$Item)
    if (-not $Item) { return [pscustomobject]@{ Bytes = [int64]0; Files = 0 } }
    if (Test-ReparsePoint $Item) { return [pscustomobject]@{ Bytes = [int64]0; Files = 1 } }
    if (-not $Item.PSIsContainer) { return [pscustomobject]@{ Bytes = [int64]$Item.Length; Files = 1 } }
    $m = Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
         Measure-Object -Property Length -Sum
    [pscustomobject]@{ Bytes = [int64]$(if ($m.Sum) { $m.Sum } else { 0 }); Files = [int]$m.Count }
}

# Sum of file bytes under a set of literal roots (used by tool-driven tasks that
# measure before/after instead of deleting item by item).
function Get-PathBytes {
    param([string[]]$Root)
    [int64]$sum = 0
    foreach ($r in $Root) {
        $it = Get-Item -LiteralPath $r -Force -ErrorAction SilentlyContinue
        if ($it) { $sum += (Measure-FsItem $it).Bytes }
    }
    $sum
}

function Test-KeepItem {
    param([string]$FullPath, [string]$Name, [string[]]$ExcludePattern)
    if ($script:KeepPaths -contains $FullPath.ToLowerInvariant()) { return $true }
    foreach ($p in (@($script:KeepNamePatterns) + @($ExcludePattern))) {
        if ($p -and ($Name -like $p)) { return $true }
    }
    $false
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
    # ProfileList is authoritative (profiles moved off C:\Users, AzureAD S-1-12-1-*);
    # the C:\Users scan catches anything the registry misses.
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[object]
    $keys = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-[\d-]+$' }
    foreach ($k in $keys) {
        $p = (Get-ItemProperty -LiteralPath $k.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $p) { continue }
        $p = [Environment]::ExpandEnvironmentVariables($p).TrimEnd('\')
        if ((Test-Path -LiteralPath $p -PathType Container) -and -not $seen[$p.ToLowerInvariant()]) {
            $seen[$p.ToLowerInvariant()] = $true
            $out.Add([pscustomobject]@{ Name = (Split-Path $p -Leaf); FullName = $p })
        }
    }
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') -and -not $seen[$_.FullName.ToLowerInvariant()] } |
        ForEach-Object { $out.Add([pscustomobject]@{ Name = $_.Name; FullName = $_.FullName }) }
    $out
}

# Steam install roots (registry first, default path as fallback) and every
# library folder listed in libraryfolders.vdf - games live on other disks too.
function Get-SteamRoots {
    $r = foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        (Get-ItemProperty -Path $k -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    }
    @(@($r) + "${env:ProgramFiles(x86)}\Steam" | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique)
}

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    foreach ($root in (Get-SteamRoots)) {
        $libs.Add($root)
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue), '"path"\s+"([^"]+)"')) {
            $libs.Add($m.Groups[1].Value.Replace('\\', '\').TrimEnd('\'))
        }
    }
    @($libs | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)
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

# Tokens: <USER> every profile, <DRIVE> every local disk ('C:\'), <STEAM> Steam
# install roots, <STEAMLIB> every Steam library, <SID> the Recycle Bin owner
# folder pattern (current user's SID under -CurrentUserOnly, else all users).
function Expand-TaskPath {
    param([string[]]$Raw)
    $out = New-Object System.Collections.Generic.List[string]
    $tokens = [ordered]@{
        '<USER>'     = { Get-UserProfiles | ForEach-Object { $_.FullName } }
        '<DRIVE>'    = { Get-LocalDrives }
        '<STEAMLIB>' = { Get-SteamLibraries }
        '<STEAM>'    = { Get-SteamRoots }
        '<SID>'      = {
            if ($CurrentUserOnly) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } else { 'S-1-*' }
        }
    }
    foreach ($entry in $Raw) {
        $cands = @([Environment]::ExpandEnvironmentVariables($entry))
        foreach ($t in $tokens.Keys) {
            if (-not ($cands | Where-Object { $_.Contains($t) })) { continue }
            $values = @(& $tokens[$t])
            $cands = @(foreach ($c in $cands) {
                if ($c.Contains($t)) { foreach ($v in $values) { $c.Replace($t, $v) } } else { $c }
            })
        }
        foreach ($c in $cands) { $out.Add($c) }
    }
    $out
}

function Test-UpdateRebootPending {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

# =====================================================================
# CORE: LOCKED-FILE HANDLING (delete-on-reboot via MoveFileEx)
# =====================================================================
function Initialize-DeferredDelete {
    if ('WinSenior.Native' -as [type]) { return }
    Add-Type -Namespace WinSenior -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@ -ErrorAction SilentlyContinue
}

# Schedule a locked file (or every file under a locked folder) for deletion at
# the next reboot. Returns the number of entries queued.
function Register-DeferredDelete {
    param([string]$FullPath)
    Initialize-DeferredDelete
    if (-not ('WinSenior.Native' -as [type])) { return 0 }
    $queued = 0
    $self = Get-Item -LiteralPath $FullPath -Force -ErrorAction SilentlyContinue
    $targets = if (Test-ReparsePoint $self) { @($FullPath) }   # queue the link, never its target
    elseif (Test-Path -LiteralPath $FullPath -PathType Container) {
        # Files first (deepest first), then the directories themselves.
        @(Get-ChildItem -LiteralPath $FullPath -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { $_.FullName }) + @($FullPath)
    } else { @($FullPath) }
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }   # already gone
        if ([WinSenior.Native]::MoveFileEx($t, $null, 4)) { $queued++ }   # 4 = MOVEFILE_DELAY_UNTIL_REBOOT
    }
    $queued
}

# After an age-filtered pass, remove sub-folders that were left empty.
function Remove-EmptyDirectory {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return 0 }
    $removed = 0
    $dirs = Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-ReparsePoint $_) } |
            Sort-Object { $_.FullName.Length } -Descending
    foreach ($d in $dirs) {
        if (-not (Test-SafeToDelete $d.FullName)) { continue }
        $any = Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $any) {
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $d.FullName)) { $removed++ }
        }
    }
    $removed
}

# =====================================================================
# CORE: PATH CLEANUP (honest accounting + real ShouldProcess)
# =====================================================================
function Invoke-PathCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Path,
        [int]$AgeDays = 0,
        [string]$Description = 'items',
        # Leaf-name wildcards to keep (e.g. Prefetch\Layout.ini, Quick Access pins)
        [string[]]$ExcludePattern
    )

    $files = 0; [int64]$bytes = 0; $errors = 0; $deferred = 0
    $cutoff = if ($AgeDays -gt 0) { (Get-Date).AddDays(-$AgeDays) } else { $null }

    foreach ($spec in $Path) {
        # A bare directory path (no wildcard) means "empty this directory".
        $wild = $spec -match '[\*\?]'
        $container = if ($wild) { Split-Path $spec -Parent } else { $spec }

        # (Test-Path with a wildcard skips hidden folders such as $Recycle.Bin, so a
        # wildcard spec goes straight to Get-ChildItem -Force, which is empty if absent.)
        if ($wild) {
            # 5.1 still writes access-denied globbing errors to stderr despite SilentlyContinue
            try { $items = Get-ChildItem -Path $spec -Force -ErrorAction SilentlyContinue 2>$null } catch { $items = @() }
        }
        elseif (-not (Test-Path -LiteralPath $spec)) { continue }
        else {
            $root = Get-Item -LiteralPath $spec -Force -ErrorAction SilentlyContinue
            if (Test-ReparsePoint $root) {
                Write-CleanupLog "refusing to empty a linked folder: $spec" 'Warning'; continue
            }
            $items = Get-ChildItem -LiteralPath $spec -Force -ErrorAction SilentlyContinue
        }

        # Age filter works on FILES: a folder's own timestamp does not change when
        # something deep inside it does, so filtering folders would delete fresh data.
        if ($cutoff) {
            $items = foreach ($it in $items) {
                if ($it.PSIsContainer -and -not (Test-ReparsePoint $it)) {
                    Get-ChildItem -LiteralPath $it.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $cutoff }
                }
                elseif ($it.LastWriteTime -lt $cutoff) { $it }
            }
        }

        foreach ($item in $items) {
            $full = $item.FullName
            if (Test-KeepItem -FullPath $full -Name $item.Name -ExcludePattern $ExcludePattern) { continue }
            if (-not (Test-SafeToDelete $full)) {
                Write-CleanupLog "refusing unsafe path: $full" 'Warning'
                continue
            }
            $isLink = Test-ReparsePoint $item
            $m      = Measure-FsItem $item
            $size   = $m.Bytes
            $count  = $m.Files

            if ($PSCmdlet.ShouldProcess($full, "Remove ($Description)")) {
                try {
                    if ($isLink) {
                        # Remove the link itself; the target it points to is untouched.
                        if ($item.PSIsContainer) { [System.IO.Directory]::Delete($full, $false) }
                        else { [System.IO.File]::Delete($full) }
                    }
                    else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
                    if (-not (Test-Path -LiteralPath $full)) { $files += $count; $bytes += $size }
                }
                catch {
                    # Partial success inside a folder still counts: measure what is left.
                    if (Test-Path -LiteralPath $full) {
                        $left = (Measure-FsItem (Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue)).Bytes
                        if ($left -lt $size) { $bytes += ($size - $left) }
                        if ($DeferLocked -and (Register-DeferredDelete $full) -gt 0) {
                            $deferred++
                            Write-CleanupLog "  deferred to reboot: $full" 'Debug'
                            continue
                        }
                    }
                    $errors++
                    Write-CleanupLog "  $full : $($_.Exception.Message)" 'Debug'
                }
            }
            elseif (Test-WhatIfMode) {
                # -WhatIf: count what would be freed (ShouldProcess already printed the preview)
                $files += $count; $bytes += $size
            }
        }

        # Age-filtered passes leave empty folder skeletons behind - tidy them.
        if ($cutoff -and -not (Test-WhatIfMode)) {
            $roots = if ($wild) { Get-Item -Path $container -Force -ErrorAction SilentlyContinue }
                     else { Get-Item -LiteralPath $container -Force -ErrorAction SilentlyContinue }
            foreach ($c in @($roots | Where-Object { $_.PSIsContainer -and -not (Test-ReparsePoint $_) })) {
                [void](Remove-EmptyDirectory -Root $c.FullName)
            }
        }
    }

    [pscustomobject]@{ Files = $files; Bytes = $bytes; Errors = $errors; Deferred = $deferred }
}

# Stop a set of services, run a body, then restart whatever was running.
# Stop-Service -Force also stops running DEPENDENTS (cryptsvc -> AppIDSvc, WSearch ->
# WMPNetworkSvc ...), so those are restarted too. If a service refuses to stop the
# body is skipped: deleting a live service's database is how caches get corrupted.
function Use-StoppedService {
    param([string[]]$Name, [scriptblock]$Body)
    $restart = New-Object System.Collections.Generic.List[string]
    $blocked = $null
    if (-not (Test-WhatIfMode)) {
        foreach ($n in $Name) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -ne 'Running') { continue }
            $deps = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
            Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
            try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) } catch { Write-Verbose "wait $n" }
            $svc.Refresh()
            if (-not $restart.Contains($n)) { $restart.Add($n) }
            foreach ($d in $deps) { if (-not $restart.Contains($d)) { $restart.Add($d) } }
            if ($svc.Status -ne 'Stopped') { $blocked = $n; break }
        }
    }
    try {
        if ($blocked) {
            Write-CleanupLog "  service '$blocked' did not stop - skipped to avoid corrupting its data" 'Warning'
            [pscustomobject]@{ Files = 0; Bytes = [int64]0; Errors = 1; Deferred = 0 }
        }
        else { & $Body }
    }
    finally {
        foreach ($n in $restart) { Start-Service -Name $n -ErrorAction SilentlyContinue }
    }
}

# Run a native command unless in WhatIf mode. Native tools never throw, so the exit
# code decides: 0 = ok, 3010 = ok + reboot needed, anything else = failure.
function Invoke-NativeStep {
    param([string]$Caption, [scriptblock]$Body)
    if (Test-WhatIfMode) {
        Write-CleanupLog "[WhatIf] would run: $Caption" 'WhatIf'
        return $true
    }
    try {
        $global:LASTEXITCODE = 0
        & $Body
        $code = [int]$global:LASTEXITCODE
        if ($code -ne 0 -and $code -ne 3010) { throw ("exit code {0} (0x{1:X8})" -f $code, $code) }
        $note = if ($code -eq 3010) { ' (reboot required to finish)' } else { '' }
        Write-CleanupLog "$Caption$note" 'Success'; return $true
    }
    catch { Write-CleanupLog "$Caption failed: $($_.Exception.Message)" 'Error'; return $false }
}

# Browsers / apps that hold a task's files open. Returns $true when the task must be
# skipped. Interactive runs (or -CloseApps) close browsers in THIS session only -
# never another user's session and never from a silent scheduled run.
function Test-TaskBlocked {
    param([object]$Task)
    if (-not $Task.Processes -or (Test-WhatIfMode)) { return $false }
    $running = @(Get-Process -Name $Task.Processes -ErrorAction SilentlyContinue)
    if (-not $running) { return $false }
    $mayClose = ($Task.Category -eq 'Browsers') -and ($CloseApps -or -not $Unattended)
    if ($mayClose) {
        $session = (Get-Process -Id $PID).SessionId
        $mine = @($running | Where-Object { $_.SessionId -eq $session })
        if ($mine) {
            $mine | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 1500
            Write-CleanupLog "  closed $($mine.Count) $($Task.Processes -join '/') process(es)" 'Debug'
        }
        $running = @(Get-Process -Name $Task.Processes -ErrorAction SilentlyContinue)
        if (-not $running) { return $false }
    }
    $names = ($running | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '
    $hint  = if ($Task.Category -eq 'Browsers') { ' (close it, or use -CloseApps)' } else { ' (close it and re-run)' }
    Write-CleanupLog "  skipped: $names is running$hint" 'Warning'
    $true
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

# =====================================================================
# TASK REGISTRY  (the single source of truth)
#   -Processes    process names that lock the task's files (skip / close first)
#   -Exclude      leaf-name wildcards to keep inside the task's paths
#   -SkipIf       scriptblock; a non-empty string return = skip with that reason
# =====================================================================
function New-CleanupTask {
    param(
        [string]$Id, [string]$Name, [string]$Category, [string]$Risk,
        [bool]$DefaultOn = $true, [int]$AgeDays = 0,
        [string[]]$Paths, [scriptblock]$Action, [string[]]$StopServices,
        [string[]]$Processes, [string[]]$Exclude, [scriptblock]$SkipIf
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Category = $Category; Risk = $Risk
        DefaultOn = $DefaultOn; AgeDays = $AgeDays
        Paths = $Paths; Action = $Action; StopServices = $StopServices
        Processes = $Processes; Exclude = $Exclude; SkipIf = $SkipIf
    }
}

function Get-CleanupTaskRegistry {
    @(
        # ---------------- Browsers (Safe) ----------------
        # Chromium keeps per-profile caches under User Data\<profile>\ and browser-wide
        # shader / component / crash caches directly under User Data\.
        New-CleanupTask chrome 'Chrome cache' Browsers Safe -Processes chrome -Paths @(
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Cache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\DawnGraphiteCache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\DawnWebGPUCache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Service Worker\CacheStorage\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\GrShaderCache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\ShaderCache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\GraphiteDawnCache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\component_crx_cache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\Crashpad\reports\*')
        New-CleanupTask edge 'Edge cache' Browsers Safe -Processes msedge -Paths @(
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Cache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\DawnGraphiteCache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\DawnWebGPUCache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Service Worker\CacheStorage\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\GrShaderCache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\ShaderCache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\GraphiteDawnCache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\component_crx_cache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\Crashpad\reports\*')
        New-CleanupTask firefox 'Firefox cache' Browsers Safe -Processes firefox -Paths @(
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\cache2\*',
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\startupCache\*',
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\thumbnails\*',
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\shader-cache\*',
            '<USER>\AppData\Roaming\Mozilla\Firefox\Crash Reports\pending\*')
        New-CleanupTask opera 'Opera cache' Browsers Safe -Processes opera -Paths @(
            '<USER>\AppData\Roaming\Opera Software\Opera Stable\Cache\*',
            '<USER>\AppData\Roaming\Opera Software\Opera Stable\GPUCache\*',
            '<USER>\AppData\Roaming\Opera Software\Opera Stable\Code Cache\*',
            '<USER>\AppData\Local\Opera Software\Opera Stable\Cache\*',
            '<USER>\AppData\Roaming\Opera Software\Opera GX Stable\Cache\*',
            '<USER>\AppData\Roaming\Opera Software\Opera GX Stable\GPUCache\*',
            '<USER>\AppData\Local\Opera Software\Opera GX Stable\Cache\*')
        New-CleanupTask yandex 'Yandex cache' Browsers Safe -Processes browser -Paths @(
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\*\Cache\*',
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\GrShaderCache\*',
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\ShaderCache\*')
        New-CleanupTask brave 'Brave cache' Browsers Safe -Processes brave -Paths @(
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Cache\*',
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\GrShaderCache\*',
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\ShaderCache\*',
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\component_crx_cache\*')
        New-CleanupTask vivaldi 'Vivaldi cache' Browsers Safe -Processes vivaldi -Paths @(
            '<USER>\AppData\Local\Vivaldi\User Data\*\Cache\*',
            '<USER>\AppData\Local\Vivaldi\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\Vivaldi\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\Vivaldi\User Data\GrShaderCache\*',
            '<USER>\AppData\Local\Vivaldi\User Data\ShaderCache\*')
        # Chrome's on-device Gemini Nano model (~4 GB). Chrome downloads it again unless
        # the optimizer's priv-chrome-ai policy is applied, so it is opt-in here.
        New-CleanupTask chrome-ai-model 'Chrome on-device AI model (Gemini Nano, ~4 GB)' Browsers Aggressive -DefaultOn $false -Processes chrome -Paths @(
            '<USER>\AppData\Local\Google\Chrome\User Data\OptGuideOnDeviceModel\*')

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
        New-CleanupTask vs 'Visual Studio component & IntelliSense caches' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\VisualStudio\*\ComponentModelCache\*',
            '<USER>\AppData\Local\Microsoft\VSApplicationInsights\*',
            '<USER>\AppData\Local\Microsoft\VSCommon\*\SQM\*',
            '<USER>\AppData\Local\Temp\VSFeedbackIntelliCodeLogs\*',
            '<USER>\AppData\Local\Temp\VSRemoteControl\*',
            '<USER>\AppData\Local\Microsoft\Team Foundation\*\Cache\*')
        New-CleanupTask python-tools 'Python tool caches (uv / poetry / pipx / pyenv)' DevTools Safe -Paths @(
            '<USER>\AppData\Local\uv\cache\*',
            '<USER>\AppData\Local\pypoetry\Cache\*',
            '<USER>\.cache\pypoetry\*',
            '<USER>\AppData\Local\pipx\.cache\*',
            '<USER>\.pyenv\pyenv-win\install_cache\*')
        New-CleanupTask java-tools 'JVM build caches (Maven/Gradle wrapper dists, sbt boot, kotlin daemon)' DevTools Safe -Paths @(
            '<USER>\.m2\wrapper\dists\*',
            '<USER>\.gradle\daemon\*\*.log',
            '<USER>\.gradle\wrapper\dists\*\*\*.zip',
            '<USER>\.sbt\boot\*',
            '<USER>\AppData\Local\kotlin\daemon\*')
        New-CleanupTask dotnet-tools '.NET SDK temp & telemetry caches' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Temp\.net\*',
            '<USER>\.dotnet\TelemetryStorageService\*',
            '<USER>\.dotnet\sdk-advertising\*')
        New-CleanupTask node-tools 'Node toolchain caches (node-gyp / electron / bun / deno / Cypress)' DevTools Safe -Paths @(
            '<USER>\AppData\Local\node-gyp\Cache\*',
            '<USER>\AppData\Local\electron\Cache\*',
            '<USER>\AppData\Local\electron-builder\Cache\*',
            '<USER>\.bun\install\cache\*',
            '<USER>\AppData\Local\deno\deps\*',
            '<USER>\AppData\Local\deno\npm\*',
            '<USER>\AppData\Local\Cypress\Cache\*')
        New-CleanupTask git-tools 'GitHub Desktop logs & cache' DevTools Safe -Paths @(
            '<USER>\AppData\Roaming\GitHub Desktop\logs\*',
            '<USER>\AppData\Roaming\GitHub Desktop\Cache\*',
            '<USER>\AppData\Roaming\GitHub Desktop\GPUCache\*')
        New-CleanupTask composer-php 'PHP Composer cache' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Composer\files\*',
            '<USER>\AppData\Local\Composer\repo\*')
        New-CleanupTask ml-caches 'ML model & browser-automation caches (HuggingFace / torch / Playwright / Puppeteer)' DevTools Moderate -DefaultOn $false -Paths @(
            '<USER>\.cache\huggingface\hub\*',
            '<USER>\.cache\torch\hub\*',
            '<USER>\.cache\ms-playwright\*',
            '<USER>\AppData\Local\ms-playwright\*',
            '<USER>\.cache\puppeteer\*')
        # The global NuGet package folder is re-downloaded on the next restore; opt-in
        # because it breaks offline builds until then.
        New-CleanupTask nuget-global 'NuGet global packages folder (re-downloaded on restore)' DevTools Aggressive -DefaultOn $false -Paths @(
            '<USER>\.nuget\packages\*')
        New-CleanupTask docker-logs 'Docker Desktop / WSL logs & caches' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Docker\log\*',
            '<USER>\AppData\Roaming\Docker Desktop\Cache\*',
            '<USER>\AppData\Roaming\Docker Desktop\GPUCache\*',
            '<USER>\AppData\Local\Temp\wsl-*')

        # ---------------- Apps / messengers (Safe) ----------------
        New-CleanupTask appcache 'Windows app cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\AppCache\*',
            '<USER>\AppData\Local\ConnectedDevicesPlatform\*',
            '<USER>\AppData\Local\Packages\*\AC\INetCache\*',
            '<USER>\AppData\Local\Packages\*\AC\Temp\*')
        New-CleanupTask teams 'Microsoft Teams cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Microsoft\Teams\Cache\*',
            '<USER>\AppData\Roaming\Microsoft\Teams\GPUCache\*',
            '<USER>\AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage\*')
        # New Teams (MSTeams package): Microsoft's documented cache reset empties the whole
        # LocalCache\Microsoft\MSTeams folder. Only safe while Teams is closed.
        New-CleanupTask teams-new 'New Microsoft Teams cache' Apps Moderate -Processes ms-teams -Paths @(
            '<USER>\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\*')
        # WebView2 hosts (new Outlook, Widgets, Copilot, Teams, many desktop apps): only the
        # Chromium cache folders inside each EBWebView profile, never cookies/storage.
        New-CleanupTask webview2 'WebView2 app caches (new Outlook, Widgets, Copilot, ...)' Apps Moderate -Processes olk -Paths @(
            '<USER>\AppData\Local\*\EBWebView\*\Cache\*',
            '<USER>\AppData\Local\*\EBWebView\*\Code Cache\*',
            '<USER>\AppData\Local\*\EBWebView\*\GPUCache\*',
            '<USER>\AppData\Local\*\*\EBWebView\*\Cache\*',
            '<USER>\AppData\Local\*\*\EBWebView\*\Code Cache\*',
            '<USER>\AppData\Local\*\*\EBWebView\*\GPUCache\*',
            '<USER>\AppData\Local\Packages\*\LocalState\EBWebView\*\Cache\*',
            '<USER>\AppData\Local\Packages\*\LocalState\EBWebView\*\Code Cache\*',
            '<USER>\AppData\Local\Microsoft\Olk\logs\*')
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
        # Click-to-Run keeps every downloaded update payload; stale ones are never reused.
        New-CleanupTask office-c2r 'Office Click-to-Run update downloads (>7 days)' Apps Moderate -AgeDays 7 -Paths @(
            '%ProgramFiles%\Microsoft Office\Updates\Download\PackageFiles\*',
            '%ProgramFiles(x86)%\Microsoft Office\Updates\Download\PackageFiles\*')
        New-CleanupTask onedrive 'OneDrive logs' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\OneDrive\logs\*',
            '<USER>\AppData\Local\Microsoft\OneDrive\setup\logs\*')
        New-CleanupTask adobe-media 'Adobe media & Camera Raw cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Adobe\Common\Media Cache\*',
            '<USER>\AppData\Roaming\Adobe\Common\Media Cache Files\*',
            '<USER>\AppData\Local\Adobe\CameraRaw\Cache\*')
        New-CleanupTask rdp-cache 'Remote Desktop client bitmap cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Terminal Server Client\Cache\*')
        New-CleanupTask telegram 'Telegram Desktop media cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Telegram Desktop\tdata\user_data\cache\*',
            '<USER>\AppData\Roaming\Telegram Desktop\tdata\user_data\media_cache\*',
            '<USER>\AppData\Roaming\Telegram Desktop\tdata\emoji\*',
            '<USER>\AppData\Local\Packages\TelegramMessengerLLP.TelegramDesktop_*\LocalCache\Roaming\Telegram Desktop UWP\tdata\user_data\cache\*')
        New-CleanupTask whatsapp 'WhatsApp Desktop cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Packages\5319275A.WhatsAppDesktop_*\LocalCache\*',
            '<USER>\AppData\Roaming\WhatsApp\Cache\*',
            '<USER>\AppData\Roaming\WhatsApp\Code Cache\*',
            '<USER>\AppData\Roaming\WhatsApp\GPUCache\*')
        New-CleanupTask messengers 'Zoom / Skype / Signal / Viber caches & logs' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Zoom\logs\*',
            '<USER>\AppData\Roaming\Zoom\data\Cache\*',
            '<USER>\AppData\Roaming\Microsoft\Skype for Desktop\Cache\*',
            '<USER>\AppData\Roaming\Microsoft\Skype for Desktop\Code Cache\*',
            '<USER>\AppData\Roaming\Microsoft\Skype for Desktop\logs\*',
            '<USER>\AppData\Roaming\Signal\logs\*',
            '<USER>\AppData\Roaming\Signal\Cache\*',
            '<USER>\AppData\Roaming\ViberPC\*\Cache\*')
        # Moderate: catches every Chromium/Electron app, not just the ones listed by name.
        New-CleanupTask electron-generic 'Generic Electron/Chromium app caches (any app in AppData)' Apps Moderate -Paths @(
            '<USER>\AppData\Roaming\*\Cache\*',
            '<USER>\AppData\Roaming\*\Code Cache\*',
            '<USER>\AppData\Roaming\*\GPUCache\*',
            '<USER>\AppData\Roaming\*\DawnCache\*',
            '<USER>\AppData\Roaming\*\DawnGraphiteCache\*',
            '<USER>\AppData\Roaming\*\DawnWebGPUCache\*',
            '<USER>\AppData\Roaming\*\Service Worker\CacheStorage\*',
            '<USER>\AppData\Local\*\GPUCache\*',
            '<USER>\AppData\Local\*\DawnCache\*')
        New-CleanupTask media-players 'Media player caches (VLC / iTunes / Windows Media Player / Plex)' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\vlc\art\*',
            '<USER>\AppData\Local\Microsoft\Media Player\Art Cache\*',
            '<USER>\AppData\Local\Microsoft\Media Player\Transcoded Files Cache\*',
            '<USER>\AppData\Local\Plex Media Server\Cache\*',
            '<USER>\AppData\Local\Plex\Cache\*')
        New-CleanupTask uwp-caches 'Store app (UWP) temp state & local caches' Apps Safe -Paths @(
            '<USER>\AppData\Local\Packages\*\TempState\*',
            '<USER>\AppData\Local\Packages\*\LocalCache\Local\Microsoft\Windows\INetCache\*',
            '<USER>\AppData\Local\Packages\*\AC\Microsoft\Internet Explorer\DOMStore\*',
            '<USER>\AppData\Local\Packages\Microsoft.Windows.Photos_*\LocalState\PhotosAppCache\*',
            '<USER>\AppData\Local\Packages\Microsoft.WindowsStore_*\LocalCache\*',
            '<USER>\AppData\Local\Packages\Microsoft.Windows.ContentDeliveryManager_*\LocalCache\*')
        New-CleanupTask notifications 'Notification image cache & Explorer side caches' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\Notifications\wpnidm\*',
            '<USER>\AppData\Local\Microsoft\Windows\Caches\*',
            '<USER>\AppData\Local\Microsoft\Windows\SchCache\*',
            '<USER>\AppData\Local\Microsoft\Windows\WebCache.old\*')
        New-CleanupTask gpu-apps 'GPU vendor app caches & telemetry (NVIDIA App / GeForce Experience / AMD / Intel)' Apps Safe -Paths @(
            '<USER>\AppData\Local\NVIDIA Corporation\NVIDIA App\CefCache\*',
            '<USER>\AppData\Local\NVIDIA Corporation\NVIDIA GeForce Experience\CefCache\*',
            '<USER>\AppData\Local\NVIDIA Corporation\NvTelemetry\*',
            '%ProgramData%\NVIDIA Corporation\NvTelemetry\*',
            '%ProgramData%\NVIDIA Corporation\Downloader\*',
            '<USER>\AppData\Local\AMD\CN\Cache\*',
            '<USER>\AppData\Local\AMD\DxCache\*',
            '<USER>\AppData\Local\AMD\GLCache\*',
            '<USER>\AppData\Local\AMD\VkCache\*',
            '<USER>\AppData\Local\Intel\ShaderCache\*')

        # ---------------- Games (launcher caches, Safe) ----------------
        New-CleanupTask game-caches 'Game launcher caches (Steam/Epic/Battle.net/GOG)' Games Safe -Paths @(
            '<STEAM>\appcache\httpcache\*',
            '<STEAM>\config\htmlcache\*',
            '<USER>\AppData\Local\Steam\htmlcache\*',
            '<USER>\AppData\Local\EpicGamesLauncher\Saved\webcache\*',
            '<USER>\AppData\Local\EpicGamesLauncher\Saved\webcache_*\*',
            '<USER>\AppData\Local\Battle.net\Cache\*',
            '%ProgramData%\Battle.net\Agent\data\cache\*',
            '<USER>\AppData\Local\GOG.com\Galaxy\webcache\*')
        New-CleanupTask game-logs 'Game launcher logs & crash dumps (Steam/Epic/EA/Ubisoft/Riot/Xbox)' Games Safe -Paths @(
            '<STEAM>\logs\*',
            '<STEAM>\dumps\*',
            '<USER>\AppData\Local\EpicGamesLauncher\Saved\Logs\*',
            '<USER>\AppData\Local\EpicGamesLauncher\Saved\Crashes\*',
            '<USER>\AppData\Local\Electronic Arts\EA Desktop\Logs\*',
            '<USER>\AppData\Local\Electronic Arts\EA Desktop\cache\*',
            '<USER>\AppData\Local\Ubisoft Game Launcher\logs\*',
            '<USER>\AppData\Local\Ubisoft Game Launcher\cache\*',
            '<USER>\AppData\Local\Riot Games\Riot Client\Logs\*',
            '%ProgramData%\Riot Games\Logs\*',
            '<USER>\AppData\Local\Packages\Microsoft.GamingApp_*\LocalCache\*',
            '<USER>\AppData\Local\Packages\Microsoft.XboxGamingOverlay_*\TempState\*')
        New-CleanupTask game-engines 'Game engine caches (Unreal DDC / Unity / Godot)' Games Moderate -Paths @(
            '<USER>\AppData\Local\UnrealEngine\Common\DerivedDataCache\*',
            '<USER>\AppData\Local\UnrealEngine\*\Saved\Logs\*',
            '<USER>\AppData\Local\UnrealEngine\*\Saved\Crashes\*',
            '<USER>\AppData\Local\Unity\cache\*',
            '<USER>\AppData\LocalLow\Unity\Caches\*',
            '<USER>\AppData\Roaming\Godot\shader_cache\*',
            '<USER>\AppData\Roaming\Godot\logs\*')
        # Aggressive: games recompile shaders on next launch (first-run stutter).
        New-CleanupTask game-shaders 'Per-game shader caches on every disk (Steam libraries / Unity games)' Games Aggressive -Processes steam -Paths @(
            '<STEAMLIB>\steamapps\shadercache\*',
            '<DRIVE>SteamLibrary\steamapps\shadercache\*',
            '<DRIVE>Games\Steam\steamapps\shadercache\*',
            '<DRIVE>Steam\steamapps\shadercache\*',
            '<USER>\AppData\LocalLow\*\*\ShaderCache\*')

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
            '<USER>\AppData\Local\AMD\DxCache\*',
            # Drivers before 571.86 kept these under LocalLow; newer ones moved back to
            # Local, so the LocalLow copy is dead weight.
            '<USER>\AppData\LocalLow\NVIDIA\PerDriverVersion\DXCache\*',
            '<USER>\AppData\LocalLow\NVIDIA\PerDriverVersion\GLCache\*')
        New-CleanupTask win-caches 'Windows per-user app caches' System Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\Caches\*')
        # Installer extraction folders only (C:\NVIDIA\DisplayDriver, C:\AMD\*Software*...),
        # not any folder that happens to be called NVIDIA/AMD on a data disk.
        New-CleanupTask gpu-leftovers 'GPU driver installer leftovers (NVIDIA/AMD)' System Safe -Paths @(
            '%SystemDrive%\NVIDIA\DisplayDriver\*',
            '%SystemDrive%\AMD\*Software*',
            '%SystemDrive%\AMD\*Chipset*',
            '%SystemDrive%\AMD\*Radeon*',
            '%SystemDrive%\AMD\*Driver*',
            '%ProgramData%\NVIDIA Corporation\Downloader\*',
            '%ProgramData%\NVIDIA Corporation\NV_Cache\*')
        New-CleanupTask webcache 'WinINet WebCache database' System Moderate -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\WebCache\*')
        # Microsoft's own cmdlet empties the cache through DoSvc instead of deleting its
        # state files from under the running service. Folder delete is the fallback.
        New-CleanupTask deliveryopt 'Delivery Optimization cache' System Safe -Action {
            $roots = Expand-TaskPath @(
                '%WINDIR%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache',
                '%WINDIR%\SoftwareDistribution\DeliveryOptimization')
            $before = Get-PathBytes $roots
            if (Test-WhatIfMode) {
                Write-CleanupLog "[WhatIf] would clear the Delivery Optimization cache ($(Format-FileSize $before))" 'WhatIf'
                return [pscustomobject]@{ Files = 0; Bytes = $before; Errors = 0 }
            }
            $viaCmdlet = $false
            try {
                if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                    Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                    $viaCmdlet = $true
                }
            } catch { Write-CleanupLog "  Delete-DeliveryOptimizationCache: $($_.Exception.Message)" 'Debug' }
            if (-not $viaCmdlet) {
                $r = Use-StoppedService -Name 'DoSvc' -Body {
                    Invoke-PathCleanup -Path ($roots | ForEach-Object { "$_\*" }) -Description 'Delivery Optimization cache'
                }
                return $r
            }
            $freed = [Math]::Max([int64]0, $before - (Get-PathBytes $roots))
            [pscustomobject]@{ Files = 0; Bytes = $freed; Errors = 0 }
        }
        # Windows 11 (and patched Windows 10) give SYSTEM processes their own temp dir.
        New-CleanupTask systemtemp 'SYSTEM temp folder (Windows\SystemTemp)' System Safe -Paths @(
            '%WINDIR%\SystemTemp\*')
        New-CleanupTask svc-temp 'Service-account temp folders (LocalService / NetworkService / system profile)' System Safe -Paths @(
            '%WINDIR%\ServiceProfiles\LocalService\AppData\Local\Temp\*',
            '%WINDIR%\ServiceProfiles\NetworkService\AppData\Local\Temp\*',
            '%WINDIR%\System32\config\systemprofile\AppData\Local\Temp\*',
            '%WINDIR%\SysWOW64\config\systemprofile\AppData\Local\Temp\*',
            '%WINDIR%\ServiceProfiles\LocalService\AppData\Local\Microsoft\Windows\INetCache\*',
            '%WINDIR%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\INetCache\*',
            '%WINDIR%\System32\config\systemprofile\AppData\Local\Microsoft\Windows\INetCache\*',
            '%SystemDrive%\Users\Default\AppData\Local\Temp\*')
        New-CleanupTask upgrade-logs 'Windows setup / upgrade / servicing logs (Panther, CBS, USO, WindowsUpdate.log)' System Safe -Paths @(
            '%WINDIR%\Panther\*.log',
            '%WINDIR%\Panther\*.xml',
            '%WINDIR%\Panther\UnattendGC\*',
            '%WINDIR%\Logs\CBS\*.log',
            '%WINDIR%\Logs\CBS\*.cab',
            '%WINDIR%\Logs\MoSetup\*',
            '%WINDIR%\Logs\WindowsUpdate\*',
            '%WINDIR%\Logs\NetSetup\*',
            '%WINDIR%\Logs\waasmedic\*',
            '%WINDIR%\Logs\SIH\*',
            '%ProgramData%\USOShared\Logs\*',
            '%WINDIR%\WindowsUpdate.log',
            '%WINDIR%\setupact.log',
            '%WINDIR%\setuperr.log',
            '%WINDIR%\PFRO.log')
        # Defender's own folders are deliberately NOT here: tamper protection blocks the
        # deletes (and can raise tamper alerts), and wiping scan caches forces rescans.
        New-CleanupTask win-misc 'Windows misc caches (Offline Web Pages, Search temp, PerfLogs)' System Safe -Paths @(
            '%WINDIR%\Offline Web Pages\*',
            '%ProgramData%\Microsoft\Windows\Caches\*',
            '%ProgramData%\Microsoft\Search\Data\Temp\*',
            '%SystemDrive%\PerfLogs\*')
        # Resets the whole BITS queue (cancels every job: Windows Update, Defender, Intune),
        # so it is a troubleshooting step, opt-in. The ESE database is removed as a set -
        # leaving edb*.log / edb.chk behind half-deletes it.
        New-CleanupTask bits-cache 'Reset BITS transfer queue (cancels all background downloads)' System Moderate -DefaultOn $false -StopServices @('BITS') -Paths @(
            '%ProgramData%\Microsoft\Network\Downloader\*.tmp',
            '%ProgramData%\Microsoft\Network\Downloader\qmgr*.dat',
            '%ProgramData%\Microsoft\Network\Downloader\qmgr.db',
            '%ProgramData%\Microsoft\Network\Downloader\qmgr.jfm',
            '%ProgramData%\Microsoft\Network\Downloader\edb*.log',
            '%ProgramData%\Microsoft\Network\Downloader\edb*.jrs',
            '%ProgramData%\Microsoft\Network\Downloader\edb.chk')
        New-CleanupTask dns-flush 'Flush DNS resolver, ARP & NetBIOS caches' System Safe -Action {
            Invoke-NativeStep 'ipconfig /flushdns' { & ipconfig.exe /flushdns *>$null } | Out-Null
            Invoke-NativeStep 'arp -d *'           { & arp.exe -d * *>$null } | Out-Null
            Invoke-NativeStep 'nbtstat -R'         { & nbtstat.exe -R *>$null } | Out-Null
            $null
        }
        # A repair step rather than cleanup (-i re-provisions the Store), so opt-in.
        New-CleanupTask store-reset 'Reset Microsoft Store cache (WSReset, silent)' System Safe -DefaultOn $false -Action {
            $exe = Join-Path $env:WINDIR 'System32\WSReset.exe'
            if (-not (Test-Path $exe)) { return $null }
            Invoke-NativeStep 'WSReset.exe -i' {
                $p = Start-Process -FilePath $exe -ArgumentList '-i' -WindowStyle Hidden -PassThru
                if (-not $p.WaitForExit(60000)) { $p.Kill() }
            } | Out-Null
            $null
        }
        # Opt-in: emptying every working set makes apps page back in (stutter) and the
        # standby list is Windows' file cache - it refills on its own.
        New-CleanupTask memory-standby 'Purge standby memory list & trim working sets (frees RAM, not disk)' System Safe -DefaultOn $false -Action {
            # Same documented NtSetSystemInformation(SystemMemoryListInformation) call RAMMap uses.
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would purge standby memory list' 'WhatIf'; return $null }
            if (-not ('WinSenior.Memory' -as [type])) {
                Add-Type -Namespace WinSenior -Name Memory -MemberDefinition @'
[DllImport("ntdll.dll")] public static extern int NtSetSystemInformation(int cls, ref int info, int len);
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, int acc, out IntPtr tok);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string s, string n, out long luid);
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKP np, int len, IntPtr prev, IntPtr ret);
[StructLayout(LayoutKind.Sequential)] public struct TOKP { public int Count; public long Luid; public int Attr; }
public static bool Enable(string name) {
    IntPtr tok; if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out tok)) return false;
    TOKP tp; tp.Count = 1; tp.Attr = 2; if (!LookupPrivilegeValue(null, name, out tp.Luid)) return false;
    return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
}
'@ -ErrorAction SilentlyContinue
            }
            if (-not ('WinSenior.Memory' -as [type])) { return $null }
            [void][WinSenior.Memory]::Enable('SeProfileSingleProcessPrivilege')
            [void][WinSenior.Memory]::Enable('SeIncreaseQuotaPrivilege')
            $before = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
            foreach ($cmd in 4, 2) {   # 4 = purge standby list, 2 = empty working sets
                $v = [int]$cmd
                [void][WinSenior.Memory]::NtSetSystemInformation(80, [ref]$v, 4)
            }
            $after = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
            Write-CleanupLog ("  RAM freed: {0}" -f (Format-FileSize ([Math]::Max([int64]0, [int64]($after - $before))))) 'Success'
            $null
        }
        # Recent-item shortcuts only. Jump lists hold the user's PINNED items (and the
        # Quick Access pins file f01b4d95cf55d32a...), so they are a separate opt-in task.
        New-CleanupTask recent 'Recent items list' System Moderate -DefaultOn $true -Paths @(
            '<USER>\AppData\Roaming\Microsoft\Windows\Recent\*.lnk')
        New-CleanupTask jumplists 'Jump lists (unpins jump-list items; Quick Access pins kept)' System Aggressive -DefaultOn $false `
            -Exclude @('f01b4d95cf55d32a*') -Paths @(
            '<USER>\AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\*',
            '<USER>\AppData\Roaming\Microsoft\Windows\Recent\CustomDestinations\*')
        New-CleanupTask fontcache 'Font cache' System Moderate -StopServices @('FontCache') -Paths @(
            '%WINDIR%\ServiceProfiles\LocalService\AppData\Local\FontCache\*')
        New-CleanupTask winlogs 'Windows log files' System Moderate -Paths @('%WINDIR%\Logs\*')
        # Microsoft: clearing Prefetch slows the next boots/app launches while it rebuilds.
        # Kept for privacy-minded users, opt-in; Layout.ini (boot defrag layout) is kept.
        New-CleanupTask prefetch 'Prefetch (slower boot until rebuilt)' System Aggressive -DefaultOn $false -Exclude @('Layout.ini') -Paths @(
            '%WINDIR%\Prefetch\*')
        New-CleanupTask search-index 'Rebuild Windows Search index (deletes Windows.edb, re-indexes in background)' System Aggressive -DefaultOn $false -Action {
            $db = @("$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb",
                    "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.db")
            $existing = @($db | Where-Object { Test-Path -LiteralPath $_ })
            if (-not $existing) { Write-CleanupLog '  no search index database found' 'Debug'; return $null }
            $size = ($existing | ForEach-Object { (Get-Item -LiteralPath $_ -Force).Length } | Measure-Object -Sum).Sum
            if (Test-WhatIfMode) {
                Write-CleanupLog "[WhatIf] would delete search index ($(Format-FileSize $size)) and trigger a rebuild" 'WhatIf'
                return [pscustomobject]@{ Files = $existing.Count; Bytes = $size; Errors = 0 }
            }
            Use-StoppedService -Name 'WSearch' -Body {
                $ok = 0; $err = 0
                foreach ($f in $existing) {
                    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $f) { $err++ } else { $ok++ }
                }
                # SetupCompletedSuccessfully=0 makes the indexer rebuild from scratch on next start.
                Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0 -Type DWord -ErrorAction SilentlyContinue
                [pscustomobject]@{ Files = $ok; Bytes = $(if ($err) { 0 } else { $size }); Errors = $err }
            }
        }
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

            # Group third-party packages by provider + class + original .inf name (inf names
            # alone collide across vendors, e.g. usbser.inf); keep the newest version of
            # each, mark older duplicates. Never touch boot-critical drivers.
            $stale = foreach ($g in ($pkgs | Where-Object { -not $_.BootCritical -and $_.OriginalFileName } |
                        Group-Object { '{0}|{1}|{2}' -f $_.ProviderName, $_.ClassName,
                            [System.IO.Path]::GetFileName([string]$_.OriginalFileName).ToLowerInvariant() })) {
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
        # A 'Temp' folder on a data disk may be someone's working folder: only week-old files.
        New-CleanupTask disk-temp 'Drive-level temp folders (all local disks, >7 days)' Disks Moderate -AgeDays 7 -Paths @(
            '<DRIVE>Temp\*',
            '<DRIVE>tmp\*')
        New-CleanupTask disk-chkdsk 'CHKDSK recovered fragments (FOUND.*)' Disks Safe -Paths @(
            '<DRIVE>FOUND.*\*')

        # ---------------- Logs / dumps ----------------
        New-CleanupTask wer 'Windows Error Reporting' Logs Safe -Paths @(
            '%ProgramData%\Microsoft\Windows\WER\ReportQueue\*',
            '%ProgramData%\Microsoft\Windows\WER\ReportArchive\*',
            '<USER>\AppData\Local\Microsoft\Windows\WER\*')
        New-CleanupTask extra-logs 'Setup & device-install logs' Logs Safe -Paths @(
            '%WINDIR%\Panther\*',
            '%WINDIR%\inf\setupapi.dev*.log',
            '%WINDIR%\inf\setupapi.setup*.log')
        New-CleanupTask livekernel 'Live kernel crash dumps (driver/GPU TDR)' Logs Safe -Paths @(
            '%WINDIR%\LiveKernelReports\*.dmp',
            '%WINDIR%\LiveKernelReports\*\*.dmp')
        New-CleanupTask diag-telemetry 'Diagnostics & telemetry caches (Diagnosis, ETL traces, SleepStudy, WDI)' Logs Moderate -StopServices @('DiagTrack') -Paths @(
            '%ProgramData%\Microsoft\Diagnosis\ETLLogs\*',
            '%ProgramData%\Microsoft\Diagnosis\DownloadedSettings\*',
            '%ProgramData%\Microsoft\Diagnosis\*.rbs',
            '%WINDIR%\System32\LogFiles\WMI\*.etl',
            '%WINDIR%\System32\LogFiles\WMI\RtBackup\*',
            '%WINDIR%\System32\SleepStudy\*.etl',
            '%WINDIR%\System32\WDI\LogFiles\*',
            '%ProgramData%\Microsoft\Windows\Power\*.etl',
            '<USER>\AppData\Local\Microsoft\Windows\PowerShell\CommandAnalysis\*')
        New-CleanupTask app-logs 'Third-party app logs (Adobe, Autodesk, Corsair, Logitech, Razer, Intel, PowerToys, Terminal)' Logs Safe -Paths @(
            '%ProgramData%\Adobe\*\Logs\*',
            '<USER>\AppData\Local\Adobe\*\Logs\*',
            '<USER>\AppData\Roaming\Adobe\*\Logs\*',
            '%ProgramData%\Autodesk\*\Logs\*',
            '<USER>\AppData\Local\Autodesk\*\Logs\*',
            '<USER>\AppData\Roaming\Corsair\CUE\logs\*',
            '<USER>\AppData\Local\LGHUB\logs\*',
            '<USER>\AppData\Local\Razer\Synapse3\Log\*',
            '%ProgramData%\Razer\Synapse3\Logs\*',
            '%ProgramData%\Intel\*\Logs\*',
            '<USER>\AppData\Local\Microsoft\PowerToys\Logs\*',
            '<USER>\AppData\Local\Packages\Microsoft.WindowsTerminal_*\LocalState\*.log',
            '<USER>\AppData\Local\Temp\*.log',
            '<USER>\AppData\Local\Temp\*.etl',
            '<USER>\AppData\Local\Temp\*.dmp')
        New-CleanupTask installer-leftovers 'Installer leftovers (MSI temp, Squirrel/NSIS/Inno temp, Chrome/Edge updater downloads)' Logs Safe -Paths @(
            '%WINDIR%\Installer\*.tmp',
            '<USER>\AppData\Local\SquirrelTemp\*',
            '<USER>\AppData\Local\Temp\nsis*',
            '<USER>\AppData\Local\Temp\7z*',
            '<USER>\AppData\Local\Temp\is-*.tmp',
            '<USER>\AppData\Local\Temp\{*}',
            '<USER>\AppData\Local\Google\Update\Download\*',
            '<USER>\AppData\Local\Google\Update\Install\*',
            '<USER>\AppData\Local\Microsoft\EdgeUpdate\Download\*',
            '<USER>\AppData\Local\Microsoft\EdgeUpdate\Install\*',
            '%ProgramFiles(x86)%\Google\Update\Download\*',
            '%ProgramFiles(x86)%\Microsoft\EdgeUpdate\Download\*')
        New-CleanupTask empty-dirs 'Remove empty folders left behind in temp locations' Logs Safe -Action {
            $roots = Expand-TaskPath @('<USER>\AppData\Local\Temp', '%WINDIR%\Temp')
            $n = 0
            foreach ($r in $roots) {
                if (-not (Test-Path -LiteralPath $r)) { continue }
                if (Test-WhatIfMode) {
                    $n += @(Get-ChildItem -LiteralPath $r -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1) }).Count
                } else { $n += Remove-EmptyDirectory -Root $r }
            }
            [pscustomobject]@{ Files = $n; Bytes = 0; Errors = 0 }
        }
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
        # Every user's bin on every disk, with real byte accounting. (Clear-RecycleBin only
        # empties the CALLER's bin - nothing at all when the weekly task runs as SYSTEM.)
        New-CleanupTask recyclebin 'Recycle Bin (all users, all disks)' Logs Moderate -Exclude @('desktop.ini') -Paths @(
            '<DRIVE>$Recycle.Bin\<SID>\*')
        New-CleanupTask eventlogs 'Clear event logs (archived first)' Logs Dangerous -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would archive & clear Application/System/Setup logs' 'WhatIf'; return $null }
            # Archive outside %TEMP% - the temp tasks would delete the backup on the next run.
            $archive = Join-Path $env:ProgramData "WinSenior\eventlogs\$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            New-Item -ItemType Directory -Path $archive -Force -ErrorAction SilentlyContinue | Out-Null
            $err = 0
            foreach ($log in 'Application','System','Setup') {
                $dest = Join-Path $archive "$log.evtx"
                & wevtutil.exe export-log $log "$dest" /overwrite:true 2>$null
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
                    Write-CleanupLog "Export of '$log' failed - log NOT cleared" 'Warning'; $err++; continue
                }
                & wevtutil.exe clear-log $log 2>$null
                if ($LASTEXITCODE -eq 0) { Write-CleanupLog "Archived & cleared '$log' (backup: $dest)" 'Success' }
                else { Write-CleanupLog "Clearing '$log' failed (exit $LASTEXITCODE)" 'Warning'; $err++ }
            }
            [pscustomobject]@{ Files = 0; Bytes = [int64]0; Errors = $err }
        }

        # ---------------- Updates ----------------
        # Only the download cache. catroot2 is a troubleshooting reset (Troubleshoot tab),
        # not a cache. Skipped while an update is staged and waiting for a reboot -
        # deleting its payload then makes the install fail and re-download.
        New-CleanupTask wu-cache 'Windows Update download cache' Updates Moderate `
            -SkipIf { if (Test-UpdateRebootPending) { 'an update is waiting for a reboot - restart first' } } `
            -StopServices @('wuauserv','bits') -Paths @(
            '%WINDIR%\SoftwareDistribution\Download\*')
        # Deletes update history (DataStore) too: a repair step, not routine cleanup.
        New-CleanupTask wu-full 'Full SoftwareDistribution reset (wipes update history)' Updates Aggressive -DefaultOn $false `
            -SkipIf { if (Test-UpdateRebootPending) { 'an update is waiting for a reboot - restart first' } } `
            -StopServices @('wuauserv','bits','UsoSvc') -Paths @(
            '%WINDIR%\SoftwareDistribution\*')
        New-CleanupTask patchcache 'Windows Installer patch cache' Updates Dangerous -Paths @(
            '%WINDIR%\Installer\$PatchCache$\*',
            '%WINDIR%\Installer\*.tmp')
        New-CleanupTask windows-old 'Windows.old & upgrade leftovers' Updates Dangerous -Action {
            $total = [pscustomobject]@{ Files = 0; Bytes = 0; Errors = 0 }
            $old = Get-Item -LiteralPath "$env:SystemDrive\Windows.old" -Force -ErrorAction SilentlyContinue
            if ($old -and $old.CreationTime -gt (Get-Date).AddDays(-10)) {
                Write-CleanupLog ("  Windows.old is only {0:N0} day(s) old - removing it ends the 'go back' rollback window" -f `
                    ((Get-Date) - $old.CreationTime).TotalDays) 'Safety'
            }
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

        # Update Assistant / Media Creation / reset scratch left at the drive root once the
        # upgrade or reset has finished (contents only - the engine never deletes roots).
        New-CleanupTask upgrade-leftovers 'Upgrade assistant & reset leftovers ($GetCurrent, Windows10Upgrade, $SysReset)' Updates Moderate `
            -SkipIf { if (Test-UpdateRebootPending) { 'an update is waiting for a reboot - restart first' } } -Paths @(
            '%SystemDrive%\$GetCurrent\*',
            '%SystemDrive%\Windows10Upgrade\*',
            '%SystemDrive%\$SysReset\*')
        New-CleanupTask hiberfil 'Disable hibernation & delete hiberfil.sys (also disables Fast Startup)' Updates Dangerous -DefaultOn $false -Action {
            $f = "$env:SystemDrive\hiberfil.sys"
            if (-not (Test-Path -LiteralPath $f)) { Write-CleanupLog '  hibernation already off' 'Debug'; return $null }
            $size = (Get-Item -LiteralPath $f -Force).Length
            if (Test-WhatIfMode) {
                Write-CleanupLog "[WhatIf] would run powercfg /hibernate off ($(Format-FileSize $size))" 'WhatIf'
                return [pscustomobject]@{ Files = 1; Bytes = $size; Errors = 0 }
            }
            $ok = Invoke-NativeStep 'powercfg /hibernate off' { & powercfg.exe /hibernate off *>$null }
            [pscustomobject]@{ Files = 1; Bytes = $(if ($ok) { $size } else { 0 }); Errors = $(if ($ok) { 0 } else { 1 }) }
        }
        New-CleanupTask shadow-old 'Delete all but the newest restore point / shadow copy (vssadmin)' Updates Dangerous -DefaultOn $false -Action {
            # System-drive restore-point shadows only: other volumes' shadows and the
            # non-client-accessible ones made by backup software are left alone.
            $sysVol = (Get-CimInstance Win32_Volume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction SilentlyContinue).DeviceID
            $shadows = @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue |
                         Where-Object { $_.VolumeName -eq $sysVol -and $_.ClientAccessible } | Sort-Object InstallDate)
            if ($shadows.Count -le 1) { Write-CleanupLog '  nothing to prune' 'Debug'; return $null }
            $old = @($shadows | Select-Object -First ($shadows.Count - 1))
            if (Test-WhatIfMode) {
                Write-CleanupLog "[WhatIf] would delete $($old.Count) older shadow copies" 'WhatIf'
                return [pscustomobject]@{ Files = $old.Count; Bytes = 0; Errors = 0 }
            }
            $n = 0
            foreach ($sc in $old) {
                & vssadmin.exe delete shadows /shadow=$($sc.ID) /quiet *>$null
                if ($LASTEXITCODE -eq 0) { $n++ }
            }
            [pscustomobject]@{ Files = $n; Bytes = 0; Errors = ($old.Count - $n) }
        }

        # ---------------- Optimization (slow; skipped by -SkipOptimization) ----------------
        New-CleanupTask dism-analyze 'Analyze component store (report only)' Optimization Safe -DefaultOn $true -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would run DISM /AnalyzeComponentStore' 'WhatIf'; return $null }
            $out = & dism.exe /online /Cleanup-Image /AnalyzeComponentStore 2>&1
            $out | Where-Object { $_ -match ':' } | ForEach-Object { Write-CleanupLog "  $_" 'Debug' }
            Write-CleanupLog 'Component store analyzed' 'Success'; $null
        }
        # The scheduled task runs the same cleanup in the background; running it AND the
        # synchronous DISM call below makes them compete, so the task is opt-in.
        New-CleanupTask component-task 'Run StartComponentCleanup scheduled task (background)' Optimization Moderate -DefaultOn $false -Action {
            Invoke-NativeStep 'schtasks StartComponentCleanup' {
                & schtasks.exe /Run /TN '\Microsoft\Windows\Servicing\StartComponentCleanup' *>$null
            } | Out-Null
            $null
        }
        # WinSxS is hard-linked, so folder sizes lie; the system drive's free-space delta
        # is the honest measure of what component cleanup gave back.
        New-CleanupTask dism-cleanup 'DISM component cleanup' Optimization Moderate `
            -SkipIf { if (Test-UpdateRebootPending) { 'servicing is waiting for a reboot - restart first' } } -Action {
            $free0 = (New-Object System.IO.DriveInfo($env:SystemDrive)).AvailableFreeSpace
            $ok = Invoke-NativeStep 'DISM /StartComponentCleanup' {
                & dism.exe /online /Cleanup-Image /StartComponentCleanup /Quiet *>$null
            }
            if (Test-WhatIfMode) { return $null }
            if (-not $ok) { return [pscustomobject]@{ Files = 0; Bytes = [int64]0; Errors = 1 } }
            $gain = (New-Object System.IO.DriveInfo($env:SystemDrive)).AvailableFreeSpace - $free0
            [pscustomobject]@{ Files = 0; Bytes = [int64][Math]::Max(0, $gain); Errors = 0 }
        }
        # /ResetBase makes every installed update permanently UNINSTALLABLE - irreversible,
        # so it lives in the Dangerous tier with the other point-of-no-return operations.
        # (/SPSuperseded only ever applied to Windows 7-era service packs.)
        New-CleanupTask dism-resetbase 'DISM reset base (installed updates can no longer be uninstalled)' Optimization Dangerous -DefaultOn $true `
            -SkipIf { if (Test-UpdateRebootPending) { 'servicing is waiting for a reboot - restart first' } } -Action {
            $free0 = (New-Object System.IO.DriveInfo($env:SystemDrive)).AvailableFreeSpace
            $ok = Invoke-NativeStep 'DISM /StartComponentCleanup /ResetBase' {
                & dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet *>$null
            }
            if (Test-WhatIfMode) { return $null }
            if (-not $ok) { return [pscustomobject]@{ Files = 0; Bytes = [int64]0; Errors = 1 } }
            $gain = (New-Object System.IO.DriveInfo($env:SystemDrive)).AvailableFreeSpace - $free0
            [pscustomobject]@{ Files = 0; Bytes = [int64][Math]::Max(0, $gain); Errors = 0 }
        }
        New-CleanupTask dism-logs 'DISM logs (>7 days)' Optimization Safe -AgeDays 7 -Paths @('%WINDIR%\Logs\DISM\*')
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

    $skip = $null
    if ($Task.SkipIf) { $skip = & $Task.SkipIf }
    if ($skip) { Write-CleanupLog "  skipped: $skip" 'Warning' }
    elseif (Test-TaskBlocked -Task $Task) { $skip = 'app running' }
    if ($skip) {
        $script:Stats.Add([pscustomobject]@{
            Task = $Task.Id; Name = $Task.Name; Category = $Task.Category; Risk = $Task.Risk
            Files = 0; Bytes = [int64]0; Errors = 0; Deferred = 0; Skipped = [string]$skip
        })
        return
    }

    $result = $null
    if ($Task.Action) {
        $result = & $Task.Action
    }
    else {
        $paths  = Expand-TaskPath $Task.Paths
        $effAge = [Math]::Max($MaxAgeDays, $Task.AgeDays)
        $excl   = $Task.Exclude
        if ($Task.StopServices) {
            $result = Use-StoppedService -Name $Task.StopServices -Body {
                Invoke-PathCleanup -Path $paths -AgeDays $effAge -Description $Task.Name -ExcludePattern $excl
            }
        }
        else {
            $result = Invoke-PathCleanup -Path $paths -AgeDays $effAge -Description $Task.Name -ExcludePattern $excl
        }
    }

    if ($result -and ($result.PSObject.Properties.Name -contains 'Bytes')) {
        $script:TotalBytes  += [int64]$result.Bytes
        $script:TotalFiles  += [int]$result.Files
        $script:TotalErrors += [int]$result.Errors
        $def = if ($result.PSObject.Properties.Name -contains 'Deferred') { [int]$result.Deferred } else { 0 }
        $script:TotalDeferred += $def
        $script:Stats.Add([pscustomobject]@{
            Task = $Task.Id; Name = $Task.Name; Category = $Task.Category; Risk = $Task.Risk
            Files = [int]$result.Files; Bytes = [int64]$result.Bytes; Errors = [int]$result.Errors; Deferred = $def
            Skipped = $null
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
        $hint = if ($DeferLocked) { '' } else { '  (use -DeferLocked to remove them at next reboot)' }
        Write-CleanupLog "Errors (locked/in-use items): $script:TotalErrors$hint" 'Warning'
    }
    if ($script:TotalDeferred -gt 0) {
        Write-CleanupLog "Scheduled for deletion at next reboot: $script:TotalDeferred item(s)" 'Info'
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
            TotalDeferred = $script:TotalDeferred
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
Windows System Cleaner and Optimizer  (registry-driven engine)

USAGE
  .\Cleanup-Windows-Senior.ps1 [options]

SELECTION
  -Category <names>     Limit to: Browsers, DevTools, Apps, Games, System, Disks, Logs, Updates, Optimization
  -Include  <ids>       Force tasks on  (see -ListTasks for ids)
  -Exclude  <ids>       Force tasks off
  -IncludeDangerous     Also run irreversible tier (event logs, patch cache, Windows.old, old drivers, DISM ResetBase)
  -Conservative         Cap at Safe + Moderate (skip Aggressive)
  -CurrentUserOnly,-cu  Clean only the current profile (default: all users)
  -Drives <letters>     Local disks for drive-level cleanup, e.g. -Drives C,D (default: all local disks)
  -SkipOptimization,-so Skip the slow SFC/DISM category
  -MaxAgeDays <n>       Only delete files older than n days
  -DeferLocked, -dl     Schedule locked/in-use files for deletion at next reboot
  -CloseApps            Close running browsers (this session) instead of skipping their caches
                        (interactive runs close them anyway; -Unattended runs skip without it)

SAFETY
  -WhatIf / -DryRun,-dr Preview only, change nothing (real ShouldProcess)
  -NoRestorePoint,-nrp  Skip the System Restore point (created by default)
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
    Write-CleanupLog "Windows System Cleaner v$(Get-WinSeniorVersion)" 'Step'
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
