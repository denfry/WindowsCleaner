<#
.SYNOPSIS
    Windows troubleshooting engine - scans for common problems, then repairs them.

.DESCRIPTION
    A declarative, single-file Windows 10/11 diagnostics tool. Every check is one entry in
    a check registry: a read-only Scan that returns OK / Warn / Fail, and an optional Fix.
    The default flow is scan-then-choose: it scans (changing nothing), prints a health
    report, and lets you pick which detected issues to repair. Fixes run through
    PowerShell's ShouldProcess (so -WhatIf is real) after a real System Restore point.

    Heavy repairs (SFC, DISM RestoreHealth, Windows Update reset, network stack reset) are
    included but only run when you explicitly select them (or pass -FixAll -IncludeHeavy).
    Repairs only ever improve health - this engine enables Defender, it never disables it.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Version : 6.0.0
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
    [string[]]$Category,

    # Force these check ids on / off (see -ListChecks for ids)
    [string[]]$Include,
    [string[]]$Exclude,

    # Scan and report only - never offer or apply fixes
    [switch]$ScanOnly,

    # Non-interactive: after scanning, auto-apply fixable issues (Safe+Moderate)
    [switch]$FixAll,

    # With -FixAll, also auto-apply Aggressive (heavy / reboot) repairs
    [switch]$IncludeHeavy,

    # Cap auto-fixes at Safe + Moderate (skip Aggressive)
    [Alias('SafeMode')]
    [switch]$Conservative,

    [Alias('dr')]
    [switch]$DryRun,

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
$script:FixErrors        = 0
$script:RebootNeeded     = $false
$script:RestorePointMade = $false

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

