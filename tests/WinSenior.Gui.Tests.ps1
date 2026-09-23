# Pester tests for WinSenior.Gui.ps1 - the WPF desktop app - and the WinSenior.cmd launcher.
# The window itself is never shown; we verify the script parses, the embedded XAML
# loads into a real WPF object tree, every control the code-behind wires exists, and
# the pure helpers (argument building, log splitting, WhatIf compaction, progress,
# history, HTML export) behave - those are lifted out of the script via its AST, so
# nothing in the GUI runs.

BeforeAll {
    $script:Gui = Join-Path $PSScriptRoot '..\WinSenior.Gui.ps1'
    $script:Src = Get-Content $script:Gui -Raw
    $m = [regex]::Match($script:Src, "(?s)\`$xaml = @'\r?\n(.*?)\r?\n'@")
    $script:XamlText = if ($m.Success) { $m.Groups[1].Value } else { $null }

    # Load the pure helper functions (and the shared library they use) without running the app.
    . (Join-Path $PSScriptRoot '..\WinSenior.Common.ps1')
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:Gui), [ref]$null, [ref]$null)
    $want = 'ConvertTo-WsCmdArg', 'Get-WsMaxAge', 'Get-WsSelectionArg', 'Split-WsLogChunk', 'Format-WsEngineLine',
            'Get-WsStepName', 'ConvertTo-WsDate', 'Get-WsHistoryEntry', 'ConvertTo-WsReportHtml'
    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $false)
    foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }
    $pat = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$script:WhatIfPattern' }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($pat.Extent.Text))
}

Describe 'WinSenior.Gui.ps1' {
    It 'parses without errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:Gui), [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
    It 'is pure ASCII (loads identically under Windows PowerShell 5.1)' {
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $script:Gui))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'embeds a XAML here-string' {
        $script:XamlText | Should -Not -BeNullOrEmpty
    }
    It 'loads the XAML into a WPF Window' {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$script:XamlText)
        $win = [System.Windows.Markup.XamlReader]::Load($reader)
        $win | Should -BeOfType System.Windows.Window
        $win.Close()
    }
    It 'names every control the code-behind references' {
        $used  = [regex]::Matches($script:Src, '\$W\.([A-Za-z0-9]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $xml   = [xml]$script:XamlText
        $named = $xml.SelectNodes('//*[@*[local-name()="Name"]]') |
            ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') }
        $missing = @($used | Where-Object { $_ -notin $named })
        $missing | Should -BeNullOrEmpty
    }
    It 'has a page for every nav button (incl. Startup and History)' {
        foreach ($p in 'PageClean', 'PageOpt', 'PageRepair', 'PageStartup', 'PageHistory', 'PageUndo', 'PageSchedule', 'PageAbout') {
            $script:XamlText | Should -Match "x:Name=`"$p`""
        }
    }
    It 'wraps the static pages in a ScrollViewer so they never get cut off' {
        foreach ($p in 'PageUndo', 'PageSchedule', 'PageAbout') {
            $script:XamlText | Should -Match "<ScrollViewer x:Name=`"$p`""
        }
    }
    It 'runs the engines through their scripts instead of re-implementing deletion' {
        $script:Src | Should -Match 'Start-Engine -Script \$script:CleanupScript'
        $script:Src | Should -Not -Match 'Remove-Item -LiteralPath [^\r\n]*-Recurse'
    }
    It 'always passes -Unattended so engines never block on Read-Host' {
        $script:Src | Should -Match "\`$a \+= '-Unattended'"
    }
    It 'loads WPF before the first MessageBox' {
        $load = $script:Src.IndexOf('Add-Type -AssemblyName PresentationFramework')
        $box  = $script:Src.IndexOf('[System.Windows.MessageBox]::Show')
        $load | Should -BeGreaterThan 0
        $load | Should -BeLessThan $box
    }
    It 'guards against crashes: dispatcher handler, ShowDialog try/catch, single instance' {
        $script:Src | Should -Match 'Dispatcher\.Add_UnhandledException'
        $script:Src | Should -Match '(?s)try \{\s*\[void\]\$Win\.ShowDialog\(\)'
        $script:Src | Should -Match 'Global\\WinSeniorGui'
    }
    It 'keeps the exit code on Windows PowerShell 5.1 (touches the process handle)' {
        $script:Src | Should -Match '\$null = \$script:Proc\.Handle'
    }
    It 'clears OnDone BEFORE running it (so Fix -> re-scan keeps its handler)' {
        $script:Src | Should -Match '(?s)\$handler = \$script:OnDone\s+\$script:OnDone = \$null.*& \$handler'
    }
    It 'creates the restore point without a temp script' {
        $script:Src | Should -Not -Match 'winsenior-gui-rp'
        $script:Src | Should -Match 'New-WinSeniorRestorePoint'
    }
    It 'passes -CloseApps from the "Close running browsers first" box' {
        $script:XamlText | Should -Match 'x:Name="ChkCloseApps"'
        $script:Src | Should -Match "ChkCloseApps\.IsChecked\) \{ \`$a \+= '-CloseApps'"
    }
    It 'only lets the automation hook press read-only buttons' {
        $line = ($script:Src -split "`n" | Where-Object { $_ -match '^\$script:SafeAutoRun' }) -join ''
        $line | Should -Match 'BtnScan'
        foreach ($b in 'BtnClean', 'BtnOptApply', 'BtnRepFix', 'BtnRepFixAll', 'BtnUndoLast', 'BtnRestorePoint', 'BtnSchedInstall') {
            $line | Should -Not -Match "'$b'"
        }
    }
}

