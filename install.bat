@echo off
REM ============================================================================
REM  Professional Video Downloader - Windows Installer
REM  Idempotent dependency bootstrap: winget/Chocolatey, yt-dlp, ffmpeg+ffprobe.
REM  Regenerates professional-video-downloader.lnk, then launches the script.
REM  Self-elevates via UAC only when a dependency install requires admin.
REM ============================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "PS1=%SCRIPT_DIR%\professional-video-downloader.ps1"
set "BOOTSTRAP=%SCRIPT_DIR%\install-bootstrap.ps1"
set "PF_ROOT=%ProgramW6432%"
if not defined PF_ROOT set "PF_ROOT=%ProgramFiles%"
set "INSTALL_ROOT=%PF_ROOT%\myTech.Today\professional-video-downloader"
set "SHORTCUT_DIR=%ProgramData%\Microsoft\Windows\Start Menu\Programs\myTech.Today"

echo.
echo ============================================================
echo   Professional Video Downloader - Setup
echo ============================================================
echo.

if not exist "%PS1%" (
    echo [ERROR] professional-video-downloader.ps1 not found next to install.bat.
    echo         Looked for: "%PS1%"
    pause
    exit /b 1
)

if not exist "%BOOTSTRAP%" (
    echo [ERROR] install-bootstrap.ps1 not found next to install.bat.
    echo         Looked for: "%BOOTSTRAP%"
    pause
    exit /b 1
)

set "VERSION_FILE=%SCRIPT_DIR%\VERSION"
if not exist "%VERSION_FILE%" (
    echo [ERROR] VERSION not found next to install.bat.
    echo         Looked for: "%VERSION_FILE%"
    pause
    exit /b 1
)

set "APP_VERSION="
for /f "usebackq tokens=* delims=" %%V in ("%VERSION_FILE%") do (
    if not defined APP_VERSION set "APP_VERSION=%%V"
)
if not defined APP_VERSION (
    echo [ERROR] VERSION file is empty.
    pause
    exit /b 1
)

REM Locate a PowerShell host. Windows ships powershell.exe 5.1; pwsh is preferred if installed.
set "PS_BIN="
where pwsh >nul 2>&1
if %ERRORLEVEL% EQU 0 set "PS_BIN=pwsh"
if not defined PS_BIN (
    where powershell >nul 2>&1
    if %ERRORLEVEL% EQU 0 set "PS_BIN=powershell"
)
if not defined PS_BIN (
    echo [ERROR] No PowerShell host found on PATH.
    echo         Install PowerShell 7+ from https://aka.ms/powershell and retry.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   Professional Video Downloader v%APP_VERSION% - Setup
echo ============================================================
echo.
echo Install root: %INSTALL_ROOT%
echo Start Menu:   %SHORTCUT_DIR%
echo.

REM Run the bootstrap (dependency check/install + .lnk refresh). Forwards args to the script.
"%PS_BIN%" -NoProfile -ExecutionPolicy Bypass -File "%BOOTSTRAP%" -ScriptDir "%SCRIPT_DIR%" -InstallRoot "%INSTALL_ROOT%" -ShortcutDir "%SHORTCUT_DIR%" %*
set "EC=%ERRORLEVEL%"

if not "%EC%"=="0" (
    echo.
    echo [WARN] Setup exited with code %EC%.
    pause
)

endlocal & exit /b %EC%
