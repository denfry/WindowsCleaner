<#
.SYNOPSIS
    WinSenior smart memory - reclaims RAM held by real leftovers, not placebo.

.DESCRIPTION
    "RAM cleaners" that empty every working set or purge the standby list make the
    used-memory number drop and then fault the same pages straight back from disk:
    standby memory is cache that Windows hands to programs instantly anyway. What
    actually keeps RAM occupied after you are done is LIVE PROCESSES that outlive
    their job: Gradle / Kotlin / Maven daemons after a (mod) build, MSBuild and
    Roslyn build servers, WSL2's vmmem, orphaned language servers and Jupyter
    kernels, a Minecraft javaw with no window. This module finds exactly those.

      Get-WsMemoryState       locale-proof counters (CIM PerfOS_Memory)
      Get-WsMemoryPressure    OK / Warn / Critical per Microsoft's thresholds
      Get-WsProcessSnapshot   processes with command line, parent, CPU, memory
      Find-WsMemoryLeftover   PURE rule engine over snapshots (Pester-tested)
      Invoke-WsMemoryReclaim  graceful stop commands first, then idle orphans
      Set-WsMemoryPrevention  fix the cause: Gradle idle timeout, WSL autoMemoryReclaim
      Clear-WsStandbyList     opt-in only, low-priority standby list (manual)
      Install-/Remove-WsMemoryAuto   per-user background task (every 10 min)

    Rules for killing (all must hold): the process matches a known leftover rule,
    it has no visible window, its own CPU stayed below 1 % of one core over the
    idle window, it has no live child process doing work, and it is older than the
    idle window. Graceful commands (gradle --stop, dotnet build-server shutdown,
    mvnd --stop) always run before any Stop-Process.

    Thresholds: Microsoft Learn "Troubleshoot performance problems in Windows" -
    Available MBytes < 10 % RAM warning / < 1 % or < 500 MB critical;
    % Committed Bytes In Use 60-80 % warning / > 80 % critical.

.EXAMPLE
    .\WinSenior.Memory.ps1                 # report: pressure + leftovers
    .\WinSenior.Memory.ps1 -Reclaim        # stop the leftovers (asks unless -Unattended)
    .\WinSenior.Memory.ps1 -Reclaim -WhatIf
    .\WinSenior.Memory.ps1 -Prevent        # Gradle idle timeout + WSL autoMemoryReclaim
    .\WinSenior.Memory.ps1 -InstallAuto    # background check every 10 minutes
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Reclaim,
    [switch]$Auto,
    [switch]$Prevent,
    [switch]$PurgeStandby,
    [switch]$InstallAuto,
    [switch]$RemoveAuto,
    [switch]$IncludeWsl,
    [int]$IdleMinutes = 15,
    [switch]$Unattended,
    [string]$LogPath = "$env:TEMP\WinSenior-Memory.log",
    [string]$ReportPath
)

. (Join-Path $PSScriptRoot 'WinSenior.Common.ps1')

# CimCmdlets' load-time Set-Alias honours a global -WhatIf and spams "What if: Set
# Alias" on 5.1 - load it up front with WhatIf off.
$wsWi = $global:WhatIfPreference
try { $global:WhatIfPreference = $false; Import-Module CimCmdlets -ErrorAction SilentlyContinue } finally { $global:WhatIfPreference = $wsWi }

function Write-MemLog { param([string]$Message, [string]$Level = 'Info') Write-WsLog -Message $Message -Level $Level -LogPath $LogPath }

$script:WsMemStateDir = Join-Path $env:LOCALAPPDATA 'WinSenior'

# =====================================================================
# STATE / PRESSURE
# =====================================================================
function Get-WsMemoryState {
    $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $pm  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    $total = if ($os) { [int64]$os.TotalVisibleMemorySize * 1KB } else { 0 }
    [pscustomobject]@{
        TotalBytes      = $total
        AvailableBytes  = if ($pm) { [int64]$pm.AvailableBytes } elseif ($os) { [int64]$os.FreePhysicalMemory * 1KB } else { 0 }
        CommitPercent   = if ($pm) { [double]$pm.PercentCommittedBytesInUse } else { 0 }
        CommittedBytes  = if ($pm) { [int64]$pm.CommittedBytes } else { 0 }
        CommitLimit     = if ($pm) { [int64]$pm.CommitLimit } else { 0 }
        NonpagedBytes   = if ($pm) { [int64]$pm.PoolNonpagedBytes } else { 0 }
        StandbyBytes    = if ($pm) { [int64]$pm.StandbyCacheNormalPriorityBytes + [int64]$pm.StandbyCacheReserveBytes + [int64]$pm.StandbyCacheCoreBytes } else { 0 }
        PagesInputPerSec = if ($pm) { [double]$pm.PagesInputPersec } else { 0 }
    }
}

