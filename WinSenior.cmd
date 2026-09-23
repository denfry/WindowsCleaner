@echo off
:: ============================================================
::  Windows Senior - one-click launcher
::
::    git clone https://github.com/denfry/WindowsCleaner
::    cd WindowsCleaner
::    WinSenior.cmd            -> desktop app (WPF, nothing to install)
::    WinSenior.cmd console    -> arrow-key console menu instead
::
::  Double-clicking works too. Nothing is downloaded: the GUI uses
::  WPF, which ships with every Windows 10/11. The launcher removes the
::  Mark-of-the-Web from the scripts (zip downloads), asks for
::  Administrator once (UAC) and starts the app without a console.
::
::  The folder may contain spaces, ( ) & ' ! or non-Latin letters: paths are
::  never expanded inside ( ) blocks and reach PowerShell only through
::  environment variables (WS_*), never spliced into the command text.
::  WINSENIOR_NOELEVATE=1 skips the UAC step (automated smoke tests only).
::  Author: denfry  -  https://github.com/denfry/WindowsCleaner
:: ============================================================
setlocal DisableDelayedExpansion
set "WS_ROOT=%~dp0"

:: Prefer PowerShell 7 when installed; Windows PowerShell 5.1 is always there.
set "WS_PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "WS_PS=pwsh.exe"

if /i "%~1"=="console" goto :console
set "WS_TARGET=%WS_ROOT%WinSenior.Gui.ps1"
set "WS_STYLE=Hidden"
goto :check

:console
set "WS_TARGET=%WS_ROOT%WinSenior.ps1"
set "WS_STYLE=Normal"

:check
if exist "%WS_TARGET%" goto :launch
echo [!] "%WS_TARGET%" not found. Run this launcher from the cloned repository folder.
pause
exit /b 1

:launch
"%WS_PS%" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Continue'; Get-ChildItem -LiteralPath $env:WS_ROOT -Include *.ps1,*.cmd,*.bat -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue; $q = [string][char]34; $a = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle',$env:WS_STYLE,'-File',($q + $env:WS_TARGET + $q)); $run = @{ FilePath = $env:WS_PS; WindowStyle = $env:WS_STYLE; ArgumentList = ($a -join ' '); ErrorAction = 'Stop' }; if ($env:WINSENIOR_NOELEVATE) { $run.ArgumentList += ' -NoElevate' } else { $run.Verb = 'RunAs' }; try { Start-Process @run } catch { Write-Host '[!] Administrator rights are required (UAC was cancelled).' -ForegroundColor Red; Start-Sleep 3; exit 1 }"
set "WS_RC=%ERRORLEVEL%"
endlocal & exit /b %WS_RC%
