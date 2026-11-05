<#
.SYNOPSIS
    WinSenior drivers - official-source driver updates, GPU guidance, backup/restore.

.DESCRIPTION
    No third-party driver database, no download sites: every driver comes from
    Microsoft Update (the catalog Windows itself uses) through the Windows Update
    Agent COM API, and graphics drivers are pointed at the vendor's own page / app,
    because for gaming the vendor driver is newer and carries the game profiles.

      Get-WsGpuInfo             GPUs, vendor, driver version/age, official source
      Get-WsProblemDevice       devices with a Device Manager error code
      Find-WsDriverUpdate       WUA search "IsInstalled=0 and Type='Driver'" in a
                                separate process with a timeout (first scans are slow)
      Install-WsDriverUpdate    download + install selected updates (admin)
      Hide-WsDriverUpdate       IUpdate.IsHidden so WU stops pushing that driver
                                (keeps a vendor GPU driver from being replaced)
      Backup-WsDriverStore      pnputil /export-driver * <dir>   (Win10 1607+)
      Restore-WsDriverStore     pnputil /add-driver <dir>\*.inf /subdirs /install

.EXAMPLE
    .\WinSenior.Drivers.ps1                      # GPU + problem devices + available updates
    .\WinSenior.Drivers.ps1 -Install all         # install every non-GPU update found
    .\WinSenior.Drivers.ps1 -Backup              # export third-party drivers
    .\WinSenior.Drivers.ps1 -Restore D:\backup\20261105
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Install,
    [switch]$IncludeGpu,
    [switch]$HideGpuUpdates,
    [switch]$Backup,
    [string]$BackupPath,
    [string]$Restore,
    [int]$TimeoutSeconds = 900,
    [switch]$Unattended,
    [string]$LogPath = "$env:TEMP\WinSenior-Drivers.log",
    [string]$ReportPath
)

. (Join-Path $PSScriptRoot 'WinSenior.Common.ps1')
$wsWi = $global:WhatIfPreference
try { $global:WhatIfPreference = $false; Import-Module CimCmdlets -ErrorAction SilentlyContinue } finally { $global:WhatIfPreference = $wsWi }

function Write-DrvLog { param([string]$Message, [string]$Level = 'Info') Write-WsLog -Message $Message -Level $Level -LogPath $LogPath }

# =====================================================================
# GPU
# =====================================================================
# PCI vendor IDs -> official source. Pure table, Pester-tested.
function Get-WsGpuVendorTable {
    @{
        '10DE' = [pscustomobject]@{ Vendor = 'NVIDIA'; Url = 'https://www.nvidia.com/en-us/drivers/'
                    App = 'NVIDIA App'; WingetId = 'XP8CLZL93F5Z4P'; WingetSource = 'msstore' }
        '1002' = [pscustomobject]@{ Vendor = 'AMD'; Url = 'https://www.amd.com/en/support/download/drivers.html'
                    App = 'AMD Software: Adrenalin Edition (auto-detect tool on the page)'; WingetId = $null; WingetSource = $null }
        '8086' = [pscustomobject]@{ Vendor = 'Intel'; Url = 'https://www.intel.com/content/www/us/en/support/detect.html'
                    App = 'Intel Driver & Support Assistant'; WingetId = 'Intel.IntelDriverAndSupportAssistant'; WingetSource = 'winget' }
    }
}

# Pure: one Win32_VideoController-like row -> GPU record with advice.
function ConvertTo-WsGpuRecord {
    param([object]$Controller, [datetime]$Now = (Get-Date))
    $ven = if ([string]$Controller.PNPDeviceID -match 'VEN_([0-9A-Fa-f]{4})') { $Matches[1].ToUpperInvariant() } else { '' }
    $info = (Get-WsGpuVendorTable)[$ven]
    $date = $null
    if ($Controller.DriverDate) { try { $date = [datetime]$Controller.DriverDate } catch { $date = $null } }
    $age = if ($date) { [int]($Now - $date).TotalDays } else { $null }
    # NVIDIA: Windows version 32.0.15.6094 -> driver 560.94 (last 5 digits of the last two fields)
    $friendly = [string]$Controller.DriverVersion
    if ($ven -eq '10DE' -and $friendly -match '\.(\d+)\.(\d+)$') {
        $d = ($Matches[1] + $Matches[2]); if ($d.Length -ge 5) { $d = $d.Substring($d.Length - 5); $friendly = '{0}.{1}' -f [int]$d.Substring(0, 3), $d.Substring(3) }
    }
    $advice = if (-not $info) { 'Basic/virtual adapter - Windows Update is the right source.' }
              elseif ($null -ne $age -and $age -gt 180) { "Driver is $age days old - get the current one from $($info.Vendor) (official page / $($info.App))." }
              else { "Up to date enough ($age days). For games keep using $($info.Vendor)'s own driver, not Windows Update's." }
    [pscustomobject]@{
        Name = [string]$Controller.Name; Vendor = $(if ($info) { $info.Vendor } else { 'Other' }); VendorId = $ven
        DriverVersion = [string]$Controller.DriverVersion; VendorVersion = $friendly
        DriverDate = $date; AgeDays = $age; NeedsUpdate = [bool]($info -and $null -ne $age -and $age -gt 180)
        OfficialUrl = $(if ($info) { $info.Url } else { $null }); VendorApp = $(if ($info) { $info.App } else { $null })
        WingetId = $(if ($info) { $info.WingetId } else { $null }); WingetSource = $(if ($info) { $info.WingetSource } else { $null })
        Advice = $advice
    }
}