# Pure: classify a state object. Reasons are English sentences for the log/GUI.
function Get-WsMemoryPressure {
    param([object]$State)
    $level = 'OK'; $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $State -or $State.TotalBytes -le 0) { return [pscustomobject]@{ Level = 'Unknown'; Reasons = @('no data'); PoolLeak = $false } }
    $availPct = 100.0 * $State.AvailableBytes / $State.TotalBytes
    if ($State.AvailableBytes -lt 500MB -or $availPct -lt 1) {
        $level = 'Critical'; $reasons.Add(('available memory critically low ({0:N0} MB)' -f ($State.AvailableBytes / 1MB)))
    }
    elseif ($availPct -lt 10 -and $State.AvailableBytes -lt 4GB) {
        $level = 'Warn'; $reasons.Add(('available memory low ({0:N1} % of RAM)' -f $availPct))
    }
    if ($State.CommitPercent -gt 80) {
        $level = 'Critical'; $reasons.Add(('commit charge {0:N0} % of the limit - programs may fail to allocate' -f $State.CommitPercent))
    }
    elseif ($State.CommitPercent -ge 60 -and $level -eq 'OK') {
        $level = 'Warn'; $reasons.Add(('commit charge {0:N0} % of the limit' -f $State.CommitPercent))
    }
    $poolLeak = ($State.NonpagedBytes -gt 0.10 * $State.TotalBytes)
    if ($poolLeak) {
        $reasons.Add(('non-paged pool {0:N0} MB (> 10 % of RAM) - likely a driver leak; update network/GPU drivers or reboot' -f ($State.NonpagedBytes / 1MB)))
        if ($level -eq 'OK') { $level = 'Warn' }
    }
    [pscustomobject]@{ Level = $level; Reasons = [string[]]$reasons; AvailablePercent = [Math]::Round($availPct, 1); PoolLeak = $poolLeak }
}

# =====================================================================
# PROCESS SNAPSHOT
# =====================================================================
function Get-WsProcessSnapshot {
    $now = Get-Date
    $windows = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $windows[$p.Id] = $true } } catch { Write-Verbose $_ }
    }
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $byId = @{}; foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }
    foreach ($p in $procs) {
        $parent = $byId[[int]$p.ParentProcessId]
        # PID reuse guard: a "parent" created after the child is not its parent.
        $parentAlive = [bool]($parent -and $parent.CreationDate -and $p.CreationDate -and $parent.CreationDate -le $p.CreationDate)
        [pscustomobject]@{
            Pid          = [int]$p.ProcessId
            ParentPid    = [int]$p.ParentProcessId
            ParentAlive  = $parentAlive
            ParentName   = if ($parentAlive) { [string]$parent.Name } else { '' }
            Name         = [string]$p.Name
            CommandLine  = [string]$p.CommandLine
            PrivateBytes = [int64]$p.PrivatePageCount
            WorkingSet   = [int64]$p.WorkingSetSize
            CpuSeconds   = ([double]$p.KernelModeTime + [double]$p.UserModeTime) / 1e7
            StartTime    = $p.CreationDate
            AgeMinutes   = if ($p.CreationDate) { ($now - $p.CreationDate).TotalMinutes } else { 0 }
            HasWindow    = [bool]$windows[[int]$p.ProcessId]
            SessionId    = [int]$p.SessionId
        }
    }
}

