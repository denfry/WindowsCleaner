<#
.SYNOPSIS
    One-line installer for Windows Senior (WinSenior).

.DESCRIPTION
    Paste into PowerShell (no git, no manual download, no admin needed to install):

        irm https://github.com/denfry/WindowsCleaner/releases/latest/download/install.ps1 | iex

    What it does:
      1. Reads SHA256SUMS.txt of the latest GitHub release to learn the zip name + hash.
      2. Downloads that zip over HTTPS and refuses to continue if the SHA256 differs.
      3. Unpacks it to %LOCALAPPDATA%\WinSenior\app (replacing an older version).
      4. Adds "Windows Senior" to the Start menu and the desktop.
      5. Starts the app (it asks for Administrator itself via UAC).

    Running it again updates to the newest release. Options, when you want them:

        & ([scriptblock]::Create((irm https://github.com/denfry/WindowsCleaner/releases/latest/download/install.ps1))) -NoLaunch
        ... -NoShortcut      no Start menu / desktop shortcuts
        ... -Console         start the arrow-key console menu instead of the app
        ... -Uninstall       remove the app, its shortcuts, the \WinSenior\ scheduled tasks
                             and %ProgramFiles%\WinSenior (asks for Administrator once
                             if those exist)

    Nothing here needs Administrator; the app elevates when it starts.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Requires: Windows 10/11, PowerShell 5.1+.
#>
# Everything runs inside one script block: `irm | iex` executes in the caller's own
# session, so nothing (preferences, functions, variables) may leak into their console.
& {
[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$NoShortcut,
    [switch]$Console,
    [switch]$Uninstall,
    # Where the release files come from. Default: the latest GitHub release. A local
    # folder containing SHA256SUMS.txt + the zip also works (offline installs, tests).
    [string]$Source = $(if ($env:WINSENIOR_INSTALL_SOURCE) { $env:WINSENIOR_INSTALL_SOURCE } else {
        'https://github.com/denfry/WindowsCleaner/releases/latest/download' }),
    [string]$InstallRoot = $(if ($env:WINSENIOR_INSTALL_ROOT) { $env:WINSENIOR_INSTALL_ROOT } else {
        Join-Path $env:LOCALAPPDATA 'WinSenior' }),
    # What -Uninstall removes besides the app (overridable for tests): the Task Scheduler
    # folder with the scheduled cleanup / health scan / Smart Memory tasks, and the
    # admins-only copy of the scripts those tasks run.
    [string]$TaskFolder = $(if ($env:WINSENIOR_TASK_FOLDER) { $env:WINSENIOR_TASK_FOLDER } else { '\WinSenior' }),
    [string]$MachineRoot = $(if ($env:WINSENIOR_MACHINE_ROOT) { $env:WINSENIOR_MACHINE_ROOT } else {
        Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) 'WinSenior' })
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is 10x slower with the bar

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Bad  { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red }

# Parse a SHA256SUMS.txt body ("<hex>  <file>") and return the WinSenior zip entry.
function Get-WinSeniorReleaseEntry {
    param([Parameter(Mandatory)][string]$SumsText)
    foreach ($line in ($SumsText -split "`r?`n")) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(WinSenior-[0-9][0-9A-Za-z.\-]*\.zip)\s*$') {
            return [pscustomobject]@{ Hash = $Matches[1].ToUpperInvariant(); File = $Matches[2] }
        }
    }
    $null
}

# Download / hash / unzip use .NET directly, never module cmdlets: Windows PowerShell
# started from pwsh 7 inherits pwsh's PSModulePath and then cannot load Get-FileHash,
# Expand-Archive or Invoke-WebRequest - the installer must work regardless.
function Get-SourceItem {
    param([string]$Name, [string]$OutFile)
    if ($Source -match '^https?://') {
        $uri = "$($Source.TrimEnd('/'))/$Name"
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'WinSenior-installer'
        if ($wc.Proxy) { $wc.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }
        try {
            if ($OutFile) { $wc.DownloadFile($uri, $OutFile) }
            else { [Text.Encoding]::UTF8.GetString($wc.DownloadData($uri)) }
        } finally { $wc.Dispose() }
    }
    else {
        $p = Join-Path $Source $Name
        if ($OutFile) { [IO.File]::Copy($p, $OutFile, $true) } else { [IO.File]::ReadAllText($p) }
    }
}

function Get-Sha256 {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs  = [IO.File]::OpenRead($Path)
    try { -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('X2') }) }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Get-ShortcutPath {
    @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Windows Senior.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop'))  'Windows Senior.lnk')
    )
}

