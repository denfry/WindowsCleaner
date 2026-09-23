<#
.SYNOPSIS
    Startup-apps library for WinSenior: list autostart entries and enable/disable
    them exactly the way Task Manager does.

.DESCRIPTION
    Dot-sourced by the desktop app. Reads the classic autostart locations

      - HKCU  ...\CurrentVersion\Run
      - HKLM  ...\CurrentVersion\Run
      - HKLM  WOW6432Node\...\CurrentVersion\Run   (32-bit apps on 64-bit Windows)
      - the per-user and the common (all users) Startup folders

    and reports whether each entry is enabled from the matching
    Explorer\StartupApproved\{Run,Run32,StartupFolder} binary value.

    Toggling an entry writes ONLY that StartupApproved value - the Run entry or the
    shortcut itself is never touched or deleted - so every change is fully reversible
    and shows up identically in Task Manager's Startup tab.

    StartupApproved value format (12 bytes): the first byte is the state
    (0x02 / 0x06 = enabled, 0x03 / 0x07 = disabled - bit 0 set means disabled); the
    last 8 bytes of a disabled entry hold the FILETIME when it was disabled. No value
    at all means enabled.

    Registry roots and folders are parameters, so the tests run against a throwaway
    HKCU key and a temp folder and never touch the real Run keys.

    Source stays pure ASCII so it loads identically under Windows PowerShell 5.1.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.3.0
#>

# =====================================================================
# LOCATIONS (injectable roots)
# =====================================================================
function Get-WinSeniorStartupLocation {
    param(
        # Stand-in for HKCU:\Software (tests pass a temporary HKCU key).
        [string]$UserRoot = 'HKCU:\Software',
        # Stand-in for HKLM:\SOFTWARE.
        [string]$MachineRoot = 'HKLM:\SOFTWARE',
        [string]$UserStartupFolder = [Environment]::GetFolderPath('Startup'),
        [string]$CommonStartupFolder = [Environment]::GetFolderPath('CommonStartup')
    )
    $run  = 'Microsoft\Windows\CurrentVersion\Run'
    $appr = 'Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $u = $UserRoot.TrimEnd('\'); $m = $MachineRoot.TrimEnd('\')
    @(
        [pscustomobject]@{ Location = 'HKCU Run'; Scope = 'Current user'; Kind = 'Registry'
                           Path = "$u\$run"; ApprovedKey = "$u\$appr\Run" }
        [pscustomobject]@{ Location = 'HKLM Run'; Scope = 'All users'; Kind = 'Registry'
                           Path = "$m\$run"; ApprovedKey = "$m\$appr\Run" }
        [pscustomobject]@{ Location = 'HKLM Run (32-bit)'; Scope = 'All users'; Kind = 'Registry'
                           Path = "$m\WOW6432Node\$run"; ApprovedKey = "$m\$appr\Run32" }
        [pscustomobject]@{ Location = 'Startup folder'; Scope = 'Current user'; Kind = 'Folder'
                           Path = $UserStartupFolder; ApprovedKey = "$u\$appr\StartupFolder" }
        [pscustomobject]@{ Location = 'Common Startup folder'; Scope = 'All users'; Kind = 'Folder'
                           Path = $CommonStartupFolder; ApprovedKey = "$m\$appr\StartupFolder" }
    ) | Where-Object { $_.Path }
}

# =====================================================================
# REGISTRY ACCESS (.NET, so value names with * ? [ ] are taken literally)
# =====================================================================
function Resolve-WsRegistryPath {
    # 'HKCU:\Software\X' / 'HKEY_CURRENT_USER\Software\X' / 'Registry::HKLM\X'
    #  -> @{ Hive = <RegistryKey>; SubKey = 'Software\X' }
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path -replace '^(Microsoft\.PowerShell\.Core\\)?Registry::', ''
    if ($p -notmatch '^(?<hive>[^:\\]+):?\\?(?<sub>.*)$') { throw "Unsupported registry path: $Path" }
    $sub = $Matches.sub   # capture now: switch -Regex below overwrites $Matches
    $hive = switch -Regex ($Matches.hive) {
        '^(HKCU|HKEY_CURRENT_USER)$'  { [Microsoft.Win32.Registry]::CurrentUser }
        '^(HKLM|HKEY_LOCAL_MACHINE)$' { [Microsoft.Win32.Registry]::LocalMachine }
        '^(HKU|HKEY_USERS)$'          { [Microsoft.Win32.Registry]::Users }
        default { throw "Unsupported registry hive in: $Path" }
    }
    @{ Hive = $hive; SubKey = $sub.TrimEnd('\') }
}

function Open-WsRegistryKey {
    param([Parameter(Mandatory)][string]$Path, [switch]$Writable, [switch]$Create)
    $r = Resolve-WsRegistryPath $Path
    if ($Create) { return $r.Hive.CreateSubKey($r.SubKey) }
    $r.Hive.OpenSubKey($r.SubKey, [bool]$Writable)
}

# =====================================================================
# PURE HELPERS
# =====================================================================
# StartupApproved bytes -> $true (enabled) / $false (disabled). Missing = enabled.
function ConvertFrom-StartupApprovedValue {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return $true }
    # 0x02 / 0x06 enabled, 0x03 / 0x07 disabled: bit 0 is the "disabled" flag.
    (($Bytes[0] -band 1) -eq 0)
}

# The 12-byte value Task Manager writes. Disabled entries carry the FILETIME of the change.
function ConvertTo-StartupApprovedValue {
    param([Parameter(Mandatory)][bool]$Enabled, [datetime]$When = (Get-Date))
    $b = New-Object byte[] 12
    if ($Enabled) { $b[0] = 2 }
    else {
        $b[0] = 3
        [BitConverter]::GetBytes($When.ToFileTimeUtc()).CopyTo($b, 4)
    }
    , $b
}

# Executable path out of a Run command line: '"C:\a b\x.exe" /min' -> 'C:\a b\x.exe'.
function Get-WinSeniorStartupTarget {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) { return $c.Substring(1, $end - 1) }
        return $c.Trim('"')
    }
    $m = [regex]::Match($c, '^(?<p>.+?\.(exe|com|bat|cmd|lnk|vbs|vbe|js|jse|wsf|ps1|msc|scr|cpl))(\s|,|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups['p'].Value }
    ($c -split '\s+', 2)[0]
}

