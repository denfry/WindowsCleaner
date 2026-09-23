<#
.SYNOPSIS
    Windows troubleshooting engine - scans for common problems, then repairs them.

.DESCRIPTION
    A declarative, single-file Windows 10/11 diagnostics tool. Every check is one entry in
    a check registry: a read-only Scan that returns OK / Warn / Fail, and an optional Fix.
    The default flow is scan-then-choose: it scans (changing nothing), prints a health
    report, and lets you pick which detected issues to repair. Fixes run through
    PowerShell's ShouldProcess (so -WhatIf is real) after a real System Restore point.
    After every fix the check is scanned again, and it only counts as Fixed when the
    re-scan comes back OK.

    Heavy repairs (SFC, DISM RestoreHealth, network stack reset) are included but only
    run when you explicitly select them (or pass -FixAll -IncludeHeavy).
    Repairs only ever improve health - this engine enables Defender, the firewall and
    UAC, it never disables them.

    Scans are read-only, locale-independent (CIM / registry / .NET / exit codes / enum
    names - never localized command output) and every network probe has a timeout.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.3.0
    Requires: PowerShell 5.1+ (Windows). Administrator rights.

.EXAMPLE
    .\Repair-Windows-Senior.ps1
    Scan, show the report, then choose what to repair.

.EXAMPLE
    .\Repair-Windows-Senior.ps1 -ScanOnly
    Diagnose only - never change anything.

.EXAMPLE
    .\Repair-Windows-Senior.ps1 -FixAll -IncludeHeavy -Unattended
    Scan and auto-apply every fixable issue, including heavy repairs.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    # Limit to these categories: Integrity, Disk, Update, Network, Devices, Services, Security, System
    [AllowEmptyString()][AllowEmptyCollection()]
    [string[]]$Category,

    # Run only these check ids (or add them to -Category). Comma-joined strings are accepted.
    [AllowEmptyString()][AllowEmptyCollection()]
    [string[]]$Include,
    # Force these check ids off. Comma-joined strings are accepted.
    [AllowEmptyString()][AllowEmptyCollection()]
    [string[]]$Exclude,

    # Scan and report only - never offer or apply fixes
    [switch]$ScanOnly,

    # Non-interactive: after scanning, auto-apply fixable issues (Safe+Moderate)
    [switch]$FixAll,

    # With -FixAll, also auto-apply Aggressive (heavy / reboot) repairs
    [switch]$IncludeHeavy,

    # Cap every fix path at Safe + Moderate (skip Aggressive), even with -IncludeHeavy
    [Alias('SafeMode')]
    [switch]$Conservative,

    [Alias('dr')]
    [switch]$DryRun,

    # No prompts. On its own it only scans and reports; add -FixAll to repair.
    [Alias('Force','f')]
    [switch]$Unattended,

    [Alias('nrp')]
    [switch]$NoRestorePoint,

    [string]$LogPath = "$env:TEMP\WindowsRepair.log",

    [string]$ReportPath,

    [switch]$ListChecks,

    [switch]$Help
)

# =====================================================================
# SCRIPT STATE
# =====================================================================
$script:StartTime        = Get-Date
$script:Results          = New-Object System.Collections.Generic.List[object]
$script:Fixed            = 0
$script:PendingReboot    = 0
$script:StillFailing     = 0
$script:Previewed        = 0
$script:FixErrors        = 0
$script:RebootNeeded     = $false
$script:FixNeedsReboot   = $false   # set by a Fix scriptblock that needs a restart to finish
$script:RestorePointMade = $false
$script:RepNcsiCache     = $null
$script:RepNetScanState  = $null
$script:RepLicenseJob    = $null

if ($DryRun) { $WhatIfPreference = $true }

# =====================================================================
# SHARED LIBRARY (admin / restore-point / logging / format helpers)
# =====================================================================
. (Join-Path $PSScriptRoot 'WinSenior.Common.ps1')

# =====================================================================
# LOGGING / UTIL
# =====================================================================
function Write-RepLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug','Step','WhatIf','Safety')]
        [string]$Level = 'Info'
    )
    Write-WsLog -Message $Message -Level $Level -LogPath $LogPath
}

function New-RepairRestorePoint {
    $st = New-WinSeniorRestorePoint `
        -Description "Before Windows Repair $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        -LogAction { param($m, $l) Write-RepLog $m $l }
    if ($st -eq 'Created') { $script:RestorePointMade = $true }
    return ($st -ne 'Failed')
}

# Splits comma-joined ids ("a,b" arrives as ONE element through powershell -File),
# trims them and drops empties, so -Include/-Exclude '' is harmless.
function ConvertTo-RepIdList {
    param([string[]]$Value)
    @($Value | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Registry value or $null (never throws). REG_BINARY / REG_MULTI_SZ come back intact (not unrolled).
function Get-RepRegValue {
    param([string]$Path, [string]$Name)
    try { $v = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
    if ($v -is [array]) { , $v } else { $v }
}

function Get-RepBackupDir {
    $d = Join-Path $env:ProgramData 'WinSenior\backups'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -WhatIf:$false | Out-Null }
    $d
}

function Test-RepPartOfDomain {
    [bool](Get-CimInstance Win32_ComputerSystem -Property PartOfDomain -ErrorAction SilentlyContinue).PartOfDomain
}

function Test-RepMdmEnrolled {
    foreach ($k in (Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue)) {
        if ((Get-RepRegValue $k.PSPath 'ProviderID') -eq 'MS DM Server') { return $true }
    }
    $false
}

# Restores a service start type; falls back to the registry Start value when the
# service ACL denies Set-Service (DoSvc, WaaSMedicSvc...). Returns how it was written.
function Restore-RepServiceStart {
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('Automatic','Manual')][string]$StartType = 'Manual')
    try { Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop; return 'Set-Service' }
    catch {
        $v = if ($StartType -eq 'Automatic') { 2 } else { 3 }
        Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value $v -Type DWord -ErrorAction Stop
        return 'registry'
    }
}

# Runs a script in a separate runspace with a hard timeout (COM calls can hang).
function Invoke-RepWithTimeout {
    param([Parameter(Mandatory)][string]$ScriptText, [int]$TimeoutSec = 20)
    $ps = [powershell]::Create()
    $h = $null
    try {
        [void]$ps.AddScript($ScriptText)
        $h = $ps.BeginInvoke()
        if (-not $h.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
            [void]$ps.BeginStop($null, $null)
            throw "timed out after $TimeoutSec s"
        }
        $out = $ps.EndInvoke($h)
        if ($ps.Streams.Error.Count) { throw $ps.Streams.Error[0].Exception }
        @($out)
    }
    finally { if ($h -and $h.IsCompleted) { $ps.Dispose() } }
}

# NCSI probe (the same URL Windows uses). Cached for 60 s so net + time checks share it.
function Get-RepNcsiProbe {
    param([switch]$Fresh)
    if (-not $Fresh -and $script:RepNcsiCache -and ((Get-Date) - $script:RepNcsiCache.At).TotalSeconds -lt 60) {
        return $script:RepNcsiCache
    }
    $res = @{ At = Get-Date; Ok = $false; ServerTime = $null; LocalTime = $null; Error = $null }
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # 5.1 progress bar slows Invoke-WebRequest badly
    try {
        $t0 = [DateTimeOffset]::UtcNow
        $r  = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $t1 = [DateTimeOffset]::UtcNow
        $res.LocalTime = $t0.AddTicks([long](($t1 - $t0).Ticks / 2))
        $res.Ok = ("$($r.Content)".Trim() -eq 'Microsoft Connect Test')
        $d = @($r.Headers['Date'])[0]   # string in 5.1, string[] in 7
        if ($d) { $res.ServerTime = [DateTimeOffset]::Parse("$d", [Globalization.CultureInfo]::InvariantCulture) }
    }
    catch { $res.Error = $_.Exception.Message }
    finally { $ProgressPreference = $oldProgress }
    $script:RepNcsiCache = $res
    $res
}

# Internet / DNS state. OK | DnsFail | ProbeBlocked | Offline
function Get-RepNetState {
    param([switch]$Fresh)
    $inet = $false
    try {
        $inet = [bool](Get-NetConnectionProfile -ErrorAction Stop | Where-Object {
            "$($_.IPv4Connectivity)" -eq 'Internet' -or "$($_.IPv6Connectivity)" -eq 'Internet' })
    } catch { $inet = $false }
    $probe = Get-RepNcsiProbe -Fresh:$Fresh
    # System resolver with a hard 5 s cap (Resolve-DnsName -QuickTimeout still took 8 s and
    # failed spuriously with a slow secondary DNS server; this is what applications see).
    $dns = $false
    try {
        $ar = [System.Net.Dns]::BeginGetHostAddresses('www.microsoft.com', $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(5000)) { $dns = [bool]@([System.Net.Dns]::EndGetHostAddresses($ar)).Count }
    } catch { $dns = $false }
    $state = if ($probe.Ok -and $dns) { 'OK' }
             elseif ($probe.Ok)       { 'DnsFail' }
             elseif ($dns -and $inet) { 'ProbeBlocked' }
             elseif ($inet)           { 'DnsFail' }
             else                     { 'Offline' }
    @{ State = $state; Internet = $inet; Probe = $probe.Ok; Dns = $dns }
}

# Defender mode: passive when a third-party AV owns real-time protection.
function Get-RepDefenderMode {
    $res = @{ Present = $false; Passive = $false; Mode = ''; ThirdParty = @(); Status = $null }
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) { return $res }
    try { $st = Get-MpComputerStatus -ErrorAction Stop } catch { return $res }
    $res.Present = $true
    $res.Status  = $st
    $res.Mode    = "$($st.AMRunningMode)"
    $res.Passive = [bool]($res.Mode -and $res.Mode -ne 'Normal')
    # Defender registers with pathToSignedProductExe 'windowsdefender://' (display names are localized).
    $res.ThirdParty = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
        Where-Object { "$($_.pathToSignedProductExe)" -notmatch '^windowsdefender:' } | ForEach-Object { "$($_.displayName)" })
    $res
}

# True when a hosts line maps a Windows Update / Defender / activation / NCSI host.
function Test-RepHostsHijackLine {
    param([string]$Line)
    $l = ("$Line" -replace '#.*$', '').Trim()
    if (-not $l) { return $false }
    $tok = @($l -split '\s+')
    if ($tok.Count -lt 2) { return $false }
    $pat = '(?i)(^|\.)(windowsupdate\.com|windowsupdate\.microsoft\.com|update\.microsoft\.com|delivery\.mp\.microsoft\.com|' +
           'wustat\.windows\.com|ntservicepack\.microsoft\.com|wdcp\.microsoft\.com|wdcpalt\.microsoft\.com|wd\.microsoft\.com|' +
           'definitionupdates\.microsoft\.com|smartscreen\.microsoft\.com|smartscreen-prod\.microsoft\.com|sls\.microsoft\.com|' +
           'licensing\.mp\.microsoft\.com|msftncsi\.com|msftconnecttest\.com)\.?$'
    foreach ($h in $tok[1..($tok.Count - 1)]) { if ($h -match $pat) { return $true } }
    $false
}

# Windows Update HRESULT -> the check that addresses it (pure; accepts int or '0x...' string).
function Get-WuErrorRoute {
    param($HResult)
    if ($null -eq $HResult -or "$HResult" -eq '') { return $null }
    if ($HResult -is [string]) {
        $hex = ($HResult.Trim() -replace '^0[xX]', '').ToUpperInvariant().PadLeft(8, '0')
    } else {
        $hex = '{0:X8}' -f ([int64]$HResult -band [int64]4294967295)
    }
    $map = @{
        '800F081F' = 'img-health'; '800F0831' = 'img-health'; '80073712' = 'img-health'; '80073701' = 'img-health'
        '8007371B' = 'img-health'; '80070570' = 'img-health'; '800F0825' = 'img-health'
        '80070643' = 'winre'
        '80070422' = 'svc-defaults'
        '8024401B' = 'net-connectivity/proxy-hijack'; '80244022' = 'net-connectivity/proxy-hijack'
        '80072EE2' = 'net-connectivity/proxy-hijack'; '80072EFD' = 'net-connectivity/proxy-hijack'
        '80072EFE' = 'net-connectivity/proxy-hijack'
        '80242006' = 'wu-health'; '8007000D' = 'wu-health'
        '80070BC9' = 'reboot-pending'; '80242014' = 'reboot-pending'
        '80070070' = 'disk-space'
        '80072F8F' = 'time-sync'
    }
    $map[$hex]
}

# Appx package state for the current user. Get-AppxPackage cannot load under pwsh 7
# (and -ErrorAction SilentlyContinue does not catch that), so route through powershell.exe.
function Get-RepAppxState {
    param([string[]]$Name)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $list = ($Name | ForEach-Object { "'$_'" }) -join ','
        $cmd  = "`$ProgressPreference = 'SilentlyContinue'; @(foreach (`$n in @($list)) { Get-AppxPackage -Name `$n -ErrorAction SilentlyContinue | Select-Object -First 1 | " +
                "ForEach-Object { [pscustomobject]@{ Name = `$_.Name; Status = [string]`$_.Status } } }) | ConvertTo-Json -Compress"
        $enc  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        $json = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $enc 2>$null
        if ($LASTEXITCODE -ne 0) { throw "powershell.exe exited $LASTEXITCODE" }
        $txt = ($json -join '').Trim()
        if (-not $txt) { return @() }
        return @($txt | ConvertFrom-Json)
    }
    foreach ($n in $Name) {
        Get-AppxPackage -Name $n -ErrorAction Stop | Select-Object -First 1 |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = [string]$_.Status } }
    }
}