Describe 'GUI helpers' {
    Context 'Get-WsSelectionArg' {
        It 'omits -Exclude when every row is ticked (never sends an empty value)' {
            $a = @(Get-WsSelectionArg -AllIds 'a', 'b' -OnIds 'a', 'b')
            $a | Should -Be @('-Include', 'a,b')
        }
        It 'omits -Include when nothing is ticked' {
            @(Get-WsSelectionArg -AllIds 'a', 'b' -OnIds @()) | Should -Be @('-Exclude', 'a,b')
        }
        It 'splits on and off ids' {
            @(Get-WsSelectionArg -AllIds 'a', 'b', 'c' -OnIds 'b') | Should -Be @('-Include', 'b', '-Exclude', 'a,c')
        }
    }

    Context 'Get-WsMaxAge' {
        It 'accepts whole days' { Get-WsMaxAge '14' | Should -Be 14 }
        It 'treats empty as 0'  { Get-WsMaxAge '' | Should -Be 0 }
        It 'rejects text'       { Get-WsMaxAge 'abc' | Should -BeNullOrEmpty }
        It 'rejects negatives'  { Get-WsMaxAge '-3' | Should -BeNullOrEmpty }
        It 'rejects huge values' { Get-WsMaxAge '99999999999' | Should -BeNullOrEmpty }
    }

    Context 'ConvertTo-WsCmdArg' {
        It 'leaves simple tokens alone' { ConvertTo-WsCmdArg '-Include' | Should -Be '-Include' }
        It 'quotes paths with spaces'   { ConvertTo-WsCmdArg 'C:\a b\x.ps1' | Should -Be '"C:\a b\x.ps1"' }
        It 'doubles a trailing backslash inside quotes' { ConvertTo-WsCmdArg 'C:\a b\' | Should -Be '"C:\a b\\"' }
        It 'escapes embedded quotes'    { ConvertTo-WsCmdArg 'say "hi"' | Should -Be '"say \"hi\""' }
        It 'quotes an empty value'      { ConvertTo-WsCmdArg '' | Should -Be '""' }
    }

    Context 'Split-WsLogChunk' {
        It 'keeps an unfinished line for the next read' {
            $r = Split-WsLogChunk '' "one`r`ntw"
            @($r.Lines) | Should -Be @('one')
            $r.Rest | Should -Be 'tw'
            $r2 = Split-WsLogChunk $r.Rest "o`r`nthree`r`n"
            @($r2.Lines) | Should -Be @('two', 'three')
            $r2.Rest | Should -Be ''
        }
        It 'returns no lines while no newline arrived' {
            $r = Split-WsLogChunk 'abc' 'def'
            @($r.Lines).Count | Should -Be 0
            $r.Rest | Should -Be 'abcdef'
        }
        It 'drops a UTF-8 byte-order mark' {
            (Split-WsLogChunk '' ([string][char]0xFEFF + "x`n")).Lines | Should -Be @('x')
        }
    }

    Context 'Format-WsEngineLine (WhatIf compaction)' {
        It 'compacts the English ShouldProcess line' {
            Format-WsEngineLine 'What if: Performing the operation "Remove (Chrome cache)" on target "C:\Users\a\Cache\x".' |
                Should -Be '  [WhatIf] C:\Users\a\Cache\x'
        }
        It 'compacts a localized (Russian) ShouldProcess line' {
            # 'WhatIf: <Cyrillic "performing the operation"> "Remove (...)" <Cyrillic "on target"> "..."'
            $op  = -join ([char[]](0x0412, 0x044B, 0x043F, 0x043E, 0x043B, 0x043D, 0x0435, 0x043D, 0x0438, 0x0435))
            $tgt = -join ([char[]](0x043D, 0x0430, 0x0434))
            $line = "WhatIf: $op `"Remove (Temp)`" $tgt `"C:\Temp\f.tmp`"."
            Format-WsEngineLine $line | Should -Be '  [WhatIf] C:\Temp\f.tmp'
        }
        It 'labels tweak previews' {
            Format-WsEngineLine 'What if: Performing the operation "Apply tweak [Privacy/Safe]" on target "Disable ads ID".' |
                Should -Be '  [WhatIf] Apply tweak [Privacy/Safe]: Disable ads ID'
        }
        It 'strips ANSI colour codes and leaves other lines alone' {
            Format-WsEngineLine ([string][char]27 + '[32m[+] done' + [string][char]27 + '[0m') | Should -Be '[+] done'
        }
    }

    Context 'Get-WsStepName (progress)' {
        It 'reads the cleanup step line' {
            Get-WsStepName '==> Chrome cache  [Browsers/Safe]' | Should -Be 'Chrome cache'
        }
        It 'ignores headers and summaries' {
            Get-WsStepName '==> Windows System Cleaner v6.3.0' | Should -BeNullOrEmpty
            Get-WsStepName '==> ===== DRY RUN SUMMARY =====' | Should -BeNullOrEmpty
        }
        It 'counts a tweak preview' {
            Get-WsStepName 'WhatIf: x "Apply tweak [Performance/Safe]" y "Zero menu show delay".' | Should -Be 'Zero menu show delay'
        }
        It 'counts an applied tweak only when it is one of the selected names' {
            Get-WsStepName '[+] Zero menu show delay' -Names 'Zero menu show delay' | Should -Be 'Zero menu show delay'
            Get-WsStepName '[+] System Restore point created' -Names 'Zero menu show delay' | Should -BeNullOrEmpty
        }
    }

    Context 'Get-WsHistoryEntry' {
        It 'summarises a live cleanup and counts its bytes' {
            $rep = [pscustomobject]@{ Engine = 'Cleanup'; Mode = 'Live'; Timestamp = '2026-09-01T10:20:30'
                Summary = [pscustomobject]@{ TotalBytes = 2048; TotalFreed = '2.00 KB'; TotalFiles = 3; TotalErrors = 1 }; Items = @() }
            $h = Get-WsHistoryEntry -Report $rep -Path 'C:\r\gui-cleanup-1.json'
            $h.Engine | Should -Be 'Cleanup'
            $h.Mode   | Should -Be 'Live'
            $h.Bytes  | Should -Be 2048
            $h.Errors | Should -Be 1
            $h.Result | Should -Match '^Freed 2.00 KB'
            $h.Source | Should -Be 'App'
            $h.Date.ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-09-01 10:20'
        }
        It 'never counts a dry run toward the total' {
            $rep = [pscustomobject]@{ Engine = 'Cleanup'; Mode = 'DryRun'; Timestamp = '2026-09-01T10:20:30'
                Summary = [pscustomobject]@{ TotalBytes = 999; TotalFreed = '999 B'; TotalFiles = 1; TotalErrors = 0 }; Items = @() }
            $h = Get-WsHistoryEntry -Report $rep -Path 'C:\r\cleanup.json'
            $h.Bytes  | Should -Be 0
            $h.Result | Should -Match '^Would free'
            $h.Source | Should -Be 'Scheduled'
        }
        It 'summarises optimize and repair runs' {
            $o = Get-WsHistoryEntry -Report ([pscustomobject]@{ Engine = 'Optimize'; Mode = 'Live'; Timestamp = '2026-09-01T10:20:30'
                Summary = [pscustomobject]@{ Applied = 4; Skipped = 2; Errors = 0 }; Items = @() })
            $o.Result | Should -Be 'Applied 4, skipped 2'
            $r = Get-WsHistoryEntry -Report ([pscustomobject]@{ Engine = 'Repair'; Mode = 'Live'; Timestamp = '2026-09-01T10:20:30'
                Summary = [pscustomobject]@{ Fixed = 1; FixErrors = 0; Reboot = $true }
                Items = @([pscustomobject]@{ Status = 'Fail' }, [pscustomobject]@{ Status = 'Warn' }, [pscustomobject]@{ Status = 'OK' }) })
            $r.Result | Should -Be '1 failing, 1 warning, fixed 1 (reboot needed)'
        }
    }

    Context 'ConvertTo-WsReportHtml' {
        It 'builds a self-contained, encoded HTML page with summary and items' {
            $rep = [pscustomobject]@{ Tool = 'WinSenior'; Version = '6.3.0'; Engine = 'Cleanup'; Host = 'PC'; Timestamp = '2026-09-01T10:20:30'
                Mode = 'Live'; RestorePoint = $true; DurationSec = 1.5
                Summary = [pscustomobject]@{ TotalFreed = '1 KB' }
                Items = @([pscustomobject]@{ Task = 'x<script>'; Bytes = 1024; Files = 2 }) }
            $html = ConvertTo-WsReportHtml -Report $rep -SourcePath 'C:\r\a.json'
            $html | Should -Match '^<!DOCTYPE html>'
            $html | Should -Match '<table>'
            $html | Should -Match 'TotalFreed'
            $html | Should -Match 'x&lt;script&gt;'
            $html | Should -Not -Match '<script'
            $html | Should -Not -Match '(src|href)="http'
        }
    }
}

Describe 'WinSenior.cmd launcher' {
    BeforeAll { $script:Cmd = Get-Content (Join-Path $PSScriptRoot '..\WinSenior.cmd') -Raw }
    It 'elevates via RunAs and targets the GUI by default' {
        $script:Cmd | Should -Match 'RunAs'
        $script:Cmd | Should -Match 'WinSenior\.Gui\.ps1'
    }
    It 'unblocks downloaded scripts and offers a console mode' {
        $script:Cmd | Should -Match 'Unblock-File'
        $script:Cmd | Should -Match '"console"'
    }
    It 'never expands a path inside a parenthesised block' {
        foreach ($line in ($script:Cmd -split "`r?`n")) {
            $line | Should -Not -Match '^\s*(if|for)\b.*\($'
        }
    }
    It 'hands paths to PowerShell through environment variables only' {
        $script:Cmd | Should -Match '\$env:WS_TARGET'
        $script:Cmd | Should -Match '\$env:WS_ROOT'
        $script:Cmd | Should -Not -Match "'%WS_"
        $script:Cmd | Should -Not -Match "'%ROOT%"
    }
    It 'has CRLF line endings (cmd.exe mis-parses labels in LF-only files)' {
        $raw = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\WinSenior.cmd'))
        ($raw -replace "`r`n", '') | Should -Not -Match "`n"
    }
    It 'launches from a folder whose name has spaces, ) & '' and Cyrillic' {
        $cyr = -join ([char[]](0x041F, 0x0430, 0x043F, 0x043A, 0x0430))
        $dir = Join-Path $env:TEMP ("ws cmd (x86) & it's $cyr " + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            Copy-Item (Join-Path $PSScriptRoot '..\WinSenior.cmd') $dir
            $marker = Join-Path $dir 'started.txt'
            # Stub GUI: records the path it was started from and its arguments.
            Set-Content -LiteralPath (Join-Path $dir 'WinSenior.Gui.ps1') -Encoding ASCII -Value @(
                'param([switch]$NoElevate)'
                '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "started.txt"), ("{0}|{1}" -f $PSCommandPath, [bool]$NoElevate), [Text.Encoding]::UTF8)'
            )
            $env:WINSENIOR_NOELEVATE = '1'
            try {
                $cmdLine = '/d /c ""{0}""' -f (Join-Path $dir 'WinSenior.cmd')
                $p = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -WindowStyle Hidden -PassThru -Wait
            } finally { Remove-Item Env:\WINSENIOR_NOELEVATE -ErrorAction SilentlyContinue }
            $p.ExitCode | Should -Be 0
            $deadline = (Get-Date).AddSeconds(40)
            while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
            Test-Path -LiteralPath $marker | Should -BeTrue
            $got = [IO.File]::ReadAllText($marker)
            # %TEMP% may be an 8.3 short path (CI: C:\Users\RUNNER~1) while cmd reports the
            # long one, so compare from the folder name down.
            $got | Should -BeLike ("*\{0}\WinSenior.Gui.ps1|True" -f (Split-Path $dir -Leaf))
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'WinSenior.ps1 -Gui' {
    BeforeAll { $script:Menu = Get-Content (Join-Path $PSScriptRoot '..\WinSenior.ps1') -Raw }
    It 'exposes a -Gui switch' {
        $script:Menu | Should -Match '\[switch\]\$Gui'
    }
    It 'forwards every bound parameter and keeps the runtime when it elevates' {
        $script:Menu | Should -Match 'PSBoundParameters'
        $script:Menu | Should -Match 'Start-Process -FilePath \(Get-WsHostExe\) -Verb RunAs'
        $script:Menu | Should -Not -Match "Start-Process -FilePath 'powershell\.exe' -Verb RunAs"
    }
}