function Get-WsGpuInfo {
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -like 'PCI\*' } | ForEach-Object { ConvertTo-WsGpuRecord $_ }
}

# =====================================================================
# DEVICES
# =====================================================================
function Get-WsProblemDevice {
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 } |   # 22 = disabled by the user
        ForEach-Object {
            $hint = switch ([int]$_.ConfigManagerErrorCode) {
                1 { 'not configured correctly' } 3 { 'driver may be corrupted' } 10 { 'cannot start' }
                18 { 'reinstall the driver' } 28 { 'no driver installed' } 31 { 'driver failed to load' }
                39 { 'driver missing or corrupted' } 43 { 'device reported a problem (often hardware/driver)' }
                45 { 'not connected' } 52 { 'driver signature cannot be verified' }
                default { "error code $($_.ConfigManagerErrorCode)" }
            }
            [pscustomobject]@{ Name = $_.Name; Class = $_.PNPClass; Code = [int]$_.ConfigManagerErrorCode; Problem = $hint; DeviceId = $_.PNPDeviceID }
        }
}

# =====================================================================
# WINDOWS UPDATE AGENT
# =====================================================================
# The search body, run in a child process (Start-Job) so a stuck online scan can be
# abandoned after $TimeoutSeconds instead of hanging the app.
$script:WsWuSearchBlock = {
    $s = New-Object -ComObject Microsoft.Update.Session
    $s.ClientApplicationID = 'WinSenior'
    $q = $s.CreateUpdateSearcher()
    $q.Online = $true
    $r = $q.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    foreach ($u in $r.Updates) {
        [pscustomobject]@{
            UpdateId = [string]$u.Identity.UpdateID; Revision = [int]$u.Identity.RevisionNumber
            Title = [string]$u.Title; DriverClass = [string]$u.DriverClass
            DriverDate = $u.DriverVerDate; HardwareId = [string]$u.DriverHardwareID
            Manufacturer = [string]$u.DriverManufacturer; Model = [string]$u.DriverModel
            SizeBytes = [int64]$u.MaxDownloadSize; NeedsReboot = ([int]$u.InstallationBehavior.RebootBehavior -ne 0)
        }
    }
}

# Driver delivery switched off by policy (often left behind by "tweaker" tools):
# Windows Update then offers no drivers at all, so an empty result means nothing.
function Get-WsDriverPolicyBlock {
    $wu = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
    $ds = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' -ErrorAction SilentlyContinue
    $why = @()
    if ($wu -and [int]$wu.ExcludeWUDriversInQualityUpdate -eq 1) { $why += 'ExcludeWUDriversInQualityUpdate=1' }
    if ($ds -and [int]$ds.SearchOrderConfig -eq 0) { $why += 'DriverSearching\SearchOrderConfig=0' }
    if (-not $why) { return $null }
    "Windows Update is blocked from delivering drivers by policy ($($why -join ', ')). Remove it in Troubleshoot -> 'Windows Update blocked by policy' to get driver updates."
}

# Pure: GPU updates (class Display, or a PCI display vendor in the hardware id) are
# held back unless asked: Microsoft Update's GPU driver is usually older / OEM.
function Test-WsGpuDriverUpdate {
    param([object]$Update)
    ([string]$Update.DriverClass -match '^Display') -or ([string]$Update.HardwareId -match '^PCI\\VEN_(10DE|1002)&')
}

