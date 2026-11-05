<#
.SYNOPSIS
    WinSenior apps - inventory, uninstall with leftover cleanup, updates and
    installs through winget (Microsoft's official package manager).

.DESCRIPTION
    Replaces separate uninstallers / updaters / "download sites": everything here
    uses what Windows already ships - the Add/Remove Programs registry, Store
    packages and winget, whose packages come from the vendors' own URLs with a
    SHA-256 pinned in the Microsoft-reviewed manifest.

      Get-WsInstalledApp        Win32 (HKLM 64/32-bit + HKCU) and Store apps
      Get-WsUninstallCommand    PURE: best silent command (MSI / quiet string /
                                Inno Setup / NSIS) or the interactive fallback
      Uninstall-WsApp           run it, wait, then look for leftovers (HKCU entries
                                run WITHOUT admin rights - any user program can write them)
      Find-WsAppLeftover        folders + registry keys left behind, each with a
      Get-WsLeftoverConfidence  confidence score (BCU-style; only Good/VeryGood
                                are offered by default)
      Get-WsLeftoverBlocker     hard safety checks (protected / personal folders,
                                links, programs or another app inside)
      Remove-WsAppLeftover      moves leftovers to a 30-day quarantine, never deletes
      ConvertFrom-WsWingetTable PURE: parse winget's table by column position
                                (headers are localized - positions are not)
      Get-WsAppUpdate / Update-WsApp / Install-WsApp   winget wrappers
      Get-WsAppCatalog          curated popular apps (verified winget ids)

.EXAMPLE
    .\WinSenior.Apps.ps1 -List
    .\WinSenior.Apps.ps1 -Updates
    .\WinSenior.Apps.ps1 -UpdateAll
    .\WinSenior.Apps.ps1 -Uninstall 'Some App'
    .\WinSenior.Apps.ps1 -Install Mozilla.Firefox,7zip.7zip
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$List,
    [switch]$Updates,
    [switch]$UpdateAll,
    [string[]]$Update,
    [string[]]$Uninstall,
    [string[]]$Install,
    [switch]$Catalog,
    [switch]$RemoveLeftovers,
    [switch]$Unattended,
    [string]$LogPath = "$env:TEMP\WinSenior-Apps.log",
    [string]$ReportPath
)

. (Join-Path $PSScriptRoot 'WinSenior.Common.ps1')
$wsWi = $global:WhatIfPreference
try { $global:WhatIfPreference = $false; Import-Module CimCmdlets -ErrorAction SilentlyContinue } finally { $global:WhatIfPreference = $wsWi }

function Write-AppLog { param([string]$Message, [string]$Level = 'Info') Write-WsLog -Message $Message -Level $Level -LogPath $LogPath }

# =====================================================================
# INVENTORY
# =====================================================================
$script:WsUninstallRoots = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine'; Arch = 'x64' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine'; Arch = 'x86' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'User'; Arch = '' }
)

# Pure: one uninstall-key property bag -> app record, or $null when it should be
# hidden (system components, updates/patches, nameless entries) - the same filter
# Programs and Features uses.
function ConvertTo-WsAppRecord {
    param([object]$Props, [string]$KeyName, [string]$KeyPath, [string]$Scope, [string]$Arch)
    if (-not $Props -or -not $Props.DisplayName) { return $null }
    if ([int]$Props.SystemComponent -eq 1) { return $null }
    if ($Props.ParentKeyName -or $Props.ReleaseType -match 'Update|Hotfix|Security Update') { return $null }
    if (-not $Props.UninstallString -and -not $Props.QuietUninstallString) { return $null }
    $date = $null
    if ([string]$Props.InstallDate -match '^(\d{4})(\d{2})(\d{2})$') {
        try { $date = Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour 0 -Minute 0 -Second 0 } catch { $date = $null }
    }
    $isMsi = ([int]$Props.WindowsInstaller -eq 1) -and ($KeyName -match '^\{[0-9A-Fa-f-]{36}\}$')
    [pscustomobject]@{
        Name = [string]$Props.DisplayName; Version = [string]$Props.DisplayVersion; Publisher = [string]$Props.Publisher
        InstallDate = $date; SizeBytes = [int64]([double]$Props.EstimatedSize * 1KB)
        Source = $(if ($isMsi) { 'MSI' } else { 'Win32' }); Scope = $Scope; Arch = $Arch
        ProductCode = $(if ($isMsi) { $KeyName } else { $null })
        UninstallString = [string]$Props.UninstallString; QuietUninstallString = [string]$Props.QuietUninstallString
        InstallLocation = [string]$Props.InstallLocation; KeyPath = $KeyPath; PackageFullName = $null
    }
}

function Get-WsInstalledApp {
    param([switch]$IncludeStore)
    $seen = @{}
    foreach ($root in $script:WsUninstallRoots) {
        foreach ($k in (Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $r = ConvertTo-WsAppRecord -Props $p -KeyName $k.PSChildName -KeyPath $k.Name -Scope $root.Scope -Arch $root.Arch
            if (-not $r) { continue }
            $key = ($r.Name + '|' + $r.Version).ToLowerInvariant()
            if ($seen[$key]) { continue }
            $seen[$key] = $true
            $r
        }
    }
    if ($IncludeStore) {
        try {
            Get-AppxPackage -ErrorAction Stop | Where-Object {
                -not $_.IsFramework -and $_.SignatureKind -eq 'Store' -and -not $_.NonRemovable
            } | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name; Version = [string]$_.Version; Publisher = ($_.Publisher -replace '^CN=([^,]+).*', '$1')
                    InstallDate = $null; SizeBytes = [int64]0; Source = 'Store'; Scope = 'User'; Arch = [string]$_.Architecture
                    ProductCode = $null; UninstallString = $null; QuietUninstallString = $null
                    InstallLocation = [string]$_.InstallLocation; KeyPath = $null; PackageFullName = $_.PackageFullName
                }
            }
        } catch { Write-Verbose "Appx unavailable: $($_.Exception.Message)" }   # pwsh 7 on some builds
    }
}

