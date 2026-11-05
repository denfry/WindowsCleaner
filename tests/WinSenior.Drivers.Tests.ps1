# Pester tests for WinSenior.Drivers.ps1 - pure pieces only (no Windows Update
# search, no pnputil): GPU vendor classification, NVIDIA version mapping, the
# GPU-update filter and the policy-block probe.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\WinSenior.Drivers.ps1')
    $script:Now = Get-Date '2026-11-05'
}

Describe 'ConvertTo-WsGpuRecord' {
    It 'maps an NVIDIA Windows driver version to the vendor version' {
        $g = ConvertTo-WsGpuRecord ([pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4070'; PNPDeviceID = 'PCI\VEN_10DE&DEV_2786'
                DriverVersion = '32.0.15.6094'; DriverDate = (Get-Date '2026-09-01') }) -Now $script:Now
        $g.Vendor | Should -Be 'NVIDIA'
        $g.VendorVersion | Should -Be '560.94'
        $g.NeedsUpdate | Should -BeFalse
        $g.OfficialUrl | Should -Match 'nvidia\.com'
    }
    It 'flags an AMD driver older than 180 days' {
        $g = ConvertTo-WsGpuRecord ([pscustomobject]@{ Name = 'AMD Radeon(TM) Graphics'; PNPDeviceID = 'PCI\VEN_1002&DEV_1638'
                DriverVersion = '31.0.21923.12002'; DriverDate = (Get-Date '2025-07-16') }) -Now $script:Now
        $g.Vendor | Should -Be 'AMD'
        $g.NeedsUpdate | Should -BeTrue
        $g.AgeDays | Should -Be 477
        $g.VendorVersion | Should -Be '31.0.21923.12002'
    }
    It 'routes Intel to the Driver & Support Assistant via winget' {
        $g = ConvertTo-WsGpuRecord ([pscustomobject]@{ Name = 'Intel(R) UHD'; PNPDeviceID = 'PCI\VEN_8086&DEV_9BC4'; DriverVersion = '31.0.101.2125'; DriverDate = $script:Now }) -Now $script:Now
        $g.WingetId | Should -Be 'Intel.IntelDriverAndSupportAssistant'
    }
    It 'treats unknown vendors as Windows Update territory' {
        $g = ConvertTo-WsGpuRecord ([pscustomobject]@{ Name = 'Microsoft Basic Display Adapter'; PNPDeviceID = 'PCI\VEN_1234&DEV_1111'; DriverVersion = '10.0'; DriverDate = $null }) -Now $script:Now
        $g.Vendor | Should -Be 'Other'
        $g.NeedsUpdate | Should -BeFalse
    }
}

Describe 'Test-WsGpuDriverUpdate' {
    It 'holds back display-class and NVIDIA/AMD PCI updates' {
        Test-WsGpuDriverUpdate ([pscustomobject]@{ DriverClass = 'Display'; HardwareId = 'PCI\VEN_8086&DEV_1' }) | Should -BeTrue
        Test-WsGpuDriverUpdate ([pscustomobject]@{ DriverClass = 'OtherHardware'; HardwareId = 'PCI\VEN_10DE&DEV_1AEF' }) | Should -BeTrue
    }
    It 'lets chipset / network / audio through' {
        Test-WsGpuDriverUpdate ([pscustomobject]@{ DriverClass = 'Net'; HardwareId = 'PCI\VEN_8086&DEV_15F3' }) | Should -BeFalse
        Test-WsGpuDriverUpdate ([pscustomobject]@{ DriverClass = 'MEDIA'; HardwareId = 'HDAUDIO\FUNC_01&VEN_10EC' }) | Should -BeFalse
    }
}

Describe 'Get-WsDriverPolicyBlock' {
    It 'explains an ExcludeWUDriversInQualityUpdate block' {
        Mock Get-ItemProperty { [pscustomobject]@{ ExcludeWUDriversInQualityUpdate = 1 } } -ParameterFilter { $Path -like '*WindowsUpdate' }
        Mock Get-ItemProperty { $null } -ParameterFilter { $Path -like '*DriverSearching' }
        Get-WsDriverPolicyBlock | Should -Match 'ExcludeWUDriversInQualityUpdate=1'
    }
    It 'is silent without a block' {
        Mock Get-ItemProperty { $null }
        Get-WsDriverPolicyBlock | Should -BeNullOrEmpty
    }
}