function Find-WsDriverUpdate {
    param([int]$TimeoutSeconds = 900)
    $job = Start-Job -ScriptBlock $script:WsWuSearchBlock
    try {
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            throw "Windows Update search did not finish in $TimeoutSeconds s (the update service may be busy - try again later)."
        }
        if ($job.State -eq 'Failed') { throw ($job.ChildJobs[0].JobStateInfo.Reason.Message) }
        @(Receive-Job -Job $job -ErrorAction Stop) | ForEach-Object {
            $_ | Add-Member -NotePropertyName IsGpu -NotePropertyValue (Test-WsGpuDriverUpdate $_) -PassThru -Force
        }
    }
    finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
}

function Get-WsUpdateById {
    param([string[]]$UpdateId, [switch]$IncludeHidden)
    $s = New-Object -ComObject Microsoft.Update.Session
    $s.ClientApplicationID = 'WinSenior'
    $q = $s.CreateUpdateSearcher(); $q.Online = $true
    $crit = if ($IncludeHidden) { "IsInstalled=0 and Type='Driver'" } else { "IsInstalled=0 and Type='Driver' and IsHidden=0" }
    $r = $q.Search($crit)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($u in $r.Updates) { if ($UpdateId -contains [string]$u.Identity.UpdateID) { $out.Add($u) } }
    [pscustomobject]@{ Session = $s; Updates = $out }
}

function Install-WsDriverUpdate {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$UpdateId)
    $found = Get-WsUpdateById -UpdateId $UpdateId
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
        if ($PSCmdlet.ShouldProcess($u.Title, 'Download and install driver')) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
        }
    }
    if ($coll.Count -eq 0) { return [pscustomobject]@{ Installed = 0; Failed = 0; RebootRequired = $false; Results = @() } }
    $dl = $found.Session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
    $inst = $found.Session.CreateUpdateInstaller(); $inst.Updates = $coll
    $res = $inst.Install()
    $rows = for ($i = 0; $i -lt $coll.Count; $i++) {
        $rc = [int]$res.GetUpdateResult($i).ResultCode       # 2 = succeeded, 3 = with errors, 4 = failed
        [pscustomobject]@{ Title = $coll.Item($i).Title; ResultCode = $rc; Ok = ($rc -eq 2 -or $rc -eq 3) }
    }
    [pscustomobject]@{
        Installed = @($rows | Where-Object Ok).Count; Failed = @($rows | Where-Object { -not $_.Ok }).Count
        RebootRequired = [bool]$res.RebootRequired; Results = [object[]]$rows
    }
}

function Hide-WsDriverUpdate {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$UpdateId)
    $n = 0
    foreach ($u in (Get-WsUpdateById -UpdateId $UpdateId).Updates) {
        if ($PSCmdlet.ShouldProcess($u.Title, 'Hide from Windows Update')) { $u.IsHidden = $true; $n++ }
    }
    $n
}

# =====================================================================
# BACKUP / RESTORE (third-party drivers in the driver store)
# =====================================================================
function Get-WsDefaultBackupPath {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) ("WinSenior\DriverBackup\{0:yyyyMMdd-HHmm}" -f (Get-Date))
}

function Backup-WsDriverStore {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path = (Get-WsDefaultBackupPath))
    if (-not $PSCmdlet.ShouldProcess($Path, 'Export all third-party drivers (pnputil)')) { return $null }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $out = & pnputil.exe /export-driver * "$Path" 2>&1
    $code = $LASTEXITCODE
    $infs = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue)
    [int64]$bytes = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Path = $Path; Drivers = $infs.Count; Bytes = $bytes; ExitCode = $code; Ok = ($code -eq 0 -and $infs.Count -gt 0); Output = ($out -join "`n") }
}

function Restore-WsDriverStore {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Backup folder not found: $Path" }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Add and install every driver in the backup (pnputil)')) { return $null }
    $out = & pnputil.exe /add-driver (Join-Path $Path '*.inf') /subdirs /install 2>&1
    $code = $LASTEXITCODE
    # 3010 = success, reboot required; 259 = nothing newer to install
    [pscustomobject]@{ Path = $Path; ExitCode = $code; Ok = ($code -in 0, 259, 3010); RebootRequired = ($code -eq 3010); Output = ($out -join "`n") }
}