# =====================================================================
# RULES  (data, not code paths: adding a leftover kind = one entry)
#   Match     : scriptblock over one snapshot row -> bool
#   Graceful  : native command lines tried once before any kill (optional)
#   Auto      : allowed in the unattended background mode
#   KeepChild : names of children that mean "still working" (e.g. a test worker)
# =====================================================================
function Get-WsMemoryRuleTable {
    @(
        [pscustomobject]@{ Id = 'gradle-daemon'; Name = 'Gradle daemon'; Auto = $true
            Match = { $_.Name -match '^javaw?\.exe$' -and $_.CommandLine -match 'GradleDaemon|org\.gradle\.launcher\.daemon' }
            Graceful = @('gradle --stop'); Note = 'restarts on the next build (a few seconds slower)' }
        [pscustomobject]@{ Id = 'gradle-worker'; Name = 'Gradle worker / test executor'; Auto = $true
            Match = { $_.Name -match '^javaw?\.exe$' -and $_.CommandLine -match 'GradleWorkerMain|worker\.org\.gradle\.process' }
            Graceful = @(); Note = 'child of a finished build' }
        [pscustomobject]@{ Id = 'kotlin-daemon'; Name = 'Kotlin compile daemon'; Auto = $true
            Match = { $_.Name -match '^javaw?\.exe$' -and $_.CommandLine -match 'KotlinCompileDaemon|org\.jetbrains\.kotlin\.daemon' }
            Graceful = @(); Note = 'restarts on the next Kotlin compile' }
        [pscustomobject]@{ Id = 'mvnd'; Name = 'Maven daemon (mvnd)'; Auto = $true
            Match = { $_.Name -match '^javaw?\.exe$' -and $_.CommandLine -match 'org\.mvndaemon|MavenDaemon' }
            Graceful = @('mvnd --stop'); Note = '' }
        [pscustomobject]@{ Id = 'msbuild-node'; Name = 'MSBuild reusable node'; Auto = $true
            Match = { ($_.Name -ieq 'MSBuild.exe' -or ($_.Name -ieq 'dotnet.exe' -and $_.CommandLine -match 'MSBuild\.dll')) -and $_.CommandLine -match '/nodemode:|-nodemode:' }
            Graceful = @('dotnet build-server shutdown --msbuild'); Note = 'MSBuild keeps worker nodes for 15 min after a build' }
        [pscustomobject]@{ Id = 'roslyn-server'; Name = 'C# / VB compiler server (VBCSCompiler)'; Auto = $true
            Match = { $_.Name -ieq 'VBCSCompiler.exe' -or ($_.Name -ieq 'dotnet.exe' -and $_.CommandLine -match 'VBCSCompiler\.dll') }
            Graceful = @('dotnet build-server shutdown --vbcscompiler'); Note = '' }
        [pscustomobject]@{ Id = 'razor-server'; Name = 'Razor build server'; Auto = $true
            Match = { $_.Name -ieq 'dotnet.exe' -and $_.CommandLine -match 'rzc\.dll.*server' }
            Graceful = @('dotnet build-server shutdown --razor'); Note = '' }
        [pscustomobject]@{ Id = 'lang-server'; Name = 'Orphaned language server (TypeScript / ESLint / LSP)'; Auto = $true; OrphanOnly = $true
            Match = { $_.Name -ieq 'node.exe' -and $_.CommandLine -match 'tsserver|typingsInstaller|eslintServer|language-?server|vscode-.*server' }
            Graceful = @(); Note = 'its editor is already closed' }
        [pscustomobject]@{ Id = 'jupyter-kernel'; Name = 'Orphaned Jupyter / IPython kernel'; Auto = $true; OrphanOnly = $true
            Match = { $_.Name -match '^pythonw?\.exe$' -and $_.CommandLine -match 'ipykernel_launcher|ipykernel' }
            Graceful = @(); Note = 'its notebook server is gone' }
        [pscustomobject]@{ Id = 'minecraft-java'; Name = 'Minecraft / modded Java left without a window'; Auto = $false; OrphanOnly = $true
            Match = { $_.Name -match '^javaw?\.exe$' -and $_.CommandLine -match 'net\.minecraft|cpw\.mods|modlauncher|fabricmc|quiltmc|neoforge|minecraftforge' -and $_.CommandLine -notmatch '\bnogui\b|server\.jar|dedicated' }
            Graceful = @(); Note = 'game closed but the JVM stayed (servers are never touched)' }
        [pscustomobject]@{ Id = 'android-emulator'; Name = 'Android emulator (qemu)'; Auto = $false
            Match = { $_.Name -match '^qemu-system-.*\.exe$' }
            Graceful = @('adb emu kill'); Note = 'closes the running emulator' }
        [pscustomobject]@{ Id = 'wsl-vm'; Name = 'WSL2 virtual machine (vmmem)'; Auto = $false; NeedsFlag = 'IncludeWsl'
            Match = { $_.Name -match '^vmmem(WSL)?(\.exe)?$' }
            Graceful = @('wsl --shutdown'); Note = 'stops every running Linux distro and its services' }
    )
}