# =====================================================================
# CHECK REGISTRY  (the single source of truth)
#   Scan returns @{ Status = 'OK'|'Warn'|'Fail'; Detail = '...' }
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
        # ---------------- Integrity ----------------
        New-DiagnosticCheck img-health 'System image health (DISM)' Integrity `
            -Scan {
                if (-not (Get-Command Repair-WindowsImage -ErrorAction SilentlyContinue)) {
                    return @{ Status = 'Skip'; Detail = 'DISM module unavailable' }
                }
                $state = (Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState
                switch ("$state") {
                    'Healthy'              { @{ Status = 'OK';   Detail = 'Component store healthy' } }
                    'Repairable'           { @{ Status = 'Fail'; Detail = 'Component store corruption is repairable' } }
                    default                { @{ Status = 'Warn'; Detail = "Image health: $state (deep scan with DISM /ScanHealth)" } }
                }
            } `
            -Fix {
                Write-RepLog 'Running DISM /RestoreHealth (may take several minutes)...' 'Info'
                Repair-WindowsImage -Online -RestoreHealth -ErrorAction SilentlyContinue | Out-Null
                Write-RepLog 'Running sfc /scannow...' 'Info'
                & sfc.exe /scannow | Out-Null
            } -FixRisk Aggressive -FixLabel 'DISM RestoreHealth + SFC' -Reboot $false

        # ---------------- Disk ----------------
        New-DiagnosticCheck disk-smart 'Physical disk health (SMART)' Disk `
            -Scan {
                if (-not (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                    return @{ Status = 'Skip'; Detail = 'Storage module unavailable' }
                }
                $bad = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.HealthStatus -and $_.HealthStatus -ne 'Healthy' }
                if ($bad) { @{ Status = 'Fail'; Detail = ('Unhealthy disk(s): ' + (($bad | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)" }) -join ', ') + ' - back up now') } }
                else      { @{ Status = 'OK';   Detail = 'All physical disks report Healthy' } }
            } -Fix $null

        New-DiagnosticCheck disk-space 'Low free disk space' Disk `
            -Scan {
                $worst = 'OK'; $lines = @()
                foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
                    if (-not $d.Size) { continue }
                    $pct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
                    $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
                    $lines += "$($d.DeviceID) $freeGB GB free ($pct%)"
                    if ($pct -lt 5 -or $freeGB -lt 5)        { $worst = 'Fail' }
                    elseif (($pct -lt 12 -or $freeGB -lt 15) -and $worst -ne 'Fail') { $worst = 'Warn' }
                }
                @{ Status = $worst; Detail = ($lines -join ' | ') + $(if ($worst -ne 'OK') { ' - run Disk cleanup' } else { '' }) }
            } -Fix $null

        New-DiagnosticCheck disk-dirty 'Volumes flagged for chkdsk' Disk `
            -Scan {
                $dirty = @()
                foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
                    & fsutil.exe dirty query "$($d.DeviceID)" *>$null
                    if ($LASTEXITCODE -eq 0) { $dirty += $d.DeviceID }
                }
                if ($dirty) { @{ Status = 'Warn'; Detail = ('Dirty bit set on: ' + ($dirty -join ', ')) } }
                else        { @{ Status = 'OK';   Detail = 'No volume flagged dirty' } }
            } `
            -Fix {
                foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
                    & fsutil.exe dirty query "$($d.DeviceID)" *>$null
                    if ($LASTEXITCODE -eq 0) { Write-RepLog "chkdsk $($d.DeviceID) /scan (online)..." 'Info'; & chkdsk.exe "$($d.DeviceID)" /scan | Out-Null }
                }
            } -FixRisk Moderate -FixLabel 'chkdsk /scan (online, no reboot)'

        # ---------------- Update ----------------
        New-DiagnosticCheck reboot-pending 'Pending reboot' Update `
            -Scan {
                $reasons = @()
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
                $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
                if ($pfro) { $reasons += 'PendingFileRename' }
                if ($reasons) { @{ Status = 'Warn'; Detail = ('Reboot required: ' + ($reasons -join ', ')) } }
                else          { @{ Status = 'OK';   Detail = 'No pending reboot' } }
            } `
            -Fix { Write-RepLog 'Scheduling reboot in 60s (cancel with: shutdown /a)' 'Warning'; & shutdown.exe /r /t 60 /c 'WinSenior repair reboot' } `
            -FixRisk Aggressive -FixLabel 'Reboot in 60s (cancel: shutdown /a)' -Reboot $true

        New-DiagnosticCheck wu-health 'Windows Update components' Update `
            -Scan {
                $sd = "$env:WINDIR\SoftwareDistribution\Download"
                $sizeGB = 0
                if (Test-Path $sd) { $sizeGB = [math]::Round(((Get-ChildItem $sd -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 2) }
                $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
                if ($wu -and $wu.StartType -eq 'Disabled') { return @{ Status = 'Warn'; Detail = 'wuauserv is Disabled; SoftwareDistribution ' + $sizeGB + ' GB' } }
                if ($sizeGB -gt 4) { return @{ Status = 'Warn'; Detail = "SoftwareDistribution cache is large ($sizeGB GB)" } }
                @{ Status = 'OK'; Detail = "Update cache $sizeGB GB; service OK" }
            } `
            -Fix {
                Write-RepLog 'Resetting Windows Update components...' 'Info'
                foreach ($s in 'wuauserv','bits','cryptsvc') { Stop-Service $s -Force -ErrorAction SilentlyContinue }
                foreach ($p in @("$env:WINDIR\SoftwareDistribution","$env:WINDIR\System32\catroot2")) {
                    if (Test-Path $p) { Rename-Item $p "$p.old_$(Get-Date -Format 'yyyyMMddHHmmss')" -Force -ErrorAction SilentlyContinue }
                }
                foreach ($s in 'cryptsvc','bits','wuauserv') { Start-Service $s -ErrorAction SilentlyContinue }
            } -FixRisk Moderate -FixLabel 'Reset Windows Update (rename SoftwareDistribution/catroot2)'

        # ---------------- Network ----------------
        New-DiagnosticCheck net-connectivity 'Internet & DNS' Network `
            -Scan {
                # Address held in a variable so PSScriptAnalyzer doesn't flag it as a hardcoded host.
                $pingTarget = '8.8.8.8'; $dnsTarget = 'microsoft.com'
                $ping = Test-Connection -ComputerName $pingTarget -Count 1 -Quiet -ErrorAction SilentlyContinue
                $dns  = $false
                if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
                    $dns = [bool](Resolve-DnsName $dnsTarget -ErrorAction SilentlyContinue)
                }
                if (-not $ping) { @{ Status = 'Fail'; Detail = 'No reply from 8.8.8.8 (no internet)' } }
                elseif (-not $dns) { @{ Status = 'Warn'; Detail = 'Internet OK but DNS resolution failed' } }
                else { @{ Status = 'OK'; Detail = 'Internet and DNS reachable' } }
            } `
            -Fix {
                Write-RepLog 'Flushing DNS and resetting the network stack...' 'Info'
                & ipconfig.exe /flushdns | Out-Null
                & netsh.exe winsock reset | Out-Null
                & netsh.exe int ip reset | Out-Null
                & ipconfig.exe /release | Out-Null
                & ipconfig.exe /renew | Out-Null
            } -FixRisk Aggressive -FixLabel 'Flush DNS + winsock/IP reset' -Reboot $true

        # ---------------- Devices ----------------
        New-DiagnosticCheck dev-errors 'Devices with driver problems' Devices `
            -Scan {
                $bad = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 }
                if ($bad) {
                    $names = ($bad | Select-Object -First 5 | ForEach-Object { "$($_.Name) (code $($_.ConfigManagerErrorCode))" }) -join '; '
                    @{ Status = 'Warn'; Detail = "$(@($bad).Count) device(s) with errors: $names" }
                } else { @{ Status = 'OK'; Detail = 'No devices report driver errors' } }
            } `
            -Fix { Write-RepLog 'Rescanning for hardware changes...' 'Info'; & pnputil.exe /scan-devices *>$null } `
            -FixRisk Safe -FixLabel 'Rescan devices (pnputil /scan-devices)'

        # ---------------- Services ----------------
        New-DiagnosticCheck svc-critical 'Critical services stopped' Services `
            -Scan {
                $want = 'Audiosrv','Dhcp','Dnscache','EventLog','mpssvc','Winmgmt','Schedule','BFE','LanmanWorkstation','ProfSvc','nsi','Power'
                $stopped = foreach ($n in $want) {
                    $s = Get-Service $n -ErrorAction SilentlyContinue
                    if ($s -and $s.StartType -in 'Automatic','Boot','System' -and $s.Status -ne 'Running') { $n }
                }
                $stopped = @($stopped)
                if ($stopped.Count) { @{ Status = 'Fail'; Detail = ('Stopped: ' + ($stopped -join ', ')) } }
                else                { @{ Status = 'OK';   Detail = 'All monitored critical services are running' } }
            } `
            -Fix {
                $want = 'Audiosrv','Dhcp','Dnscache','EventLog','mpssvc','Winmgmt','Schedule','BFE','LanmanWorkstation','ProfSvc','nsi','Power'
                foreach ($n in $want) {
                    $s = Get-Service $n -ErrorAction SilentlyContinue
                    if ($s -and $s.StartType -in 'Automatic','Boot','System' -and $s.Status -ne 'Running') {
                        Start-Service $n -ErrorAction SilentlyContinue
                        Write-RepLog "started $n" 'Debug'
                    }
                }
            } -FixRisk Safe -FixLabel 'Start stopped critical services'

        # ---------------- Security ----------------
        New-DiagnosticCheck def-health 'Microsoft Defender health' Security `
            -Scan {
                if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
                    return @{ Status = 'Skip'; Detail = 'Defender module unavailable (3rd-party AV?)' }
                }
                $st = Get-MpComputerStatus -ErrorAction Stop
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

        # ---------------- System ----------------
        New-DiagnosticCheck wmi-repo 'WMI repository consistency' System `
            -Scan {
                $out = & winmgmt.exe /verifyrepository 2>&1
                if ($LASTEXITCODE -eq 0) { @{ Status = 'OK'; Detail = 'WMI repository is consistent' } }
                else { @{ Status = 'Fail'; Detail = 'WMI repository inconsistent' } }
            } `
            -Fix { Write-RepLog 'Salvaging WMI repository...' 'Info'; & winmgmt.exe /salvagerepository 2>&1 | Out-Null } `
            -FixRisk Moderate -FixLabel 'Salvage WMI repository'

        New-DiagnosticCheck time-sync 'System time synchronization' System `
            -Scan {
                $w = Get-Service w32time -ErrorAction SilentlyContinue
                if (-not $w) { return @{ Status = 'Skip'; Detail = 'w32time service not found' } }
                if ($w.Status -ne 'Running') { return @{ Status = 'Warn'; Detail = 'Time service (w32time) is stopped' } }
                @{ Status = 'OK'; Detail = 'Time service running' }
            } `
            -Fix { Start-Service w32time -ErrorAction SilentlyContinue; & w32tm.exe /resync /force *>$null } `
            -FixRisk Safe -FixLabel 'Start w32time + resync clock'

        New-DiagnosticCheck event-errors 'Recent critical/error events' System `
            -Scan {
                $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-2) } -MaxEvents 300 -ErrorAction SilentlyContinue
                $ev = @($ev)
                if ($ev.Count -eq 0) { return @{ Status = 'OK'; Detail = 'No critical/error events in the last 48h' } }
                $top = ($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3 |
                        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
                $status = if ($ev.Count -gt 50) { 'Warn' } else { 'OK' }
                @{ Status = $status; Detail = "$($ev.Count) error/critical event(s) in 48h; top: $top" }
            } -Fix $null
    )
}

