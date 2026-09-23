# Pester tests for the pure logic of Optimize-Windows-Senior.ps1
# Run:  Invoke-Pester -Path .\tests
# Covers tweak-registry integrity, selection, and a registry backup->apply->undo round-trip.

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\Optimize-Windows-Senior.ps1'
    # Dot-sourcing is a no-op for the main flow (entry guard checks InvocationName -eq '.').
    . $script:Sut
    $script:Reg = Get-OptimizationTweakRegistry
}

Describe 'Get-OptimizationTweakRegistry' {
    It 'returns a non-empty set of tweaks' {
        $script:Reg.Count | Should -BeGreaterThan 20
    }
    It 'gives every tweak a unique id' {
        ($script:Reg.Id | Sort-Object -Unique).Count | Should -Be $script:Reg.Count
    }
    It 'only uses known areas' {
        $known = 'Performance','Privacy','Debloat','Network'
        ($script:Reg | Where-Object { $_.Area -notin $known }) | Should -BeNullOrEmpty
    }
    It 'only uses known risk tiers' {
        $known = 'Safe','Moderate','Aggressive','Dangerous'
        ($script:Reg | Where-Object { $_.Risk -notin $known }) | Should -BeNullOrEmpty
    }
    It 'only uses known tweak types' {
        $known = 'Registry','Service','ScheduledTask','Custom'
        ($script:Reg | Where-Object { $_.Type -notin $known }) | Should -BeNullOrEmpty
    }
    It 'gives every tweak a non-empty explanation' {
        ($script:Reg | Where-Object { [string]::IsNullOrWhiteSpace($_.Explain) }) | Should -BeNullOrEmpty
    }
    It 'gives Registry tweaks a path and at least one value' {
        foreach ($t in ($script:Reg | Where-Object Type -eq 'Registry')) {
            $t.Spec.Path   | Should -Not -BeNullOrEmpty
            @($t.Spec.Values).Count | Should -BeGreaterThan 0
        }
    }
    It 'gives Service tweaks a service name and startup type' {
        foreach ($t in ($script:Reg | Where-Object Type -eq 'Service')) {
            $t.Spec.Service | Should -Not -BeNullOrEmpty
            $t.Spec.Startup | Should -BeIn @('Disabled','Manual','Automatic')
        }
    }
    It 'gives Custom tweaks an apply and undo scriptblock' {
        foreach ($t in ($script:Reg | Where-Object Type -eq 'Custom')) {
            $t.Spec.Apply | Should -BeOfType ([scriptblock])
            $t.Spec.Undo  | Should -BeOfType ([scriptblock])
        }
    }
}

Describe 'Resolve-TweakSelection' {
    It 'selects Safe and Moderate default-on tweaks out of the box' {
        $sel = Resolve-TweakSelection -Registry $script:Reg
        @($sel | Where-Object Risk -eq 'Safe').Count     | Should -BeGreaterThan 0
        @($sel | Where-Object Risk -eq 'Moderate').Count | Should -BeGreaterThan 0
    }
    It 'leaves default-off tweaks out by default' {
        $sel = Resolve-TweakSelection -Registry $script:Reg
        @($sel | Where-Object Id -eq 'perf-sysmain').Count | Should -Be 0
    }
    It 'lets -Include force a default-off tweak on' {
        $sel = Resolve-TweakSelection -Registry $script:Reg -Include 'perf-sysmain'
        @($sel | Where-Object Id -eq 'perf-sysmain').Count | Should -Be 1
    }
    It 'honours -Exclude over the default' {
        $sel = Resolve-TweakSelection -Registry $script:Reg -Exclude 'priv-adid'
        @($sel | Where-Object Id -eq 'priv-adid').Count | Should -Be 0
    }
    It 'lets -Exclude win over -Include' {
        $sel = Resolve-TweakSelection -Registry $script:Reg -Include 'priv-adid' -Exclude 'priv-adid'
        @($sel | Where-Object Id -eq 'priv-adid').Count | Should -Be 0
    }
    It 'limits to the requested area' {
        $sel = Resolve-TweakSelection -Registry $script:Reg -Area 'Privacy'
        @($sel | Where-Object Area -ne 'Privacy').Count | Should -Be 0
    }
}

