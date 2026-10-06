#Requires -Version 5.1
<#
.SYNOPSIS
    Windows dependency bootstrap for Professional Video Downloader.

.DESCRIPTION
    Idempotent detect-then-install of:
      - winget / Chocolatey  (bootstraps Chocolatey from a verified MSI if winget is also absent)
      - yt-dlp               (latest stable)
      - ffmpeg + ffprobe
      - Python 3.10+         (only if yt-dlp must be installed via pip fallback)
    Refreshes the user's PATH, verifies each binary with --version, then
    copies the runtime into the machine install root, refreshes the machine-wide
    professional-video-downloader.lnk, and finally launches the installed
    downloader, forwarding any user-supplied args.

    Self-elevates via UAC only when a step requires admin (Chocolatey install,
    most winget package installs in machine scope, MSI fallbacks).
#>

[CmdletBinding()]
param(
    [string]$ScriptDir,
    [string]$InstallRoot,
    [string]$ShortcutDir,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Forwarded
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $ScriptDir) {
    $ScriptDir = $PSScriptRoot
}
if (-not $InstallRoot) {
    $programFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = $env:ProgramFiles
    }
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        throw 'Unable to resolve the Program Files install root.'
    }
    $InstallRoot = Join-Path (Join-Path $programFiles 'myTech.Today') 'professional-video-downloader'
}
if (-not $ShortcutDir) {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw 'Unable to resolve the ProgramData shortcut root.'
    }
    $ShortcutDir = Join-Path (Join-Path (Join-Path (Join-Path $programData 'Microsoft') 'Windows') 'Start Menu') 'Programs'
    $ShortcutDir = Join-Path $ShortcutDir 'myTech.Today'
}

# Latest stable yt-dlp release baseline required by this downloader.
$MinYtDlpVersion = [version]'2026.08.19'
$MinYtDlpVersionText = '2026.08.19'
$ChocolateyBootstrapSourceUrl = 'https://github.com/chocolatey/choco/releases/download/2.7.4/chocolatey-2.7.4.0.msi'
$ChocolateyBootstrapSha256 = 'f39efebdc012525a7057f573f136f63af91a496efddd1db4c7910d657a5ac407'
$ChocolateyBootstrapFileName = 'chocolatey-2.7.4.0.msi'

function Get-ProjectVersion {
    param([Parameter(Mandatory)][string]$RootPath)

    $versionFile = Join-Path $RootPath 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile)) {
        throw "Version file not found: $versionFile"
    }

    $version = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop).Trim()
    if (-not $version) {
        throw "Version file is empty: $versionFile"
    }

    return $version
}

function Get-YtDlpVersionInfo {
    param([Parameter(Mandatory)][string]$VersionText)

    $trimmed = $VersionText.Trim()
    if (-not $trimmed) {
        throw 'Unable to determine yt-dlp version from empty output.'
    }

    $match = [regex]::Match($trimmed, '(?<!\d)(?<core>\d+(?:\.\d+){0,3})(?<suffix>.*)$')
    if (-not $match.Success) {
        throw ("Unable to parse yt-dlp version from '{0}'." -f $trimmed)
    }

    $coreText = $match.Groups['core'].Value
    $suffix   = $match.Groups['suffix'].Value
    try {
        $coreVersion = [version]$coreText
    }
    catch {
        throw ("Unable to parse yt-dlp version from '{0}'." -f $trimmed)
    }

    return [pscustomobject]@{
        Raw      = $trimmed
        CoreText = $coreText
        Version  = $coreVersion
        Suffix   = $suffix
    }
}

function Assert-YtDlpMinimumVersion {
    param(
        [Parameter(Mandatory)][string]$InstalledVersionText,
        [Parameter(Mandatory)][version]$MinimumVersion,
        [string]$MinimumVersionText = $MinYtDlpVersionText
    )

    try {
        $versionInfo = Get-YtDlpVersionInfo -VersionText $InstalledVersionText
    }
    catch {
        throw ("Unable to determine yt-dlp version from '{0}'. Update yt-dlp with the package manager or pip used to install it, or run 'yt-dlp -U' for standalone release binaries, then rerun install.bat." -f $InstalledVersionText)
    }

    if ($versionInfo.Version -lt $MinimumVersion -or ($versionInfo.Version -eq $MinimumVersion -and $versionInfo.Suffix)) {
        throw ("yt-dlp {0} is too old. Minimum required is {1}. Update yt-dlp with the package manager or pip used to install it, or run 'yt-dlp -U' for standalone release binaries, then rerun install.bat." -f $versionInfo.Raw, $MinimumVersionText)
    }

    return $versionInfo
}

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