# PURE: decide what is a leftover. $Previous (optional) is an earlier snapshot used
# to measure CPU over a long idle window (background mode); without it the caller
# passes a short sample and -MinIdleMinutes 0 (interactive, user confirms).
function Find-WsMemoryLeftover {
    param(
        [object[]]$Snapshot,
        [object[]]$Previous,
        [double]$ElapsedMinutes = 0,
        [double]$MinIdleMinutes = 15,
        [double]$MaxCpuPercent = 1.0,
        [switch]$AutoOnly,
        [switch]$IncludeWsl,
        [object[]]$Rules = (Get-WsMemoryRuleTable)
    )
    $prevById = @{}
    foreach ($p in @($Previous)) { if ($p) { $prevById[[int]$p.Pid] = $p } }
    $childrenOf = @{}
    foreach ($p in $Snapshot) {
        if ($p.ParentAlive) {
            if (-not $childrenOf.ContainsKey($p.ParentPid)) { $childrenOf[$p.ParentPid] = New-Object System.Collections.Generic.List[object] }
            $childrenOf[$p.ParentPid].Add($p)
        }
    }
    foreach ($p in $Snapshot) {
        $rule = $null
        foreach ($r in $Rules) {
            $hit = $false
            try { $hit = [bool]($p | Where-Object -FilterScript $r.Match) } catch { $hit = $false }
            if ($hit) { $rule = $r; break }
        }
        if (-not $rule) { continue }
        $skip = $null
        if ($AutoOnly -and -not $rule.Auto) { $skip = 'manual only' }
        elseif ($rule.PSObject.Properties['NeedsFlag'] -and $rule.NeedsFlag -eq 'IncludeWsl' -and -not $IncludeWsl) { $skip = 'needs -IncludeWsl (stops all Linux distros)' }
        elseif ($p.HasWindow) { $skip = 'has a window (in use)' }
        elseif ($rule.PSObject.Properties['OrphanOnly'] -and $rule.OrphanOnly -and $p.ParentAlive) { $skip = "its parent ($($p.ParentName)) is still running" }
        elseif ($p.AgeMinutes -lt $MinIdleMinutes) { $skip = ('started {0:N0} min ago' -f $p.AgeMinutes) }
        else {
            $busyKids = @($childrenOf[$p.Pid] | Where-Object { $_ -and $_.Name -notmatch '^(conhost|cmd)\.exe$' })
            if ($busyKids.Count) { $skip = "still has $($busyKids.Count) child process(es)" }
            elseif ($ElapsedMinutes -gt 0) {
                $prev = $prevById[$p.Pid]
                if (-not $prev -or ($prev.StartTime -and $p.StartTime -and $prev.StartTime -ne $p.StartTime)) { $skip = 'not seen in the previous check yet' }
                else {
                    $cpuPct = 100.0 * ($p.CpuSeconds - $prev.CpuSeconds) / ($ElapsedMinutes * 60)
                    if ($cpuPct -gt $MaxCpuPercent) { $skip = ('busy ({0:N1} % CPU)' -f $cpuPct) }
                    elseif ($ElapsedMinutes -lt $MinIdleMinutes) { $skip = 'idle window not reached yet' }
                }
            }
        }
        [pscustomobject]@{
            Rule = $rule.Id; RuleName = $rule.Name; Pid = $p.Pid; Name = $p.Name
            PrivateBytes = $p.PrivateBytes; WorkingSet = $p.WorkingSet
            Eligible = (-not $skip); SkipReason = $skip; Graceful = @($rule.Graceful); Note = $rule.Note
        }
    }
}

# =====================================================================
# RECLAIM
# =====================================================================
function Invoke-WsGracefulCommand {
    param([string]$CommandLine)
    $exe, $rest = $CommandLine -split ' ', 2
    $cmd = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $false }
    try {
        $p = Start-Process -FilePath $cmd.Source -ArgumentList $rest -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { Write-Verbose $_ } ; return $false }
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}

