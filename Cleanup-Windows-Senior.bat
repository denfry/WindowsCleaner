@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  Windows System Cleanup Script (Batch Version)
::  Version: 6.0  - mirrors the PowerShell engine's defaults
::  - per-profile helper (cleans every user profile)
::  - independent per-browser flags
::  - safe targets: dev / messenger / shader / font caches
::  - Dangerous tier (event logs, patch cache, Windows.old) behind /IncludeDangerous
::  - all local disks; optional real restore point via /RestorePoint
::  Author: denfry  -  https://github.com/denfry/WindowsCleaner
:: ============================================================

set "SCRIPT_VERSION=6.0"
set "SCRIPT_NAME=Cleanup-Windows-Senior.bat"

:: ---------- defaults (aggressive, matching the PS engine) ----------
set "ALL_USERS=1"
set "DRY_RUN=0"
set "INCLUDE_DANGEROUS=0"
set "RESTORE_POINT=0"
set "SKIP_OPTIMIZATION=0"

set "CLEAN_CHROME=1"
set "CLEAN_EDGE=1"
set "CLEAN_FIREFOX=1"
set "CLEAN_OPERA=1"
set "CLEAN_YANDEX=1"
set "CLEAN_BRAVE=1"

set "CLEAN_TEMP=1"
set "CLEAN_THUMBNAILS=1"
set "CLEAN_PREFETCH=1"
set "CLEAN_SHADERCACHE=1"
set "CLEAN_FONTCACHE=1"
set "CLEAN_DEVCACHE=1"
set "CLEAN_MESSENGERS=1"
set "CLEAN_APPCACHE=1"

set "CLEAN_RECYCLE_BIN=1"
set "CLEAN_WER=1"
set "CLEAN_CRASH_DUMPS=1"
set "CLEAN_IIS_LOGS=1"
set "CLEAN_WINLOGS=1"
set "CLEAN_DELIVERY_OPT=1"

set "CLEAN_WU=1"
set "RUN_SFC=1"
set "OPTIMIZE_COMPONENTS=1"
set "CLEAN_DISKS=1"

set "LOG_PATH=%TEMP%\WindowsCleanup.log"

:: ---------------------- parse arguments ----------------------
:PARSE
if "%~1"=="" goto :PARSE_DONE
set "A=%~1"
if /i "!A!"=="/?"               goto :HELP
if /i "!A!"=="/help"            goto :HELP
if /i "!A!"=="/h"               goto :HELP
if /i "!A!"=="/DryRun"          ( set "DRY_RUN=1" & goto :NEXT )
if /i "!A!"=="/dr"              ( set "DRY_RUN=1" & goto :NEXT )
if /i "!A!"=="/CurrentUserOnly" ( set "ALL_USERS=0" & goto :NEXT )
if /i "!A!"=="/cu"              ( set "ALL_USERS=0" & goto :NEXT )
if /i "!A!"=="/IncludeDangerous" ( set "INCLUDE_DANGEROUS=1" & goto :NEXT )
if /i "!A!"=="/RestorePoint"    ( set "RESTORE_POINT=1" & goto :NEXT )
if /i "!A!"=="/rp"              ( set "RESTORE_POINT=1" & goto :NEXT )
if /i "!A!"=="/SkipOptimization" ( set "SKIP_OPTIMIZATION=1" & goto :NEXT )
if /i "!A!"=="/so"             ( set "SKIP_OPTIMIZATION=1" & goto :NEXT )
if /i "!A!"=="/LogPath"        ( set "LOG_PATH=%~2" & shift & goto :NEXT )
if /i "!A!"=="/nch"            ( set "CLEAN_CHROME=0" & goto :NEXT )
if /i "!A!"=="/ned"           ( set "CLEAN_EDGE=0" & goto :NEXT )
if /i "!A!"=="/nff"           ( set "CLEAN_FIREFOX=0" & goto :NEXT )
if /i "!A!"=="/nop"           ( set "CLEAN_OPERA=0" & goto :NEXT )
if /i "!A!"=="/nya"           ( set "CLEAN_YANDEX=0" & goto :NEXT )
if /i "!A!"=="/nbr"           ( set "CLEAN_BRAVE=0" & goto :NEXT )
if /i "!A!"=="/ntmp"          ( set "CLEAN_TEMP=0" & goto :NEXT )
if /i "!A!"=="/npf"           ( set "CLEAN_PREFETCH=0" & goto :NEXT )
if /i "!A!"=="/nrb"           ( set "CLEAN_RECYCLE_BIN=0" & goto :NEXT )
if /i "!A!"=="/nwu"           ( set "CLEAN_WU=0" & goto :NEXT )
if /i "!A!"=="/ndev"          ( set "CLEAN_DEVCACHE=0" & goto :NEXT )
if /i "!A!"=="/nmsg"          ( set "CLEAN_MESSENGERS=0" & goto :NEXT )
if /i "!A!"=="/ndisks"        ( set "CLEAN_DISKS=0" & goto :NEXT )
echo Unknown option: !A!   (use /? for help)
:NEXT
shift
goto :PARSE
:PARSE_DONE

