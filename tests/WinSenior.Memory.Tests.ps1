# Pester tests for WinSenior.Memory.ps1 - the pure pieces: pressure classification,
# the leftover rule engine (synthetic process snapshots, nothing is stopped) and
# the ini editor used by the prevention step.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\WinSenior.Memory.ps1')
    function New-Row {
        param([int]$Id, [string]$Name, [string]$Cmd = '', [double]$Cpu = 10, [double]$Age = 60,
              [bool]$Window = $false, [bool]$ParentAlive = $false, [int]$ParentPid = 1, [string]$ParentName = '')
        [pscustomobject]@{ Pid = $Id; ParentPid = $ParentPid; ParentAlive = $ParentAlive; ParentName = $ParentName
            Name = $Name; CommandLine = $Cmd; PrivateBytes = [int64]1GB; WorkingSet = [int64]1GB
            CpuSeconds = $Cpu; StartTime = (Get-Date '2026-01-01'); AgeMinutes = $Age; HasWindow = $Window; SessionId = 1 }
    }
}

Describe 'Get-WsMemoryPressure' {
    It 'OK with plenty of memory' {
        (Get-WsMemoryPressure ([pscustomobject]@{ TotalBytes = 16GB; AvailableBytes = 8GB; CommitPercent = 40; NonpagedBytes = 200MB })).Level | Should -Be 'OK'
    }
    It 'Warn below 10 % available (and under 4 GB)' {
        (Get-WsMemoryPressure ([pscustomobject]@{ TotalBytes = 16GB; AvailableBytes = 1GB; CommitPercent = 40; NonpagedBytes = 200MB })).Level | Should -Be 'Warn'
    }
    It 'not Warn at 8 % when 8 % is still above 4 GB' {
        (Get-WsMemoryPressure ([pscustomobject]@{ TotalBytes = 64GB; AvailableBytes = 5GB; CommitPercent = 40; NonpagedBytes = 200MB })).Level | Should -Be 'OK'
    }
    It 'Critical under 500 MB or commit > 80 %' {
        (Get-WsMemoryPressure ([pscustomobject]@{ TotalBytes = 16GB; AvailableBytes = 400MB; CommitPercent = 40; NonpagedBytes = 200MB })).Level | Should -Be 'Critical'
        (Get-WsMemoryPressure ([pscustomobject]@{ TotalBytes = 16GB; AvailableBytes = 8GB; CommitPercent = 85; NonpagedBytes = 200MB })).Level | Should -Be 'Critical'
    }
    It 'flags a non-paged pool leak' {
        $p = Get-WsMemoryPressure ([pscustomobject]@{ TotalBytes = 16GB; AvailableBytes = 8GB; CommitPercent = 40; NonpagedBytes = 3GB })
        $p.PoolLeak | Should -BeTrue
        $p.Level | Should -Be 'Warn'
    }
}