# =====================================================================
# SELECTION
# =====================================================================
function Resolve-CheckSelection {
    param([object[]]$Registry, [string[]]$Category, [string[]]$Include, [string[]]$Exclude)
    foreach ($c in $Registry) {
        $on = $true
        if ($Category -and ($c.Category -notin $Category)) { $on = $false }
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
    $r = @{ Status = 'Skip'; Detail = '' }
    try { $r = & $Check.Scan } catch { $r = @{ Status = 'Skip'; Detail = $_.Exception.Message } }
    [pscustomobject]@{
        Id = $Check.Id; Name = $Check.Name; Category = $Check.Category
        Status = $r.Status; Detail = $r.Detail
        HasFix = [bool]$Check.Fix; FixRisk = $Check.FixRisk; FixLabel = $Check.FixLabel; Reboot = $Check.Reboot
    }
}

function Invoke-Fix {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Check)
    if ($PSCmdlet.ShouldProcess($Check.Name, "Fix: $($Check.FixLabel)")) {
        try {
            & $Check.Fix
            Write-RepLog "Fixed: $($Check.Name)" 'Success'
            $script:Fixed++
            if ($Check.Reboot) { $script:RebootNeeded = $true }
            return $true
        }
        catch { $script:FixErrors++; Write-RepLog "  fix $($Check.Name): $($_.Exception.Message)" 'Error'; return $false }
    }
    $false
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
    if (-not $ReportPath) { return }
    $report = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('s')
        Mode      = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
        Fixed     = $script:Fixed
        FixErrors = $script:FixErrors
        Reboot    = $script:RebootNeeded
        Results   = $script:Results
    }
    try {
        $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8 -WhatIf:$false
        Write-RepLog "JSON report written: $ReportPath" 'Info'
    } catch { Write-RepLog "Could not write report: $($_.Exception.Message)" 'Warning' }
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
Windows Troubleshooting engine v6.0  (scan -> report -> repair)