:: ---------------------- admin check ----------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Administrator privileges required. Right-click - Run as administrator.
    exit /b 2
)

echo ========================================
echo   Windows System Cleanup  v%SCRIPT_VERSION%  (Batch)
echo ========================================
if "%DRY_RUN%"=="1" echo [DRY RUN] No changes will be made.
echo [%DATE% %TIME%] [Info] Cleanup started (batch v%SCRIPT_VERSION%, dry=%DRY_RUN%, allusers=%ALL_USERS%)> "%LOG_PATH%"

:: ---------------------- restore point ----------------------
if "%RESTORE_POINT%"=="1" if "%DRY_RUN%"=="0" (
    call :LOG "Creating system restore point..."
    powershell -NoProfile -Command "Enable-ComputerRestore -Drive \"$env:SystemDrive\\\" -EA SilentlyContinue; New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force -EA SilentlyContinue | Out-Null; Checkpoint-Computer -Description 'Before Windows Cleanup' -RestorePointType MODIFY_SETTINGS" >nul 2>&1
    if !errorlevel! equ 0 ( call :LOG_OK "Restore point created" ) else ( call :LOG_WARN "Restore point not created (System Protection may be off)" )
)

:: ---------------------- stop browsers ----------------------
if "%DRY_RUN%"=="0" (
    for %%P in (chrome.exe msedge.exe firefox.exe opera.exe browser.exe brave.exe) do taskkill /F /IM %%P >nul 2>&1
)

:: ====================================================================
::  PER-USER CLEANUP
:: ====================================================================
if "%ALL_USERS%"=="1" (
    for /d %%U in ("%SystemDrive%\Users\*") do (
        if /i not "%%~nxU"=="Public" if /i not "%%~nxU"=="Default" if /i not "%%~nxU"=="All Users" (
            call :CLEAN_PROFILE "%%~fU"
        )
    )
) else (
    call :CLEAN_PROFILE "%USERPROFILE%"
)

:: ====================================================================
::  SYSTEM-WIDE CLEANUP
:: ====================================================================
if "%CLEAN_TEMP%"=="1"          call :WIPE "%WINDIR%\Temp"
if "%CLEAN_PREFETCH%"=="1"      call :WIPE "%WINDIR%\Prefetch"
if "%CLEAN_WINLOGS%"=="1"       call :WIPE "%WINDIR%\Logs"
if "%CLEAN_DELIVERY_OPT%"=="1" (
    call :WIPE "%WINDIR%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization"
    call :WIPE "%ProgramData%\Microsoft\Windows\DeliveryOptimization"
)
if "%CLEAN_WER%"=="1" (
    call :WIPE "%ProgramData%\Microsoft\Windows\WER\ReportQueue"
    call :WIPE "%ProgramData%\Microsoft\Windows\WER\ReportArchive"
)
if "%CLEAN_CRASH_DUMPS%"=="1" (
    call :WIPE "%WINDIR%\Minidump"
    call :DELFILE "%WINDIR%\MEMORY.DMP"
)
if "%CLEAN_FONTCACHE%"=="1" (
    net stop FontCache >nul 2>&1
    call :WIPE "%WINDIR%\ServiceProfiles\LocalService\AppData\Local\FontCache"
    net start FontCache >nul 2>&1
)
if "%CLEAN_IIS_LOGS%"=="1" if exist "%WINDIR%\System32\LogFiles" (
    for /d %%D in ("%WINDIR%\System32\LogFiles\W3SVC*") do call :WIPE "%%D"
)

