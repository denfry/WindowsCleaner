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
        ... -Uninstall       remove the app folder and the shortcuts

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
        Join-Path $env:LOCALAPPDATA 'WinSenior' })
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
        if (Test-Path -LiteralPath $appDir) {
            try { Remove-Item -LiteralPath $appDir -Recurse -Force }
            catch { throw "Close Windows Senior first - the old version is in use ($($_.Exception.Message))." }
        }
        Move-Item -LiteralPath $staged -Destination $appDir
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