USAGE
  .\Repair-Windows-Senior.ps1 [options]

SELECTION
  -Category <names>     Limit to: Integrity, Disk, Update, Network, Devices, Services, Security, System
  -Include <ids>        Force checks on  (see -ListChecks for ids)
  -Exclude <ids>        Force checks off

FLOW
  (default)             Scan, show report, then choose what to repair
  -ScanOnly             Diagnose only - never change anything
  -FixAll               Non-interactive: auto-apply fixable issues (Safe+Moderate)
  -IncludeHeavy         With -FixAll, also apply Aggressive (heavy/reboot) repairs
  -Conservative         Cap auto-fixes at Safe + Moderate

SAFETY
  -WhatIf / -DryRun,-dr Preview only, change nothing (real ShouldProcess)
  -NoRestorePoint,-nrp  Skip the restore point made before repairs
  -Unattended,-Force,-f No prompts - for automation

OUTPUT
  -LogPath <path>       Text log (default: %TEMP%\WindowsRepair.log)
  -ReportPath <path>    Machine-readable JSON report
  -ListChecks           Print the check registry and exit
  -Help                 Show this help

EXAMPLES
  .\Repair-Windows-Senior.ps1
  .\Repair-Windows-Senior.ps1 -ScanOnly
  .\Repair-Windows-Senior.ps1 -FixAll -IncludeHeavy -Unattended