function Invoke-WsMemoryReclaim {
    [CmdletBinding(SupportsShouldProcess)]
    param([object[]]$Leftovers)
    $todo = @($Leftovers | Where-Object { $_.Eligible })
    $before = Get-WsMemoryState
    $done = New-Object System.Collections.Generic.List[object]
    if (-not $todo) { return [pscustomobject]@{ Stopped = @(); FreedBytes = [int64]0; Before = $before; After = $before } }

    # 1) graceful commands, once per rule
    foreach ($g in ($todo | ForEach-Object { $_.Graceful } | Where-Object { $_ } | Sort-Object -Unique)) {
        if ($PSCmdlet.ShouldProcess($g, 'Run graceful stop command')) {
            $ok = Invoke-WsGracefulCommand $g
            Write-MemLog ("  {0}: {1}" -f $g, $(if ($ok) { 'ok' } else { 'not available / failed' })) 'Debug'
        }
    }
    if (-not (Test-WhatIfMode)) { Start-Sleep -Seconds 3 }

    # 2) whatever survived and is still idle-eligible
    foreach ($l in $todo) {
        $alive = Get-Process -Id $l.Pid -ErrorAction SilentlyContinue
        if (-not $alive) { $done.Add($l); continue }
        if ($PSCmdlet.ShouldProcess("$($l.Name) (PID $($l.Pid), $(Format-FileSize $l.PrivateBytes))", "Stop $($l.RuleName)")) {
            try { Stop-Process -Id $l.Pid -Force -ErrorAction Stop; $done.Add($l) }
            catch { Write-MemLog "  could not stop PID $($l.Pid): $($_.Exception.Message)" 'Warning' }
        }
        elseif (Test-WhatIfMode) { $done.Add($l) }
    }
    if (-not (Test-WhatIfMode)) { Start-Sleep -Seconds 2 }
    $after = Get-WsMemoryState
    [int64]$claimed = 0; foreach ($d in $done) { $claimed += [int64]$d.PrivateBytes }
    # Honest number: the measured change in Available memory (never counts standby).
    $measured = if (Test-WhatIfMode) { $claimed } else { [Math]::Max([int64]0, $after.AvailableBytes - $before.AvailableBytes) }
    [pscustomobject]@{ Stopped = [object[]]$done; ClaimedBytes = $claimed; FreedBytes = $measured; Before = $before; After = $after }
}

# =====================================================================
# PREVENTION (fix the cause)
# =====================================================================
# Gradle: org.gradle.daemon.idletimeout (ms) in the user's gradle.properties.
# WSL:    [experimental] autoMemoryReclaim=gradual in %USERPROFILE%\.wslconfig.
function Set-WsIniValue {
    param([string[]]$Lines, [string]$Section, [string]$Key, [string]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    # [string] params turn $null into '' - an empty section = top of a properties file.
    $inSec = [string]::IsNullOrEmpty($Section); $done = $false; $secSeen = $false
    foreach ($l in @($Lines)) {
        if ($l -match '^\s*\[(.+)\]\s*$') {
            if ($inSec -and -not $done -and $Section) { $out.Add("$Key=$Value"); $done = $true }
            $inSec = ($Matches[1].Trim() -ieq $Section); if ($inSec) { $secSeen = $true }
        }
        elseif ($inSec -and $l -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            if (-not $done) { $out.Add("$Key=$Value"); $done = $true }
            continue
        }
        $out.Add($l)
    }
    if (-not $done) {
        if ($Section -and -not $secSeen) { $out.Add("[$Section]") }
        $out.Add("$Key=$Value")
    }
    [string[]]$out
}

function Set-WsMemoryPrevention {
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$GradleIdleMinutes = 15, [switch]$IncludeWsl)
    $changes = New-Object System.Collections.Generic.List[string]
    $gradleHome = if ($env:GRADLE_USER_HOME) { $env:GRADLE_USER_HOME } else { Join-Path $env:USERPROFILE '.gradle' }
    $gp = Join-Path $gradleHome 'gradle.properties'
    if ((Test-Path -LiteralPath $gradleHome) -and $PSCmdlet.ShouldProcess($gp, "org.gradle.daemon.idletimeout=$($GradleIdleMinutes * 60000)")) {
        $lines = if (Test-Path -LiteralPath $gp) { [IO.File]::ReadAllLines($gp) } else { @() }
        if (Test-Path -LiteralPath $gp) { Copy-Item -LiteralPath $gp -Destination "$gp.winsenior.bak" -Force -WhatIf:$false }
        [IO.File]::WriteAllLines($gp, (Set-WsIniValue -Lines $lines -Section $null -Key 'org.gradle.daemon.idletimeout' -Value ($GradleIdleMinutes * 60000)))
        $changes.Add("Gradle daemons now exit after $GradleIdleMinutes idle minutes ($gp)")
    }
    $wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($IncludeWsl -and $wslExe) {
        $wc = Join-Path $env:USERPROFILE '.wslconfig'
        if ($PSCmdlet.ShouldProcess($wc, '[experimental] autoMemoryReclaim=gradual')) {
            $lines = if (Test-Path -LiteralPath $wc) { [IO.File]::ReadAllLines($wc) } else { @() }
            if (Test-Path -LiteralPath $wc) { Copy-Item -LiteralPath $wc -Destination "$wc.winsenior.bak" -Force -WhatIf:$false }
            [IO.File]::WriteAllLines($wc, (Set-WsIniValue -Lines $lines -Section 'experimental' -Key 'autoMemoryReclaim' -Value 'gradual'))
            $changes.Add("WSL returns cached memory to Windows gradually ($wc; applies after 'wsl --shutdown')")
        }
    }
    [string[]]$changes
}