function New-WinSeniorShortcut {
    param([string]$Path, [string]$AppDir)
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath       = Join-Path $AppDir 'WinSenior.cmd'
    $lnk.WorkingDirectory = $AppDir
    $lnk.WindowStyle      = 7   # minimized: the launcher's console never flashes up
    $lnk.IconLocation     = "$env:SystemRoot\System32\cleanmgr.exe,0"
    $lnk.Description      = 'Windows Senior - cleanup, optimization and troubleshooting'
    $lnk.Save()
}

# Scheduled tasks + %ProgramFiles%\WinSenior. Task Scheduler is driven through COM, not
# the ScheduledTasks module (same PSModulePath problem as above). Returns what is left.
$machineCleanup = @'
$ErrorActionPreference = 'SilentlyContinue'
$s = New-Object -ComObject Schedule.Service; $s.Connect()
try {
    $f = $s.GetFolder('__FOLDER__')
    foreach ($t in @($f.GetTasks(1))) { try { $f.DeleteTask($t.Name, 0) } catch { } }
    if (@($f.GetTasks(1)).Count -eq 0 -and @($f.GetFolders(0)).Count -eq 0) { $s.GetFolder('\').DeleteFolder('__LEAF__', 0) }
} catch { }
if (Test-Path -LiteralPath '__ROOT__') { Remove-Item -LiteralPath '__ROOT__' -Recurse -Force }
'@

function Get-MachineCleanupScript {
    $q = { param($v) $v -replace "'", "''" }
    $machineCleanup.Replace('__FOLDER__', (& $q $TaskFolder)).Replace('__LEAF__', (& $q $TaskFolder.Trim('\'))).Replace('__ROOT__', (& $q $MachineRoot))
}

function Get-MachineLeftover {
    $left = @()
    try {
        $s = New-Object -ComObject Schedule.Service; $s.Connect()
        $f = $s.GetFolder($TaskFolder)
        $left += @($f.GetTasks(1) | ForEach-Object { "task $TaskFolder\$($_.Name)" })
        if (-not $left) { $left += "task folder $TaskFolder" }
    } catch { Write-Verbose "no task folder $TaskFolder" }
    if (Test-Path -LiteralPath $MachineRoot) { $left += $MachineRoot }
    , $left
}

function Remove-WinSeniorMachinePart {
    if (-not (Get-MachineLeftover).Count) { return }
    Write-Step 'Removing scheduled tasks and the machine-wide copy'
    & ([scriptblock]::Create((Get-MachineCleanupScript)))      # works as far as our rights go
    if ((Get-MachineLeftover).Count) {
        # The weekly cleanup runs as SYSTEM and lives in Program Files: only an admin can remove it.
        Write-Host '    Administrator rights are needed for the rest - confirm the prompt.' -ForegroundColor Yellow
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-MachineCleanupScript)))
        try {
            Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait -WindowStyle Hidden `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
        } catch { Write-Verbose "elevation declined: $($_.Exception.Message)" }
    }
    $left = Get-MachineLeftover
    if ($left.Count) {
        Write-Bad 'Not removed (no Administrator rights):'
        foreach ($l in $left) { Write-Host "      $l" }
        Write-Host '    In an Administrator PowerShell:' -ForegroundColor DarkGray
        Write-Host ("      Get-ScheduledTask -TaskPath '{0}\' | Unregister-ScheduledTask -Confirm:`$false" -f $TaskFolder) -ForegroundColor DarkGray
        Write-Host ("      Remove-Item -LiteralPath '{0}' -Recurse -Force" -f $MachineRoot) -ForegroundColor DarkGray
    }
    else { Write-Ok 'Scheduled tasks and the machine-wide copy removed.' }
}

function Invoke-WinSeniorInstall {
    $appDir = Join-Path $InstallRoot 'app'
    # `irm | iex` cannot take parameters, so the same switches are honoured as env vars.
    if ($env:WINSENIOR_INSTALL_NOLAUNCH)   { $NoLaunch   = $true }
    if ($env:WINSENIOR_INSTALL_NOSHORTCUT) { $NoShortcut = $true }

    if ($Uninstall) {
        Write-Step 'Removing Windows Senior'
        if (-not $NoShortcut) {
            foreach ($l in (Get-ShortcutPath)) { if (Test-Path -LiteralPath $l) { [IO.File]::Delete($l) } }
        }
        if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
        Write-Ok "Removed $appDir and the shortcuts."
        # The tasks would otherwise keep running: the cleanup from Program Files as SYSTEM,
        # Smart Memory every 10 minutes against a script that no longer exists.
        Remove-WinSeniorMachinePart
        Write-Host '    Settings, logs and undo backups stay in %ProgramData%\WinSenior (delete by hand if unwanted).'
        return
    }

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Windows Senior runs on Windows 10/11 only.' }
    # Windows PowerShell 5.1 on older .NET may still default to TLS 1.0/1.1; GitHub needs 1.2.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { Write-Verbose 'TLS 1.2 already on' }

    Write-Step 'Looking up the latest release'
    $entry = Get-WinSeniorReleaseEntry -SumsText (Get-SourceItem -Name 'SHA256SUMS.txt')
    if (-not $entry) { throw 'SHA256SUMS.txt does not list a WinSenior zip.' }
    Write-Ok $entry.File

    $work = Join-Path ([IO.Path]::GetTempPath()) ("winsenior-install-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $zip = Join-Path $work $entry.File
        Write-Step 'Downloading'
        Get-SourceItem -Name $entry.File -OutFile $zip
        $hash = Get-Sha256 -Path $zip
        if ($hash -ne $entry.Hash) {
            throw "SHA256 mismatch - download corrupted or tampered with (expected $($entry.Hash), got $hash). Nothing was installed."
        }
        Write-Ok 'SHA256 verified'

        Write-Step "Installing to $appDir"
        $staged = Join-Path $work 'app'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staged)
        if (-not (Test-Path -LiteralPath (Join-Path $staged 'WinSenior.Gui.ps1'))) {
            throw 'The release zip does not contain WinSenior.Gui.ps1.'
        }
        # (WebClient + ZipFile never write a Mark-of-the-Web, so no Unblock-File is needed;
        # WinSenior.cmd unblocks again on every start anyway.)
        if (-not (Test-Path -LiteralPath $InstallRoot)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
        # Copy the new files next to the target FIRST (same volume - a directory move across
        # drives fails on Windows PowerShell 5.1), and only then swap: the old version is
        # never removed before the new one is complete on disk.
        $next = Join-Path $InstallRoot 'app.new'
        if (Test-Path -LiteralPath $next) { Remove-Item -LiteralPath $next -Recurse -Force }
        Copy-Item -LiteralPath $staged -Destination $next -Recurse -Force
        # Renaming fails as a whole while a file inside is open, so the old app stays intact.
        $oldName = 'app.old-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8)
        $hadOld = Test-Path -LiteralPath $appDir
        if ($hadOld) {
            try { Rename-Item -LiteralPath $appDir -NewName $oldName -ErrorAction Stop }
            catch {
                Remove-Item -LiteralPath $next -Recurse -Force -ErrorAction SilentlyContinue
                throw "Close Windows Senior first - the old version is in use ($($_.Exception.Message))."
            }
        }
        Rename-Item -LiteralPath $next -NewName (Split-Path $appDir -Leaf)
        if ($hadOld) { Remove-Item -LiteralPath (Join-Path $InstallRoot $oldName) -Recurse -Force -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $InstallRoot -Directory -Filter 'app.old-*' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok 'Installed'
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $NoShortcut) {
        foreach ($l in (Get-ShortcutPath)) {
            try { New-WinSeniorShortcut -Path $l -AppDir $appDir } catch { Write-Verbose "shortcut $l : $($_.Exception.Message)" }
        }
        Write-Ok 'Shortcuts: Start menu + desktop ("Windows Senior")'
    }

    if (-not $NoLaunch) {
        Write-Step 'Starting Windows Senior (confirm the Administrator prompt)'
        $cmdArgs = if ($Console) { '/c ""{0}" console"' -f (Join-Path $appDir 'WinSenior.cmd') }
                   else { '/c ""{0}""' -f (Join-Path $appDir 'WinSenior.cmd') }
        Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList $cmdArgs -WindowStyle Hidden
    }
    Write-Host ''
    Write-Host 'Done. Next time open "Windows Senior" from the Start menu or the desktop.' -ForegroundColor Green
    Write-Host 'Run the same one-liner again to update.' -ForegroundColor DarkGray
}

try { Invoke-WinSeniorInstall }
catch { Write-Bad $_.Exception.Message; Write-Host '    Nothing else was changed.' -ForegroundColor DarkGray }
} @args