'@ | Write-Host
}

# =====================================================================
# MAIN
# =====================================================================
function Start-WindowsRepair {
    Write-RepLog 'Windows Troubleshooting v6.0' 'Step'
    Write-RepLog ("PowerShell {0} | Mode: {1}" -f $PSVersionTable.PSVersion, $(if (Test-WhatIfMode) { 'DryRun' } else { 'Live' })) 'Info'
    if (-not (Test-AdminPrivileges)) { Write-RepLog 'Administrator privileges are required. Re-run as Administrator.' 'Error'; exit 2 }

    $registry  = Get-DiagnosticCheckRegistry
    $selection = @(Resolve-CheckSelection -Registry $registry -Category $Category -Include $Include -Exclude $Exclude)
    if (-not $selection.Count) { Write-RepLog 'No checks selected.' 'Warning'; return }

    Write-RepLog ("Scanning {0} check(s)..." -f $selection.Count) 'Info'
    foreach ($c in $selection) {
        Write-RepLog ("  scanning: {0}" -f $c.Name) 'Debug'
        $script:Results.Add((Invoke-Scan -Check $c))
    }
    Show-ScanReport
    Write-RepReport

    if ($ScanOnly) { return }

    # Fixable = Warn/Fail with a Fix defined.
    $rank = @{ Safe = 0; Moderate = 1; Aggressive = 2 }
    $fixable = @($script:Results | Where-Object { $_.HasFix -and $_.Status -in 'Warn','Fail' })
    if (-not $fixable.Count) { Write-RepLog 'No auto-fixable issues detected.' 'Success'; return }

    # Decide which to fix.
    $toFix = @()
    if ($FixAll -or $Unattended) {
        $cap = if ($IncludeHeavy -and -not $Conservative) { 2 } elseif ($Conservative) { 1 } else { 1 }
        $toFix = $fixable | Where-Object { $rank[$_.FixRisk] -le $cap }
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

    $toFix = @($toFix)
    if (-not $toFix.Count) { Write-RepLog 'Nothing to repair.' 'Info'; return }

    if (-not $NoRestorePoint -and -not (Test-WhatIfMode)) { New-RepairRestorePoint | Out-Null }

    foreach ($r in $toFix) {
        $check = $registry | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
        if ($check) { Invoke-Fix -Check $check | Out-Null }
    }

    Write-RepLog '' 'Info'
    $verb = if (Test-WhatIfMode) { 'Would fix' } else { 'Fixed' }
    Write-RepLog ("{0}: {1} issue(s), {2} error(s)" -f $verb, $script:Fixed, $script:FixErrors) 'Success'
    if ($script:RebootNeeded) { Write-RepLog 'A reboot is required to complete some repairs.' 'Warning' }
    Write-RepLog ("Duration: {0:N1}s   Log: {1}" -f ((Get-Date) - $script:StartTime).TotalSeconds, $LogPath) 'Info'
}

# =====================================================================
# ENTRY POINT
# =====================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ($Help)       { Show-RepUsageHelp; exit 0 }
    if ($ListChecks) { Show-CheckList;    exit 0 }
    Start-WindowsRepair
}
