#Requires -Version 5.1
<#
.SYNOPSIS
    Windows dependency bootstrap for Professional Video Downloader.

.DESCRIPTION
    Idempotent detect-then-install of:
      - winget / Chocolatey  (bootstraps Chocolatey if winget is also absent)
      - yt-dlp               (latest stable)
      - ffmpeg + ffprobe
      - Python 3.9+          (only if yt-dlp must be installed via pip fallback)
    Refreshes the user's PATH, verifies each binary with --version, then
    regenerates professional-video-downloader.lnk to point at the in-place .ps1
    and finally launches the downloader, forwarding any user-supplied args.

    Self-elevates via UAC only when a step requires admin (Chocolatey install,
    most winget package installs in machine scope, MSI fallbacks).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptDir,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Forwarded
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Minimum versions (rough guidance; we don't gate on these, just log them).
$MinYtDlpVersion = [version]'2024.01.01'

function Write-Step  { param([string]$m) Write-Host "[STEP] $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Info2 { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Gray }
function Write-Warn2 { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err2  { param([string]$m) Write-Host "[ERR ] $m" -ForegroundColor Red }

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevate {
    # Restarts this script under UAC, forwarding the original parameters.
    param([string[]]$ArgList)
    $argv = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-ScriptDir',$ScriptDir) + $ArgList
    Write-Warn2 'Elevation required for dependency install. Relaunching under UAC...'
    try {
        $proc = Start-Process -FilePath (Get-Command powershell.exe).Source `
                              -ArgumentList $argv -Verb RunAs -PassThru -Wait
        exit $proc.ExitCode
    } catch {
        Write-Err2 "UAC relaunch failed: $($_.Exception.Message)"
        exit 1
    }
}

function Update-SessionPath {
    # Refresh PATH from registry so freshly-installed tools become discoverable
    # without requiring a new shell. Combines Machine + User scopes.
    $m = [Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = (@($m, $u) -ne $null -join ';') -replace ';{2,}', ';'
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-Capture {
    # Runs a command and returns its first line of stdout (trimmed). Never throws.
    param([string]$Exe, [string[]]$ArgList)
    try {
        $out = & $Exe @ArgList 2>$null
        if ($out) { return ($out | Select-Object -First 1).ToString().Trim() }
    } catch { }
    return $null
}

function Get-PackageManager {
    if (Test-Command 'winget') { return 'winget' }
    if (Test-Command 'choco')  { return 'choco' }
    return $null
}

function Install-Chocolatey {
    Write-Step 'Installing Chocolatey (admin required)'
    if (-not (Test-IsAdmin)) { Invoke-SelfElevate -ArgList $Forwarded }
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Update-SessionPath
}

function Install-Package {
    # Try winget first, then chocolatey. Returns $true on success.
    param([string]$WingetId, [string]$ChocoId, [string]$DisplayName)
    $pm = Get-PackageManager
    if (-not $pm) {
        Write-Warn2 "Neither winget nor choco found; bootstrapping Chocolatey to install $DisplayName."
        Install-Chocolatey
        $pm = Get-PackageManager
    }
    if ($pm -eq 'winget') {
        Write-Info2 "winget install --id $WingetId"
        try {
            & winget install --id $WingetId --source winget --silent `
                --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
                ForEach-Object { Write-Host "  $_" }
            Update-SessionPath
            return $true
        } catch {
            Write-Warn2 "winget failed for ${DisplayName}: $($_.Exception.Message)"
        }
    }
    if ((Get-PackageManager) -eq 'choco') {
        Write-Info2 "choco install $ChocoId -y"
        if (-not (Test-IsAdmin)) { Invoke-SelfElevate -ArgList $Forwarded }
        try {
            & choco install $ChocoId -y --no-progress 2>&1 |
                ForEach-Object { Write-Host "  $_" }
            Update-SessionPath
            return $true
        } catch {
            Write-Warn2 "choco failed for ${DisplayName}: $($_.Exception.Message)"
        }
    }
    return $false
}

function Ensure-YtDlp {
    Write-Step 'Checking yt-dlp'
    if (Test-Command 'yt-dlp') {
        $v = Invoke-Capture 'yt-dlp' @('--version')
        if (-not $v) { $v = 'unknown' }
        Write-Ok ("yt-dlp already installed: {0}" -f $v)
        return
    }
    Write-Info2 'yt-dlp not found; installing...'
    if (Install-Package -WingetId 'yt-dlp.yt-dlp' -ChocoId 'yt-dlp' -DisplayName 'yt-dlp') {
        Update-SessionPath
        if (Test-Command 'yt-dlp') {
            Write-Ok ("yt-dlp installed: {0}" -f (Invoke-Capture 'yt-dlp' @('--version')))
            return
        }
    }
    # pip fallback (requires Python 3.9+).
    Ensure-Python
    if (Test-Command 'pip') {
        Write-Info2 'Falling back to pip install --user yt-dlp'
        & pip install --user --upgrade yt-dlp 2>&1 | ForEach-Object { Write-Host "  $_" }
        Update-SessionPath
    }
    if (-not (Test-Command 'yt-dlp')) {
        throw 'yt-dlp installation failed via every method.'
    }
    Write-Ok ("yt-dlp installed (pip): {0}" -f (Invoke-Capture 'yt-dlp' @('--version')))
}

function Ensure-Ffmpeg {
    Write-Step 'Checking ffmpeg + ffprobe'
    $haveFfmpeg  = Test-Command 'ffmpeg'
    $haveFfprobe = Test-Command 'ffprobe'
    if ($haveFfmpeg -and $haveFfprobe) {
        $v = Invoke-Capture 'ffmpeg' @('-version')
        Write-Ok ("ffmpeg already installed: {0}" -f $v)
        return
    }
    Write-Info2 'ffmpeg/ffprobe not found; installing ffmpeg (ffprobe is bundled)...'
    if (Install-Package -WingetId 'Gyan.FFmpeg' -ChocoId 'ffmpeg' -DisplayName 'ffmpeg') {
        Update-SessionPath
        if ((Test-Command 'ffmpeg') -and (Test-Command 'ffprobe')) {
            Write-Ok ("ffmpeg installed: {0}" -f (Invoke-Capture 'ffmpeg' @('-version')))
            return
        }
    }
    throw 'ffmpeg/ffprobe installation failed.'
}

function Ensure-Python {
    Write-Step 'Checking Python 3.9+ (only needed for yt-dlp pip fallback)'
    if (Test-Command 'python') {
        $pyVer = Invoke-Capture 'python' @('--version')
        if ($pyVer -match '(\d+)\.(\d+)') {
            $maj = [int]$matches[1]; $min = [int]$matches[2]
            if ($maj -gt 3 -or ($maj -eq 3 -and $min -ge 9)) {
                Write-Ok ("Python already installed: {0}" -f $pyVer)
                return
            }
            Write-Warn2 ("Python present but too old: {0}; upgrading..." -f $pyVer)
        }
    }
    if (Install-Package -WingetId 'Python.Python.3.12' -ChocoId 'python' -DisplayName 'Python 3.12') {
        Update-SessionPath
        if (Test-Command 'python') {
            Write-Ok ("Python installed: {0}" -f (Invoke-Capture 'python' @('--version')))
            return
        }
    }
    throw 'Python installation failed.'
}

function Set-DownloaderShortcut {
    # Writes/refreshes professional-video-downloader.lnk next to the .ps1.
    param([Parameter(Mandatory)][string]$LnkPath, [Parameter(Mandatory)][string]$Ps1Path)
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($LnkPath)
    $sc.TargetPath       = (Get-Command powershell.exe).Source
    $sc.Arguments        = '-NoExit -ExecutionPolicy Bypass -File "{0}"' -f $Ps1Path
    $sc.WorkingDirectory = Split-Path -Parent $Ps1Path
    $sc.IconLocation     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
    $sc.Description      = 'Professional Video Downloader'
    $sc.Save()
}

# ====================== MAIN ======================
$ps1  = Join-Path $ScriptDir 'professional-video-downloader.ps1'
$lnk  = Join-Path $ScriptDir 'professional-video-downloader.lnk'

if (-not (Test-Path $ps1)) {
    Write-Err2 "Downloader script not found: $ps1"
    exit 1
}

Write-Host ''
Write-Step "Install root: $ScriptDir"
Write-Host ''

try {
    # If neither package manager is present, try winget first (Windows 10/11 ship it),
    # else fall back to Chocolatey bootstrap.
    if (-not (Get-PackageManager)) {
        Write-Warn2 'Neither winget nor Chocolatey detected. Bootstrapping Chocolatey...'
        Install-Chocolatey
    } else {
        Write-Ok ("Package manager available: {0}" -f (Get-PackageManager))
    }

    Ensure-YtDlp
    Ensure-Ffmpeg

    Write-Step 'Refreshing professional-video-downloader.lnk'
    Set-DownloaderShortcut -LnkPath $lnk -Ps1Path $ps1
    Write-Ok "Shortcut updated: $lnk"

    # Verification summary.
    Write-Host ''
    Write-Step 'Verification'
    foreach ($tool in @('yt-dlp','ffmpeg','ffprobe')) {
        if (Test-Command $tool) {
            $ver = Invoke-Capture $tool @('-version')
            if (-not $ver) { $ver = Invoke-Capture $tool @('--version') }
            Write-Ok ("{0,-9} -> {1}" -f $tool, $ver)
        } else {
            Write-Err2 ("{0,-9} -> NOT FOUND" -f $tool)
        }
    }
}
catch {
    Write-Err2 "Setup failed: $($_.Exception.Message)"
    exit 1
}

Write-Host ''
Write-Step 'Launching Professional Video Downloader'
Write-Host ''

# Forward remaining args to the downloader script.
$forwardArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ps1)
if ($Forwarded) { $forwardArgs += $Forwarded }
$proc = Start-Process -FilePath (Get-Command powershell.exe).Source `
                      -ArgumentList $forwardArgs -WorkingDirectory $ScriptDir `
                      -NoNewWindow -PassThru -Wait
exit $proc.ExitCode