:: ---------------------- Windows Update cache ----------------------
if "%CLEAN_WU%"=="1" (
    call :LOG "Cleaning Windows Update cache..."
    if "%DRY_RUN%"=="1" (
        call :LOG "[DRY] would stop wuauserv/bits/cryptsvc and wipe SoftwareDistribution + catroot2"
    ) else (
        net stop wuauserv >nul 2>&1
        net stop bits >nul 2>&1
        net stop cryptsvc >nul 2>&1
        call :WIPE "%WINDIR%\SoftwareDistribution"
        call :WIPE "%WINDIR%\System32\catroot2"
        net start cryptsvc >nul 2>&1
        net start bits >nul 2>&1
        net start wuauserv >nul 2>&1
    )
)

:: ---------------------- optimization (slow) ----------------------
if "%SKIP_OPTIMIZATION%"=="0" (
    if "%OPTIMIZE_COMPONENTS%"=="1" (
        call :LOG "DISM component cleanup..."
        if "%DRY_RUN%"=="1" (
            call :LOG "[DRY] would run DISM /StartComponentCleanup and /SPSuperseded"
        ) else (
            Dism.exe /online /Cleanup-Image /StartComponentCleanup /Quiet >nul 2>&1
            Dism.exe /online /Cleanup-Image /SPSuperseded >nul 2>&1
            call :WIPE "%WINDIR%\Logs\DISM"
            call :LOG_OK "Component store optimized"
        )
    )
    if "%RUN_SFC%"=="1" (
        if "%DRY_RUN%"=="1" ( call :LOG "[DRY] would run sfc /scannow" ) else ( call :LOG "Running sfc /scannow..." & sfc /scannow >nul 2>&1 & call :LOG_OK "SFC complete" )
    )
)

:: ---------------------- all local disks ----------------------
if "%CLEAN_DISKS%"=="1" (
    call :LOG "Cleaning drive-level junk on all local disks..."
    for /f "usebackq tokens=1" %%d in (`powershell -NoProfile -Command "(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3').DeviceID"`) do (
        call :WIPE "%%d\Temp"
        call :WIPE "%%d\tmp"
        for /d %%g in ("%%d\FOUND.*") do call :WIPE "%%g"
    )
)

:: ====================================================================
::  DANGEROUS TIER (only with /IncludeDangerous)
:: ====================================================================
if "%INCLUDE_DANGEROUS%"=="1" (
    call :LOG_WARN "Dangerous tier enabled (event logs / patch cache / Windows.old)"

    for %%L in ("Application" "System" "Setup") do (
        if "%DRY_RUN%"=="1" ( call :LOG "[DRY] would clear %%L event log" ) else ( wevtutil clear-log %%~L >nul 2>&1 )
    )
    if "%DRY_RUN%"=="0" call :LOG_OK "Event logs cleared"

    call :WIPE "%WINDIR%\Installer\$PatchCache$"

    for %%W in ("%SystemDrive%\Windows.old" "%SystemDrive%\$Windows.~BT" "%SystemDrive%\$Windows.~WS" "%WINDIR%\Downloaded Program Files") do (
        if exist "%%~W" (
            if "%DRY_RUN%"=="1" (
                call :LOG "[DRY] would remove %%~W"
            ) else (
                takeown /F "%%~W" /R /D Y >nul 2>&1
                icacls "%%~W" /grant *S-1-5-32-544:F /T /C >nul 2>&1
                rd /s /q "%%~W" >nul 2>&1
                call :LOG_OK "Removed %%~W"
            )
        )
    )
)