# =====================================================================
# OPT-IN: purge the LOW-PRIORITY standby list (manual, never automatic)
#   NtSetSystemInformation(SystemMemoryListInformation=80, MemoryPurgeLowPriorityStandbyList=5)
#   Needs admin (SeProfileSingleProcessPrivilege). Only useful against the
#   standby-list stutter some games hit; it throws away cache otherwise.
# =====================================================================
function Clear-WsStandbyList {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('low-priority standby list', 'Purge')) { return $false }
    if (-not ('WinSenior.MemNative' -as [type])) {
        Add-Type -Namespace WinSenior -Name MemNative -MemberDefinition @'
[DllImport("ntdll.dll")] public static extern int NtSetSystemInformation(int cls, ref int info, int len);
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, int acc, out IntPtr tok);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
[StructLayout(LayoutKind.Sequential, Pack=4)] public struct TP { public int Count; public long Luid; public int Attr; }
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool all, ref TP st, int len, IntPtr prev, IntPtr rl);
[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
public static int Purge(int cmd) {
    IntPtr tok; long luid;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return -1;
    if (!LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out luid)) return -2;
    TP tp = new TP(); tp.Count = 1; tp.Luid = luid; tp.Attr = 2;
    AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    return NtSetSystemInformation(80, ref cmd, 4);
}
'@
    }
    $st = [WinSenior.MemNative]::Purge(5)
    ($st -eq 0)
}

# =====================================================================
# BACKGROUND MODE (per-user task, no admin needed to run)
# =====================================================================
function Get-WsMemoryStatePath { Join-Path $script:WsMemStateDir 'memory-snapshot.json' }