Describe 'Find-WsMemoryLeftover' {
    It 'finds an idle Gradle daemon' {
        $snap = @(New-Row 10 'java.exe' 'java -cp x org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.5' -Cpu 10.1)
        $prev = @(New-Row 10 'java.exe' '' -Cpu 10.0)
        $r = @(Find-WsMemoryLeftover -Snapshot $snap -Previous $prev -ElapsedMinutes 20 -MinIdleMinutes 15)
        $r.Count | Should -Be 1
        $r[0].Rule | Should -Be 'gradle-daemon'
        $r[0].Eligible | Should -BeTrue
        $r[0].Graceful | Should -Contain 'gradle --stop'
    }
    It 'keeps a busy daemon' {
        $snap = @(New-Row 10 'java.exe' 'GradleDaemon' -Cpu 400)
        $prev = @(New-Row 10 'java.exe' '' -Cpu 10)
        $r = @(Find-WsMemoryLeftover -Snapshot $snap -Previous $prev -ElapsedMinutes 20)
        $r[0].Eligible | Should -BeFalse
        $r[0].SkipReason | Should -Match 'busy'
    }
    It 'keeps a daemon that still runs a child (active build)' {
        $snap = @((New-Row 10 'java.exe' 'GradleDaemon'), (New-Row 11 'java.exe' 'GradleWorkerMain' -ParentAlive $true -ParentPid 10))
        $r = @(Find-WsMemoryLeftover -Snapshot $snap -MinIdleMinutes 0)
        ($r | Where-Object Pid -eq 10).Eligible | Should -BeFalse
        ($r | Where-Object Pid -eq 10).SkipReason | Should -Match 'child'
    }
    It 'needs a previous sample in background mode' {
        $r = @(Find-WsMemoryLeftover -Snapshot @(New-Row 10 'java.exe' 'GradleDaemon') -Previous @() -ElapsedMinutes 20)
        $r[0].Eligible | Should -BeFalse
    }
    It 'never touches a process with a window' {
        $r = @(Find-WsMemoryLeftover -Snapshot @(New-Row 20 'javaw.exe' 'net.minecraft.client.main.Main' -Window $true) -MinIdleMinutes 0)
        $r[0].Eligible | Should -BeFalse
    }
    It 'never matches a Minecraft server' {
        $r = @(Find-WsMemoryLeftover -Snapshot @(New-Row 21 'java.exe' '-jar forge-server.jar nogui net.minecraftforge') -MinIdleMinutes 0)
        $r.Count | Should -Be 0
    }
    It 'stops a windowless orphaned Minecraft JVM only when asked interactively' {
        $row = New-Row 22 'javaw.exe' 'cpw.mods.bootstraplauncher net.minecraft'
        (@(Find-WsMemoryLeftover -Snapshot @($row) -MinIdleMinutes 0))[0].Eligible | Should -BeTrue
        (@(Find-WsMemoryLeftover -Snapshot @($row) -MinIdleMinutes 0 -AutoOnly))[0].Eligible | Should -BeFalse
    }
    It 'keeps a language server while its editor runs' {
        $r = @(Find-WsMemoryLeftover -Snapshot @(New-Row 30 'node.exe' 'tsserver.js' -ParentAlive $true -ParentName 'Code.exe') -MinIdleMinutes 0)
        $r[0].Eligible | Should -BeFalse
        $r[0].SkipReason | Should -Match 'Code.exe'
    }
    It 'requires -IncludeWsl for the WSL VM' {
        $row = New-Row 40 'vmmemWSL'
        (@(Find-WsMemoryLeftover -Snapshot @($row) -MinIdleMinutes 0))[0].Eligible | Should -BeFalse
        (@(Find-WsMemoryLeftover -Snapshot @($row) -MinIdleMinutes 0 -IncludeWsl))[0].Eligible | Should -BeTrue
    }
    It 'ignores ordinary processes' {
        @(Find-WsMemoryLeftover -Snapshot @((New-Row 50 'chrome.exe' '--type=renderer'), (New-Row 51 'java.exe' '-jar myapp.jar')) -MinIdleMinutes 0).Count | Should -Be 0
    }
    It 'treats a recycled PID as a new process' {
        $snap = @(New-Row 10 'java.exe' 'GradleDaemon' -Cpu 1)
        $prev = @([pscustomobject]@{ Pid = 10; CpuSeconds = 1; StartTime = (Get-Date '2025-01-01') })
        (@(Find-WsMemoryLeftover -Snapshot $snap -Previous $prev -ElapsedMinutes 20))[0].Eligible | Should -BeFalse
    }
}

Describe 'Set-WsIniValue' {
    It 'adds a key to a new section' {
        Set-WsIniValue -Lines @('[wsl2]', 'memory=8GB') -Section 'experimental' -Key 'autoMemoryReclaim' -Value 'gradual' |
            Should -Be @('[wsl2]', 'memory=8GB', '[experimental]', 'autoMemoryReclaim=gradual')
    }
    It 'replaces an existing key inside its section only' {
        Set-WsIniValue -Lines @('[experimental]', 'autoMemoryReclaim=disabled', '[x]', 'autoMemoryReclaim=keep') -Section 'experimental' -Key 'autoMemoryReclaim' -Value 'gradual' |
            Should -Be @('[experimental]', 'autoMemoryReclaim=gradual', '[x]', 'autoMemoryReclaim=keep')
    }
    It 'edits a section-less properties file' {
        Set-WsIniValue -Lines @('org.gradle.jvmargs=-Xmx2g', 'org.gradle.daemon.idletimeout=10800000') -Section $null -Key 'org.gradle.daemon.idletimeout' -Value '900000' |
            Should -Be @('org.gradle.jvmargs=-Xmx2g', 'org.gradle.daemon.idletimeout=900000')
    }
}