:: ---------------------- recycle bin ----------------------
if "%CLEAN_RECYCLE_BIN%"=="1" (
    if "%DRY_RUN%"=="1" ( call :LOG "[DRY] would empty Recycle Bin" ) else ( powershell -NoProfile -Command "Clear-RecycleBin -Force -ErrorAction SilentlyContinue" >nul 2>&1 & call :LOG_OK "Recycle Bin emptied" )
)

echo.
echo ========================================
if "%DRY_RUN%"=="1" ( echo   DRY RUN COMPLETE - nothing changed ) else ( echo   CLEANUP COMPLETE )
echo   Log: %LOG_PATH%
echo ========================================
echo [%DATE% %TIME%] [Success] Cleanup finished >> "%LOG_PATH%"
goto :EOF

:: ====================================================================
::  SUBROUTINE: clean one user profile  ( %~1 = profile root )
:: ====================================================================
:CLEAN_PROFILE
set "U=%~1"
call :LOG "Profile: %U%"

if "%CLEAN_TEMP%"=="1" (
    call :WIPE "%U%\AppData\Local\Temp"
    call :WIPE "%U%\AppData\Local\Microsoft\Windows\INetCache"
    call :WIPE "%U%\AppData\Local\Microsoft\Windows\Temporary Internet Files"
)
if "%CLEAN_THUMBNAILS%"=="1" (
    if "%DRY_RUN%"=="0" del /q /f "%U%\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db" >nul 2>&1
    if "%DRY_RUN%"=="0" del /q /f "%U%\AppData\Local\Microsoft\Windows\Explorer\iconcache_*.db" >nul 2>&1
)
if "%CLEAN_SHADERCACHE%"=="1" (
    call :WIPE "%U%\AppData\Local\D3DSCache"
    call :WIPE "%U%\AppData\Local\NVIDIA\DXCache"
    call :WIPE "%U%\AppData\Local\NVIDIA\GLCache"
)
if "%CLEAN_WER%"=="1"      call :WIPE "%U%\AppData\Local\Microsoft\Windows\WER"
if "%CLEAN_CRASH_DUMPS%"=="1" call :WIPE "%U%\AppData\Local\CrashDumps"
if "%CLEAN_APPCACHE%"=="1" (
    call :WIPE "%U%\AppData\Local\Microsoft\Windows\AppCache"
    call :WIPE "%U%\AppData\Local\ConnectedDevicesPlatform"
)

:: chromium-family browsers (per browser-profile cache dirs)
if "%CLEAN_CHROME%"=="1"  call :CHROMIUM "%U%\AppData\Local\Google\Chrome\User Data"
if "%CLEAN_EDGE%"=="1"    call :CHROMIUM "%U%\AppData\Local\Microsoft\Edge\User Data"
if "%CLEAN_YANDEX%"=="1"  call :CHROMIUM "%U%\AppData\Local\Yandex\YandexBrowser\User Data"
if "%CLEAN_BRAVE%"=="1"   call :CHROMIUM "%U%\AppData\Local\BraveSoftware\Brave-Browser\User Data"
if "%CLEAN_OPERA%"=="1" (
    call :WIPE "%U%\AppData\Roaming\Opera Software\Opera Stable\Cache"
    call :WIPE "%U%\AppData\Roaming\Opera Software\Opera Stable\GPUCache"
)
if "%CLEAN_FIREFOX%"=="1" if exist "%U%\AppData\Local\Mozilla\Firefox\Profiles" (
    for /d %%D in ("%U%\AppData\Local\Mozilla\Firefox\Profiles\*") do (
        call :WIPE "%%D\cache2"
        call :WIPE "%%D\startupCache"
    )
)

