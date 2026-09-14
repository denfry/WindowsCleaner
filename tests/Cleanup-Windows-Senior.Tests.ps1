# Pester tests for the pure logic of Cleanup-Windows-Senior.ps1
# Run:  Invoke-Pester -Path .\tests
# These cover selection, safety guard, age filtering and formatting.
# Destructive behaviour is validated separately via -WhatIf.

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\Cleanup-Windows-Senior.ps1'
    # Dot-sourcing is a no-op for the main flow (entry guard checks InvocationName -eq '.').
    . $script:Sut
    $script:Reg = Get-CleanupTaskRegistry
}

Describe 'Get-CleanupTaskRegistry' {
    It 'returns a non-empty set of tasks' {
        $script:Reg.Count | Should -BeGreaterThan 30
    }
    It 'gives every task a unique id' {
        ($script:Reg.Id | Sort-Object -Unique).Count | Should -Be $script:Reg.Count
    }
    It 'only uses known categories' {
        $known = 'Browsers','DevTools','Apps','Games','System','Disks','Logs','Updates','Optimization'
        ($script:Reg | Where-Object { $_.Category -notin $known }) | Should -BeNullOrEmpty
    }
    It 'only uses known risk tiers' {
        $known = 'Safe','Moderate','Aggressive','Dangerous'
        ($script:Reg | Where-Object { $_.Risk -notin $known }) | Should -BeNullOrEmpty
    }
    It 'gives each task either Paths or an Action' {
        ($script:Reg | Where-Object { -not $_.Paths -and -not $_.Action }) | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-CleanupSelection' {
    It 'runs Safe+Moderate+Aggressive but not Dangerous by default' {
        $sel = Resolve-CleanupSelection -Registry $script:Reg
        @($sel | Where-Object Risk -eq 'Dangerous').Count | Should -Be 0
        @($sel | Where-Object Risk -eq 'Aggressive').Count | Should -BeGreaterThan 0
    }
    It 'adds the Dangerous tier with -IncludeDangerous' {
        $sel = Resolve-CleanupSelection -Registry $script:Reg -IncludeDangerous:$true
        @($sel | Where-Object Risk -eq 'Dangerous').Count | Should -BeGreaterThan 0
    }
    It 'drops the Aggressive tier with -Conservative' {
        $sel = Resolve-CleanupSelection -Registry $script:Reg -Conservative:$true
        @($sel | Where-Object Risk -eq 'Aggressive').Count | Should -Be 0
    }
    It 'limits to the requested category' {
        $sel = Resolve-CleanupSelection -Registry $script:Reg -Category 'Browsers'
        @($sel | Where-Object Category -ne 'Browsers').Count | Should -Be 0
    }
    It 'honours -Exclude' {
        $sel = Resolve-CleanupSelection -Registry $script:Reg -Exclude 'prefetch'
        @($sel | Where-Object Id -eq 'prefetch').Count | Should -Be 0
    }
    It 'lets -Include force a Dangerous task on' {
        $sel = Resolve-CleanupSelection -Registry $script:Reg -Include 'eventlogs'
        @($sel | Where-Object Id -eq 'eventlogs').Count | Should -Be 1
    }
    It 'lets -Exclude win over -Include' {
        $sel = Resolve-CleanupSelection -Registry $script:Reg -Include 'prefetch' -Exclude 'prefetch'
        @($sel | Where-Object Id -eq 'prefetch').Count | Should -Be 0
    }
    It 'drops the Optimization category with -SkipOptimization' {
        $sel = Resolve-CleanupSelection -Registry $script:Reg -SkipOptimization:$true
        @($sel | Where-Object Category -eq 'Optimization').Count | Should -Be 0
    }
}

Describe 'Get-LocalDrives / <DRIVE> expansion' {
    It 'returns at least the system drive, formatted as X:\' {
        $d = Get-LocalDrives
        @($d).Count | Should -BeGreaterThan 0
        $d | ForEach-Object { $_ | Should -Match '^[A-Z]:\\$' }
    }
    It 'expands a <DRIVE> token into one path per local disk' {
        $paths = Expand-TaskPath @('<DRIVE>Temp\*')
        @($paths).Count | Should -Be (@(Get-LocalDrives).Count)
        $paths | ForEach-Object { $_ | Should -Match 'Temp\\\*$' }
    }
}

Describe 'Test-SafeToDelete' {
    It 'refuses drive roots and protected system roots' {
        Test-SafeToDelete 'C:\'            | Should -BeFalse
        Test-SafeToDelete $env:WINDIR      | Should -BeFalse
        Test-SafeToDelete $env:USERPROFILE | Should -BeFalse
        Test-SafeToDelete "$env:SystemDrive\Users" | Should -BeFalse
    }
    It 'allows sufficiently deep paths' {
        Test-SafeToDelete "$env:WINDIR\Temp\sub\file.bin" | Should -BeTrue
    }
    It 'refuses empty input' {
        Test-SafeToDelete '' | Should -BeFalse
    }
}