# Provider DLL paths from the Winsock catalog (PackedCatalogItem starts with an ANSI path).
function Get-RepWinsockProvider {
    $ansi = try { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { [Text.Encoding]::ASCII }
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinSock2\Parameters\Protocol_Catalog9'
    foreach ($sub in 'Catalog_Entries', 'Catalog_Entries64') {
        foreach ($k in (Get-ChildItem -LiteralPath "$base\$sub" -ErrorAction SilentlyContinue)) {
            $bytes = Get-RepRegValue $k.PSPath 'PackedCatalogItem'
            if ($bytes -isnot [byte[]]) { continue }
            $end = [Array]::IndexOf($bytes, [byte]0)
            if ($end -le 0) { continue }
            $raw  = $ansi.GetString($bytes, 0, $end)
            $path = [Environment]::ExpandEnvironmentVariables($raw)
            $ok   = (Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath ($path -replace '(?i)\\system32\\', '\SysWOW64\'))
            [pscustomobject]@{ Catalog = $sub; Path = $raw; Exists = $ok }
        }
    }
}

# Windows LicenseStatus via ONE SoftwareLicensingProduct query. The licensing provider
# needs ~30 s cold, so the main flow starts it in a background runspace before the scan
# loop (Invoke-RepLicensePrefetch) and the activation check only collects the answer.
function Invoke-RepLicensePrefetch {
    if ($script:RepLicenseJob) { return }
    $q = "Get-CimInstance -ClassName SoftwareLicensingProduct -Property LicenseStatus -OperationTimeoutSec 60 -ErrorAction Stop " +
         "-Filter `"ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL`" | ForEach-Object { [int]`$_.LicenseStatus }"
    $ps = [powershell]::Create()
    [void]$ps.AddScript($q)
    $script:RepLicenseJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
}

function Get-RepLicenseStatus {
    param([int]$TimeoutSec = 45)
    if (-not $script:RepLicenseJob) { Invoke-RepLicensePrefetch }
    $j = $script:RepLicenseJob
    $script:RepLicenseJob = $null
    $left = [math]::Max(0, $TimeoutSec - ((Get-Date) - $j.Started).TotalSeconds)
    if (-not $j.Handle.AsyncWaitHandle.WaitOne([int]($left * 1000))) {
        [void]$j.PS.BeginStop($null, $null)
        throw "licensing service did not answer within $TimeoutSec s"
    }
    try {
        $out = $j.PS.EndInvoke($j.Handle)
        if ($j.PS.Streams.Error.Count) { throw $j.PS.Streams.Error[0].Exception }
        @($out)
    }
    finally { $j.PS.Dispose() }
}

function Test-RepInteractiveUser {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $console = (Get-CimInstance Win32_ComputerSystem -Property UserName -ErrorAction SilentlyContinue).UserName
    @{ Ok = [bool]($console -and $console -eq $me); Console = $console; Me = $me }
}

# svc-defaults table: services whose Start=4 breaks Windows, and their default start type.
function Get-RepServiceDefault {
    $auto = 'CryptSvc', 'AudioEndpointBuilder', 'Audiosrv', 'WSearch', 'WlanSvc'
    $lvl  = [ordered]@{
        Fail = 'wuauserv', 'BITS', 'CryptSvc', 'msiserver', 'AppXSvc'
        # WSearch is deliberately absent: Optimize (perf-wsearch) may disable it on purpose.
        Warn = 'ClipSVC', 'TrustedInstaller', 'DoSvc', 'UsoSvc', 'W32Time', 'AudioEndpointBuilder', 'Audiosrv',
               'InstallService', 'StateRepository', 'TokenBroker', 'WlanSvc'
    }
    foreach ($level in $lvl.Keys) {
        foreach ($n in $lvl[$level]) {
            [pscustomobject]@{ Name = $n; Level = $level; Default = $(if ($auto -contains $n) { 'Automatic' } else { 'Manual' }) }
        }
    }
}

# =====================================================================
# CHECK REGISTRY  (the single source of truth)
#   Scan returns @{ Status = 'OK'|'Warn'|'Fail'|'Skip'; Detail = '...' } and may add
#   per-result overrides: NoFix = $true (fix does not apply to this finding),
#   FixRisk / FixLabel / Reboot (e.g. a DNS-only failure only needs a Safe flush).
#   A Fix may set $script:FixNeedsReboot = $true when it needs a restart to finish.
# =====================================================================
function New-DiagnosticCheck {
    param(
        [string]$Id, [string]$Name, [string]$Category,
        [scriptblock]$Scan, [scriptblock]$Fix,
        [string]$FixRisk = 'Safe', [string]$FixLabel, [bool]$Reboot = $false
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Category = $Category
        Scan = $Scan; Fix = $Fix; FixRisk = $FixRisk; FixLabel = $FixLabel; Reboot = $Reboot
    }
}

function Get-DiagnosticCheckRegistry {
    @(
        # ================= Integrity =================
        New-DiagnosticCheck -Id img-health -Name 'System image health (DISM)' -Category Integrity `
            -Scan {
                if (-not (Get-Command Repair-WindowsImage -ErrorAction SilentlyContinue)) {
                    return @{ Status = 'Skip'; Detail = 'DISM module unavailable' }
                }
                $state = (Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState
                switch ("$state") {
                    'Healthy'       { @{ Status = 'OK';   Detail = 'Component store healthy' } }
                    'Repairable'    { @{ Status = 'Fail'; Detail = 'Component store corruption is repairable' } }
                    'NonRepairable' { @{ Status = 'Fail'; NoFix = $true
                                         Detail = 'Component store is NOT repairable - do an in-place upgrade (run setup.exe from a Windows ISO, keep files and apps)' } }
                    default         { @{ Status = 'Warn'; Detail = "Image health: $state (deep scan with DISM /ScanHealth)" } }
                }
            } `
            -Fix {
                Write-RepLog 'Running DISM /RestoreHealth (may take several minutes)...' 'Info'
                & dism.exe /Online /Cleanup-Image /RestoreHealth /NoRestart | Out-Null
                $dismExit = $LASTEXITCODE
                if ($dismExit -eq 3010) { $script:FixNeedsReboot = $true }
                Write-RepLog 'Running sfc /scannow...' 'Info'
                & sfc.exe /scannow | Out-Null
                Write-RepLog ("sfc exit code {0}" -f $LASTEXITCODE) 'Debug'
                if ($dismExit -notin 0, 3010) { throw ("DISM RestoreHealth failed (exit 0x{0:X8})" -f $dismExit) }
            } -FixRisk Aggressive -FixLabel 'DISM RestoreHealth + SFC'

        # ================= Disk =================
        New-DiagnosticCheck -Id disk-smart -Name 'Physical disk health (SMART)' -Category Disk `
            -Scan {
                if (-not (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                    return @{ Status = 'Skip'; Detail = 'Storage module unavailable' }
                }
                $bad = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.HealthStatus -and "$($_.HealthStatus)" -ne 'Healthy' }
                if ($bad) { @{ Status = 'Fail'; Detail = ('Unhealthy disk(s): ' + (($bad | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)" }) -join ', ') + ' - back up now') } }
                else      { @{ Status = 'OK';   Detail = 'All physical disks report Healthy' } }
            } -Fix $null

        New-DiagnosticCheck -Id disk-space -Name 'Low free disk space' -Category Disk `
            -Scan {
                $worst = 'OK'; $lines = @()
                foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
                    if (-not $d.Size) { continue }
                    $pct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
                    $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
                    $lines += "$($d.DeviceID) $freeGB GB free ($pct%)"
                    if ($d.DeviceID -eq $env:SystemDrive) {
                        # System drive: absolute limits (updates / pagefile / hibernation need GBs, not %).
                        if ($freeGB -lt 5)       { $worst = 'Fail' }
                        elseif ($freeGB -lt 15 -and $worst -ne 'Fail') { $worst = 'Warn' }
                    }
                    elseif ($pct -lt 5 -and $worst -ne 'Fail') { $worst = 'Warn' }
                }
                @{ Status = $worst; Detail = ($lines -join ' | ') + $(if ($worst -ne 'OK') { ' - run Disk cleanup' } else { '' }) }
            } -Fix $null

        New-DiagnosticCheck -Id disk-dirty -Name 'File system errors (dirty bit / NTFS / disk events)' -Category Disk `
            -Scan {
                $dirty = @(Get-CimInstance Win32_Volume -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Where-Object DirtyBitSet |
                    ForEach-Object { if ($_.DriveLetter) { $_.DriveLetter } elseif ($_.Label) { $_.Label } else { $_.DeviceID } })
                $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 55, 98, 7, 153; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 200 -ErrorAction SilentlyContinue |
                    Where-Object { ($_.Id -in 55, 98 -and $_.ProviderName -match 'Ntfs') -or ($_.Id -in 7, 153 -and $_.ProviderName -eq 'disk') })
                $ntfs = @($ev | Where-Object { $_.Id -in 55, 98 }).Count
                $io   = @($ev | Where-Object { $_.Id -in 7, 153 }).Count
                if ($dirty.Count) { @{ Status = 'Fail'; Detail = ('Dirty bit set on: ' + ($dirty -join ', ') + " (NTFS events 7d: $ntfs, disk I/O events 7d: $io)") } }
                elseif ($ev.Count) { @{ Status = 'Warn'; Detail = "No dirty volume, but in 7 days: $ntfs NTFS corruption event(s), $io disk bad-block/retry event(s)" } }
                else { @{ Status = 'OK'; Detail = 'No volume flagged dirty; no NTFS/disk error events in 7 days' } }
            } `
            -Fix {
                $failed = @()
                foreach ($v in (Get-CimInstance Win32_Volume -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Where-Object DriveLetter)) {
                    $dl = "$($v.DriveLetter)".TrimEnd(':')
                    try {
                        Write-RepLog "Repair-Volume ${dl}: -Scan (online)..." 'Info'
                        $r = Repair-Volume -DriveLetter $dl -Scan -ErrorAction Stop
                        if ("$r" -ne 'NoErrorsFound') {
                            Write-RepLog "  ${dl}: scan result $r - running -SpotFix" 'Warning'
                            $r2 = Repair-Volume -DriveLetter $dl -SpotFix -ErrorAction Stop
                            Write-RepLog "  ${dl}: spot fix result $r2" 'Info'
                        }
                        # autochk clears a dirty bit at the next boot.
                        $still = Get-CimInstance Win32_Volume -Filter "DriveLetter='${dl}:'" -ErrorAction SilentlyContinue
                        if ($still.DirtyBitSet) { $script:FixNeedsReboot = $true }
                    } catch { $failed += "${dl}: $($_.Exception.Message)" }
                }
                if ($failed) { throw ('Repair-Volume failed: ' + ($failed -join '; ')) }
            } -FixRisk Moderate -FixLabel 'Repair-Volume -Scan (online), -SpotFix if errors'

        New-DiagnosticCheck -Id disk-reliability -Name 'SSD wear & temperature' -Category Disk `
            -Scan {
                if (-not (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'Storage module unavailable' } }
                $worst = 'OK'; $lines = @()
                foreach ($pd in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                    $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                    if (-not $rc) { continue }
                    $parts = @()
                    if ($null -ne $rc.Wear) { $parts += "wear $($rc.Wear)%"; if ($rc.Wear -ge 90) { $worst = 'Fail' } elseif ($rc.Wear -ge 80 -and $worst -ne 'Fail') { $worst = 'Warn' } }
                    if ($rc.Temperature) {
                        # Use the drive's own rated maximum when it reports one.
                        if ($rc.TemperatureMax -gt 0) { $failAt = [int]$rc.TemperatureMax; $warnAt = $failAt - 10 }
                        else { $failAt = 80; $warnAt = 70 }
                        $parts += "$($rc.Temperature) C (max $failAt)"
                        if ($rc.Temperature -ge $failAt) { $worst = 'Fail' } elseif ($rc.Temperature -ge $warnAt -and $worst -ne 'Fail') { $worst = 'Warn' }
                    }
                    if ($rc.ReadErrorsUncorrected) { $worst = 'Fail'; $parts += "$($rc.ReadErrorsUncorrected) uncorrected" }
                    if ($parts.Count) { $lines += ("$($pd.FriendlyName): " + ($parts -join ', ')) }
                }
                if ($lines.Count -eq 0) { @{ Status = 'OK'; Detail = 'No reliability counters reported (HDD/USB/older SATA)' } }
                else                    { @{ Status = $worst; Detail = ($lines -join ' | ') } }
            } -Fix $null

        New-DiagnosticCheck -Id trim -Name 'SSD TRIM & scheduled optimization' -Category Disk `
            -Scan {
                $issues = @()
                $ddn = Get-RepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotification'
                $ssd = @()
                if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
                    $ssd = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.MediaType)" -eq 'SSD' })
                }
                if ($ddn -eq 1 -and $ssd.Count) { $issues += 'TRIM is disabled (DisableDeleteNotification=1) on a PC with an SSD' }
                if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
                    $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
                    if ($t -and "$($t.State)" -eq 'Disabled') { $issues += 'ScheduledDefrag (drive optimization / retrim) task is disabled' }
                }
                if ($issues) { @{ Status = 'Warn'; Detail = ($issues -join '; ') } }
                else { @{ Status = 'OK'; Detail = "TRIM enabled; drive optimization scheduled ($($ssd.Count) SSD)" } }
            } `
            -Fix {
                if ((Get-RepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotification') -eq 1) {
                    & fsutil.exe behavior set DisableDeleteNotify NTFS 0 *> $null
                    if ($LASTEXITCODE -ne 0) { throw "fsutil behavior set DisableDeleteNotify failed (exit $LASTEXITCODE)" }
                }
                $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
                if ($t -and "$($t.State)" -eq 'Disabled') {
                    Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop | Out-Null
                }
            } -FixRisk Safe -FixLabel 'Enable TRIM + scheduled drive optimization'

        # ================= Update =================
        New-DiagnosticCheck -Id reboot-pending -Name 'Pending reboot' -Category Update `
            -Scan {
                $reasons = @()
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
                $pfro = Get-RepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
                if ($reasons) { @{ Status = 'Warn'; Detail = ('Reboot required: ' + ($reasons -join ', ') + $(if ($pfro) { ' (+ pending file renames)' } else { '' })) } }
                elseif ($pfro) { @{ Status = 'OK'; Detail = 'Pending file renames queued (applied at next restart; no action needed)' } }
                else { @{ Status = 'OK'; Detail = 'No pending reboot' } }
            } `
            -Fix {
                # Never restart mid-run: just flag it so the summary / GUI tells the user.
                Write-RepLog 'Restart Windows to finish pending updates (not restarting automatically).' 'Warning'
                $script:FixNeedsReboot = $true
            } -FixRisk Safe -FixLabel 'Flag reboot required (no automatic restart)' -Reboot $true

        New-DiagnosticCheck -Id wu-health -Name 'Windows Update components' -Category Update `
            -Scan {
                $sd = "$env:WINDIR\SoftwareDistribution\Download"
                $sizeGB = 0
                if (Test-Path $sd) { $sizeGB = [math]::Round(((Get-ChildItem $sd -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 2) }
                $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
                if ($wu -and "$($wu.StartType)" -eq 'Disabled') { return @{ Status = 'Warn'; Detail = "wuauserv is Disabled; SoftwareDistribution $sizeGB GB" } }
                if ($sizeGB -gt 4) { return @{ Status = 'Warn'; Detail = "SoftwareDistribution cache is large ($sizeGB GB)" } }
                @{ Status = 'OK'; Detail = "Update cache $sizeGB GB; service OK" }
            } `
            -Fix {
                Write-RepLog 'Resetting Windows Update components...' 'Info'
                $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
                if ($wu -and "$($wu.StartType)" -eq 'Disabled') {
                    $via = Restore-RepServiceStart -Name wuauserv -StartType Manual
                    Write-RepLog "wuauserv set back to Manual (via $via)" 'Info'
                }
                foreach ($s in 'wuauserv', 'bits', 'cryptsvc') { Stop-Service $s -Force -ErrorAction SilentlyContinue }
                $stamp = Get-Date -Format 'yyyyMMddHHmmss'
                $errs = @()
                foreach ($p in @("$env:WINDIR\SoftwareDistribution", "$env:WINDIR\System32\catroot2")) {
                    $leaf = Split-Path $p -Leaf
                    if (Test-Path -LiteralPath $p) {
                        try { Rename-Item -LiteralPath $p -NewName "$leaf.old_$stamp" -Force -ErrorAction Stop }
                        catch { $errs += "${leaf}: $($_.Exception.Message)" }
                    }
                    # Keep only the newest .old_* backup.
                    Get-ChildItem -LiteralPath (Split-Path $p -Parent) -Directory -Filter "$leaf.old_*" -Force -ErrorAction SilentlyContinue |
                        Sort-Object Name -Descending | Select-Object -Skip 1 |
                        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                }
                foreach ($s in 'cryptsvc', 'bits', 'wuauserv') { Start-Service $s -ErrorAction SilentlyContinue }
                if ($errs) { throw ('Could not rename: ' + ($errs -join '; ')) }
            } -FixRisk Moderate -FixLabel 'Reset Windows Update (rename SoftwareDistribution/catroot2)'

        New-DiagnosticCheck -Id wu-policy -Name 'Windows Update blocked by policy' -Category Update `
            -Scan {
                $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
                $au  = "$pol\AU"
                $fail = @(); $warn = @()
                foreach ($n in 'DisableWindowsUpdateAccess', 'SetDisableUXWUAccess', 'DoNotConnectToWindowsUpdateInternetLocations') {
                    if ((Get-RepRegValue $pol $n) -eq 1) { $fail += "$n=1" }
                }
                $domain = Test-RepPartOfDomain
                $wsus = Get-RepRegValue $pol 'WUServer'
                if ($wsus -and (Get-RepRegValue $au 'UseWUServer') -eq 1 -and -not $domain) { $fail += "WSUS server '$wsus' on a non-domain PC" }
                if ((Get-RepRegValue $au 'NoAutoUpdate') -eq 1) { $warn += 'NoAutoUpdate=1' }
                $exp = Get-RepRegValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'PauseUpdatesExpiryTime'
                if ($exp) {
                    try {
                        $dt = [DateTime]::Parse("$exp", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal')
                        if ($dt -gt (Get-Date).ToUniversalTime().AddDays(35)) { $warn += "updates paused until $($dt.ToString('yyyy-MM-dd'))" }
                    } catch { Write-Verbose "PauseUpdatesExpiryTime unparsable: $exp" }
                }
                if (-not ($fail -or $warn)) { return @{ Status = 'OK'; Detail = 'No policy blocks Windows Update' } }
                $managed = $domain -or (Test-RepMdmEnrolled)
                $detail = (@($fail) + @($warn)) -join '; '
                if ($managed) { return @{ Status = 'Warn'; NoFix = $true; Detail = "$detail (domain/MDM-managed PC - left to the administrator)" } }
                @{ Status = $(if ($fail) { 'Fail' } else { 'Warn' }); Detail = $detail }
            } `
            -Fix {
                if ((Test-RepPartOfDomain) -or (Test-RepMdmEnrolled)) { throw 'Domain-joined or MDM-enrolled PC - Windows Update policy left to the administrator' }
                $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
                $au  = "$pol\AU"
                $ux  = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
                $dir = Get-RepBackupDir
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                foreach ($k in @(@{ Reg = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Tag = 'policy' },
                                 @{ Reg = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Tag = 'ux' })) {
                    if (Test-Path -LiteralPath "Registry::$($k.Reg)") {
                        $f = Join-Path $dir "wu-$($k.Tag)-$stamp.reg"
                        & reg.exe export $k.Reg $f /y *> $null
                        if ($LASTEXITCODE -ne 0) { throw "reg export $($k.Reg) failed (exit $LASTEXITCODE) - nothing changed" }
                        Write-RepLog "Backed up $($k.Reg) to $f" 'Info'
                    }
                }
                foreach ($n in 'DisableWindowsUpdateAccess', 'SetDisableUXWUAccess', 'DoNotConnectToWindowsUpdateInternetLocations') {
                    Remove-ItemProperty -LiteralPath $pol -Name $n -ErrorAction SilentlyContinue
                }
                if ((Get-RepRegValue $pol 'WUServer') -and (Get-RepRegValue $au 'UseWUServer') -eq 1) {
                    foreach ($n in 'WUServer', 'WUStatusServer') { Remove-ItemProperty -LiteralPath $pol -Name $n -ErrorAction SilentlyContinue }
                    Remove-ItemProperty -LiteralPath $au -Name 'UseWUServer' -ErrorAction SilentlyContinue
                }
                Remove-ItemProperty -LiteralPath $au -Name 'NoAutoUpdate' -ErrorAction SilentlyContinue
                $exp = Get-RepRegValue $ux 'PauseUpdatesExpiryTime'
                if ($exp) {
                    foreach ($n in 'PauseUpdatesExpiryTime', 'PauseUpdatesStartTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime',
                                   'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime') {
                        Remove-ItemProperty -LiteralPath $ux -Name $n -ErrorAction SilentlyContinue
                    }
                }
            } -FixRisk Moderate -FixLabel 'Back up + remove Windows Update blocking policies'

        New-DiagnosticCheck -Id wu-history -Name 'Windows Update install failures' -Category Update `
            -Scan {
                $wuScript = @'
$s = New-Object -ComObject Microsoft.Update.Session
$q = $s.CreateUpdateSearcher()
$n = $q.GetTotalHistoryCount()
if ($n -gt 0) {
    foreach ($e in $q.QueryHistory(0, [math]::Min($n, 50))) {
        [pscustomobject]@{ Date = $e.Date; ResultCode = [int]$e.ResultCode; HResult = [int]$e.HResult
                           Operation = [int]$e.Operation; UpdateId = [string]$e.UpdateIdentity.UpdateID; Title = [string]$e.Title }
    }
}
'@
                try { $hist = @(Invoke-RepWithTimeout -ScriptText $wuScript -TimeoutSec 20) }
                catch { return @{ Status = 'Warn'; Detail = "Update history unreadable ($($_.Exception.Message)) - history DB may be corrupt; see wu-health" } }
                $cut = (Get-Date).ToUniversalTime().AddDays(-30)
                $bad = foreach ($g in ($hist | Where-Object { $_.Operation -eq 1 -and $_.UpdateId } | Group-Object UpdateId)) {
                    $items = @($g.Group | Sort-Object Date)
                    $lastOk = @($items | Where-Object { $_.ResultCode -in 2, 3 } | Select-Object -Last 1)
                    $fails = @($items | Where-Object { $_.ResultCode -in 4, 5 -and $_.Date -gt $cut -and (-not $lastOk -or $_.Date -gt $lastOk[0].Date) })
                    if ($fails.Count) {
                        $last = $fails[-1]
                        $kb = if ($last.Title -match 'KB\d{6,8}') { $Matches[0] } else { $g.Name.Substring(0, 8) }
                        $hr = '0x{0:X8}' -f $last.HResult
                        [pscustomobject]@{ Kb = $kb; Count = $fails.Count; HResult = $hr; Route = (Get-WuErrorRoute $last.HResult) }
                    }
                }
                $bad = @($bad)
                if (-not $bad.Count) { return @{ Status = 'OK'; Detail = "$($hist.Count) history entr(ies); no unresolved install failures in 30 days" } }
                $txt = ($bad | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object {
                    "$($_.Kb) failed $($_.Count)x ($($_.HResult)$(if ($_.Route) { " -> check $($_.Route)" }))" }) -join '; '
                @{ Status = $(if ($bad | Where-Object { $_.Count -ge 3 }) { 'Fail' } else { 'Warn' }); Detail = $txt }
            } -Fix $null

        New-DiagnosticCheck -Id bits-health -Name 'BITS transfer queue' -Category Update `
            -Scan {
                if (-not (Get-Command Get-BitsTransfer -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'BITS module unavailable' } }
                $jobs  = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue)
                $err   = @($jobs | Where-Object { "$($_.JobState)" -eq 'Error' })
                $trans = @($jobs | Where-Object { "$($_.JobState)" -eq 'TransientError' }).Count
                if ($err.Count)             { @{ Status = 'Warn'; Detail = "$($err.Count) BITS job(s) in Error state ($trans transient - normal)" } }
                elseif ($jobs.Count -gt 50) { @{ Status = 'Warn'; NoFix = $true; Detail = "$($jobs.Count) BITS jobs queued (backlog)" } }
                else                        { @{ Status = 'OK';   Detail = "$($jobs.Count) BITS job(s); none in Error ($trans transient - normal)" } }
            } `
            -Fix {
                Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { "$($_.JobState)" -eq 'Error' } |
                    Remove-BitsTransfer -ErrorAction Stop
            } -FixRisk Moderate -FixLabel 'Remove BITS jobs stuck in Error'

        # ================= Network =================
        New-DiagnosticCheck -Id net-connectivity -Name 'Internet & DNS' -Category Network `
            -Scan {
                $n = Get-RepNetState
                $script:RepNetScanState = $n.State
                switch ($n.State) {
                    'OK'           { @{ Status = 'OK'; Detail = 'Internet (NCSI probe) and DNS reachable' } }
                    'DnsFail'      { @{ Status = 'Warn'; FixRisk = 'Safe'; Reboot = $false; FixLabel = 'Flush DNS cache + re-register DNS'
                                        Detail = "DNS resolution failing (NCSI probe ok: $($n.Probe); profile says Internet: $($n.Internet))" } }
                    'ProbeBlocked' { @{ Status = 'Warn'; NoFix = $true
                                        Detail = 'Windows reports Internet and DNS works, but the HTTP connectivity probe is blocked (proxy/firewall?)' } }
                    default        { @{ Status = 'Fail'; Detail = 'No internet: connectivity probe and DNS both fail, no network profile has Internet access' } }
                }
            } `
            -Fix {
                $now = (Get-RepNetState -Fresh).State
                Write-RepLog 'Flushing DNS cache and re-registering DNS...' 'Info'
                & ipconfig.exe /flushdns | Out-Null
                & ipconfig.exe /registerdns | Out-Null
                if ($script:RepNetScanState -eq 'Offline' -and $now -eq 'Offline') {
                    Write-RepLog 'Still no connectivity - resetting Winsock and TCP/IP. This WIPES static IP/DNS settings; re-enter them after the restart.' 'Warning'
                    & netsh.exe winsock reset | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "netsh winsock reset failed (exit $LASTEXITCODE)" }
                    & netsh.exe int ip reset | Out-Null
                    if ($LASTEXITCODE -ne 0) { Write-RepLog "netsh int ip reset exit $LASTEXITCODE (partial reset is common)" 'Warning' }
                    $script:FixNeedsReboot = $true
                }
                $script:RepNcsiCache = $null
            } -FixRisk Aggressive -FixLabel 'Flush DNS; winsock/IP reset only when fully offline (wipes static IP)' -Reboot $false

        New-DiagnosticCheck -Id net-adapter -Name 'Network adapters & WLAN service' -Category Network `
            -Scan {
                $ad = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue)
                $connected = @($ad | Where-Object { $_.NetConnectionStatus -eq 2 })
                $disabled  = @($ad | Where-Object { $_.PhysicalAdapter -and $_.ConfigManagerErrorCode -eq 22 })
                $wifi = @()
                if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
                    $wifi = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 })
                }
                $wlan = Get-Service WlanSvc -ErrorAction SilentlyContinue
                $issues = @()
                if ($wifi.Count -and (-not $wlan -or "$($wlan.Status)" -ne 'Running')) { $issues += 'Wi-Fi adapter present but WLAN AutoConfig (WlanSvc) is not running' }
                if (-not $connected.Count -and $disabled.Count) { $issues += ('No adapter connected; disabled physical adapter(s): ' + (($disabled | ForEach-Object { $_.NetConnectionID }) -join ', ')) }
                if ($issues) { @{ Status = 'Fail'; Detail = ($issues -join '; ') } }
                elseif (-not $connected.Count) { @{ Status = 'Warn'; NoFix = $true; Detail = 'No network adapter is connected (cable / Wi-Fi?)' } }
                else { @{ Status = 'OK'; Detail = ("Connected: " + (($connected | ForEach-Object { $_.NetConnectionID }) -join ', ') + $(if ($disabled.Count) { " ($($disabled.Count) adapter(s) disabled by user)" } else { '' })) } }
            } `
            -Fix {
                $ad = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue)
                if (-not @($ad | Where-Object { $_.NetConnectionStatus -eq 2 }).Count) {
                    foreach ($a in @($ad | Where-Object { $_.PhysicalAdapter -and $_.ConfigManagerErrorCode -eq 22 })) {
                        $r = Invoke-CimMethod -InputObject $a -MethodName Enable -ErrorAction Stop
                        Write-RepLog "Enabled adapter $($a.NetConnectionID) (rc $($r.ReturnValue))" 'Info'
                    }
                }
                $wlan = Get-Service WlanSvc -ErrorAction SilentlyContinue
                if ($wlan -and "$($wlan.Status)" -ne 'Running') {
                    $via = Restore-RepServiceStart -Name WlanSvc -StartType Automatic
                    Write-RepLog "WlanSvc set to Automatic (via $via)" 'Info'
                    Start-Service WlanSvc -ErrorAction Stop
                }
            } -FixRisk Safe -FixLabel 'Enable disabled adapters + start WLAN AutoConfig'

        New-DiagnosticCheck -Id winsock-lsp -Name 'Winsock catalog (broken LSP)' -Category Network `
            -Scan {
                $prov = @(Get-RepWinsockProvider)
                if (-not $prov.Count) { return @{ Status = 'Skip'; Detail = 'Winsock catalog not readable' } }
                $missing = @($prov | Where-Object { -not $_.Exists } | ForEach-Object { $_.Path } | Sort-Object -Unique)
                if ($missing.Count) { @{ Status = 'Fail'; Detail = ('Winsock provider DLL missing: ' + ($missing -join ', ') + ' - breaks all networking') } }
                else { @{ Status = 'OK'; Detail = "$($prov.Count) catalog entries; all provider DLLs present" } }
            } `
            -Fix {
                & netsh.exe winsock reset | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "netsh winsock reset failed (exit $LASTEXITCODE)" }
                $script:FixNeedsReboot = $true
            } -FixRisk Moderate -FixLabel 'netsh winsock reset' -Reboot $true

        New-DiagnosticCheck -Id hosts-integrity -Name 'Hosts file integrity' -Category Network `
            -Scan {
                $hosts = "$env:WINDIR\System32\drivers\etc\hosts"
                if (-not (Test-Path -LiteralPath $hosts)) { return @{ Status = 'OK'; Detail = 'No hosts file (default)' } }
                $lines  = @(Get-Content -LiteralPath $hosts -ErrorAction SilentlyContinue)
                $active = @($lines | Where-Object { ("$_" -replace '#.*$', '').Trim() } |
                    Where-Object { $_ -notmatch '^\s*(127\.0\.0\.1|::1)\s+localhost\s*(#.*)?$' })
                $bad    = @($lines | Where-Object { Test-RepHostsHijackLine $_ })
                if ($bad.Count) { @{ Status = 'Fail'; Detail = "$($bad.Count) hosts entry(ies) redirect Windows Update / Defender / activation hosts - possible hijack" } }
                else { @{ Status = 'OK'; Detail = $(if ($active.Count) { "$($active.Count) custom entry(ies); none touch update/security hosts" } else { 'Hosts file has no active redirects' }) } }
            } `
            -Fix {
                $hosts = "$env:WINDIR\System32\drivers\etc\hosts"
                $bak = "$hosts.winsenior.bak"
                if (Test-Path -LiteralPath $bak) { $bak = "$hosts.winsenior-$(Get-Date -Format 'yyyyMMddHHmmss').bak" }
                # Latin-1 round-trips every byte, so untouched lines keep their exact encoding.
                $enc  = [Text.Encoding]::GetEncoding(28591)
                $text = [IO.File]::ReadAllText($hosts, $enc)
                Copy-Item -LiteralPath $hosts -Destination $bak -Force -ErrorAction Stop
                $fi = Get-Item -LiteralPath $hosts -Force
                if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
                $parts = [regex]::Split($text, '(?<=\n)')
                $kept  = @($parts | Where-Object { -not (Test-RepHostsHijackLine ($_.TrimEnd("`r", "`n"))) })
                [IO.File]::WriteAllText($hosts, (-join $kept), $enc)
                Write-RepLog "Removed $($parts.Count - $kept.Count) hijacking hosts line(s); backup: $bak" 'Info'
                & ipconfig.exe /flushdns | Out-Null
            } -FixRisk Moderate -FixLabel 'Remove only the hijacking hosts lines (backup first)'

        New-DiagnosticCheck -Id proxy-hijack -Name 'Proxy / PAC hijack' -Category Network `
            -Scan {
                $is = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                $p = Get-ItemProperty $is -ErrorAction SilentlyContinue
                if ($p.AutoConfigURL) {
                    if (Test-RepPartOfDomain) { @{ Status = 'Warn'; NoFix = $true; Detail = "PAC set on a domain-joined PC (likely corporate, left alone): $($p.AutoConfigURL)" } }
                    else { @{ Status = 'Fail'; Detail = "AutoConfigURL (PAC) set: $($p.AutoConfigURL)" } }
                }
                elseif ($p.ProxyEnable -eq 1 -and $p.ProxyServer -match '(^|=|;)\s*(127\.\d+\.\d+\.\d+|localhost|\[?::1\]?)(:|;|$)') {
                    # A loopback proxy is usually a VPN / proxy client or debugger the user runs: never pre-select its removal.
                    @{ Status = 'Warn'; FixRisk = 'Aggressive'; FixLabel = 'Remove local proxy (breaks VPN/proxy apps that set it)'
                       Detail = "Local proxy enabled: $($p.ProxyServer) (VPN/proxy client? verify you run one)" }
                }
                elseif ($p.ProxyEnable -eq 1 -and $p.ProxyServer) { @{ Status = 'Warn'; Detail = "Proxy enabled: $($p.ProxyServer)" } }
                else { @{ Status = 'OK'; Detail = 'No proxy / PAC configured' } }
            } `
            -Fix {
                $is = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                Set-ItemProperty $is -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
                Remove-ItemProperty $is -Name ProxyServer -ErrorAction SilentlyContinue
                if (-not (Test-RepPartOfDomain)) { Remove-ItemProperty $is -Name AutoConfigURL -ErrorAction SilentlyContinue }
                & netsh.exe winhttp reset proxy *> $null
            } -FixRisk Moderate -FixLabel 'Reset WinINET/WinHTTP proxy settings'

        # ================= Devices =================
        New-DiagnosticCheck -Id dev-errors -Name 'Devices with driver problems' -Category Devices `
            -Scan {
                # Code 22 = disabled by the user: a choice, not a fault.
                $bad = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 0, 22 }
                if ($bad) {
                    $names = ($bad | Select-Object -First 5 | ForEach-Object { "$($_.Name) (code $($_.ConfigManagerErrorCode))" }) -join '; '
                    @{ Status = 'Warn'; Detail = "$(@($bad).Count) device(s) with errors: $names" }
                } else { @{ Status = 'OK'; Detail = 'No devices report driver errors' } }
            } `
            -Fix { Write-RepLog 'Rescanning for hardware changes...' 'Info'; & pnputil.exe /scan-devices *> $null } `
            -FixRisk Safe -FixLabel 'Rescan devices (pnputil /scan-devices)'

        # ================= Services =================
        New-DiagnosticCheck -Id svc-critical -Name 'Critical services stopped' -Category Services `
            -Scan {
                $want = 'Audiosrv','Dhcp','Dnscache','EventLog','mpssvc','Winmgmt','Schedule','BFE','LanmanWorkstation','ProfSvc','nsi','Power'
                $stopped = foreach ($n in $want) {
                    $s = Get-Service $n -ErrorAction SilentlyContinue
                    if ($s -and "$($s.StartType)" -in 'Automatic','Boot','System' -and "$($s.Status)" -ne 'Running') { $n }
                }
                $stopped = @($stopped)
                if ($stopped.Count) { @{ Status = 'Fail'; Detail = ('Stopped: ' + ($stopped -join ', ')) } }
                else                { @{ Status = 'OK';   Detail = 'All monitored critical services are running' } }
            } `
            -Fix {
                $want = 'Audiosrv','Dhcp','Dnscache','EventLog','mpssvc','Winmgmt','Schedule','BFE','LanmanWorkstation','ProfSvc','nsi','Power'
                foreach ($n in $want) {
                    $s = Get-Service $n -ErrorAction SilentlyContinue
                    if ($s -and "$($s.StartType)" -in 'Automatic','Boot','System' -and "$($s.Status)" -ne 'Running') {
                        Start-Service $n -ErrorAction SilentlyContinue
                        Write-RepLog "started $n" 'Debug'
                    }
                }
            } -FixRisk Safe -FixLabel 'Start stopped critical services'

        New-DiagnosticCheck -Id svc-defaults -Name 'Core services disabled' -Category Services `
            -Scan {
                $bad = @(foreach ($s in (Get-RepServiceDefault)) {
                    if ((Get-RepRegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)" 'Start') -eq 4) { $s }
                })
                $note = if ((Get-RepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch' 'Start') -eq 4) { ' (WSearch disabled - left alone, may be an Optimize tweak)' } else { '' }
                if (-not $bad.Count) { return @{ Status = 'OK'; Detail = "No core Windows service is disabled$note" } }
                $txt = 'Disabled: ' + (($bad | ForEach-Object { $_.Name }) -join ', ') + $note
                @{ Status = $(if ($bad | Where-Object Level -eq 'Fail') { 'Fail' } else { 'Warn' }); Detail = $txt }
            } `
            -Fix {
                $failed = @()
                foreach ($s in (Get-RepServiceDefault)) {
                    if ((Get-RepRegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)" 'Start') -ne 4) { continue }
                    try {
                        $via = Restore-RepServiceStart -Name $s.Name -StartType $s.Default
                        Write-RepLog "$($s.Name) -> $($s.Default) (via $via)" 'Info'
                    } catch { $failed += "$($s.Name): $($_.Exception.Message)" }
                }
                if ($failed) { throw ('Could not restore: ' + ($failed -join '; ')) }
            } -FixRisk Moderate -FixLabel 'Restore default start type of disabled core services'

        New-DiagnosticCheck -Id spooler-health -Name 'Print spooler' -Category Services `
            -Scan {
                $sp = Get-Service Spooler -ErrorAction SilentlyContinue
                if (-not $sp) { return @{ Status = 'Skip'; Detail = 'Spooler service not found' } }
                if ("$($sp.StartType)" -eq 'Disabled') { return @{ Status = 'OK'; Detail = 'Spooler disabled (printing turned off)' } }
                # Check the service first: Get-Printer against a dead spooler errors or stalls.
                if ("$($sp.Status)" -ne 'Running') {
                    if ("$($sp.StartType)" -like 'Automatic*') { return @{ Status = 'Warn'; Detail = 'Spooler should run but is stopped' } }
                    return @{ Status = 'OK'; Detail = "Spooler stopped (start type $($sp.StartType))" }
                }
                $printers = @(Get-Printer -ErrorAction SilentlyContinue)
                if ($printers.Count -eq 0) { return @{ Status = 'OK'; Detail = 'No printers installed' } }
                $queue = @(Get-ChildItem "$env:WINDIR\System32\spool\PRINTERS" -ErrorAction SilentlyContinue)
                if ($queue.Count -gt 0) { @{ Status = 'Warn'; Detail = "$($queue.Count) file(s) stuck in the print queue" } }
                else { @{ Status = 'OK'; Detail = "Spooler running; $($printers.Count) printer(s); queue clear" } }
            } `
            -Fix {
                Stop-Service Spooler -Force -ErrorAction SilentlyContinue
                Get-ChildItem "$env:WINDIR\System32\spool\PRINTERS\*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                Start-Service Spooler -ErrorAction Stop
            } -FixRisk Safe -FixLabel 'Clear print queue + restart spooler'

        New-DiagnosticCheck -Id search-health -Name 'Windows Search index' -Category Services `
            -Scan {
                $ws = Get-Service WSearch -ErrorAction SilentlyContinue
                if (-not $ws) { return @{ Status = 'OK'; Detail = 'Windows Search not installed' } }
                if ("$($ws.StartType)" -eq 'Disabled') { return @{ Status = 'OK'; Detail = 'Windows Search disabled (intentional?)' } }
                $dir = "$env:ProgramData\Microsoft\Search\Data\Applications\Windows"
                $size = 0
                foreach ($f in 'Windows.edb', 'Windows.db') {
                    $it = Get-Item -LiteralPath (Join-Path $dir $f) -Force -ErrorAction SilentlyContinue
                    if ($it) { $size += $it.Length }
                }
                $gb = [math]::Round($size / 1GB, 1)
                if ("$($ws.StartType)" -like 'Automatic*' -and "$($ws.Status)" -ne 'Running') { @{ Status = 'Warn'; Detail = "WSearch is Automatic but not running (index $gb GB)" } }
                elseif ($gb -gt 20) { @{ Status = 'Warn'; Detail = "Search index is $gb GB (bloated)" } }
                else { @{ Status = 'OK'; Detail = "Search running; index $gb GB" } }
            } `
            -Fix {
                Write-RepLog 'Rebuilding the Windows Search index...' 'Info'
                Stop-Service WSearch -Force -ErrorAction Stop
                Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0 -Type DWord -ErrorAction Stop
                Start-Service WSearch -ErrorAction Stop
            } -FixRisk Moderate -FixLabel 'Rebuild the search index'

        # ================= Security =================
        New-DiagnosticCheck -Id def-health -Name 'Microsoft Defender health' -Category Security `
            -Scan {
                $m = Get-RepDefenderMode
                if (-not $m.Present) { return @{ Status = 'Skip'; Detail = 'Defender module unavailable (3rd-party AV?)' } }
                if ($m.Passive) {
                    if ($m.ThirdParty) { return @{ Status = 'OK'; Detail = "Third-party AV active ($($m.ThirdParty -join ', ')); Defender mode: $($m.Mode)" } }
                    return @{ Status = 'Warn'; NoFix = $true; Detail = "Defender not in active mode ($($m.Mode)) and no other antivirus is registered" }
                }
                $st = $m.Status
                $issues = @()
                if (-not $st.RealTimeProtectionEnabled) { $issues += 'real-time protection OFF' }
                if ($st.AntivirusSignatureAge -gt 7)    { $issues += "signatures $($st.AntivirusSignatureAge)d old" }
                if ($issues) { @{ Status = 'Warn'; Detail = ($issues -join '; ') } }
                else         { @{ Status = 'OK';   Detail = 'Real-time protection on; signatures current' } }
            } `
            -Fix {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
                Write-RepLog 'Updating Defender signatures...' 'Info'
                Update-MpSignature -ErrorAction SilentlyContinue
            } -FixRisk Safe -FixLabel 'Enable real-time protection + update signatures'

        New-DiagnosticCheck -Id def-signatures -Name 'Defender signatures & threats' -Category Security `
            -Scan {
                $m = Get-RepDefenderMode
                if (-not $m.Present) { return @{ Status = 'Skip'; Detail = 'Defender module unavailable' } }
                if ($m.Passive) { return @{ Status = 'OK'; Detail = "Defender passive (mode: $($m.Mode)) - third-party AV handles threats" } }
                # Latest detection per threat; 1=Detected 102=QuarantineFailed 103=RemoveFailed 107=BlockFailed.
                $latest = Get-MpThreatDetection -ErrorAction SilentlyContinue | Group-Object ThreatID |
                    ForEach-Object { $_.Group | Sort-Object LastThreatStatusChangeTime, InitialDetectionTime | Select-Object -Last 1 }
                $active = @($latest | Where-Object { $_.ThreatStatusID -in 1, 102, 103, 107 })
                if ($active.Count) { @{ Status = 'Fail'; NoFix = $true; Detail = "$($active.Count) active/unremediated threat(s) - open Windows Security > Protection history" } }
                elseif ($m.Status.DefenderSignaturesOutOfDate) { @{ Status = 'Warn'; Detail = 'Defender signatures are out of date' } }
                else { @{ Status = 'OK'; Detail = 'Defender signatures current; no active threats' } }
            } `
            -Fix { Write-RepLog 'Updating Defender signatures...' 'Info'; Update-MpSignature -ErrorAction Stop } `
            -FixRisk Safe -FixLabel 'Update Defender signatures'

        New-DiagnosticCheck -Id def-exclusions -Name 'Dangerous Defender exclusions' -Category Security `
            -Scan {
                $m = Get-RepDefenderMode
                if (-not $m.Present) { return @{ Status = 'Skip'; Detail = 'Defender module unavailable' } }
                if ($m.Passive) { return @{ Status = 'OK'; Detail = "Defender passive (mode: $($m.Mode)) - exclusions not in effect" } }
                $p = Get-MpPreference -ErrorAction SilentlyContinue
                $real = { param($v) @($v | Where-Object { $_ -and "$_" -notmatch '^N/A' }) }
                $hits = @()
                foreach ($x in (& $real $p.ExclusionPath)) {
                    $e = [Environment]::ExpandEnvironmentVariables("$x").TrimEnd('\')
                    if ($e -match '^[A-Za-z]:$' -or $e -match '(?i)^[A-Z]:\\Users$' -or $e -match '(?i)\\AppData\\Local\\Temp$' -or
                        $e -match '(?i)\\Windows\\Temp$' -or $e -ieq $env:TEMP.TrimEnd('\') -or $e -ieq $env:WINDIR.TrimEnd('\') -or
                        $e -match '(?i)\\AppData$' -or $e -match '(?i)\\AppData\\(Local|Roaming)$' -or $e -match '(?i)\\Downloads$') { $hits += "path $x" }
                }
                foreach ($x in (& $real $p.ExclusionExtension)) {
                    if ("$x".TrimStart('*').TrimStart('.') -in 'exe', 'dll', 'ps1', 'bat', 'cmd', 'vbs', 'js', 'scr', 'msi', 'hta') { $hits += "extension $x" }
                }
                foreach ($x in (& $real $p.ExclusionProcess)) {
                    if ((Split-Path "$x" -Leaf) -in 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'rundll32.exe', 'regsvr32.exe') { $hits += "process $x" }
                }
                if ($hits) { @{ Status = 'Warn'; Detail = ('Risky exclusion(s) (common malware persistence): ' + ($hits -join '; ')) } }
                else { @{ Status = 'OK'; Detail = 'No broad or high-risk Defender exclusions' } }
            } -Fix $null

        New-DiagnosticCheck -Id firewall-state -Name 'Windows Firewall enabled' -Category Security `
            -Scan {
                if (-not (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'Firewall module unavailable' } }
                $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled })
                if ($off.Count -ge 3) { @{ Status = 'Fail'; Detail = 'All firewall profiles are OFF' } }
                elseif ($off.Count)   { @{ Status = 'Warn'; Detail = ('Firewall off for: ' + (($off.Name) -join ', ')) } }
                else                  { @{ Status = 'OK';   Detail = 'All firewall profiles enabled' } }
            } `
            -Fix { Set-NetFirewallProfile -All -Enabled True -ErrorAction Stop } `
            -FixRisk Moderate -FixLabel 'Re-enable all firewall profiles'

        New-DiagnosticCheck -Id smb1-disabled -Name 'SMBv1 protocol disabled' -Category Security `
            -Scan {
                $srv = (Get-SmbServerConfiguration -ErrorAction SilentlyContinue).EnableSMB1Protocol
                if ($null -eq $srv) { return @{ Status = 'Skip'; Detail = 'SMB module unavailable' } }
                if ($srv) { @{ Status = 'Warn'; Detail = 'SMBv1 is ENABLED (EternalBlue/WannaCry vector)' } }
                else      { @{ Status = 'OK';   Detail = 'SMBv1 disabled' } }
            } `
            -Fix {
                Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
                if (Get-Command Disable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
                    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
                }
            } -FixRisk Moderate -FixLabel 'Disable SMBv1 (very old NAS/printers may lose shares)' -Reboot $true

        New-DiagnosticCheck -Id uac-enabled -Name 'User Account Control enabled' -Category Security `
            -Scan {
                $lua = Get-RepRegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
                if ($lua -eq 0) { @{ Status = 'Fail'; Detail = 'UAC is OFF (EnableLUA=0) - breaks Store/UWP apps and weakens security' } }
                else { @{ Status = 'OK'; Detail = 'UAC enabled' } }
            } `
            -Fix {
                Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 1 -Type DWord -ErrorAction Stop
            } -FixRisk Moderate -FixLabel 'Turn UAC back on (EnableLUA=1)' -Reboot $true

        New-DiagnosticCheck -Id bitlocker -Name 'BitLocker protection (system drive)' -Category Security `
            -Scan {
                $ns = 'root/cimv2/Security/MicrosoftVolumeEncryption'
                try { $vol = Get-CimInstance -Namespace $ns -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop }
                catch {
                    $code = "$($_.Exception.NativeErrorCode)"
                    if ($code -in 'InvalidNamespace', 'InvalidClass', 'NotFound') { return @{ Status = 'OK'; Detail = 'BitLocker not available on this edition (not applicable)' } }
                    if ($code -eq 'AccessDenied') { return @{ Status = 'Skip'; Detail = 'BitLocker status needs administrator rights' } }
                    return @{ Status = 'Skip'; Detail = "BitLocker status unavailable ($code)" }
                }
                if (-not $vol) { return @{ Status = 'OK'; Detail = 'System drive not encryptable (not applicable)' } }
                if ($vol.ConversionStatus -eq 0) { return @{ Status = 'OK'; Detail = 'System drive not encrypted' } }
                $issues = @(); $suspended = $false
                if ($vol.ConversionStatus -eq 1 -and $vol.ProtectionStatus -eq 0) { $issues += 'BitLocker protection is SUSPENDED'; $suspended = $true }
                $kp = Invoke-CimMethod -InputObject $vol -MethodName GetKeyProtectors -Arguments @{ KeyProtectorType = [uint32]3 } -ErrorAction SilentlyContinue
                if ($kp -and $kp.ReturnValue -eq 0 -and -not @($kp.VolumeKeyProtectorID).Count) { $issues += 'no recovery password protector (back one up!)' }
                if ($issues) { @{ Status = 'Warn'; NoFix = (-not $suspended); Detail = ($issues -join '; ') } }
                else { @{ Status = 'OK'; Detail = "Encrypted (conversion $($vol.ConversionStatus)); protection on; recovery password present" } }
            } `
            -Fix {
                $vol = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
                if ($vol.ProtectionStatus -eq 0) {
                    # Same as Resume-BitLocker, but works under pwsh 7 too.
                    $r = Invoke-CimMethod -InputObject $vol -MethodName EnableKeyProtectors -ErrorAction Stop
                    if ($r.ReturnValue -ne 0) { throw ("EnableKeyProtectors returned 0x{0:X8}" -f [uint32]$r.ReturnValue) }
                }
            } -FixRisk Safe -FixLabel 'Resume BitLocker protection'

        New-DiagnosticCheck -Id secureboot-cert -Name 'Secure Boot & 2023 certificate update' -Category Security `
            -Scan {
                if ($env:firmware_type -eq 'Legacy') { return @{ Status = 'OK'; Detail = 'Legacy BIOS - Secure Boot not applicable' } }
                $sbReg = Get-RepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
                if ($null -ne $sbReg) { $sb = ($sbReg -eq 1) }
                else {
                    try { $sb = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
                    catch { return @{ Status = 'OK'; Detail = 'Secure Boot not supported on this platform (not applicable)' } }
                }
                $svc = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
                $st  = Get-RepRegValue $svc 'UEFICA2023Status'
                $err = Get-RepRegValue $svc 'UEFICA2023Error'
                $issues = @(); $status = 'OK'
                if (-not $sb) { $issues += 'Secure Boot is OFF'; $status = 'Warn' }
                if ($err) { $issues += ("2023 CA update failed (UEFICA2023Error 0x{0:X8}) - update BIOS/UEFI firmware" -f $err); $status = 'Fail' }
                elseif ("$st" -ne 'Updated') {
                    $issues += "2023 Secure Boot CA not applied (status: $(if ($st) { $st } else { 'unknown' })) - the 2011 CAs expired June 2026; install the latest cumulative update / OEM firmware"
                    if ($status -ne 'Fail') { $status = 'Warn' }
                }
                if ($issues) { @{ Status = $status; Detail = ($issues -join '; ') } }
                else { @{ Status = 'OK'; Detail = 'Secure Boot on; 2023 CA certificates applied' } }
            } -Fix $null

        New-DiagnosticCheck -Id rootcert-update -Name 'Root certificate auto-update' -Category Security `
            -Scan {
                if ((Get-RepRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\AuthRoot' 'DisableRootAutoUpdate') -eq 1) {
                    @{ Status = 'Warn'; Detail = 'Root certificate auto-update disabled by policy (TLS / Store / update errors)' }
                } else { @{ Status = 'OK'; Detail = 'Root certificates update automatically' } }
            } `
            -Fix {
                Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\AuthRoot' -Name DisableRootAutoUpdate -ErrorAction Stop
            } -FixRisk Safe -FixLabel 'Re-enable root certificate auto-update'

        # ================= System =================
        New-DiagnosticCheck -Id wmi-repo -Name 'WMI repository consistency' -Category System `
            -Scan {
                & winmgmt.exe /verifyrepository *> $null
                if ($LASTEXITCODE -eq 0) { @{ Status = 'OK'; Detail = 'WMI repository is consistent' } }
                else { @{ Status = 'Fail'; Detail = "WMI repository inconsistent (exit $LASTEXITCODE)" } }
            } `
            -Fix {
                Write-RepLog 'Salvaging WMI repository...' 'Info'
                & winmgmt.exe /salvagerepository *> $null
                if ($LASTEXITCODE -ne 0) { throw "winmgmt /salvagerepository failed (exit $LASTEXITCODE)" }
            } -FixRisk Moderate -FixLabel 'Salvage WMI repository'

        New-DiagnosticCheck -Id time-sync -Name 'System time synchronization' -Category System `
            -Scan {
                $w = Get-Service W32Time -ErrorAction SilentlyContinue
                if (-not $w) { return @{ Status = 'Skip'; Detail = 'W32Time service not found' } }
                # Manual + stopped is normal on non-domain PCs (trigger-started), so judge by config + real offset.
                $issues = @(); $status = 'OK'
                if ("$($w.StartType)" -eq 'Disabled') { $issues += 'time service disabled'; $status = 'Warn' }
                if ((Get-RepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' 'Type') -eq 'NoSync') { $issues += 'time sync turned off (Type=NoSync)'; $status = 'Warn' }
                $probe = Get-RepNcsiProbe
                if ($probe.ServerTime -and $probe.LocalTime) {
                    $off = ($probe.LocalTime - $probe.ServerTime).TotalSeconds
                    $abs = [math]::Abs($off)
                    $txt = 'clock offset {0:+0;-0}s vs internet time' -f $off
                    if ($abs -gt 600)     { $status = 'Fail'; $issues += $txt }
                    elseif ($abs -gt 120) { if ($status -ne 'Fail') { $status = 'Warn' }; $issues += $txt }
                    elseif (-not $issues) { return @{ Status = 'OK'; Detail = "Clock in sync ($txt)" } }
                }
                elseif (-not $issues) { return @{ Status = 'OK'; Detail = 'Time sync configured; offset unknown (offline)' } }
                @{ Status = $status; Detail = ($issues -join '; ') }
            } `
            -Fix {
                $w = Get-Service W32Time -ErrorAction Stop
                if ("$($w.StartType)" -eq 'Disabled') { Restore-RepServiceStart -Name W32Time -StartType Manual | Out-Null }
                $pk = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
                if ((Get-RepRegValue $pk 'Type') -eq 'NoSync') {
                    Set-ItemProperty -LiteralPath $pk -Name Type -Value $(if (Test-RepPartOfDomain) { 'NT5DS' } else { 'NTP' }) -ErrorAction Stop
                }
                if ("$((Get-Service W32Time).Status)" -ne 'Running') { Start-Service W32Time -ErrorAction Stop }
                & w32tm.exe /config /update *> $null
                & w32tm.exe /resync /rediscover *> $null
                $rc = $LASTEXITCODE
                $script:RepNcsiCache = $null
                if ($rc -ne 0) { throw "w32tm /resync failed (exit $rc) - NTP (UDP 123) blocked?" }
            } -FixRisk Safe -FixLabel 'Enable time sync + resync clock'

        New-DiagnosticCheck -Id event-errors -Name 'Recent critical/error events' -Category System `
            -Scan {
                $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-2) } -MaxEvents 300 -ErrorAction SilentlyContinue |
                    Where-Object { -not ($_.ProviderName -match 'DistributedCOM' -and $_.Id -in 10016, 10010) })   # known-benign DCOM noise
                if ($ev.Count -eq 0) { return @{ Status = 'OK'; Detail = 'No critical/error events in the last 48h' } }
                $top = ($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3 |
                        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
                $status = if ($ev.Count -gt 50) { 'Warn' } else { 'OK' }
                @{ Status = $status; Detail = "$($ev.Count) error/critical event(s) in 48h; top: $top" }
            } -Fix $null

        New-DiagnosticCheck -Id crash-history -Name 'Recent crashes (BSOD / unexpected shutdown)' -Category System `
            -Scan {
                $since = (Get-Date).AddDays(-30)
                $marks = @()
                $marks += @(Get-ChildItem "$env:WINDIR\Minidump\*.dmp" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since } |
                    ForEach-Object { [pscustomobject]@{ T = $_.LastWriteTime; Bsod = $true } })
                $marks += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $since } -MaxEvents 100 -ErrorAction SilentlyContinue |
                    ForEach-Object { [pscustomobject]@{ T = $_.TimeCreated; Bsod = $true } })
                $marks += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -MaxEvents 100 -ErrorAction SilentlyContinue |
                    ForEach-Object { [pscustomobject]@{ T = $_.TimeCreated; Bsod = $false } })
                # One crash leaves a minidump + WER event + Kernel-Power 41 at next boot: artifacts within 10 min = 1 crash.
                $crashes = @(); $cur = $null
                foreach ($x in ($marks | Sort-Object T)) {
                    if ($cur -and ($x.T - $cur.Last).TotalMinutes -le 10) { $cur.Last = $x.T; if ($x.Bsod) { $cur.Bsod = $true } }
                    else { $cur = [pscustomobject]@{ Last = $x.T; Bsod = $x.Bsod }; $crashes += $cur }
                }
                $n = $crashes.Count
                $b = @($crashes | Where-Object Bsod).Count
                $txt = "$n crash(es) in 30 days ($b BSOD, $($n - $b) unexpected power-off/reset)"
                if ($n -eq 0)     { @{ Status = 'OK';   Detail = 'No crashes or unexpected shutdowns in 30 days' } }
                elseif ($n -ge 2) { @{ Status = 'Warn'; Detail = "$txt - recurring instability" } }
                else              { @{ Status = 'OK';   Detail = "$txt (isolated)" } }
            } -Fix $null

        New-DiagnosticCheck -Id restore-enabled -Name 'System Restore protection' -Category System `
            -Scan {
                $rp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -ErrorAction SilentlyContinue
                $pts = 0
                try { $pts = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue).Count } catch { $pts = 0 }
                if ($rp.DisableSR -eq 1) { @{ Status = 'Warn'; Detail = 'System Restore is disabled (no rollback safety net)' } }
                elseif ($pts -eq 0)      { @{ Status = 'Warn'; Detail = 'System Restore on but no restore points exist' } }
                else                     { @{ Status = 'OK';   Detail = "System Restore on; $pts restore point(s)" } }
            } `
            -Fix {
                # WMI path works under both Windows PowerShell 5.1 and pwsh 7.
                Enable-WsSystemRestore -Drive "$env:SystemDrive\"
                $rk = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
                $prev = Get-RepRegValue $rk 'SystemRestorePointCreationFrequency'
                # Lift the 24h throttle only for this checkpoint, then put it back.
                New-ItemProperty -Path $rk -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                try { Invoke-WsCheckpoint -Description 'WinSenior baseline' }
                finally {
                    if ($null -eq $prev) { Remove-ItemProperty -LiteralPath $rk -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue }
                    else { Set-ItemProperty -LiteralPath $rk -Name 'SystemRestorePointCreationFrequency' -Value $prev -Type DWord -ErrorAction SilentlyContinue }
                }
            } -FixRisk Safe -FixLabel 'Enable System Restore + create a checkpoint'

        New-DiagnosticCheck -Id sched-task-health -Name 'Critical scheduled tasks enabled' -Category System `
            -Scan {
                if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'ScheduledTasks module unavailable' } }
                $want = @(
                    @{ P = '\Microsoft\Windows\WindowsUpdate\';        N = 'Scheduled Start' },
                    @{ P = '\Microsoft\Windows\UpdateOrchestrator\';   N = 'Schedule Scan' },
                    @{ P = '\Microsoft\Windows\SystemRestore\';        N = 'SR' },
                    @{ P = '\Microsoft\Windows\Windows Defender\';     N = 'Windows Defender Scheduled Scan' })
                $disabled = foreach ($t in $want) {
                    $st = Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue
                    if ($st -and "$($st.State)" -eq 'Disabled') { $t.N }
                }
                $disabled = @($disabled)
                if ($disabled.Count) { @{ Status = 'Warn'; Detail = ('Critical task(s) disabled: ' + ($disabled -join ', ')) } }
                else                 { @{ Status = 'OK';   Detail = 'Monitored critical tasks are enabled' } }
            } `
            -Fix {
                $want = @(
                    @{ P = '\Microsoft\Windows\WindowsUpdate\';        N = 'Scheduled Start' },
                    @{ P = '\Microsoft\Windows\UpdateOrchestrator\';   N = 'Schedule Scan' },
                    @{ P = '\Microsoft\Windows\SystemRestore\';        N = 'SR' },
                    @{ P = '\Microsoft\Windows\Windows Defender\';     N = 'Windows Defender Scheduled Scan' })
                $failed = @()
                foreach ($t in $want) {
                    $st = Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue
                    if ($st -and "$($st.State)" -eq 'Disabled') {
                        try { Enable-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction Stop | Out-Null; Write-RepLog "enabled $($t.P)$($t.N)" 'Debug' }
                        catch { $failed += "$($t.N): $($_.Exception.Message)" }
                    }
                }
                if ($failed) { throw ('Could not enable: ' + ($failed -join '; ')) }
            } -FixRisk Moderate -FixLabel 'Re-enable critical scheduled tasks (curated list)'

        New-DiagnosticCheck -Id store-health -Name 'Microsoft Store health' -Category System `
            -Scan {
                try { $store = @(Get-RepAppxState -Name 'Microsoft.WindowsStore') | Select-Object -First 1 }
                catch { return @{ Status = 'Skip'; Detail = "Appx query failed: $($_.Exception.Message)" } }
                if (-not $store) { return @{ Status = 'Warn'; Detail = 'Microsoft Store package not found for this user' } }
                if ($store.Status -and $store.Status -ne 'Ok') { @{ Status = 'Warn'; Detail = "Store package status: $($store.Status)" } }
                else { @{ Status = 'OK'; Detail = 'Store package present' } }
            } `
            -Fix { Write-RepLog 'Resetting Microsoft Store cache (wsreset)...' 'Info'; & wsreset.exe *> $null } `
            -FixRisk Safe -FixLabel 'Reset Store cache (wsreset)'

        New-DiagnosticCheck -Id shell-appx -Name 'Start menu / shell packages' -Category System `
            -Scan {
                $sysApps = Join-Path $env:SystemRoot 'SystemApps'
                $want = @('Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.Windows.ShellExperienceHost')
                if ([Environment]::OSVersion.Version.Build -ge 22000) {
                    foreach ($opt in 'MicrosoftWindows.Client.CBS', 'MicrosoftWindows.Client.Core') {
                        if (Get-ChildItem -LiteralPath $sysApps -Directory -Filter "$($opt)_*" -ErrorAction SilentlyContinue) { $want += $opt }
                    }
                }
                try { $pk = @(Get-RepAppxState -Name $want) }
                catch { return @{ Status = 'Skip'; Detail = "Appx query failed: $($_.Exception.Message)" } }
                $issues = @()
                foreach ($n in $want) {
                    $p = $pk | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                    if (-not $p) { $issues += "$n not registered" }
                    elseif ($p.Status -and $p.Status -ne 'Ok') { $issues += "$n status $($p.Status)" }
                }
                $shellExe = 'explorer.exe', 'StartMenuExperienceHost.exe', 'SearchHost.exe', 'SearchApp.exe', 'ShellExperienceHost.exe'
                $crash = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 500 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Properties.Count -and "$($_.Properties[0].Value)" -in $shellExe })
                if ($crash.Count -ge 3) {
                    $issues += ('shell crashes in 7 days: ' + (($crash | Group-Object { "$($_.Properties[0].Value)" } | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '))
                }
                if ($issues) { @{ Status = 'Warn'; Detail = ($issues -join '; ') } }
                else { @{ Status = 'OK'; Detail = "$($want.Count) shell package(s) registered; no repeated shell crashes" } }
            } `
            -Fix {
                $u = Test-RepInteractiveUser
                if (-not $u.Ok) { throw "Shell packages must be re-registered from the signed-in user's session (console user: $($u.Console); running as: $($u.Me))" }
                $rx = '^(Microsoft\.Windows\.StartMenuExperienceHost|Microsoft\.Windows\.ShellExperienceHost|MicrosoftWindows\.Client\.CBS|MicrosoftWindows\.Client\.Core)_'
                $manifests = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'SystemApps') -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match $rx } | ForEach-Object { Join-Path $_.FullName 'AppxManifest.xml' } | Where-Object { Test-Path -LiteralPath $_ })
                if (-not $manifests.Count) { throw 'No shell package manifests found under SystemApps' }
                if ($PSVersionTable.PSEdition -eq 'Core') {
                    $list = ($manifests | ForEach-Object { "'$_'" }) -join ','
                    $cmd  = "`$ProgressPreference = 'SilentlyContinue'; foreach (`$m in @($list)) { Add-AppxPackage -Register -DisableDevelopmentMode `$m -ErrorAction Stop }"
                    $enc  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
                    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $enc
                    if ($LASTEXITCODE -ne 0) { throw "Add-AppxPackage -Register failed (powershell.exe exit $LASTEXITCODE)" }
                } else {
                    foreach ($m in $manifests) { Add-AppxPackage -Register -DisableDevelopmentMode $m -ErrorAction Stop }
                }
                Write-RepLog "Re-registered $($manifests.Count) shell package(s); restarting shell hosts" 'Info'
                Stop-Process -Name StartMenuExperienceHost, ShellExperienceHost -Force -ErrorAction SilentlyContinue
            } -FixRisk Moderate -FixLabel 'Re-register Start/shell packages (current user)'

        New-DiagnosticCheck -Id winre -Name 'Windows Recovery Environment' -Category System `
            -Scan {
                $xmlPath = "$env:WINDIR\System32\Recovery\ReAgent.xml"
                if (-not (Test-Path -LiteralPath $xmlPath)) { return @{ Status = 'Warn'; Detail = 'ReAgent.xml missing - WinRE is not configured' } }
                try { $x = [xml](Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop) }
                catch { return @{ Status = 'Skip'; Detail = 'ReAgent.xml unreadable' } }
                $issues = @(); $enabled = ("$($x.WindowsRE.InstallState.state)" -eq '1')
                if (-not $enabled) { $issues += 'WinRE is disabled (no recovery / reset options at boot)' }
                if (Get-Command Get-Partition -ErrorAction SilentlyContinue) {
                    $parts = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { "$($_.GptType)" -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -or $_.MbrType -eq 39 })
                    $off = "$($x.WindowsRE.WinreLocation.offset)"
                    if ($off -and $off -ne '0') { $m = @($parts | Where-Object { "$($_.Offset)" -eq $off }); if ($m.Count) { $parts = $m } }
                    foreach ($p in $parts) {
                        $v = $p | Get-Volume -ErrorAction SilentlyContinue
                        if ($v -and $v.SizeRemaining -lt 250MB) {
                            $issues += ('recovery partition has only {0} MB free (<250 MB; WinRE updates fail with 0x80070643 - see KB5028997)' -f [math]::Round($v.SizeRemaining / 1MB))
                        }
                    }
                }
                if ($issues) { @{ Status = 'Warn'; NoFix = $enabled; Detail = ($issues -join '; ') } }
                else { @{ Status = 'OK'; Detail = 'WinRE enabled; recovery partition has room' } }
            } `
            -Fix {
                & reagentc.exe /enable *> $null
                if ($LASTEXITCODE -ne 0) { throw "reagentc /enable failed (exit $LASTEXITCODE)" }
            } -FixRisk Moderate -FixLabel 'Enable WinRE (reagentc /enable)'

        New-DiagnosticCheck -Id pagefile -Name 'Page file & commit memory' -Category System `
            -Scan {
                $cs  = Get-CimInstance Win32_ComputerSystem -Property AutomaticManagedPagefile -ErrorAction Stop
                $pfs = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
                $os  = Get-CimInstance Win32_OperatingSystem -Property FreeVirtualMemory, TotalVirtualMemorySize -ErrorAction Stop
                $pct = if ($os.TotalVirtualMemorySize) { [math]::Round(100 * $os.FreeVirtualMemory / $os.TotalVirtualMemorySize, 1) } else { 100 }
                $ev  = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction SilentlyContinue).Count
                $auto = [bool]$cs.AutomaticManagedPagefile
                $mode = if ($auto) { 'system-managed' } else { "custom ($($pfs.Count) file(s))" }
                if (-not $auto -and $pfs.Count -eq 0) { return @{ Status = 'Fail'; Detail = 'No page file - apps crash with out-of-memory and no crash dumps are written' } }
                $issues = @()
                if ($pct -lt 10) { $issues += "only $pct% commit free" }
                if ($ev) { $issues += "$ev low-memory event(s) in 7 days" }
                if ($issues) { @{ Status = 'Warn'; NoFix = $auto; Detail = "Page file $mode; " + ($issues -join '; ') } }
                else { @{ Status = 'OK'; Detail = "Page file $mode; $pct% commit free" } }
            } `
            -Fix {
                Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Set-CimInstance -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
            } -FixRisk Moderate -FixLabel 'Let Windows manage the page file' -Reboot $true

        New-DiagnosticCheck -Id env-path -Name 'System PATH & TEMP variables' -Category System `
            -Scan {
                $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
                if (-not $k) { return @{ Status = 'Skip'; Detail = 'Environment key unreadable' } }
                try {
                    $raw  = "$($k.GetValue('Path', $null, 'DoNotExpandEnvironmentNames'))"
                    $temps = @{ 'machine TEMP' = $k.GetValue('TEMP', $null, 'DoNotExpandEnvironmentNames'); 'machine TMP' = $k.GetValue('TMP', $null, 'DoNotExpandEnvironmentNames') }
                } finally { $k.Close() }
                $uk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
                if ($uk) {
                    try { $temps['user TEMP'] = $uk.GetValue('TEMP', $null, 'DoNotExpandEnvironmentNames'); $temps['user TMP'] = $uk.GetValue('TMP', $null, 'DoNotExpandEnvironmentNames') }
                    finally { $uk.Close() }
                }
                $sys32 = (Join-Path $env:SystemRoot 'System32').TrimEnd('\')
                $entries = @($raw -split ';' | Where-Object { $_.Trim() })
                $expanded = @($entries | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') })
                $fail = @(); $warn = @()
                if (-not ($expanded | Where-Object { $_ -ieq $sys32 })) { $fail += 'System32 missing from machine PATH' }
                foreach ($t in $temps.Keys) {
                    if ($temps[$t]) {
                        $p = [Environment]::ExpandEnvironmentVariables("$($temps[$t])")
                        if (-not (Test-Path -LiteralPath $p)) { $fail += "$t points to a missing folder ($p)" }
                    }
                }
                $dead = @($expanded | Where-Object { -not (Test-Path -LiteralPath $_) }).Count
                if ($raw.Length -gt 2047) { $warn += "PATH is $($raw.Length) chars (>2047)" }
                if ($dead -gt 5) { $warn += "$dead PATH entries point to missing folders" }
                if ($fail) { @{ Status = 'Fail'; Detail = (@($fail) + @($warn)) -join '; ' } }
                elseif ($warn) { @{ Status = 'Warn'; NoFix = $true; Detail = ($warn -join '; ') + ' (review manually; entries are never removed automatically)' } }
                else { @{ Status = 'OK'; Detail = "PATH has $($entries.Count) entries ($dead dead); TEMP folders exist" } }
            } `
            -Fix {
                $keyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
                $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath, $true)
                if (-not $k) { throw 'Cannot open the machine Environment key for writing' }
                try {
                    $raw = "$($k.GetValue('Path', $null, 'DoNotExpandEnvironmentNames'))"
                    $have = @($raw -split ';' | Where-Object { $_.Trim() } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') })
                    $defaults = '%SystemRoot%\system32', '%SystemRoot%', '%SystemRoot%\System32\Wbem', '%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\'
                    $missing = @($defaults | Where-Object { $d = [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\'); -not ($have | Where-Object { $_ -ieq $d }) })
                    if ($missing.Count) {
                        $bak = Join-Path (Get-RepBackupDir) ("path-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                        Set-Content -LiteralPath $bak -Value $raw -Encoding UTF8 -ErrorAction Stop
                        $new = (($missing -join ';') + ';' + $raw.TrimStart(';'))
                        $k.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                        Write-RepLog "Prepended to machine PATH: $($missing -join ';') (backup: $bak)" 'Info'
                    }
                    foreach ($n in 'TEMP', 'TMP') {
                        $v = $k.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
                        if ($v) { $p = [Environment]::ExpandEnvironmentVariables("$v"); if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } }
                    }
                } finally { $k.Close() }
                $uk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
                if ($uk) {
                    try {
                        foreach ($n in 'TEMP', 'TMP') {
                            $v = $uk.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
                            if ($v) { $p = [Environment]::ExpandEnvironmentVariables("$v"); if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } }
                        }
                    } finally { $uk.Close() }
                }
            } -FixRisk Safe -FixLabel 'Re-add default PATH entries (backup first) + create missing TEMP folders'

        New-DiagnosticCheck -Id verifier-on -Name 'Driver Verifier left enabled' -Category System `
            -Scan {
                $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
                $drv = Get-RepRegValue $mm 'VerifyDrivers'
                $lvl = Get-RepRegValue $mm 'VerifyDriverLevel'
                if ("$drv".Trim() -or ($null -ne $lvl -and $lvl -ne 0)) {
                    @{ Status = 'Fail'; Detail = "Driver Verifier is active (drivers: '$drv', level: $lvl) - causes slowdowns and deliberate BSODs" }
                } else { @{ Status = 'OK'; Detail = 'Driver Verifier off' } }
            } `
            -Fix {
                & verifier.exe /reset *> $null
                if ($LASTEXITCODE -notin 0, 2) { throw "verifier /reset failed (exit $LASTEXITCODE)" }
            } -FixRisk Moderate -FixLabel 'Turn Driver Verifier off (verifier /reset)' -Reboot $true

        New-DiagnosticCheck -Id activation -Name 'Windows activation' -Category System `
            -Scan {
                try { $lic = @(Get-RepLicenseStatus -TimeoutSec 45) }
                catch { return @{ Status = 'Skip'; Detail = "Activation status unavailable: $($_.Exception.Message)" } }
                if (-not $lic.Count) { return @{ Status = 'Warn'; Detail = 'No Windows product key installed' } }
                $names = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOB grace'; 3 = 'OOT grace'; 4 = 'Non-genuine grace'; 5 = 'Notification'; 6 = 'Extended grace' }
                $s = if ($lic -contains 1) { 1 } else { [int]$lic[0] }
                $label = if ($names.ContainsKey($s)) { $names[$s] } else { "status $s" }
                if ($s -eq 1) { @{ Status = 'OK'; Detail = 'Windows is activated' } }
                elseif ($s -in 0, 4) { @{ Status = 'Fail'; Detail = "Windows not activated ($label)" } }
                else { @{ Status = 'Warn'; Detail = "Windows activation: $label" } }
            } -Fix $null
    )
}

# =====================================================================
# SELECTION
#   -Include alone = run only those ids; with -Category it adds to the category set.
# =====================================================================
function Resolve-CheckSelection {
    param([object[]]$Registry, [string[]]$Category, [string[]]$Include, [string[]]$Exclude)
    $Category = ConvertTo-RepIdList $Category
    $Include  = ConvertTo-RepIdList $Include
    $Exclude  = ConvertTo-RepIdList $Exclude
    foreach ($c in $Registry) {
        $on = $true
        if ($Category -and ($c.Category -notin $Category)) { $on = $false }
        if ($Include -and -not $Category) { $on = $false }
        if (($Include -contains $c.Id) -or ($Include -contains $c.Name)) { $on = $true }
        if (($Exclude -contains $c.Id) -or ($Exclude -contains $c.Name)) { $on = $false }
        if ($on) { $c }
    }
}

# =====================================================================
# SCAN / FIX
# =====================================================================
function Invoke-Scan {
    param([object]$Check)
    $r = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $r = & $Check.Scan } catch { $r = @{ Status = 'Skip'; Detail = $_.Exception.Message } }
    $sw.Stop()
    # Tolerate stray pipeline output: keep the last hashtable the scan emitted.
    if ($r -isnot [hashtable]) { $r = @($r | Where-Object { $_ -is [hashtable] }) | Select-Object -Last 1 }
    if (-not $r) { $r = @{ Status = 'Skip'; Detail = 'Scan returned no result' } }
    [pscustomobject]@{
        Id = $Check.Id; Name = $Check.Name; Category = $Check.Category
        Status = $r.Status; Detail = $r.Detail
        HasFix   = ([bool]$Check.Fix -and -not $r.NoFix)
        FixRisk  = $(if ($r.FixRisk)  { $r.FixRisk }  else { $Check.FixRisk })
        FixLabel = $(if ($r.FixLabel) { $r.FixLabel } else { $Check.FixLabel })
        Reboot   = $(if ($r.ContainsKey('Reboot')) { [bool]$r.Reboot } else { $Check.Reboot })
        ScanMs   = $sw.ElapsedMilliseconds
        PreFixStatus = $null
        FixOutcome   = $null
    }
}

# Applies a fix, then re-scans. Returns the outcome:
#   Fixed | PendingReboot | StillFailing | Unverified | Error | Previewed
# and (with -Result) updates that report row with the post-fix status.
function Invoke-Fix {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Check, [object]$Result)
    if (-not $PSCmdlet.ShouldProcess($Check.Name, "Fix: $($Check.FixLabel)")) {
        $script:Previewed++
        if ($Result) { $Result.FixOutcome = 'Previewed' }
        return 'Previewed'
    }
    $script:FixNeedsReboot = $false
    $err = $null
    try { & $Check.Fix } catch { $err = $_.Exception.Message }
    $post = Invoke-Scan -Check $Check
    $needsReboot = [bool]($Check.Reboot -or $script:FixNeedsReboot -or ($Result -and $Result.Reboot))
    $outcome = if ($err)                      { 'Error' }
               elseif ($post.Status -eq 'OK') { 'Fixed' }
               elseif ($needsReboot)          { 'PendingReboot' }
               elseif ($post.Status -eq 'Skip') { 'Unverified' }
               else                           { 'StillFailing' }
    switch ($outcome) {
        'Fixed'         { $script:Fixed++;         Write-RepLog "Fixed: $($Check.Name)" 'Success' }
        'PendingReboot' { $script:PendingReboot++; Write-RepLog "Applied, restart required: $($Check.Name) - $($post.Detail)" 'Warning' }
        'Error'         { $script:FixErrors++;     Write-RepLog "  fix $($Check.Name): $err" 'Error' }
        default         { $script:StillFailing++;  Write-RepLog "Fix applied but not confirmed ($($post.Status)): $($Check.Name) - $($post.Detail)" 'Warning' }
    }
    if ($script:FixNeedsReboot -or ($needsReboot -and $outcome -in 'Fixed', 'PendingReboot')) { $script:RebootNeeded = $true }
    if ($Result) {
        $Result.PreFixStatus = $Result.Status
        $Result.Status       = $post.Status
        $Result.Detail       = $post.Detail
        $Result.HasFix       = $post.HasFix
        $Result.FixOutcome   = $outcome
    }
    $outcome
}

function Get-StatusColor { param([string]$S)
    switch ($S) { 'OK' { 'Green' } 'Warn' { 'Yellow' } 'Fail' { 'Red' } default { 'DarkGray' } } }

function Show-ScanReport {
    Write-RepLog '' 'Info'
    Write-RepLog '===== HEALTH REPORT =====' 'Step'
    $last = $null
    foreach ($r in $script:Results) {
        if ($r.Category -ne $last) { Write-Host ("  {0}" -f $r.Category) -ForegroundColor Cyan; $last = $r.Category }
        $mark = switch ($r.Status) { 'OK' { 'OK  ' } 'Warn' { 'WARN' } 'Fail' { 'FAIL' } default { 'skip' } }
        Write-Host ("    [{0}] {1,-34} {2}" -f $mark, $r.Name, $r.Detail) -ForegroundColor (Get-StatusColor $r.Status)
    }
    $warn = @($script:Results | Where-Object Status -eq 'Warn').Count
    $fail = @($script:Results | Where-Object Status -eq 'Fail').Count
    Write-RepLog '' 'Info'
    Write-RepLog ("Issues found: {0} failing, {1} warning, {2} OK" -f $fail, $warn,
        @($script:Results | Where-Object Status -eq 'OK').Count) $(if ($fail) { 'Error' } elseif ($warn) { 'Warning' } else { 'Success' })
}

function Write-RepReport {
    Write-WinSeniorReport -ReportPath $ReportPath -Engine 'Repair' `
        -RestorePoint $script:RestorePointMade -StartTime $script:StartTime `
        -Summary @{
            Fixed         = $script:Fixed
            PendingReboot = $script:PendingReboot
            StillFailing  = $script:StillFailing
            Previewed     = $script:Previewed
            FixErrors     = $script:FixErrors
            Reboot        = $script:RebootNeeded
        } `
        -Items $script:Results `
        -LogAction { param($m, $l) Write-RepLog $m $l }
}

# =====================================================================
# UI: help / list
# =====================================================================
function Show-CheckList {
    Write-Host ''
    Write-Host 'Diagnostic check registry:' -ForegroundColor Cyan
    Get-DiagnosticCheckRegistry |
        Format-Table @{ L='Id'; E={$_.Id}; W=18 },
                     @{ L='Category'; E={$_.Category}; W=10 },
                     @{ L='Fix'; E={ if($_.Fix){$_.FixRisk}else{'(report only)'} }; W=14 },
                     @{ L='Check'; E={$_.Name} } -AutoSize
    Write-Host ''
}

function Show-RepUsageHelp {
@'
Windows Troubleshooting engine v{VERSION}  (scan -> report -> repair)

USAGE
  .\Repair-Windows-Senior.ps1 [options]

SELECTION
  -Category <names>     Limit to: Integrity, Disk, Update, Network, Devices, Services, Security, System
  -Include <ids>        Run only these checks (with -Category: add them)  (see -ListChecks)
  -Exclude <ids>        Force checks off

FLOW
  (default)             Scan, show report, then choose what to repair
  -ScanOnly             Diagnose only - never change anything
  -FixAll               Non-interactive: auto-apply fixable issues (Safe+Moderate)
  -IncludeHeavy         With -FixAll, also apply Aggressive (heavy/reboot) repairs
  -Conservative         Cap every fix path at Safe + Moderate

SAFETY
  -WhatIf / -DryRun,-dr Preview only, change nothing (real ShouldProcess)
  -NoRestorePoint,-nrp  Skip the restore point made before repairs
  -Unattended,-Force,-f No prompts; alone it only scans + reports (add -FixAll to repair)

OUTPUT
  -LogPath <path>       Text log (default: %TEMP%\WindowsRepair.log)
  -ReportPath <path>    Machine-readable JSON report (rewritten after repairs)
  -ListChecks           Print the check registry and exit
  -Help                 Show this help

EXAMPLES
  .\Repair-Windows-Senior.ps1
  .\Repair-Windows-Senior.ps1 -ScanOnly
  .\Repair-Windows-Senior.ps1 -FixAll -IncludeHeavy -Unattended
'@ -replace '\{VERSION\}', (Get-WinSeniorVersion) | Write-Host
}

# =====================================================================
# MAIN
# =====================================================================
function Start-WindowsRepair {
    Write-RepLog ("Windows Troubleshooting v{0}" -f (Get-WinSeniorVersion)) 'Step'
    Write-RepLog ("PowerShell {0} | Mode: {1}" -f $PSVersionTable.PSVersion, $(if (Test-WhatIfMode) { 'DryRun' } else { 'Live' })) 'Info'
    if (-not (Test-AdminPrivileges)) { Write-RepLog 'Administrator privileges are required. Re-run as Administrator.' 'Error'; exit 2 }

    $registry  = Get-DiagnosticCheckRegistry
    $selection = @(Resolve-CheckSelection -Registry $registry -Category $Category -Include $Include -Exclude $Exclude)
    if (-not $selection.Count) { Write-RepLog 'No checks selected.' 'Warning'; return }

    Write-RepLog ("Scanning {0} check(s)..." -f $selection.Count) 'Info'
    # The licensing query is slow cold: run it alongside the other scans.
    if ($selection | Where-Object { $_.Id -eq 'activation' }) { Invoke-RepLicensePrefetch }
    foreach ($c in $selection) {
        Write-RepLog ("  scanning: {0}" -f $c.Name) 'Debug'
        $script:Results.Add((Invoke-Scan -Check $c))
    }
    Show-ScanReport
    Write-RepReport

    if ($ScanOnly) { return }

    # Fixable = Warn/Fail with a Fix that applies to this finding.
    $rank = @{ Safe = 0; Moderate = 1; Aggressive = 2 }
    $fixable = @($script:Results | Where-Object { $_.HasFix -and $_.Status -in 'Warn','Fail' })
    if (-not $fixable.Count) { Write-RepLog 'No auto-fixable issues detected.' 'Success'; return }

    # Decide which to fix.
    $toFix = @()
    if ($FixAll) {
        $cap = if ($IncludeHeavy -and -not $Conservative) { 2 } else { 1 }
        $toFix = $fixable | Where-Object { $rank[$_.FixRisk] -le $cap }
    }
    elseif ($Unattended) {
        # -Unattended alone means "no prompts", not "repair everything".
        Write-RepLog ("{0} fixable issue(s) found; report only (add -FixAll to repair)." -f $fixable.Count) 'Info'
        return
    }
    elseif (-not (Test-WhatIfMode)) {
        Write-RepLog '' 'Info'
        Write-RepLog 'Fixable issues:' 'Step'
        $i = 0; $map = @{}
        foreach ($f in $fixable) {
            $i++; $map[$i] = $f
            $rb = if ($f.Reboot) { ' [reboot]' } else { '' }
            Write-Host ("   {0,2}. ({1,-10}) {2} -> {3}{4}" -f $i, $f.FixRisk, $f.Name, $f.FixLabel, $rb) -ForegroundColor (Get-StatusColor $f.Status)
        }
        Write-Host ''
        Write-Host '  Enter numbers to fix | a=all safe (Safe+Moderate)  h=all incl. heavy  Enter=skip' -ForegroundColor DarkGray
        $in = (Read-Host '  >').Trim()
        if ($in -eq '')      { Write-RepLog 'No repairs selected.' 'Info'; return }
        elseif ($in -eq 'a') { $toFix = $fixable | Where-Object { $rank[$_.FixRisk] -le 1 } }
        elseif ($in -eq 'h') { $toFix = $fixable }
        else {
            $sel = @()
            foreach ($tok in ($in -split '[\s,]+')) { if ($tok -match '^\d+$' -and $map.ContainsKey([int]$tok)) { $sel += $map[[int]$tok] } }
            $toFix = $sel
        }
    }
    else {
        # -WhatIf: preview fixing everything fixable.
        $toFix = $fixable
    }

    # -Conservative caps every path (interactive 'h' and -WhatIf previews included).
    if ($Conservative) {
        $skipped = @($toFix | Where-Object { $rank[$_.FixRisk] -gt 1 })
        foreach ($s in $skipped) { Write-RepLog "Conservative: skipping Aggressive fix '$($s.Name)'" 'Info' }
        $toFix = $toFix | Where-Object { $rank[$_.FixRisk] -le 1 }
    }

    $toFix = @($toFix)
    if (-not $toFix.Count) { Write-RepLog 'Nothing to repair.' 'Info'; return }

    if (-not $NoRestorePoint -and -not (Test-WhatIfMode)) { New-RepairRestorePoint | Out-Null }

    foreach ($r in $toFix) {
        $check = $registry | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
        if ($check) { Invoke-Fix -Check $check -Result $r | Out-Null }
    }

    Write-RepLog '' 'Info'
    if (Test-WhatIfMode) { Write-RepLog ("Would fix: {0} issue(s)" -f $script:Previewed) 'WhatIf' }
    else {
        Write-RepLog ("Fixed: {0} | restart pending: {1} | not resolved: {2} | errors: {3}" -f
            $script:Fixed, $script:PendingReboot, $script:StillFailing, $script:FixErrors) $(if ($script:FixErrors -or $script:StillFailing) { 'Warning' } else { 'Success' })
    }
    if ($script:RebootNeeded) { Write-RepLog 'A reboot is required to complete some repairs.' 'Warning' }
    # Rewrite the report with post-fix statuses, counters and the reboot flag.
    Write-RepReport
    Write-RepLog ("Duration: {0:N1}s   Log: {1}" -f ((Get-Date) - $script:StartTime).TotalSeconds, $LogPath) 'Info'
}

# =====================================================================
# ENTRY POINT
# =====================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ($Help)       { Show-RepUsageHelp; exit 0 }
    if ($ListChecks) { Show-CheckList;    exit 0 }
    # The desktop app passes '-Include a,b,c' through -File as ONE string: split it.
    $Category = ConvertTo-RepIdList $Category
    $Include  = ConvertTo-RepIdList $Include
    $Exclude  = ConvertTo-RepIdList $Exclude
    Start-WindowsRepair
}