function ConvertTo-WindowsCommandLine {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    $encodedArguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in $Arguments) {
        if ($null -eq $argument) {
            $argument = ''
        }

        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append([char]'"')
        $backslashCount = 0

        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq [char]'\') {
                $backslashCount++
                continue
            }

            if ($character -eq [char]'"') {
                for ($i = 0; $i -lt (($backslashCount * 2) + 1); $i++) {
                    [void]$builder.Append([char]'\')
                }
                [void]$builder.Append([char]'"')
                $backslashCount = 0
                continue
            }

            for ($i = 0; $i -lt $backslashCount; $i++) {
                [void]$builder.Append([char]'\')
            }
            $backslashCount = 0
            [void]$builder.Append($character)
        }

        for ($i = 0; $i -lt ($backslashCount * 2); $i++) {
            [void]$builder.Append([char]'\')
        }
        [void]$builder.Append([char]'"')
        $encodedArguments.Add($builder.ToString())
    }

    return ($encodedArguments -join ' ')
}

function New-SelfElevationArgumentList {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ScriptDir,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ShortcutDir,
        [string[]]$Forwarded
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $ScriptPath,
        '-ScriptDir',
        $ScriptDir,
        '-InstallRoot',
        $InstallRoot,
        '-ShortcutDir',
        $ShortcutDir
    )
    if ($Forwarded) {
        $arguments += $Forwarded
    }
    return ,$arguments
}