Describe 'Format-FileSize' {
    It 'formats bytes, KB, MB, GB' {
        Format-FileSize 512        | Should -Match 'B'
        Format-FileSize 1024       | Should -Match 'KB'
        Format-FileSize 1048576    | Should -Match 'MB'
        Format-FileSize 1073741824 | Should -Match 'GB'
    }
}

Describe 'Invoke-PathCleanup (WhatIf accounting)' {
    BeforeAll {
        $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pester_clean_{0}" -f (Get-Random))
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        1..2 | ForEach-Object { Set-Content -Path (Join-Path $script:Tmp "f$_.bin") -Value ('x' * 1000) }
    }
    AfterAll {
        Remove-Item $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'reports would-free bytes under -WhatIf and deletes nothing' {
        $countBefore = (Get-ChildItem $script:Tmp).Count
        $r = Invoke-PathCleanup -Path "$($script:Tmp)\*" -Description 'pester' -WhatIf
        $r.Files | Should -Be 2
        $r.Bytes | Should -BeGreaterThan 0
        (Get-ChildItem $script:Tmp).Count | Should -Be $countBefore
    }
}

Describe 'New coverage additions' {
    It 'adds the SRUM telemetry DB cleanup with DPS stopped first' {
        $t = $script:Reg | Where-Object Id -eq 'srum-db'
        $t           | Should -Not -BeNullOrEmpty
        $t.Category  | Should -Be 'Logs'
        $t.StopServices | Should -Contain 'DPS'
    }
    It 'adds RDP / PowerShell / app cache and live-kernel dump tasks' {
        @($script:Reg | Where-Object Id -in 'rdp-cache', 'ps-modulecache', 'win-caches', 'livekernel', 'eventtranscript').Count | Should -Be 5
    }
}

Describe 'v6.2 coverage & mechanisms' {
    It 'has grown past 90 tasks' {
        $script:Reg.Count | Should -BeGreaterThan 90
    }
    It 'adds messenger, dev-tool, game-engine, service-temp and upgrade-log tasks' {
        $ids = 'telegram','whatsapp','messengers','electron-generic','uwp-caches','vs','python-tools','node-tools',
               'game-logs','game-engines','svc-temp','upgrade-logs','bits-cache','dns-flush','memory-standby',
               'diag-telemetry','app-logs','installer-leftovers','empty-dirs','search-index','hiberfil','shadow-old'
        @($script:Reg | Where-Object Id -in $ids).Count | Should -Be $ids.Count
    }
    It 'keeps the new irreversible operations off by default and in the Dangerous tier' {
        foreach ($id in 'hiberfil', 'shadow-old') {
            $t = $script:Reg | Where-Object Id -eq $id
            $t.Risk      | Should -Be 'Dangerous'
            $t.DefaultOn | Should -BeFalse
        }
        ($script:Reg | Where-Object Id -eq 'search-index').DefaultOn | Should -BeFalse
    }
    It 'stops the owning service before touching BITS / DiagTrack data' {
        ($script:Reg | Where-Object Id -eq 'bits-cache').StopServices     | Should -Contain 'BITS'
        ($script:Reg | Where-Object Id -eq 'diag-telemetry').StopServices | Should -Contain 'DiagTrack'
    }
    It 'exposes -DeferLocked on the engine' {
        (Get-Command $script:Sut).Parameters.Keys | Should -Contain 'DeferLocked'
    }
    It 'Register-DeferredDelete returns 0 for a path that does not exist' {
        Register-DeferredDelete (Join-Path $env:TEMP ("no_such_{0}" -f (Get-Random))) | Should -Be 0
    }
}

Describe 'Remove-EmptyDirectory' {
    BeforeAll {
        $script:Tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ("pester_empty_{0}" -f (Get-Random))
        New-Item -ItemType Directory -Path "$script:Tmp2\a\b\c" -Force | Out-Null
        New-Item -ItemType Directory -Path "$script:Tmp2\keep"    -Force | Out-Null
        Set-Content -Path "$script:Tmp2\keep\file.txt" -Value 'x'
    }
    AfterAll { Remove-Item $script:Tmp2 -Recurse -Force -ErrorAction SilentlyContinue }
    It 'removes nested empty folders and keeps folders with content' {
        $n = Remove-EmptyDirectory -Root $script:Tmp2
        $n | Should -Be 3
        Test-Path "$script:Tmp2\a"             | Should -BeFalse
        Test-Path "$script:Tmp2\keep\file.txt" | Should -BeTrue
    }
}