function Invoke-WsMemoryAuto {
    param([int]$IdleMinutes = 15)
    $statePath = Get-WsMemoryStatePath
    $snap = @(Get-WsProcessSnapshot)
    $prev = $null; $elapsed = 0
    if (Test-Path -LiteralPath $statePath) {
        try {
            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $elapsed = ((Get-Date) - [datetime]$saved.Time).TotalMinutes
            $prev = @($saved.Rows | ForEach-Object { [pscustomobject]@{ Pid = [int]$_.Pid; CpuSeconds = [double]$_.CpuSeconds; StartTime = if ($_.StartTime) { [datetime]$_.StartTime } else { $null } } })
        } catch { $prev = $null }
    }
    [void](Add-WsDiskSample)      # the 10-minute heartbeat doubles as the disk-history sampler
    $pressure = Get-WsMemoryPressure (Get-WsMemoryState)
    # Under real pressure, a 5-minute idle window is enough.
    $win = if ($pressure.Level -ne 'OK') { [Math]::Min(5, $IdleMinutes) } else { $IdleMinutes }
    $result = $null
    if ($prev -and $elapsed -ge 1) {
        $left = @(Find-WsMemoryLeftover -Snapshot $snap -Previous $prev -ElapsedMinutes $elapsed -MinIdleMinutes $win -AutoOnly)
        if (@($left | Where-Object { $_.Eligible }).Count) {
            $result = Invoke-WsMemoryReclaim -Leftovers $left -Confirm:$false
            foreach ($s in $result.Stopped) { Write-MemLog ("auto: stopped {0} (PID {1}, {2})" -f $s.RuleName, $s.Pid, (Format-FileSize $s.PrivateBytes)) 'Success' }
        }
    }
    # Keep only the rows the rules care about; the state file stays tiny.
    $rules = Get-WsMemoryRuleTable
    $keep = @(Find-WsMemoryLeftover -Snapshot $snap -MinIdleMinutes 0 -Rules $rules | ForEach-Object { $_.Pid })
    $rows = @($snap | Where-Object { $keep -contains $_.Pid } | ForEach-Object { @{ Pid = $_.Pid; CpuSeconds = $_.CpuSeconds; StartTime = if ($_.StartTime) { $_.StartTime.ToString('o') } else { $null } } })
    if (-not (Test-Path -LiteralPath $script:WsMemStateDir)) { New-Item -ItemType Directory -Path $script:WsMemStateDir -Force -WhatIf:$false | Out-Null }
    (@{ Time = (Get-Date).ToString('o'); Rows = $rows } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statePath -Encoding UTF8 -WhatIf:$false
    $result
}

$script:WsMemTaskName = 'WinSenior Smart Memory'

function Install-WsMemoryAuto {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ScriptPath = $PSCommandPath, [int]$EveryMinutes = 10, [int]$IdleMinutes = 15)
    $host5 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Auto -IdleMinutes $IdleMinutes"
    if (-not $PSCmdlet.ShouldProcess($script:WsMemTaskName, "Register (every $EveryMinutes min, current user)")) { return $false }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action    = New-ScheduledTaskAction -Execute $host5 -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
    # S4U = runs without a visible window and without storing a password; same user, no elevation.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:WsMemTaskName -TaskPath '\WinSenior\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Stops idle build daemons and orphaned processes that hold RAM (WinSenior).' -Force | Out-Null
    $true
}

function Remove-WsMemoryAuto {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess($script:WsMemTaskName, 'Unregister')) {
        Unregister-ScheduledTask -TaskName $script:WsMemTaskName -TaskPath '\WinSenior\' -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# CLI
# =====================================================================
# Who holds the commit charge: private bytes grouped by executable name.
function Get-WsTopMemoryConsumer {
    param([object[]]$Snapshot, [int]$Top = 6)
    $Snapshot | Group-Object Name | ForEach-Object {
        [int64]$sum = 0; foreach ($p in $_.Group) { $sum += [int64]$p.PrivateBytes }
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; PrivateBytes = $sum }
    } | Sort-Object PrivateBytes -Descending | Select-Object -First $Top
}

