# Pester tests for the shared library WinSenior.Common.ps1
# Run:  Invoke-Pester -Path .\tests
# Covers the helpers every engine now dot-sources: byte formatting, the canonical
# logger, and the System Restore point routine (mocked, so nothing touches the box).

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\WinSenior.Common.ps1'
    . $script:Sut
}

Describe 'Test-AdminPrivileges' {
    It 'returns a boolean' {
        Test-AdminPrivileges | Should -BeOfType ([bool])
    }
}

Describe 'Format-FileSize' {
    # Decimal separator is culture-dependent (1.50 vs 1,50), so match structurally.
    It 'formats bytes' { Format-FileSize 512 | Should -Be '512 B' }
    It 'formats zero'  { Format-FileSize 0   | Should -Be '0 B' }
    It 'scales to KB'  { Format-FileSize 1536        | Should -Match '^1[.,]50 KB$' }
    It 'scales to MB'  { Format-FileSize (5MB)        | Should -Match '^5[.,]00 MB$' }
    It 'scales to GB'  { Format-FileSize (2GB)        | Should -Match '^2[.,]00 GB$' }
    It 'scales to TB'  { Format-FileSize (3TB)        | Should -Match '^3[.,]00 TB$' }
}

Describe 'Write-WsLog' {
    It 'writes a stamped line to the log file' {
        $tmp = Join-Path $env:TEMP ("wslog_{0}.log" -f [guid]::NewGuid().ToString('N'))
        Write-WsLog -Message 'hello world' -Level 'Info' -LogPath $tmp
        $tmp | Should -Exist
        (Get-Content $tmp -Raw) | Should -Match '\[Info\] hello world'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'does not throw when no LogPath is given' {
        { Write-WsLog -Message 'console only' -Level 'Warning' } | Should -Not -Throw
    }
}

Describe 'New-WinSeniorRestorePoint' {
    # A capturing logger built from a LOCAL variable + GetNewClosure. Using $script:
    # scope here does NOT survive the closure's module boundary under Pester 5 (the
    # variable reads back as $null inside the scriptblock), so keep it function-local.
    It 'is a no-op under -WhatIf and never checkpoints' {
        Mock Checkpoint-Computer { }
        $captured = [System.Collections.Generic.List[string]]::new()
        $logger = { param($m, $l) $captured.Add("$l|$m") }.GetNewClosure()
        $WhatIfPreference = $true
        $r = New-WinSeniorRestorePoint -Description 'test' -LogAction $logger
        $r | Should -Be 'WhatIf'
        ($captured -join "`n") | Should -Match 'would create a System Restore point'
        Should -Invoke Checkpoint-Computer -Times 0 -Exactly
    }

    It 'returns Created and checkpoints once on success' {
        Mock New-ItemProperty    { }
        Mock Enable-ComputerRestore { }
        Mock Checkpoint-Computer  { }
        $captured = [System.Collections.Generic.List[string]]::new()
        $logger = { param($m, $l) $captured.Add("$l|$m") }.GetNewClosure()
        $WhatIfPreference = $false
        $r = New-WinSeniorRestorePoint -Description 'test' -LogAction $logger
        $r | Should -Be 'Created'
        Should -Invoke Checkpoint-Computer -Times 1 -Exactly
        ($captured -join "`n") | Should -Match 'System Restore point created'
    }

    It 'returns Failed when the checkpoint throws' {
        Mock New-ItemProperty    { }
        Mock Enable-ComputerRestore { }
        Mock Checkpoint-Computer  { throw 'protection off' }
        $captured = [System.Collections.Generic.List[string]]::new()
        $logger = { param($m, $l) $captured.Add("$l|$m") }.GetNewClosure()
        $WhatIfPreference = $false
        $r = New-WinSeniorRestorePoint -Description 'test' -LogAction $logger
        $r | Should -Be 'Failed'
        ($captured -join "`n") | Should -Match 'Restore point not created'
    }
}

Describe 'Write-WinSeniorReport' {
    It 'is a no-op without -ReportPath' {
        { Write-WinSeniorReport -Engine 'Cleanup' -Summary @{} } | Should -Not -Throw
    }
    It 'writes a unified envelope that round-trips' {
        $tmp = Join-Path $env:TEMP ("wsrep_{0}.json" -f [guid]::NewGuid().ToString('N'))
        $start = (Get-Date).AddSeconds(-5)
        Write-WinSeniorReport -ReportPath $tmp -Engine 'Cleanup' `
            -RestorePoint $true -StartTime $start `
            -Summary @{ TotalFiles = 7; TotalBytes = 1024 } `
            -Items @([pscustomobject]@{ Id = 'a' })
        $tmp | Should -Exist
        $obj = Get-Content $tmp -Raw | ConvertFrom-Json
        $obj.Tool               | Should -Be 'WinSenior'
        $obj.Engine             | Should -Be 'Cleanup'
        $obj.Version            | Should -Be (Get-WinSeniorVersion)
        $obj.RestorePoint       | Should -BeTrue
        $obj.DurationSec        | Should -BeGreaterThan 0
        $obj.Summary.TotalFiles | Should -Be 7
        @($obj.Items).Count     | Should -Be 1
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'rejects an unknown engine' {
        { Write-WinSeniorReport -ReportPath 'x' -Engine 'Bogus' } | Should -Throw
    }
}