# =====================================================================
# UNINSTALL COMMAND (pure)
# =====================================================================
# Split "C:\Program Files\X\unins000.exe" /SILENT  or  C:\X\u.exe /S into exe + args.
function Split-WsCommandLine {
    param([string]$CommandLine)
    $c = $CommandLine.Trim()
    if ($c -match '^"([^"]+)"\s*(.*)$') { return [pscustomobject]@{ Exe = $Matches[1]; Args = $Matches[2].Trim() } }
    # Unquoted path with spaces: take the longest prefix that ends in .exe
    if ($c -match '^(.+?\.exe)(\s+.*)?$') { return [pscustomobject]@{ Exe = $Matches[1]; Args = ([string]$Matches[2]).Trim() } }
    $parts = $c -split '\s+', 2
    [pscustomobject]@{ Exe = $parts[0]; Args = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

# RunAsUser: the entry came from HKCU, which any program of that user can write
# without admin rights - its command must never inherit our elevation.
function Get-WsUninstallCommand {
    param([object]$App)
    $c = Get-WsUninstallCommandCore $App
    $c | Add-Member -NotePropertyName RunAsUser -NotePropertyValue ($App.Scope -eq 'User' -and $c.Kind -ne 'Store') -PassThru
}

function Get-WsUninstallCommandCore {
    param([object]$App)
    if ($App.Source -eq 'Store') { return [pscustomobject]@{ Kind = 'Store'; Exe = $null; Args = $App.PackageFullName; Silent = $true } }
    if ($App.ProductCode) {
        return [pscustomobject]@{ Kind = 'MSI'; Exe = 'msiexec.exe'; Args = "/x $($App.ProductCode) /qn /norestart"; Silent = $true }
    }
    if ($App.QuietUninstallString) {
        $q = Split-WsCommandLine $App.QuietUninstallString
        return [pscustomobject]@{ Kind = 'Quiet'; Exe = $q.Exe; Args = $q.Args; Silent = $true }
    }
    $u = Split-WsCommandLine $App.UninstallString
    if ($u.Exe -match '(?i)msiexec' -and $u.Args -match '(\{[0-9A-Fa-f-]{36}\})') {
        return [pscustomobject]@{ Kind = 'MSI'; Exe = 'msiexec.exe'; Args = "/x $($Matches[1]) /qn /norestart"; Silent = $true }
    }
    $leaf = [IO.Path]::GetFileName($u.Exe)
    if ($leaf -match '(?i)^unins\d{3}\.exe$') {        # Inno Setup
        return [pscustomobject]@{ Kind = 'Inno'; Exe = $u.Exe; Args = (($u.Args + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim()); Silent = $true }
    }
    if ($leaf -match '(?i)^(uninst(all)?|uninstaller)\.exe$' -and $u.Args -notmatch '(?i)(^|\s)/S(\s|$)') {   # NSIS convention
        return [pscustomobject]@{ Kind = 'NSIS'; Exe = $u.Exe; Args = (($u.Args + ' /S').Trim()); Silent = $true }
    }
    [pscustomobject]@{ Kind = 'Interactive'; Exe = $u.Exe; Args = $u.Args; Silent = $false }
}

# =====================================================================
# LEFTOVERS (BCU-style confidence)
# =====================================================================
$script:WsGenericNames = @('microsoft', 'microsoft corporation', 'windows', 'common files', 'update', 'updates', 'temp', 'tmp',
    'cache', 'data', 'logs', 'google', 'intel', 'amd', 'nvidia', 'nvidia corporation', 'packages', 'programs', 'users',
    'appdata', 'local', 'roaming', 'program files', 'program files (x86)', 'system32', 'drivers', 'installer', 'mozilla',
    'apple', 'adobe', 'java', 'oracle', 'python', 'node', 'npm', 'git', 'steam', 'software', 'classes', 'policies', 'wow6432node',
    # catch-all folders installers like to write into InstallLocation
    'games', 'game', 'my games', 'documents', 'docs', 'desktop', 'downloads', 'music', 'pictures', 'videos', 'onedrive', 'dropbox',
    'tools', 'utils', 'utilities', 'apps', 'applications', 'app', 'bin', 'lib', 'soft', 'portable', 'install', 'setup', 'distr',
    'backup', 'backups', 'work', 'projects', 'src', 'source', 'dev', 'home', 'public', 'shared', 'common', 'files', 'misc', 'other')

function Get-WsNameKey { param([string]$s) (($s -replace '\(.*?\)|\bv?\d+(\.\d+)*\b|x64|x86|64-bit|32-bit', '') -replace '[^\p{L}\p{N}]', '').ToLowerInvariant() }

# Pure. Candidate = @{ Path; Kind='Folder'|'RegKey'; Leaf }. Returns VeryGood/Good/
# Questionable/Bad. OtherApps = install locations / names of apps still installed.
# InstallLocation is just a registry string (installers write D:\Games or the
# Documents folder there), so it only counts when the folder NAME also looks like
# the app or its publisher.
function Get-WsLeftoverConfidence {
    param([object]$Candidate, [object]$App, [string[]]$OtherLocations = @(), [string[]]$OtherNames = @())
    $leaf = [string]$Candidate.Leaf
    $lk = Get-WsNameKey $leaf
    if (-not $lk -or $script:WsGenericNames -contains $leaf.ToLowerInvariant() -or $script:WsGenericNames -contains $lk -or $lk.Length -lt 3) { return 'Bad' }
    $full = ([string]$Candidate.Path).TrimEnd('\').ToLowerInvariant()
    foreach ($o in $OtherLocations) {
        if (-not $o) { continue }
        $ol = $o.TrimEnd('\').ToLowerInvariant()
        if ($ol -eq $full -or $ol.StartsWith($full + '\')) { return 'Bad' }          # another app lives here
    }
    foreach ($n in $OtherNames) { if ((Get-WsNameKey $n) -eq $lk) { return 'Bad' } }  # another installed app has this name
    $nk = Get-WsNameKey $App.Name; $pk = Get-WsNameKey $App.Publisher
    $nameScore = 0
    if ($lk -eq $nk) { $nameScore = 2 }
    elseif ($nk.Length -ge 4 -and ($nk.StartsWith($lk) -or $lk.StartsWith($nk)) -and $lk.Length -ge 4) { $nameScore = 1 }
    $pubLike = $pk -and $pk.Length -ge 3 -and ($lk -eq $pk -or ($lk.Length -ge 4 -and ($pk.StartsWith($lk) -or $lk.StartsWith($pk))))
    $score = $nameScore
    if ($App.InstallLocation -and $full -eq $App.InstallLocation.TrimEnd('\').ToLowerInvariant() -and ($nameScore -gt 0 -or $pubLike)) { $score += 3 }
    if ($pk -and $full -match [regex]::Escape($pk) -and $lk -ne $pk) { $score += 1 }
    switch ($score) { { $_ -ge 3 } { 'VeryGood'; break } 2 { 'Good'; break } 1 { 'Questionable'; break } default { 'Bad' } }
}

# One walk of a folder that never enters a junction / symlink (Get-ChildItem
# -Recurse in Windows PowerShell 5.1 follows them). Stops after $Limit entries.
function Get-WsFolderScan {
    param([string]$Path, [int]$Limit = 50000)
    $r = [pscustomobject]@{ Bytes = [int64]0; Files = 0; Programs = (New-Object System.Collections.Generic.List[string])
        Dirs = (New-Object System.Collections.Generic.List[string]); Links = 0; Truncated = $false }
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push((New-Object System.IO.DirectoryInfo($Path)))
    $seen = 0
    :walk while ($stack.Count) {
        $d = $stack.Pop()
        try { $entries = $d.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if (++$seen -gt $Limit) { $r.Truncated = $true; break walk }
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $r.Links++; continue }
            if ($e -is [System.IO.DirectoryInfo]) { $r.Dirs.Add($e.Name); $stack.Push($e); continue }
            $r.Files++; $r.Bytes += $e.Length
            if ($e.Extension -match '^\.(exe|com|scr|msi)$') { $r.Programs.Add($e.FullName.Substring($Path.TrimEnd('\').Length + 1)) }
        }
    }
    $r
}

# Folders below which nothing is ever an app leftover (user documents, desktop ...).
function Get-WsUserDataPath {
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($n in 'Desktop', 'MyDocuments', 'MyMusic', 'MyPictures', 'MyVideos', 'Favorites', 'CommonDesktopDirectory', 'CommonDocuments') {
        try { $l.Add([Environment]::GetFolderPath($n)) } catch { Write-Verbose $n }
    }
    foreach ($v in 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial') { $x = [Environment]::GetEnvironmentVariable($v); if ($x) { $l.Add($x) } }
    $usf = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    foreach ($g in '{374DE290-123F-4565-9164-39C4925E467B}', '{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}') {   # Downloads, Saved Games
        if ($usf -and $usf.$g) { $l.Add([Environment]::ExpandEnvironmentVariables($usf.$g)) }
    }
    if ($env:USERPROFILE) { foreach ($s in $script:WsUserDataFolderNames) { $l.Add((Join-Path $env:USERPROFILE $s)) } }
    @($l | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique)
}

# Why this leftover must NOT be removed, or $null when it may go. Re-checked right
# before the move, so it also guards entries built by hand or by an older version.
function Get-WsLeftoverBlocker {
    param([object]$Leftover, [object[]]$Remaining = @(), [object]$ProtectedSet, [string[]]$UserData = (Get-WsUserDataPath))
    $path = ([string]$Leftover.Path).Trim()
    if ($Leftover.Kind -eq 'RegKey') {
        if ($path -notmatch '^(HKCU|HKLM):\\SOFTWARE\\(WOW6432Node\\)?[^\\]+') { return 'not an app key under SOFTWARE' }
        if ($path -match '(?i)^HK(CU|LM):\\SOFTWARE\\(WOW6432Node\\)?(Microsoft|Classes|Policies|Wow6432Node)(\\|$)') { return 'system registry branch' }
        return $null
    }
    if ($path -notmatch '^[A-Za-z]:\\') { return 'not a local path' }
    if ($path -match '(^|\\)\.{1,2}(\\|$)') { return 'relative path' }
    if ($path -match '~\d') { return 'short 8.3 path - cannot be checked' }
    $p = $path.TrimEnd('\')
    if (($p -split '\\').Count -lt 3) { return 'too close to the drive root' }
    if (Test-WsProtectedPath -Path $p -ProtectedSet $ProtectedSet) { return 'protected system or user folder' }
    foreach ($u in $UserData) { if ($p -ieq $u -or $p.StartsWith($u + '\', [StringComparison]::OrdinalIgnoreCase)) { return "inside a personal folder ($u)" } }
    $it = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if (-not $it) { return 'already gone' }
    if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'is a link / junction' }
    if (-not $it.PSIsContainer) { return 'not a folder' }
    foreach ($o in $Remaining) {
        $ol = ([string]$o.InstallLocation).TrimEnd('\')
        if ($ol -and ($ol -ieq $p -or $ol.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase))) { return "another app is installed here ($($o.Name))" }
    }
    $scan = Get-WsFolderScan -Path $p
    if ($scan.Truncated) { return 'too many files for a leftover' }
    if ($scan.Programs.Count) { return "still contains programs ($($scan.Programs[0]))" }
    $otherKeys = @{}
    foreach ($o in $Remaining) { $k = Get-WsNameKey $o.Name; if ($k.Length -ge 4) { $otherKeys[$k] = $o.Name } }
    foreach ($d in $scan.Dirs) { $k = Get-WsNameKey $d; if ($k -and $otherKeys[$k]) { return "contains a folder of another installed app ($($otherKeys[$k]))" } }
    $null
}

function Find-WsAppLeftover {
    param([object]$App, [object[]]$Remaining = @())
    $names = @($App.Name, ($App.Name -replace '\s*\(.*?\)\s*', '' -replace '\s+v?\d+(\.\d+)*$', '').Trim()) | Where-Object { $_ } | Sort-Object -Unique
    $pub = ($App.Publisher -replace ',?\s*(Inc|LLC|Ltd|GmbH|Corp(oration)?|Co|S\.A|AB)\.?$', '').Trim()
    # A per-user (HKCU) entry can be written by any program of that user, so its
    # InstallLocation / names are trusted only inside the user's own profile.
    $userScope = $App.Scope -eq 'User'
    $roots = if ($userScope) { @($env:APPDATA, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs')) }
             else { @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs')) }
    $roots = @($roots | Where-Object { $_ })
    $hives = if ($userScope) { @('HKCU:\SOFTWARE') } else { @('HKCU:\SOFTWARE', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node') }
    $cands = New-Object System.Collections.Generic.List[object]
    $loc = ([string]$App.InstallLocation).Trim().Trim('"').TrimEnd('\')
    $locOk = $loc -and (-not $userScope -or ($env:USERPROFILE -and $loc.StartsWith($env:USERPROFILE + '\', [StringComparison]::OrdinalIgnoreCase)))
    if ($locOk -and (Test-Path -LiteralPath $loc -PathType Container)) {
        $cands.Add([pscustomobject]@{ Kind = 'Folder'; Path = $loc; Leaf = (Split-Path $loc -Leaf) })
    }
    foreach ($r in $roots) {
        foreach ($n in $names) { $p = Join-Path $r $n; if (Test-Path -LiteralPath $p -PathType Container) { $cands.Add([pscustomobject]@{ Kind = 'Folder'; Path = $p; Leaf = $n }) } }
        if ($pub) { foreach ($n in $names) { $p = Join-Path (Join-Path $r $pub) $n; if (Test-Path -LiteralPath $p -PathType Container) { $cands.Add([pscustomobject]@{ Kind = 'Folder'; Path = $p; Leaf = $n }) } } }
    }
    foreach ($hive in $hives) {
        foreach ($n in $names) {
            foreach ($p in @((Join-Path $hive $n), $(if ($pub) { Join-Path (Join-Path $hive $pub) $n }))) {
                if ($p -and (Test-Path -LiteralPath $p)) { $cands.Add([pscustomobject]@{ Kind = 'RegKey'; Path = $p; Leaf = $n }) }
            }
        }
    }
    $otherLoc = @($Remaining | ForEach-Object { $_.InstallLocation } | Where-Object { $_ })
    $otherNames = @($Remaining | Where-Object { $_.Name -ne $App.Name } | ForEach-Object { $_.Name })
    $userData = Get-WsUserDataPath
    $cands | Sort-Object Path -Unique | ForEach-Object {
        $size = 0
        if ($_.Kind -eq 'Folder') { $size = (Get-WsFolderScan -Path $_.Path).Bytes }
        $conf = Get-WsLeftoverConfidence -Candidate $_ -App $App -OtherLocations $otherLoc -OtherNames $otherNames
        $l = [pscustomobject]@{ Kind = $_.Kind; Path = $_.Path; SizeBytes = $size; Confidence = $conf; Blocker = $null }
        if ($conf -in 'VeryGood', 'Good') { $l.Blocker = Get-WsLeftoverBlocker -Leftover $l -Remaining $Remaining -UserData $userData }
        $l
    }
}

# =====================================================================
# QUARANTINE (30 days, like the msi-orphans task)
#   Leftovers are MOVED, never deleted outright: a folder goes to a quarantine
#   folder on its own volume (a move is a rename - instant, no copy), a registry
#   key is exported to a .reg file first. Batches older than 30 days are purged.
# =====================================================================
$script:WsQuarantineDays = 30

function Get-WsAppQuarantineRoot {
    param([string]$ForPath)
    $sys = Join-Path $env:ProgramData 'WinSenior\AppQuarantine'
    if (-not $ForPath -or $ForPath -notmatch '^[A-Za-z]:\\') { return $sys }
    $vol = [IO.Path]::GetPathRoot($ForPath)
    if ($vol -ieq [IO.Path]::GetPathRoot($env:ProgramData)) { return $sys }
    Join-Path $vol 'WinSenior.Quarantine'
}

function Initialize-WsQuarantineFolder {
    param([string]$Root)
    if (Test-Path -LiteralPath $Root) { return }
    New-Item -ItemType Directory -Path $Root -Force -WhatIf:$false | Out-Null
    # Administrators + SYSTEM only, so nobody else can read the user's old data or plant
    # links. (Only when elevated - a non-admin run would lock itself out.)
    if (Test-AdminPrivileges) { & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' *> $null }
    if ($Root -match '^[A-Za-z]:\\[^\\]+$') { try { (Get-Item -LiteralPath $Root -Force).Attributes = 'Directory, Hidden' } catch { Write-Verbose $_ } }
}

function Get-WsAppQuarantineRootAll {
    $all = @(Get-WsAppQuarantineRoot)
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $all += (Join-Path $d.RootDirectory.FullName 'WinSenior.Quarantine') }
    }
    @($all | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)
}

function Clear-WsAppQuarantine {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Root = (Get-WsAppQuarantineRootAll), [int]$Days = $script:WsQuarantineDays)
    $n = 0
    foreach ($r in $Root) {
        foreach ($b in @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-$Days) })) {
            if (-not $PSCmdlet.ShouldProcess($b.FullName, "Delete quarantined leftovers (> $Days days)")) { continue }
            try { Remove-WsTree -Path $b.FullName; $n++ } catch { Write-AppLog "  could not purge $($b.FullName): $($_.Exception.Message)" 'Warning' }
        }
    }
    $n
}

function Remove-WsAppLeftover {
    [CmdletBinding(SupportsShouldProcess)]
    param([object[]]$Leftovers, [string[]]$Confidence = @('VeryGood', 'Good'), [object[]]$Remaining = @(),
          [string]$QuarantineRoot)    # override (tests); default = per volume, see Get-WsAppQuarantineRoot
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $batches = @{}
    $userData = Get-WsUserDataPath
    $n = 0
    foreach ($l in ($Leftovers | Where-Object { $Confidence -contains $_.Confidence })) {
        $why = Get-WsLeftoverBlocker -Leftover $l -Remaining $Remaining -UserData $userData
        if ($why) { Write-AppLog "  kept $($l.Path): $why" 'Warning'; continue }
        if (-not $PSCmdlet.ShouldProcess($l.Path, "Move leftover $($l.Kind.ToLower()) ($($l.Confidence)) to quarantine, deleted after $script:WsQuarantineDays days")) { continue }
        try {
            $root = if ($QuarantineRoot) { $QuarantineRoot } elseif ($l.Kind -eq 'Folder') { Get-WsAppQuarantineRoot $l.Path } else { Get-WsAppQuarantineRoot }
            Initialize-WsQuarantineFolder $root
            $batch = Join-Path $root $stamp
            if (-not $batches[$batch]) {
                New-Item -ItemType Directory -Path $batch -Force -WhatIf:$false | Out-Null
                $batches[$batch] = New-Object System.Collections.Generic.List[object]
            }
            $slot = '{0:D2}-{1}' -f ($batches[$batch].Count + 1), ((Split-Path $l.Path -Leaf) -replace '[\\/:*?"<>|]', '_')
            if ($l.Kind -eq 'Folder') {
                $dest = Join-Path $batch $slot
                [IO.Directory]::Move($l.Path.TrimEnd('\'), $dest)        # same volume: a rename, links move as links
            }
            else {
                $dest = Join-Path $batch ($slot + '.reg')
                $native = $l.Path -replace '^(HKCU|HKLM):', '$1'
                & reg.exe export $native $dest /y *> $null
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dest)) { throw "reg export failed ($LASTEXITCODE)" }
                Remove-Item -LiteralPath $l.Path -Recurse -Force -ErrorAction Stop
            }
            $batches[$batch].Add([ordered]@{ Kind = $l.Kind; From = $l.Path; To = $dest; Bytes = $l.SizeBytes })
            Write-AppLog "  quarantined $($l.Path)" 'Info'
            $n++
        }
        catch { Write-AppLog "  could not remove $($l.Path): $($_.Exception.Message)" 'Warning' }
    }
    foreach ($b in $batches.Keys) {
        @{ Created = (Get-Date).ToString('s'); PurgeAfterDays = $script:WsQuarantineDays; Items = $batches[$b] } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $b 'manifest.json') -Encoding UTF8 -WhatIf:$false
        Write-AppLog "  quarantine: $b (restore: move the folder back / double-click the .reg; purged after $script:WsQuarantineDays days)" 'Info'
    }
    $n
}

# =====================================================================
# UNINSTALL
# =====================================================================
# Run a program with the interactive user's normal (non-elevated) token: a one-shot
# scheduled task with RunLevel Limited. Used for HKCU uninstall entries - anything
# running as that user can write them, so they must never get our admin rights.
function Invoke-WsUnelevated {
    param([string]$Exe, [string]$Arguments, [int]$TimeoutMinutes = 30)
    $name = 'WinSenior Uninstall ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $act = if ($Arguments) { New-ScheduledTaskAction -Execute $Exe -Argument $Arguments } else { New-ScheduledTaskAction -Execute $Exe }
    $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMinutes)
    Register-ScheduledTask -TaskName $name -TaskPath '\WinSenior\' -Action $act -Principal $pr -Settings $st -Force -ErrorAction Stop | Out-Null
    try {
        Start-ScheduledTask -TaskName $name -TaskPath '\WinSenior\' -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        do {
            Start-Sleep -Milliseconds 500
            $t = Get-ScheduledTask -TaskName $name -TaskPath '\WinSenior\' -ErrorAction SilentlyContinue
        } while ($t -and $t.State -in 'Running', 'Queued' -and (Get-Date) -lt $deadline)
        if ($t -and $t.State -in 'Running', 'Queued') { return $null }     # timed out, still running
        [int]((Get-ScheduledTaskInfo -TaskName $name -TaskPath '\WinSenior\').LastTaskResult)
    }
    finally { Unregister-ScheduledTask -TaskName $name -TaskPath '\WinSenior\' -Confirm:$false -ErrorAction SilentlyContinue }
}

function Uninstall-WsApp {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$App, [int]$TimeoutMinutes = 30)
    $cmd = Get-WsUninstallCommand $App
    if (-not $PSCmdlet.ShouldProcess("$($App.Name) $($App.Version)", "Uninstall ($($cmd.Kind))")) { return $null }
    $code = $null
    if ($cmd.Kind -eq 'Store') {
        try { Remove-AppxPackage -Package $cmd.Args -ErrorAction Stop; $code = 0 } catch { $code = 1; Write-AppLog "  $($_.Exception.Message)" 'Error' }
    }
    else {
        $exe = [Environment]::ExpandEnvironmentVariables($cmd.Exe)
        Write-AppLog ("  command: `"{0}`" {1}" -f $exe, $cmd.Args) 'Info'
        try {
            if ($cmd.RunAsUser -and (Test-AdminPrivileges)) {
                Write-AppLog '  per-user entry (HKCU): its uninstaller runs WITHOUT administrator rights' 'Info'
                $code = Invoke-WsUnelevated -Exe $exe -Arguments $cmd.Args -TimeoutMinutes $TimeoutMinutes
                if ($null -eq $code) { Write-AppLog '  uninstaller still running - not waiting any longer' 'Warning' }
                elseif ($code -in 740, -2147024156) {   # ERROR_ELEVATION_REQUIRED / 0x800702E4
                    Write-AppLog '  this per-user uninstaller asks for administrator rights - run it from Settings > Apps instead' 'Warning'
                }
            }
            else {
                $sp = @{ FilePath = $exe; PassThru = $true; ErrorAction = 'Stop' }
                if ($cmd.Args) { $sp.ArgumentList = $cmd.Args }
                if ($cmd.Silent) { $sp.WindowStyle = 'Hidden' }
                $p = Start-Process @sp
                if (-not $p.WaitForExit($TimeoutMinutes * 60000)) { Write-AppLog '  uninstaller still running - not waiting any longer' 'Warning' }
                else { $code = $p.ExitCode }
            }
            # Inno/NSIS uninstallers re-launch themselves from %TEMP% and exit at once.
            if ($cmd.Kind -in 'Inno', 'NSIS') { Start-Sleep -Seconds 5; Get-Process -Name 'Au_', 'un_*', '_iu*' -ErrorAction SilentlyContinue | Wait-Process -Timeout 600 -ErrorAction SilentlyContinue }
        } catch { $code = -1; Write-AppLog "  could not start the uninstaller: $($_.Exception.Message)" 'Error' }
    }
    $still = $false
    if ($App.KeyPath) { $still = Test-Path -LiteralPath ("Registry::" + $App.KeyPath) }
    elseif ($App.Source -eq 'Store') { $still = [bool](Get-AppxPackage -Name $App.Name -ErrorAction SilentlyContinue) }
    # 0 ok, 1605 not installed, 1614 uninstalled, 3010 ok + reboot
    $ok = (-not $still) -and ($null -eq $code -or $code -in 0, 1605, 1614, 3010)
    [pscustomobject]@{ App = $App.Name; Kind = $cmd.Kind; ExitCode = $code; Removed = (-not $still); Ok = $ok; RebootRequired = ($code -eq 3010) }
}

# =====================================================================
# WINGET
# =====================================================================
function Test-WsWinget { [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }

# Pure: parse the FIRST table in winget output. Column starts come from the header
# line right above the dashed rule (header words are localized, positions are not).
function ConvertFrom-WsWingetTable {
    param([string[]]$Lines)
    $clean = @($Lines | ForEach-Object { $s = [string]$_; $i = $s.LastIndexOf([char]13); if ($i -ge 0) { $s.Substring($i + 1) } else { $s } })
    $rule = -1
    for ($i = 1; $i -lt $clean.Count; $i++) { if ($clean[$i] -match '^-{10,}\s*$') { $rule = $i; break } }
    if ($rule -lt 1) { return @() }
    $hdr = $clean[$rule - 1].TrimEnd()
    $starts = New-Object System.Collections.Generic.List[int]
    for ($c = 0; $c -lt $hdr.Length; $c++) {
        if ($hdr[$c] -ne ' ' -and ($c -eq 0 -or $hdr[$c - 1] -eq ' ')) { $starts.Add($c) }
    }
    if ($starts.Count -lt 3) { return @() }
    $names = 'Name', 'Id', 'Version', 'Available', 'Source'
    for ($r = $rule + 1; $r -lt $clean.Count; $r++) {
        $line = $clean[$r]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -le $starts[1]) { break }
        $vals = @{}
        for ($k = 0; $k -lt $starts.Count -and $k -lt $names.Count; $k++) {
            $a = $starts[$k]
            $b = if ($k + 1 -lt $starts.Count) { [Math]::Min($starts[$k + 1], $line.Length) } else { $line.Length }
            $vals[$names[$k]] = if ($a -lt $line.Length) { $line.Substring($a, [Math]::Max(0, $b - $a)).Trim() } else { '' }
        }
        if (-not $vals.Id -or $vals.Id -match '\s') { break }      # footer text, not a row
        [pscustomobject]@{ Name = $vals.Name; Id = $vals.Id; Version = $vals.Version; Available = $vals.Available; Source = $vals.Source }
    }
}

$script:WsWingetCommon = @('--accept-source-agreements', '--disable-interactivity')

function Invoke-WsWinget {
    param([string[]]$Arguments)
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $out = & winget.exe @Arguments 2>&1 | ForEach-Object { [string]$_ }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = [string[]]$out }
    }
    finally { try { [Console]::OutputEncoding = $prev } catch { Write-Verbose $_ } }
}

# winget result codes worth naming (MS docs returnCodes.md)
function Get-WsWingetCodeText {
    param([int]$Code)
    switch ('0x{0:X8}' -f $Code) {
        '0x00000000' { 'ok' } '0x8A15002B' { 'no applicable update' } '0x8A150014' { 'package not found' }
        '0x8A150016' { 'several packages match - use the exact id' } '0x8A150061' { 'already installed' }
        '0x8A150109' { 'ok, reboot required' } '0x8A15010A' { 'ok, reboot required' } '0x8A150101' { 'the app is running - close it' }
        '0x8A150102' { 'another installation is in progress' } '0x8A15010F' { 'blocked by policy' }
        default { 'error 0x{0:X8}' -f $Code }
    }
}

function Get-WsAppUpdate {
    $r = Invoke-WsWinget (@('upgrade', '--source', 'winget') + $script:WsWingetCommon)
    @(ConvertFrom-WsWingetTable $r.Lines | Where-Object { $_.Available })
}

function Update-WsApp {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Id)
    foreach ($i in $Id) {
        if (-not $PSCmdlet.ShouldProcess($i, 'winget upgrade')) { continue }
        $r = Invoke-WsWinget (@('upgrade', '--id', $i, '--exact', '--silent', '--accept-package-agreements', '--source', 'winget') + $script:WsWingetCommon)
        $ok = ($r.ExitCode -eq 0) -or (('0x{0:X8}' -f $r.ExitCode) -in '0x8A150109', '0x8A15010A')
        [pscustomobject]@{ Id = $i; ExitCode = $r.ExitCode; Ok = $ok; Text = (Get-WsWingetCodeText $r.ExitCode) }
    }
}

function Install-WsApp {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Id)
    $cat = @{}; foreach ($c in (Get-WsAppCatalog)) { $cat[$c.Id] = $c }
    foreach ($i in $Id) {
        if (-not $PSCmdlet.ShouldProcess($i, 'winget install')) { continue }
        $src = if ($cat[$i] -and $cat[$i].Source) { $cat[$i].Source } else { 'winget' }
        $r = Invoke-WsWinget (@('install', '--id', $i, '--exact', '--silent', '--accept-package-agreements', '--source', $src) + $script:WsWingetCommon)
        $hex = '0x{0:X8}' -f $r.ExitCode
        $ok = ($r.ExitCode -eq 0) -or ($hex -in '0x8A150061', '0x8A150109', '0x8A15010A')
        [pscustomobject]@{ Id = $i; ExitCode = $r.ExitCode; Ok = $ok; Text = (Get-WsWingetCodeText $r.ExitCode) }
    }
}

# Curated catalog: every id verified with "winget show --id <id> --exact" (2026-11-05).
function Get-WsAppCatalog {
    $c = @(
        # Category       Id                                   Name
        ,@('Browsers',     'Mozilla.Firefox',                   'Firefox')
        ,@('Browsers',     'Google.Chrome',                     'Google Chrome')
        ,@('Browsers',     'Brave.Brave',                       'Brave')
        ,@('Browsers',     'Yandex.Browser',                    'Yandex Browser')
        ,@('Browsers',     'Opera.Opera',                       'Opera')
        ,@('Messengers',   'Telegram.TelegramDesktop',          'Telegram')
        ,@('Messengers',   'Discord.Discord',                   'Discord')
        ,@('Messengers',   'Zoom.Zoom',                         'Zoom')
        ,@('Media',        'VideoLAN.VLC',                      'VLC media player')
        ,@('Media',        'Daum.PotPlayer',                    'PotPlayer')
        ,@('Media',        'Spotify.Spotify',                   'Spotify')
        ,@('Media',        'Audacity.Audacity',                 'Audacity')
        ,@('Media',        'HandBrake.HandBrake',               'HandBrake')
        ,@('Media',        'OBSProject.OBSStudio',              'OBS Studio')
        ,@('Media',        'GIMP.GIMP.3',                       'GIMP')
        ,@('Office',       'TheDocumentFoundation.LibreOffice', 'LibreOffice')
        ,@('Office',       'ONLYOFFICE.DesktopEditors',         'ONLYOFFICE')
        ,@('Office',       'SumatraPDF.SumatraPDF',             'SumatraPDF')
        ,@('Office',       'Obsidian.Obsidian',                 'Obsidian')
        ,@('Utilities',    '7zip.7zip',                         '7-Zip')
        ,@('Utilities',    'voidtools.Everything',              'Everything (file search)')
        ,@('Utilities',    'Microsoft.PowerToys',               'PowerToys')
        ,@('Utilities',    'Notepad++.Notepad++',               'Notepad++')
        ,@('Utilities',    'ShareX.ShareX',                     'ShareX')
        ,@('Utilities',    'AntibodySoftware.WizTree',          'WizTree (disk usage)')
        ,@('Utilities',    'qBittorrent.qBittorrent',           'qBittorrent')
        ,@('Utilities',    'Rufus.Rufus',                       'Rufus')
        ,@('Utilities',    'Ventoy.Ventoy',                     'Ventoy')
        ,@('Security',     'KeePassXCTeam.KeePassXC',           'KeePassXC')
        ,@('Security',     'Bitwarden.Bitwarden',               'Bitwarden')
        ,@('Hardware',     'CrystalDewWorld.CrystalDiskInfo',   'CrystalDiskInfo')
        ,@('Hardware',     'CrystalDewWorld.CrystalDiskMark',   'CrystalDiskMark')
        ,@('Hardware',     'CPUID.CPU-Z',                       'CPU-Z')
        ,@('Hardware',     'TechPowerUp.GPU-Z',                 'GPU-Z')
        ,@('Hardware',     'REALiX.HWiNFO',                     'HWiNFO')
        ,@('Gaming',       'Valve.Steam',                       'Steam')
        ,@('Gaming',       'EpicGames.EpicGamesLauncher',       'Epic Games Launcher')
        ,@('Gaming',       'Mojang.MinecraftLauncher',          'Minecraft Launcher')
        ,@('Gaming',       'PrismLauncher.PrismLauncher',       'Prism Launcher (Minecraft mods)')
        ,@('Runtimes',     'Microsoft.VCRedist.2015+.x64',      'Visual C++ 2015-2022 (x64)')
        ,@('Runtimes',     'Microsoft.DotNet.DesktopRuntime.8', '.NET Desktop Runtime 8')
        ,@('Runtimes',     'EclipseAdoptium.Temurin.21.JRE',    'Java 21 (Temurin JRE)')
        ,@('Runtimes',     'Microsoft.DirectX',                 'DirectX End-User Runtime')
        ,@('Developer',    'Microsoft.VisualStudioCode',        'Visual Studio Code')
        ,@('Developer',    'Git.Git',                           'Git')
        ,@('Developer',    'Python.Python.3.13',                'Python 3.13')
        ,@('Developer',    'OpenJS.NodeJS.LTS',                 'Node.js LTS')
        ,@('Developer',    'Microsoft.WindowsTerminal',         'Windows Terminal')
        ,@('Developer',    'Microsoft.PowerShell',              'PowerShell 7')
        ,@('Developer',    'JetBrains.Toolbox',                 'JetBrains Toolbox')
        ,@('Developer',    'Docker.DockerDesktop',              'Docker Desktop')
        ,@('Developer',    'PuTTY.PuTTY',                       'PuTTY')
        ,@('Developer',    'WinSCP.WinSCP',                     'WinSCP')
    )
    foreach ($e in $c) { [pscustomobject]@{ Category = $e[0]; Id = $e[1]; Name = $e[2]; Source = 'winget' } }
}

# =====================================================================
# CLI
# =====================================================================
function Resolve-WsAppByName {
    param([object[]]$Apps, [string]$Query)
    $exact = @($Apps | Where-Object { $_.Name -ieq $Query -or $_.ProductCode -ieq $Query -or $_.PackageFullName -ieq $Query })
    if ($exact) { return $exact }
    @($Apps | Where-Object { $_.Name -like "*$Query*" })
}

function Start-WsApps {
    if ($Catalog) {
        Get-WsAppCatalog | Format-Table Category, Id, Name -AutoSize | Out-String | Write-Host
        return
    }
    if ($Install) {
        if (-not (Test-WsWinget)) { Write-AppLog 'winget is not available - install "App Installer" from Microsoft Store.' 'Error'; exit 3 }
        foreach ($r in (Install-WsApp -Id $Install)) { Write-AppLog ("{0}: {1}" -f $r.Id, $r.Text) $(if ($r.Ok) { 'Success' } else { 'Error' }) }
        return
    }
    if ($Updates -or $UpdateAll -or $Update) {
        if (-not (Test-WsWinget)) { Write-AppLog 'winget is not available - install "App Installer" from Microsoft Store.' 'Error'; exit 3 }
        Write-AppLog 'Checking for app updates (winget)...' 'Step'
        $ups = @(Get-WsAppUpdate)
        foreach ($u in $ups) { Write-AppLog ("  {0,-44} {1,-16} -> {2}" -f $u.Name, $u.Version, $u.Available) 'Info' }
        Write-AppLog "$($ups.Count) update(s) available." $(if ($ups.Count) { 'Warning' } else { 'Success' })
        $ids = if ($UpdateAll) { @($ups | ForEach-Object { $_.Id }) } elseif ($Update) { $Update } else { @() }
        foreach ($r in (Update-WsApp -Id $ids)) { Write-AppLog ("  {0}: {1}" -f $r.Id, $r.Text) $(if ($r.Ok) { 'Success' } else { 'Error' }) }
        if ($ReportPath) { Write-WinSeniorReport -ReportPath $ReportPath -Engine 'Apps' -Summary @{ UpdatesAvailable = $ups.Count } -Items ([object[]]$ups) -LogAction { param($m, $l) Write-AppLog $m $l } }
        return
    }
    $apps = @(Get-WsInstalledApp -IncludeStore)
    if ($Uninstall) {
        if (Test-AdminPrivileges) { [void](Clear-WsAppQuarantine) }    # leftovers quarantined > 30 days ago
        foreach ($q in $Uninstall) {
            $hit = @(Resolve-WsAppByName $apps $q)
            if ($hit.Count -ne 1) { Write-AppLog ("'{0}': {1} match(es) - use the exact name." -f $q, $hit.Count) 'Warning'; $hit | ForEach-Object { Write-AppLog "    $($_.Name)" 'Info' }; continue }
            $app = $hit[0]
            $cmd = Get-WsUninstallCommand $app
            if (-not $cmd.Silent -and $Unattended) { Write-AppLog "$($app.Name): no silent uninstaller - skipped in unattended mode." 'Warning'; continue }
            Write-AppLog "Uninstalling $($app.Name) ($($cmd.Kind))" 'Step'
            $res = Uninstall-WsApp -App $app
            if (-not $res) { continue }
            Write-AppLog ("  {0} (exit {1})" -f $(if ($res.Ok) { 'removed' } else { 'NOT removed' }), $res.ExitCode) $(if ($res.Ok) { 'Success' } else { 'Error' })
            if ($res.Removed) {
                $remaining = @(Get-WsInstalledApp)
                $left = @(Find-WsAppLeftover -App $app -Remaining $remaining)
                foreach ($l in $left) {
                    Write-AppLog ("  leftover {0,-6} {1,-12} {2} {3}{4}" -f $l.Kind, $l.Confidence, $l.Path, $(if ($l.SizeBytes) { Format-FileSize $l.SizeBytes }),
                        $(if ($l.Blocker) { "  [kept: $($l.Blocker)]" })) 'Info'
                }
                if ($RemoveLeftovers -and $left) {
                    $n = Remove-WsAppLeftover -Leftovers $left -Remaining $remaining
                    Write-AppLog "  moved $n leftover(s) to quarantine (Good/VeryGood only, deleted after $script:WsQuarantineDays days)" 'Success'
                }
            }
        }
        return
    }
    # default: -List
    $apps | Sort-Object SizeBytes -Descending |
        Format-Table @{ L = 'Name'; E = { $_.Name }; W = 48 }, Version, @{ L = 'Size'; E = { if ($_.SizeBytes) { Format-FileSize $_.SizeBytes } } },
                     @{ L = 'Installed'; E = { if ($_.InstallDate) { $_.InstallDate.ToString('yyyy-MM-dd') } } }, Source, Publisher -AutoSize | Out-String -Width 220 | Write-Host
    Write-AppLog "$($apps.Count) app(s)." 'Info'
    if ($ReportPath) { Write-WinSeniorReport -ReportPath $ReportPath -Engine 'Apps' -Summary @{ Installed = $apps.Count } -Items ([object[]]$apps) -LogAction { param($m, $l) Write-AppLog $m $l } }
}

if ($MyInvocation.InvocationName -ne '.') { Start-WsApps }