:: developer tool caches
if "%CLEAN_DEVCACHE%"=="1" (
    call :WIPE "%U%\AppData\Local\npm-cache"
    call :WIPE "%U%\AppData\Local\pip\Cache"
    call :WIPE "%U%\AppData\Local\Yarn\Cache"
    call :WIPE "%U%\AppData\Local\NuGet\v3-cache"
    call :WIPE "%U%\AppData\Roaming\Code\Cache"
    call :WIPE "%U%\AppData\Roaming\Code\CachedData"
    call :WIPE "%U%\.gradle\caches"
)

:: messenger / media caches
if "%CLEAN_MESSENGERS%"=="1" (
    call :WIPE "%U%\AppData\Roaming\Microsoft\Teams\Cache"
    call :WIPE "%U%\AppData\Roaming\Microsoft\Teams\GPUCache"
    call :WIPE "%U%\AppData\Roaming\discord\Cache"
    call :WIPE "%U%\AppData\Roaming\discord\GPUCache"
    call :WIPE "%U%\AppData\Roaming\Slack\Cache"
    call :WIPE "%U%\AppData\Local\Spotify\Storage"
)
goto :EOF

:: ----- empty all cache dirs under a chromium "User Data" folder -----
:CHROMIUM
set "UD=%~1"
if not exist "%UD%" goto :EOF
for /d %%P in ("%UD%\*") do (
    call :WIPE "%%P\Cache"
    call :WIPE "%%P\Code Cache"
    call :WIPE "%%P\GPUCache"
    call :WIPE "%%P\Service Worker\CacheStorage"
)
goto :EOF

:: ====================================================================
::  HELPERS
:: ====================================================================
:WIPE
set "TGT=%~1"
if not exist "%TGT%" goto :EOF
if "%DRY_RUN%"=="1" ( call :LOG "[DRY] would wipe: %TGT%" & goto :EOF )
del /q /f /s "%TGT%\*" >nul 2>&1
for /d %%d in ("%TGT%\*") do rd /s /q "%%d" >nul 2>&1
call :LOG_OK "wiped: %TGT%"
goto :EOF

:DELFILE
set "TGT=%~1"
if not exist "%TGT%" goto :EOF
if "%DRY_RUN%"=="1" ( call :LOG "[DRY] would delete: %TGT%" & goto :EOF )
del /q /f "%TGT%" >nul 2>&1
call :LOG_OK "deleted: %TGT%"
goto :EOF

:LOG
echo [i] %~1
echo [%DATE% %TIME%] [Info] %~1 >> "%LOG_PATH%"
goto :EOF
:LOG_OK
echo [+] %~1
echo [%DATE% %TIME%] [Success] %~1 >> "%LOG_PATH%"
goto :EOF
:LOG_WARN
echo [!] %~1
echo [%DATE% %TIME%] [Warning] %~1 >> "%LOG_PATH%"
goto :EOF

:: ====================================================================
::  HELP
:: ====================================================================
:HELP
echo.
echo %SCRIPT_NAME%  v%SCRIPT_VERSION%
echo.
echo USAGE: %SCRIPT_NAME% [options]
echo.
echo   /DryRun, /dr          Preview only, change nothing
echo   /CurrentUserOnly, /cu Clean only current profile (default: all users)
echo   /IncludeDangerous     Also clear event logs, patch cache, Windows.old
echo   /RestorePoint, /rp    Create a real restore point first (off by default here)
echo   /SkipOptimization,/so Skip the slow SFC/DISM steps
echo   /LogPath ^<path^>       Log file location
echo.
echo   Disable a target: /nch /ned /nff /nop /nya /nbr  (browsers)
echo                     /ntmp /npf /nrb /nwu /ndev /nmsg /ndisks
echo.
echo   /ndisks disables drive-level cleanup of all local disks (C:, D:, ...)
echo.
echo NOTE: requires Administrator. The PowerShell version
echo       (Cleanup-Windows-Senior.ps1) has more control and real -WhatIf.
goto :EOF