# =====================================================================
# CLI
# =====================================================================
function Start-WsDrivers {
    $isAdmin = Test-AdminPrivileges
    if ($Backup) {
        if (-not $isAdmin) { Write-DrvLog 'Driver backup needs administrator rights.' 'Error'; exit 2 }
        $p = if ($BackupPath) { $BackupPath } else { Get-WsDefaultBackupPath }
        $r = Backup-WsDriverStore -Path $p
        if ($r) { Write-DrvLog ("Backed up {0} driver(s), {1} -> {2}" -f $r.Drivers, (Format-FileSize $r.Bytes), $r.Path) $(if ($r.Ok) { 'Success' } else { 'Error' }) }
        return
    }
    if ($Restore) {
        if (-not $isAdmin) { Write-DrvLog 'Driver restore needs administrator rights.' 'Error'; exit 2 }
        $r = Restore-WsDriverStore -Path $Restore
        if ($r) { Write-DrvLog ("Restore finished (exit {0}){1}" -f $r.ExitCode, $(if ($r.RebootRequired) { ' - reboot to finish' } else { '' })) $(if ($r.Ok) { 'Success' } else { 'Error' }) }
        return
    }

    Write-DrvLog 'Graphics' 'Step'
    $gpus = @(Get-WsGpuInfo)
    foreach ($g in $gpus) {
        Write-DrvLog ("  {0}  driver {1} ({2})" -f $g.Name, $g.VendorVersion, $(if ($g.DriverDate) { $g.DriverDate.ToString('yyyy-MM-dd') } else { 'date unknown' })) 'Info'
        Write-DrvLog "    $($g.Advice)" $(if ($g.NeedsUpdate) { 'Warning' } else { 'Success' })
        if ($g.OfficialUrl) { Write-DrvLog "    official: $($g.OfficialUrl)" 'Info' }
    }
    Write-DrvLog 'Devices with problems' 'Step'
    $bad = @(Get-WsProblemDevice)
    if (-not $bad) { Write-DrvLog '  none' 'Success' }
    foreach ($d in $bad) { Write-DrvLog ("  {0} [{1}]: {2}" -f $d.Name, $d.Class, $d.Problem) 'Warning' }

    Write-DrvLog 'Driver updates from Microsoft Update (this can take a few minutes)' 'Step'
    $pol = Get-WsDriverPolicyBlock
    if ($pol) { Write-DrvLog "  $pol" 'Warning' }
    $updates = @(); $searchOk = $true
    try { $updates = @(Find-WsDriverUpdate -TimeoutSeconds $TimeoutSeconds) }
    catch { $searchOk = $false; Write-DrvLog "  search failed: $($_.Exception.Message)" 'Error' }
    if ($searchOk -and -not $updates) { Write-DrvLog '  all drivers are current' 'Success' }
    foreach ($u in $updates) {
        $tag = if ($u.IsGpu) { ' [GPU - prefer the vendor driver]' } else { '' }
        Write-DrvLog ("  {0}  ({1}){2}" -f $u.Title, (Format-FileSize $u.SizeBytes), $tag) 'Info'
    }

    if ($HideGpuUpdates) {
        $gpuIds = @($updates | Where-Object IsGpu | ForEach-Object { $_.UpdateId })
        if ($gpuIds) { $n = Hide-WsDriverUpdate -UpdateId $gpuIds; Write-DrvLog "Hidden $n GPU driver update(s) from Windows Update." 'Success' }
    }

    $installed = $null
    if ($Install) {
        if (-not $isAdmin) { Write-DrvLog 'Installing drivers needs administrator rights.' 'Error'; exit 2 }
        $pick = if ($Install -contains 'all') { @($updates | Where-Object { $IncludeGpu -or -not $_.IsGpu }) }
                else { @($updates | Where-Object { $Install -contains $_.UpdateId -or $Install -contains $_.Title }) }
        if ($pick) {
            if (-not $Unattended -and -not (Test-WhatIfMode)) { New-WinSeniorRestorePoint -Description "Before driver install $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -LogAction { param($m, $l) Write-DrvLog $m $l } | Out-Null }
            $installed = Install-WsDriverUpdate -UpdateId @($pick | ForEach-Object { $_.UpdateId })
            foreach ($r in $installed.Results) { Write-DrvLog ("  {0}: {1}" -f $r.Title, $(if ($r.Ok) { 'installed' } else { "failed (code $($r.ResultCode))" })) $(if ($r.Ok) { 'Success' } else { 'Error' }) }
            if ($installed.RebootRequired) { Write-DrvLog 'Reboot to finish the driver installation.' 'Warning' }
        }
    }

    if ($ReportPath) {
        Write-WinSeniorReport -ReportPath $ReportPath -Engine 'Drivers' -Summary @{
            Gpus = [object[]]$gpus; ProblemDevices = $bad.Count; UpdatesAvailable = $updates.Count
            Installed = $(if ($installed) { $installed.Installed } else { 0 }); RebootRequired = [bool]($installed -and $installed.RebootRequired)
        } -Items ([object[]]$updates) -LogAction { param($m, $l) Write-DrvLog $m $l }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Start-WsDrivers }