Describe 'Registry value backup / restore' {
    BeforeAll {
        $script:TestKey = 'HKCU:\Software\WinSeniorTest'
        if (Test-Path $script:TestKey) { Remove-Item $script:TestKey -Recurse -Force }
    }
    AfterAll {
        if (Test-Path $script:TestKey) { Remove-Item $script:TestKey -Recurse -Force }
    }
    It 'restores a previously-absent value by removing it' {
        $snap = Get-RegValueSnapshot -Path $script:TestKey -Name 'Foo'
        $snap.Existed | Should -BeFalse
        Set-RegValue -Path $script:TestKey -Name 'Foo' -Kind DWord -Value 1
        (Get-ItemProperty $script:TestKey -Name Foo).Foo | Should -Be 1
        Restore-RegValue -Path $script:TestKey -Snap $snap
        (Get-Item $script:TestKey).GetValueNames() | Should -Not -Contain 'Foo'
    }
    It 'restores a previously-existing value to its old data' {
        Set-RegValue -Path $script:TestKey -Name 'Bar' -Kind DWord -Value 5
        $snap = Get-RegValueSnapshot -Path $script:TestKey -Name 'Bar'
        $snap.Existed | Should -BeTrue
        $snap.Value   | Should -Be 5
        Set-RegValue -Path $script:TestKey -Name 'Bar' -Kind DWord -Value 9
        (Get-ItemProperty $script:TestKey -Name Bar).Bar | Should -Be 9
        Restore-RegValue -Path $script:TestKey -Snap $snap
        (Get-ItemProperty $script:TestKey -Name Bar).Bar | Should -Be 5
    }
}

