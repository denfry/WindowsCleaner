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
::  Author: denfry  -  https://github.com/denfry/WindowsCleaner
:: ============================================================
setlocal
set "ROOT=%~dp0"

:: Prefer PowerShell 7 when installed; Windows PowerShell 5.1 is always there.
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"

if /i "%~1"=="console" (
    set "TARGET=%ROOT%WinSenior.ps1"
    set "STYLE=Normal"
) else (
    set "TARGET=%ROOT%WinSenior.Gui.ps1"
    set "STYLE=Hidden"
)

if not exist "%TARGET%" (
    echo [!] %TARGET% not found. Run this launcher from the cloned repository folder.
    pause
    exit /b 1
)

%PS% -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-ChildItem -LiteralPath '%ROOT%' -Include *.ps1,*.cmd,*.bat -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue;" ^
  "try { Start-Process -FilePath '%PS%' -Verb RunAs -WindowStyle %STYLE% -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','%STYLE%','-File','\"%TARGET%\"') }" ^
  "catch { Write-Host '[!] Administrator rights are required (UAC was cancelled).' -ForegroundColor Red; Start-Sleep 3; exit 1 }"

endlocal