# =====================================================================
# QUERY
# =====================================================================
function Get-WsStartupApproval {
    param([string]$ApprovedKey, [string]$Name)
    $k = $null
    try {
        $k = Open-WsRegistryKey -Path $ApprovedKey
        if (-not $k) { return $null }
        $v = $k.GetValue($Name, $null)
        if ($v -is [byte[]]) { return , $v }
        return $null
    }
    catch { return $null }
    finally { if ($k) { $k.Close() } }
}

function Get-WsShortcutCommand {
    param([string]$Path)
    if ($Path -notlike '*.lnk') { return $Path }
    try {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($Path)
        $t = [string]$lnk.TargetPath
        if (-not $t) { return $Path }
        $cmd = if ($t -match '\s') { '"' + $t + '"' } else { $t }
        if ($lnk.Arguments) { $cmd += ' ' + $lnk.Arguments }
        $cmd
    }
    catch { $Path }
}

function Get-WinSeniorStartupItem {
    param(
        # Output of Get-WinSeniorStartupLocation (inject test roots there).
        [object[]]$Locations = (Get-WinSeniorStartupLocation)
    )
    foreach ($loc in $Locations) {
        $entries = @()
        if ($loc.Kind -eq 'Registry') {
            $k = $null
            try {
                $k = Open-WsRegistryKey -Path $loc.Path
                if ($k) {
                    $entries = foreach ($n in $k.GetValueNames()) {
                        if ([string]::IsNullOrEmpty($n)) { continue }
                        [pscustomobject]@{ Name = $n; Command = [string]$k.GetValue($n); File = $null }
                    }
                }
            }
            catch { $entries = @() }
            finally { if ($k) { $k.Close() } }
        }
        elseif ($loc.Kind -eq 'Folder' -and (Test-Path -LiteralPath $loc.Path -PathType Container)) {
            $entries = Get-ChildItem -LiteralPath $loc.Path -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'desktop.ini' } |
                ForEach-Object { [pscustomobject]@{ Name = $_.Name; Command = (Get-WsShortcutCommand $_.FullName); File = $_.FullName } }
        }
        foreach ($e in @($entries)) {
            $bytes  = Get-WsStartupApproval -ApprovedKey $loc.ApprovedKey -Name $e.Name
            $target = Get-WinSeniorStartupTarget $e.Command
            $exists = $null
            if ($target -and [IO.Path]::IsPathRooted($target)) { $exists = Test-Path -LiteralPath $target }
            [pscustomobject]@{
                Name         = $e.Name
                Command      = $e.Command
                Location     = $loc.Location
                Scope        = $loc.Scope
                Kind         = $loc.Kind
                Source       = $loc.Path
                File         = $e.File
                ApprovedKey  = $loc.ApprovedKey
                Enabled      = (ConvertFrom-StartupApprovedValue $bytes)
                Target       = $target
                TargetExists = $exists
            }
        }
    }
}

# =====================================================================
# CHANGE (StartupApproved only - reversible, never deletes the entry)
# =====================================================================
function Set-WinSeniorStartupItemState {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $verb = if ($Enabled) { 'Enable startup entry' } else { 'Disable startup entry' }
    if (-not $PSCmdlet.ShouldProcess("$($Item.Location): $($Item.Name)", $verb)) { return $Item }
    $k = $null
    try {
        $k = Open-WsRegistryKey -Path $Item.ApprovedKey -Create
        if (-not $k) { throw "Cannot open $($Item.ApprovedKey)" }
        $k.SetValue($Item.Name, [byte[]](ConvertTo-StartupApprovedValue -Enabled $Enabled), [Microsoft.Win32.RegistryValueKind]::Binary)
    }
    finally { if ($k) { $k.Close() } }
    $Item.Enabled = $Enabled
    $Item
}

# Plural name kept as an alias for callers that expect it.
Set-Alias -Name Get-WinSeniorStartupItems -Value Get-WinSeniorStartupItem -Scope Script