function Show-WsMemoryReport {
    param([object]$State, [object]$Pressure, [object[]]$Leftovers, [object[]]$Snapshot)
    Write-MemLog ("Memory: {0} available of {1} ({2} %), commit {3:N0} %, standby cache {4}" -f `
        (Format-FileSize $State.AvailableBytes), (Format-FileSize $State.TotalBytes), $Pressure.AvailablePercent, $State.CommitPercent, (Format-FileSize $State.StandbyBytes)) 'Step'
    $lvl = switch ($Pressure.Level) { 'OK' { 'Success' } 'Warn' { 'Warning' } default { 'Error' } }
    Write-MemLog "Pressure: $($Pressure.Level)" $lvl
    foreach ($r in $Pressure.Reasons) { Write-MemLog "  $r" 'Info' }
    if ($State.CommitPercent -gt 80) {
        Write-MemLog ("  commit {0} of {1}: enlarge the page file (System managed) or close the biggest consumers below" -f (Format-FileSize $State.CommittedBytes), (Format-FileSize $State.CommitLimit)) 'Info'
    }
    if ($Snapshot) {
        Write-MemLog 'Largest consumers (private memory):' 'Info'
        foreach ($t in (Get-WsTopMemoryConsumer $Snapshot)) {
            Write-MemLog ("  {0,-32} x{1,-3} {2,10}" -f $t.Name, $t.Count, (Format-FileSize $t.PrivateBytes)) 'Info'
        }
    }
    if (-not $Leftovers) { Write-MemLog 'No leftover processes found.' 'Success'; return }
    foreach ($l in ($Leftovers | Sort-Object PrivateBytes -Descending)) {
        $tag = if ($l.Eligible) { 'Warning' } else { 'Debug' }
        $why = if ($l.Eligible) { 'can be stopped' } else { "kept: $($l.SkipReason)" }
        Write-MemLog ("  {0,-44} PID {1,-6} {2,10}  {3}" -f $l.RuleName, $l.Pid, (Format-FileSize $l.PrivateBytes), $why) $tag
    }
}

function Start-WsMemory {
    if ($InstallAuto) { if (Install-WsMemoryAuto -IdleMinutes $IdleMinutes) { Write-MemLog "Background check registered: every 10 min, stops leftovers idle > $IdleMinutes min." 'Success' }; return }
    if ($RemoveAuto)  { Remove-WsMemoryAuto; Write-MemLog 'Background check removed.' 'Success'; return }
    if ($Auto)        { [void](Invoke-WsMemoryAuto -IdleMinutes $IdleMinutes); return }
    if ($Prevent) {
        $c = @(Set-WsMemoryPrevention -GradleIdleMinutes $IdleMinutes -IncludeWsl:$IncludeWsl)
        if ($c) { $c | ForEach-Object { Write-MemLog $_ 'Success' } } else { Write-MemLog 'Nothing to change (no Gradle home / WSL not selected).' 'Info' }
        return
    }
    if ($PurgeStandby) {
        if (-not (Test-AdminPrivileges)) { Write-MemLog 'Purging the standby list needs administrator rights.' 'Error'; return }
        $before = Get-WsMemoryState
        $ok = Clear-WsStandbyList
        $after = Get-WsMemoryState
        Write-MemLog ("Low-priority standby purge: {0}. Note: this is cache Windows refills from disk." -f $(if ($ok) { 'done' } else { 'failed' })) $(if ($ok) { 'Success' } else { 'Error' })
        Write-MemLog ("Available {0} -> {1}" -f (Format-FileSize $before.AvailableBytes), (Format-FileSize $after.AvailableBytes)) 'Info'
        return
    }

    $state = Get-WsMemoryState
    $press = Get-WsMemoryPressure $state
    # Interactive: a 5-second CPU sample stands in for the long idle window.
    $s1 = @(Get-WsProcessSnapshot); Start-Sleep -Seconds 5; $s2 = @(Get-WsProcessSnapshot)
    $left = @(Find-WsMemoryLeftover -Snapshot $s2 -Previous $s1 -ElapsedMinutes (5 / 60) -MinIdleMinutes 0 -MaxCpuPercent 2 -IncludeWsl:$IncludeWsl)
    Show-WsMemoryReport -State $state -Pressure $press -Leftovers $left -Snapshot $s2
    $result = $null
    if ($Reclaim -and @($left | Where-Object Eligible).Count) {
        if (-not $Unattended -and -not (Test-WhatIfMode)) {
            $a = Read-Host 'Stop the processes marked "can be stopped"? (y/N)'
            if ($a -notmatch '^(y|yes|d|da)$') { Write-MemLog 'Nothing stopped.' 'Info'; return }
        }
        $result = Invoke-WsMemoryReclaim -Leftovers $left
        $verb = if (Test-WhatIfMode) { 'Would free about' } else { 'Available memory grew by' }
        Write-MemLog ("{0} {1} ({2} process(es))" -f $verb, (Format-FileSize $result.FreedBytes), @($result.Stopped).Count) 'Success'
    }
    if ($ReportPath) {
        $items = @($left | ForEach-Object { [pscustomobject]@{ Rule = $_.Rule; Name = $_.RuleName; Pid = $_.Pid; PrivateBytes = $_.PrivateBytes; Eligible = $_.Eligible; SkipReason = $_.SkipReason } })
        Write-WinSeniorReport -ReportPath $ReportPath -Engine 'Memory' -Summary @{
            Pressure = $press.Level; AvailableBytes = $state.AvailableBytes; TotalBytes = $state.TotalBytes
            CommitPercent = $state.CommitPercent; FreedBytes = $(if ($result) { $result.FreedBytes } else { 0 })
        } -Items $items -LogAction { param($m, $l) Write-MemLog $m $l }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Start-WsMemory }