function Invoke-SelfElevate {
    # Restarts this script under UAC, forwarding the original parameters.
    param([string[]]$ArgList)
    $elevationArguments = @{
        ScriptPath = $PSCommandPath
        ScriptDir = $ScriptDir
        InstallRoot = $InstallRoot
        ShortcutDir = $ShortcutDir
        Forwarded = $ArgList
    }
    $argv = New-SelfElevationArgumentList @elevationArguments
    $encodedArguments = ConvertTo-WindowsCommandLine -Arguments $argv
    Write-Warn2 'Elevation required for dependency install. Relaunching under UAC...'
    try {
        $proc = Start-Process -FilePath (Get-PowerShellHostExecutable) `
                              -ArgumentList $encodedArguments -Verb RunAs -PassThru -Wait
        exit $proc.ExitCode
    } catch {
        Write-Err2 'UAC relaunch failed. Setup cannot continue.'
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

function Get-PipModuleRunner {
    foreach ($runner in @('python', 'py')) {
        if (-not (Test-Command $runner)) {
            continue
        }

        $pipVersion = Invoke-Capture $runner @('-m', 'pip', '--version')
        if ($LASTEXITCODE -eq 0 -and $pipVersion) {
            return [pscustomobject]@{
                Runner     = $runner
                PipVersion = $pipVersion
            }
        }
    }

    return $null
}

function Get-PackageManager {
    if (Test-Command 'winget') { return 'winget' }
    if (Test-Command 'choco')  { return 'choco' }
    return $null
}

function Get-DefaultInstallRoot {
    $programFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = $env:ProgramFiles
    }
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        throw 'Unable to resolve the Program Files install root.'
    }

    $installRoot = Join-Path $programFiles 'myTech.Today'
    return (Join-Path $installRoot 'professional-video-downloader')
}

function Get-DefaultShortcutDir {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw 'Unable to resolve the ProgramData shortcut root.'
    }

    $shortcutDir = Join-Path $programData 'Microsoft'
    $shortcutDir = Join-Path $shortcutDir 'Windows'
    $shortcutDir = Join-Path $shortcutDir 'Start Menu'
    $shortcutDir = Join-Path $shortcutDir 'Programs'
    return (Join-Path $shortcutDir 'myTech.Today')
}

function Install-Chocolatey {
    Write-Step 'Installing Chocolatey from verified MSI (admin required)'
    if (-not (Test-IsAdmin)) { Invoke-SelfElevate -ArgList $Forwarded }
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

    $bootstrapMsiPath = Join-Path ([System.IO.Path]::GetTempPath()) $ChocolateyBootstrapFileName
    try {
        Write-Info2 "Chocolatey bootstrap source: $ChocolateyBootstrapSourceUrl"
        Write-Info2 "Expected SHA256: $ChocolateyBootstrapSha256"
        Write-Info2 "Downloading Chocolatey MSI to $bootstrapMsiPath"

        try {
            Invoke-WebRequest -Uri $ChocolateyBootstrapSourceUrl -OutFile $bootstrapMsiPath -ErrorAction Stop
        }
        catch {
            throw ("Chocolatey bootstrap download failed from {0}: {1}. Download the official Chocolatey MSI manually and rerun install.bat." -f $ChocolateyBootstrapSourceUrl, $_.Exception.Message)
        }

        if (-not (Test-Path -LiteralPath $bootstrapMsiPath)) {
            throw "Chocolatey bootstrap download failed to create a file: $bootstrapMsiPath"
        }

        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $bootstrapMsiPath -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -ne $ChocolateyBootstrapSha256) {
            throw ("Chocolatey bootstrap verification failed for {0}. Expected SHA256 {1} but got {2}. Download the official Chocolatey MSI manually and rerun install.bat." -f $ChocolateyBootstrapSourceUrl, $ChocolateyBootstrapSha256, $actualHash)
        }

        Write-Ok "Chocolatey MSI verified: $actualHash"

        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $bootstrapMsiPath, '/qn', '/norestart') -PassThru -Wait
        if ($proc.ExitCode -notin 0, 3010, 1641) {
            throw "Chocolatey MSI installation failed with exit code $($proc.ExitCode)."
        }

        Update-SessionPath
        if (-not (Test-Command 'choco')) {
            throw 'Chocolatey installed successfully but choco is not yet available in this shell. Open a new elevated PowerShell session or reboot, then rerun install.bat.'
        }

        Write-Ok 'Chocolatey installed and PATH refreshed.'
    }
    finally {
        if (Test-Path -LiteralPath $bootstrapMsiPath) {
            Remove-Item -LiteralPath $bootstrapMsiPath -Force -ErrorAction SilentlyContinue
        }
    }
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
        $versionInfo = Assert-YtDlpMinimumVersion -InstalledVersionText $v -MinimumVersion $MinYtDlpVersion
        Write-Ok ("yt-dlp already installed: {0}" -f $versionInfo.Raw)
        return
    }
    Write-Info2 'yt-dlp not found; installing...'
    if (Install-Package -WingetId 'yt-dlp.yt-dlp' -ChocoId 'yt-dlp' -DisplayName 'yt-dlp') {
        Update-SessionPath
        if (Test-Command 'yt-dlp') {
            $v = Invoke-Capture 'yt-dlp' @('--version')
            if (-not $v) { $v = 'unknown' }
            $versionInfo = Assert-YtDlpMinimumVersion -InstalledVersionText $v -MinimumVersion $MinYtDlpVersion
            Write-Ok ("yt-dlp installed: {0}" -f $versionInfo.Raw)
            return
        }
    }
    # pip fallback (requires Python 3.10+).
    $pipRunner = Ensure-Python
    if (-not $pipRunner) {
        throw 'Python installation failed.'
    }
    Write-Info2 ("Falling back to {0} -m pip install --user --upgrade yt-dlp" -f $pipRunner.Runner)
    & $pipRunner.Runner -m pip install --user --upgrade yt-dlp 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} -m pip install failed with exit code {1}." -f $pipRunner.Runner, $LASTEXITCODE)
    }
    Update-SessionPath
    if (-not (Test-Command 'yt-dlp')) {
        throw ("yt-dlp installation failed via {0} -m pip." -f $pipRunner.Runner)
    }
    $v = Invoke-Capture 'yt-dlp' @('--version')
    if (-not $v) { $v = 'unknown' }
    $versionInfo = Assert-YtDlpMinimumVersion -InstalledVersionText $v -MinimumVersion $MinYtDlpVersion
    Write-Ok ("yt-dlp installed via {0} -m pip: {1}" -f $pipRunner.Runner, $versionInfo.Raw)
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
    Write-Step 'Checking Python 3.10+ (only needed for yt-dlp pip fallback)'
    if (Test-Command 'python') {
        $pyVer = Invoke-Capture 'python' @('--version')
        if ($pyVer -match '(\d+)\.(\d+)') {
            $maj = [int]$matches[1]; $min = [int]$matches[2]
            if ($maj -gt 3 -or ($maj -eq 3 -and $min -ge 10)) {
                $pipRunner = Get-PipModuleRunner
                if (-not $pipRunner) {
                    throw 'Python is installed, but neither python -m pip nor py -m pip is available. Repair Python, then rerun install.bat.'
                }
                Write-Ok ("Python already installed: {0}" -f $pyVer)
                Write-Ok ("Python module runner verified: {0} -m pip ({1})" -f $pipRunner.Runner, $pipRunner.PipVersion)
                return $pipRunner
            }
            Write-Warn2 ("Python present but too old: {0}; upgrading..." -f $pyVer)
        }
    }
    if (Install-Package -WingetId 'Python.Python.3.12' -ChocoId 'python' -DisplayName 'Python 3.12') {
        Update-SessionPath
        $pipRunner = Get-PipModuleRunner
        if ($pipRunner) {
            $pyVer = Invoke-Capture $pipRunner.Runner @('--version')
            if ($pyVer) {
                Write-Ok ("Python installed: {0}" -f $pyVer)
                Write-Ok ("Python module runner verified: {0} -m pip ({1})" -f $pipRunner.Runner, $pipRunner.PipVersion)
                return $pipRunner
            }
        }
        throw 'Python installation succeeded, but neither python -m pip nor py -m pip is available. Repair Python, then rerun install.bat.'
    }
    throw 'Python installation failed.'
}

function Get-PowerShellHostExecutable {
    param(
        [ValidateSet('Core', 'Desktop')]
        [string]$Edition = $PSVersionTable.PSEdition,
        [string]$PsHomePath = $PSHOME
    )

    $exeName = if ($Edition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $candidate = Join-Path $PsHomePath $exeName
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    throw ("PowerShell host executable not found: {0}" -f $candidate)
}

function Set-DownloaderShortcut {
    # Writes/refreshes professional-video-downloader.lnk at the machine-wide Start Menu path.
    param(
        [Parameter(Mandatory)][string]$LnkPath,
        [Parameter(Mandatory)][string]$Ps1Path,
        [Parameter()][string]$HostExecutablePath = (Get-PowerShellHostExecutable),
        [Parameter()][string]$WorkingDirectory = (Split-Path -Parent $Ps1Path)
    )
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($LnkPath)
    $sc.TargetPath       = $HostExecutablePath
    $sc.Arguments        = '-NoExit -ExecutionPolicy Bypass -File "{0}"' -f $Ps1Path
    $sc.WorkingDirectory = $WorkingDirectory
    $sc.IconLocation     = "$HostExecutablePath,0"
    $sc.Description      = 'Professional Video Downloader'
    $sc.Save()
}

function Install-RuntimeFiles {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $sourcePs1 = Join-Path $SourceDir 'professional-video-downloader.ps1'
    $sourceVersion = Join-Path $SourceDir 'VERSION'
    if (-not (Test-Path -LiteralPath $sourcePs1)) {
        throw "Downloader script not found: $sourcePs1"
    }
    if (-not (Test-Path -LiteralPath $sourceVersion)) {
        throw "VERSION file not found: $sourceVersion"
    }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourcePs1 -Destination $InstallRoot -Force -ErrorAction Stop
    Copy-Item -LiteralPath $sourceVersion -Destination $InstallRoot -Force -ErrorAction Stop
    return (Join-Path $InstallRoot 'professional-video-downloader.ps1')
}

function Invoke-Installer {
    param(
        [string]$SourceDir = $ScriptDir,
        [string]$InstallRoot = $script:InstallRoot,
        [string]$ShortcutDir = $script:ShortcutDir,
        [string[]]$Forwarded
    )

    $installedPs1 = Join-Path $InstallRoot 'professional-video-downloader.ps1'
    $shortcutPath = Join-Path $ShortcutDir 'professional-video-downloader.lnk'

    $Version = Get-ProjectVersion -RootPath $SourceDir

    Write-Host ''
    Write-Step ("Professional Video Downloader v{0} - Setup" -f $Version)
    Write-Step "Source root: $SourceDir"
    Write-Step "Install root: $InstallRoot"
    Write-Host ''

    try {
        if (-not (Test-IsAdmin)) {
            Invoke-SelfElevate -ArgList $Forwarded
        }

        Write-Step 'Creating machine-wide install layout'
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $ShortcutDir -Force | Out-Null

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

        Write-Step 'Copying runtime files'
        $installedPs1 = Install-RuntimeFiles -SourceDir $SourceDir -InstallRoot $InstallRoot
        Write-Ok "Runtime files installed: $InstallRoot"

        Write-Step 'Refreshing professional-video-downloader.lnk'
        Set-DownloaderShortcut -LnkPath $shortcutPath -Ps1Path $installedPs1 -WorkingDirectory $InstallRoot
        Write-Ok "Shortcut updated: $shortcutPath"

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
        return 1
    }

    Write-Host ''
    Write-Step 'Launching Professional Video Downloader'
    Write-Host ''

    # Forward remaining args to the installed downloader script.
    $forwardArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installedPs1)
    if ($Forwarded) { $forwardArgs += $Forwarded }
    $encodedArguments = ConvertTo-WindowsCommandLine -Arguments $forwardArgs
    try {
        $hostExecutable = Get-PowerShellHostExecutable
        $launchParameters = @{
            FilePath = $hostExecutable
            ArgumentList = $encodedArguments
            WorkingDirectory = $InstallRoot
            NoNewWindow = $true
            PassThru = $true
            Wait = $true
        }
        $proc = Start-Process @launchParameters
        return $proc.ExitCode
    }
    catch {
        Write-Err2 'Setup completed, but the downloader could not be launched. Open the installed shortcut or rerun setup with the same options.'
        return 1
    }
}

# ====================== MAIN ======================
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Installer -SourceDir $ScriptDir -InstallRoot $InstallRoot -ShortcutDir $ShortcutDir -Forwarded $Forwarded)
}
