# Pester tests for WinSenior.Schedule.ps1
# Run:  Invoke-Pester -Path .\tests
# Covers the pure planner Get-WinSeniorScheduleSpec only - no task is registered,
# so the tests are safe and deterministic. Install/Remove call Register-/Unregister-
# ScheduledTask and are verified on a real machine.

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot '..\WinSenior.Schedule.ps1'
    . $script:Sut
    $script:Spec = Get-WinSeniorScheduleSpec -Root 'C:\WS' -ReportDir 'C:\WS\reports'
}

Describe 'Get-WinSeniorScheduleSpec' {
    It 'returns two task specs' {
        @($script:Spec).Count | Should -Be 2
    }
    It 'places both tasks under the \WinSenior\ folder' {
        foreach ($s in $script:Spec) { $s.TaskPath | Should -Be '\WinSenior\' }
    }
    It 'launches powershell.exe with bypass and a hidden window' {
        foreach ($s in $script:Spec) {
            $s.Execute  | Should -Be 'powershell.exe'
            $s.Argument | Should -Match '-ExecutionPolicy Bypass'
            $s.Argument | Should -Match '-WindowStyle Hidden'
        }
    }
    It 'points every report under the given ReportDir' {
        foreach ($s in $script:Spec) {
            $s.Argument | Should -Match ([regex]::Escape('C:\WS\reports'))
        }
    }
    It 'runs the cleanup weekly, unattended, with no restore point' {
        $c = $script:Spec | Where-Object { $_.Name -match 'Cleanup' }
        $c.Cadence  | Should -Be 'Weekly'
        $c.Day      | Should -Be 'Sunday'
        $c.Argument | Should -Match '-Unattended'
        $c.Argument | Should -Match '-NoRestorePoint'
        $c.Argument | Should -Match 'Cleanup-Windows-Senior\.ps1'
    }
    It 'runs the health scan monthly and read-only' {
        $r = $script:Spec | Where-Object { $_.Name -match 'Scan' }
        $r.Cadence  | Should -Be 'Monthly'
        $r.Day      | Should -Be 1
        $r.Argument | Should -Match '-ScanOnly'
        $r.Argument | Should -Match 'Repair-Windows-Senior\.ps1'
    }
}