Describe 'Tweak-level apply / undo (Registry type)' {
    BeforeAll {
        $script:TestKey2 = 'HKCU:\Software\WinSeniorTest'
        if (Test-Path $script:TestKey2) { Remove-Item $script:TestKey2 -Recurse -Force }
    }
    AfterAll {
        if (Test-Path $script:TestKey2) { Remove-Item $script:TestKey2 -Recurse -Force }
    }
    It 'applies via Set-TweakState and reverts via Restore-Tweak' {
        $t = New-RegTweak rt-test 'round-trip test' Performance Safe `
                -Path $script:TestKey2 -Values @((RegVal 'Vfx' DWord 2)) -Explain 'test'
        Test-TweakApplied -Tweak $t | Should -BeFalse
        $snap = Get-TweakSnapshot -Tweak $t
        Set-TweakState -Tweak $t -Snapshot $snap
        Test-TweakApplied -Tweak $t | Should -BeTrue
        $entry = [pscustomobject]@{ Id = 'rt-test'; Type = 'Registry'; Snapshot = $snap }
        Restore-Tweak -Entry $entry -Registry @($t)
        Test-TweakApplied -Tweak $t | Should -BeFalse
    }
}

Describe 'New coverage additions' {
    It 'adds the Recall/AI privacy tweak as a registry tweak under WindowsAI' {
        $t = $script:Reg | Where-Object Id -eq 'priv-recall'
        $t           | Should -Not -BeNullOrEmpty
        $t.Type      | Should -Be 'Registry'
        $t.Spec.Path | Should -Match 'WindowsAI'
    }
    It 'adds the classic context-menu tweak as a custom tweak, off by default' {
        $t = $script:Reg | Where-Object Id -eq 'ux-context-menu'
        $t.Type      | Should -Be 'Custom'
        $t.DefaultOn | Should -BeFalse
    }
    It 'adds the combined taskbar/Start ad-surface debloat tweak' {
        $t = $script:Reg | Where-Object Id -eq 'debloat-taskbar-ads'
        @($t.Spec.Values).Count | Should -BeGreaterThan 3
    }
    It 'keeps debatable additions off by default' {
        foreach ($id in 'priv-clipboard', 'net-teredo', 'perf-faststartup', 'ux-fileext') {
            ($script:Reg | Where-Object Id -eq $id).DefaultOn | Should -BeFalse
        }
    }
}

Describe 'Research-pass additions and corrections' {
    BeforeAll {
        $script:ById = @{}
        foreach ($t in $script:Reg) { $script:ById[$t.Id] = $t }
        # Every value of a Registry tweak, with its effective path.
        function Get-TestRegValue {
            param([string]$Id, [string]$Name)
            $t = $script:ById[$Id]
            foreach ($v in $t.Spec.Values) {
                if ($v.Name -eq $Name) {
                    [pscustomobject]@{ Path = (Get-RegValuePath -Tweak $t -Value $v); Kind = $v.Kind; Value = $v.Value }
                }
            }
        }
    }

    It 'registers every new tweak id in a valid area' -TestCases @(
        @{ Id = 'debloat-widgets-policy' }, @{ Id = 'debloat-feeds-w10' }, @{ Id = 'debloat-meetnow' },
        @{ Id = 'priv-ai-paint' }, @{ Id = 'priv-ai-notepad' }, @{ Id = 'priv-langlist' },
        @{ Id = 'priv-settings-ads' }, @{ Id = 'priv-suggested-actions' }, @{ Id = 'priv-trackprogs' },
        @{ Id = 'priv-findmydevice' }, @{ Id = 'priv-location' }, @{ Id = 'priv-chrome-ai' },
        @{ Id = 'priv-recall-remove' }, @{ Id = 'perf-edge-bg' }, @{ Id = 'debloat-edge' },
        @{ Id = 'debloat-start-reco' }, @{ Id = 'debloat-stickykeys' }, @{ Id = 'ux-mouseaccel' },
        @{ Id = 'ux-launch-thispc' }, @{ Id = 'ux-hidden' }, @{ Id = 'ux-endtask' },
        @{ Id = 'ux-explorer-home-gallery' }, @{ Id = 'perf-powerthrottling' }, @{ Id = 'perf-usb-suspend' },
        @{ Id = 'perf-wu-latest' }, @{ Id = 'perf-reserved-storage' }, @{ Id = 'perf-hags' },
        @{ Id = 'debloat-copilot-app' }
    ) {
        param($Id)
        $t = $script:ById[$Id]
        $t | Should -Not -BeNullOrEmpty
        $t.Area | Should -BeIn @('Performance','Privacy','Debloat','Network')
        $t.Explain | Should -Not -BeNullOrEmpty
    }

    It 'gives every Custom tweak Test, Backup, Apply and Undo scriptblocks' {
        foreach ($t in ($script:Reg | Where-Object Type -eq 'Custom')) {
            $t.Spec.Test   | Should -BeOfType ([scriptblock])
            $t.Spec.Backup | Should -BeOfType ([scriptblock])
            $t.Spec.Apply  | Should -BeOfType ([scriptblock])
            $t.Spec.Undo   | Should -BeOfType ([scriptblock])
        }
    }

    It 'makes the new powercfg/DISM/Appx/CLSID tweaks Custom' {
        foreach ($id in 'perf-usb-suspend', 'perf-reserved-storage', 'ux-explorer-home-gallery', 'debloat-copilot-app') {
            $script:ById[$id].Type | Should -Be 'Custom'
        }
    }

    It 'disables Teredo via the v6Transition policy, not DisabledComponents' {
        $v = Get-TestRegValue 'net-teredo' 'Teredo_State'
        $v.Value | Should -Be 'Disabled'
        $v.Kind  | Should -Be 'String'
        $v.Path  | Should -Match 'TCPIP\\v6Transition'
        @($script:ById['net-teredo'].Spec.Values.Name) | Should -Not -Contain 'DisabledComponents'
    }

    It 'uses SystemResponsiveness 10 and ships net-throttling off' {
        (Get-TestRegValue 'net-throttling' 'SystemResponsiveness').Value | Should -Be 10
        $script:ById['net-throttling'].DefaultOn | Should -BeFalse
    }

    It 'keeps font smoothing in perf-visualfx and uses the custom setting' {
        (Get-TestRegValue 'perf-visualfx' 'VisualFXSetting').Value | Should -Be 3
        $fs = Get-TestRegValue 'perf-visualfx' 'FontSmoothing'
        $fs.Value | Should -Be '2'
        $fs.Path  | Should -Be 'HKCU:\Control Panel\Desktop'
        (Get-TestRegValue 'perf-visualfx' 'UserPreferencesMask').Kind | Should -Be 'Binary'
        $script:ById['perf-visualfx'].DefaultOn | Should -BeTrue
    }

    It 'no longer writes the UCPD-blocked TaskbarDa value' {
        @($script:ById['debloat-taskbar-ads'].Spec.Values.Name) | Should -Not -Contain 'TaskbarDa'
    }

    It 'moves the Spotlight policy to HKCU and adds the Home/Pro switches' {
        $script:ById['priv-spotlight'].Spec.Path | Should -Match '^HKCU:'
        (Get-TestRegValue 'priv-spotlight' 'RotatingLockScreenEnabled').Value | Should -Be 0
        (Get-TestRegValue 'priv-spotlight' 'SubscribedContent-338387Enabled').Value | Should -Be 0
    }

    It 'writes both CEIP locations and the extra web-search policies' {
        @(Get-TestRegValue 'priv-ceip' 'CEIPEnable').Count | Should -Be 2
        (Get-TestRegValue 'priv-websearch' 'DisableSearchBoxSuggestions').Value | Should -Be 1
        (Get-TestRegValue 'priv-websearch' 'EnableDynamicContentInWSB').Value | Should -Be 0
    }

    It 'drops the fullscreen-optimization override from net-gamedvr' {
        @($script:ById['net-gamedvr'].Spec.Values.Name) | Should -Not -Contain 'GameDVR_FSEBehaviorMode'
        (Get-TestRegValue 'net-gamedvr' 'AppCaptureEnabled').Value | Should -Be 0
    }

    It 'flips harmful or placebo defaults off' {
        foreach ($id in 'perf-bgapps', 'priv-dmwappush', 'net-gamedvr-policy', 'net-throttling',
                        'debloat-copilot-app', 'perf-usb-suspend', 'perf-reserved-storage', 'perf-hags',
                        'priv-location', 'priv-findmydevice', 'debloat-start-reco') {
            $script:ById[$id].DefaultOn | Should -BeFalse -Because $id
        }
    }

    It 'no longer removes Get Help' {
        (Get-OptAppxPattern junk) | Should -Not -Contain '*Microsoft.GetHelp*'
    }

    It 'does not reuse a ContentDeliveryManager value across tweaks' {
        $cdm = foreach ($t in ($script:Reg | Where-Object Type -eq 'Registry')) {
            foreach ($v in $t.Spec.Values) {
                $p = Get-RegValuePath -Tweak $t -Value $v
                if ($p -match 'ContentDeliveryManager$') { $v.Name }
            }
        }
        @($cdm).Count | Should -Be @($cdm | Sort-Object -Unique).Count
    }

    It 'keeps the registry source pure ASCII' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Sut)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Id list normalization (desktop app passes comma-joined ids)' {
    It 'splits a single comma-joined string into ids' {
        $ids = ConvertTo-OptIdList @('perf-sysmain, ux-fileext,,priv-adid ')
        $ids | Should -Be @('perf-sysmain', 'ux-fileext', 'priv-adid')
    }
    It 'keeps $null as nothing' {
        @(ConvertTo-OptIdList $null).Count | Should -Be 0
    }
    It 'lets split ids drive Resolve-TweakSelection' {
        $inc = ConvertTo-OptIdList @('perf-sysmain,ux-fileext')
        $exc = ConvertTo-OptIdList @('priv-adid,priv-tips')
        $sel = Resolve-TweakSelection -Registry $script:Reg -Include $inc -Exclude $exc
        @($sel | Where-Object Id -in 'perf-sysmain', 'ux-fileext').Count | Should -Be 2
        @($sel | Where-Object Id -in 'priv-adid', 'priv-tips').Count | Should -Be 0
    }
}

Describe 'Binary and multi-path registry round-trip' {
    BeforeAll {
        $script:TestKey3 = 'HKCU:\Software\WinSeniorTest'
        if (Test-Path $script:TestKey3) { Remove-Item $script:TestKey3 -Recurse -Force }
    }
    AfterAll {
        if (Test-Path $script:TestKey3) { Remove-Item $script:TestKey3 -Recurse -Force }
    }
    It 'restores a pre-existing binary value through a JSON manifest round-trip' {
        $orig = [byte[]](0x9E, 0x1E, 0x07, 0x80, 0x12, 0x00, 0x00, 0x00)
        Set-RegValue -Path $script:TestKey3 -Name 'Mask' -Kind Binary -Value $orig
        $t = New-RegTweak rt-bin 'binary round-trip' Performance Safe `
                -Path $script:TestKey3 `
                -Values @((RegVal 'Mask' Binary ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)))) -Explain 'test'
        Test-TweakApplied -Tweak $t | Should -BeFalse
        $snap = Get-TweakSnapshot -Tweak $t
        Set-TweakState -Tweak $t -Snapshot $snap
        Test-TweakApplied -Tweak $t | Should -BeTrue
        (Get-ItemProperty $script:TestKey3 -Name Mask).Mask | Should -Be ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00))
        # Undo reads the snapshot back from a JSON manifest, as -Undo does.
        $json  = [pscustomobject]@{ Id = 'rt-bin'; Type = 'Registry'; Snapshot = $snap } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        Restore-Tweak -Entry $json -Registry @($t)
        $back = (Get-Item $script:TestKey3).GetValue('Mask')
        $back | Should -Be $orig
        (Get-Item $script:TestKey3).GetValueKind('Mask') | Should -Be 'Binary'
    }
    It 'applies and reverts a value that lives under its own -Path' {
        $sub = "$script:TestKey3\Sub"
        $t = New-RegTweak rt-multi 'multi-path round-trip' Performance Safe `
                -Path $script:TestKey3 `
                -Values @((RegVal 'A' DWord 1), (RegVal 'B' String 'x' -Path $sub)) -Explain 'test'
        $snap = Get-TweakSnapshot -Tweak $t
        Set-TweakState -Tweak $t -Snapshot $snap
        (Get-ItemProperty $sub -Name B).B | Should -Be 'x'
        Test-TweakApplied -Tweak $t | Should -BeTrue
        $json = [pscustomobject]@{ Id = 'rt-multi'; Type = 'Registry'; Snapshot = $snap } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        Restore-Tweak -Entry $json -Registry @($t)
        (Get-Item $sub).GetValueNames() | Should -Not -Contain 'B'
        (Get-Item $script:TestKey3).GetValueNames() | Should -Not -Contain 'A'
    }
}
