[CmdletBinding()]
param(
    [string]$RootPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $RootPath) {
    if (-not $PSCommandPath) {
        throw 'Unable to resolve the test script path.'
    }

    $RootPath = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

function Write-Step {
    param([string]$Message)
    Write-Host "[TEST] $Message" -ForegroundColor Cyan
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-FileText {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing file: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
}

function New-TestWorkspace {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-install-sh-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestWorkspace {
    param([Parameter(Mandatory)][string]$Path)

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-ScenarioInstallRoot {
    param([Parameter(Mandatory)][string]$Path)

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-GitBashSh {
    $path = 'C:\Program Files\Git\usr\bin\sh.exe'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Git Bash sh.exe not found: $path"
    }

    return $path
}

function Convert-ToGitBashPath {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $resolved = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
    }
    else {
        $resolved = [System.IO.Path]::GetFullPath($Path)
    }
    $resolved = $resolved -replace '\\', '/'
    if ($resolved -match '^(?<drive>[A-Za-z]):/(?<rest>.*)$') {
        return ('/{0}/{1}' -f $matches.drive.ToLowerInvariant(), $matches.rest)
    }

    return $resolved
}

function Quote-ShellLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return "'" + ($Value -replace "'", "'""'""'") + "'"
}

function Write-ShellShimSet {
    param([Parameter(Mandatory)][string]$BinDir)

    $shim = @'
#!/usr/bin/env sh
set -eu

cmd="$(basename -- "$0")"

log_call() {
    if [ -n "${PVD_CALL_LOG:-}" ]; then
        printf '%s %s\n' "$cmd" "$*" >> "${PVD_CALL_LOG}"
    fi
}

write_ytdlp_shim() {
    cat > "${PVD_BIN_DIR}/yt-dlp" <<'EOF'
#!/usr/bin/env sh
set -eu
case "${1:-}" in
    --version)
        printf '%s\n' "${PVD_YTDLP_VERSION:-yt-dlp 2026.08.19}"
        ;;
    *)
        printf '%s\n' "${PVD_YTDLP_VERSION:-yt-dlp 2026.08.19}"
        ;;
esac
exit 0
EOF
    chmod +x "${PVD_BIN_DIR}/yt-dlp"
}

write_ffmpeg_shims() {
    cat > "${PVD_BIN_DIR}/ffmpeg" <<'EOF'
#!/usr/bin/env sh
set -eu
case "${1:-}" in
    --version|-version)
        printf '%s\n' "${PVD_FFMPEG_VERSION:-ffmpeg version 7.1}"
        ;;
    *)
        printf '%s\n' "${PVD_FFMPEG_VERSION:-ffmpeg version 7.1}"
        ;;
esac
exit 0
EOF

    cat > "${PVD_BIN_DIR}/ffprobe" <<'EOF'
#!/usr/bin/env sh
set -eu
case "${1:-}" in
    --version|-version)
        printf '%s\n' "${PVD_FFPROBE_VERSION:-ffprobe version 7.1}"
        ;;
    *)
        printf '%s\n' "${PVD_FFPROBE_VERSION:-ffprobe version 7.1}"
        ;;
esac
exit 0
EOF

    chmod +x "${PVD_BIN_DIR}/ffmpeg" "${PVD_BIN_DIR}/ffprobe"
}

case "$cmd" in
    uname)
        log_call "$@"
        printf '%s\n' "${PVD_UNAME:-Linux}"
        exit 0
        ;;
    id)
        log_call "$@"
        printf '%s\n' "${PVD_UID:-0}"
        exit 0
        ;;
    sudo)
        log_call "$@"
        printf '%s\n' 'sudo is not available in the test harness.'
        exit 127
        ;;
    pwsh)
        log_call "$@"
        if [ "${2:-}" = "-Command" ]; then
            printf '%s\n' "${PVD_PWSH_VERSION:-7.4.0}"
            exit 0
        fi
        if [ "${2:-}" = "-ExecutionPolicy" ] && [ "${4:-}" = "-File" ]; then
            exit 0
        fi
        printf '%s\n' "${PVD_PWSH_VERSION:-7.4.0}"
        exit 0
        ;;
    apt-get)
        log_call "$@"
        case "${1:-}" in
            update)
                exit "${PVD_APT_UPDATE_EXIT:-0}"
                ;;
            install)
                pkg="${3:-}"
                case "${pkg}" in
                    yt-dlp)
                        if [ "${PVD_APT_CREATE_YTDLP:-1}" = "1" ]; then
                            write_ytdlp_shim
                        fi
                        exit "${PVD_APT_YTDLP_EXIT:-0}"
                        ;;
                    ffmpeg)
                        if [ "${PVD_APT_CREATE_FFMPEG:-1}" = "1" ]; then
                            write_ffmpeg_shims
                        fi
                        exit "${PVD_APT_FFMPEG_EXIT:-0}"
                        ;;
                    powershell)
                        exit "${PVD_APT_PWSH_EXIT:-0}"
                        ;;
                esac
                exit 0
                ;;
        esac
        exit 0
        ;;
    brew)
        log_call "$@"
        case "${1:-}" in
            update)
                exit "${PVD_BREW_UPDATE_EXIT:-0}"
                ;;
            install)
                if [ "${2:-}" = "--cask" ] && [ "${3:-}" = "powershell" ]; then
                    exit "${PVD_BREW_CASK_PWSH_EXIT:-0}"
                fi

                pkg="${2:-}"
                case "${pkg}" in
                    yt-dlp)
                        if [ "${PVD_BREW_CREATE_YTDLP:-1}" = "1" ]; then
                            write_ytdlp_shim
                        fi
                        exit "${PVD_BREW_YTDLP_EXIT:-0}"
                        ;;
                    ffmpeg)
                        if [ "${PVD_BREW_CREATE_FFMPEG:-1}" = "1" ]; then
                            write_ffmpeg_shims
                        fi
                        exit "${PVD_BREW_FFMPEG_EXIT:-0}"
                        ;;
                    powershell)
                        exit "${PVD_BREW_PWSH_EXIT:-0}"
                        ;;
                esac
                exit 0
                ;;
        esac
        exit 0
        ;;
    pip3)
        log_call "$@"
        case "${1:-}" in
            install)
                if [ "${2:-}" = "--user" ] && [ "${3:-}" = "--upgrade" ] && [ "${4:-}" = "yt-dlp" ]; then
                    if [ "${PVD_PIP3_CREATE_YTDLP:-1}" = "1" ]; then
                        write_ytdlp_shim
                    fi
                    exit "${PVD_PIP3_INSTALL_EXIT:-0}"
                fi
                ;;
            --version)
                printf '%s\n' "${PVD_PIP3_VERSION:-pip 24.0}"
                exit 0
                ;;
        esac
        exit 0
        ;;
    pip)
        log_call "$@"
        case "${1:-}" in
            install)
                if [ "${2:-}" = "--user" ] && [ "${3:-}" = "--upgrade" ] && [ "${4:-}" = "yt-dlp" ]; then
                    if [ "${PVD_PIP_CREATE_YTDLP:-1}" = "1" ]; then
                        write_ytdlp_shim
                    fi
                    exit "${PVD_PIP_INSTALL_EXIT:-0}"
                fi
                ;;
            --version)
                printf '%s\n' "${PVD_PIP_VERSION:-pip 24.0}"
                exit 0
                ;;
        esac
        exit 0
        ;;
    yt-dlp)
        log_call "$@"
        case "${1:-}" in
            --version)
                printf '%s\n' "${PVD_YTDLP_VERSION:-yt-dlp 2026.08.19}"
                ;;
            *)
                printf '%s\n' "${PVD_YTDLP_VERSION:-yt-dlp 2026.08.19}"
                ;;
        esac
        exit 0
        ;;
    ffmpeg)
        log_call "$@"
        case "${1:-}" in
            --version|-version)
                printf '%s\n' "${PVD_FFMPEG_VERSION:-ffmpeg version 7.1}"
                ;;
            *)
                printf '%s\n' "${PVD_FFMPEG_VERSION:-ffmpeg version 7.1}"
                ;;
        esac
        exit 0
        ;;
    ffprobe)
        log_call "$@"
        case "${1:-}" in
            --version|-version)
                printf '%s\n' "${PVD_FFPROBE_VERSION:-ffprobe version 7.1}"
                ;;
            *)
                printf '%s\n' "${PVD_FFPROBE_VERSION:-ffprobe version 7.1}"
                ;;
        esac
        exit 0
        ;;
    *)
        log_call "$@"
        exit 0
        ;;
esac
'@

    foreach ($name in @('uname', 'id', 'pwsh', 'apt-get', 'brew', 'pip3', 'pip')) {
        Set-Content -LiteralPath (Join-Path $BinDir $name) -Value $shim -Encoding Ascii
    }
}

function Set-ExecutableBits {
    param([Parameter(Mandatory)][string]$BinDir)

    $sh = Get-GitBashSh
    $posixDir = Convert-ToGitBashPath -Path $BinDir
    & $sh -lc "chmod +x '$posixDir'/*"
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to mark Git Bash shims executable.'
    }
}

function Invoke-InstallerRun {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][hashtable]$Environment
    )

    $sh = Get-GitBashSh
    $scriptPath = Join-Path $Workspace 'install.sh'
    $posixScript = Convert-ToGitBashPath -Path $scriptPath
    $posixBin = $Environment['PVD_BIN_DIR']
    $runnerPath = Join-Path $Workspace 'runner.sh'
    $posixRunner = Convert-ToGitBashPath -Path $runnerPath
    $stdoutPath = Join-Path $Workspace 'stdout.log'
    $stderrPath = Join-Path $Workspace 'stderr.log'

    $savedEnv = @{}
    foreach ($entry in $Environment.GetEnumerator()) {
        $savedEnv[$entry.Key] = [System.Environment]::GetEnvironmentVariable($entry.Key)
        [System.Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }

    try {
        $runner = @'
#!/usr/bin/env sh
set -eu

export PATH="__BIN__:/usr/bin:/bin:/mingw64/bin:/mingw32/bin"
export PVD_BIN_DIR="__BIN__"
export PVD_CALL_LOG="__CALLLOG__"
export PVD_UID="__UID__"
export PVD_UNAME="__UNAME__"
export PVD_PWSH_VERSION="__PWSH__"
export PVD_YTDLP_VERSION="__YTDLP__"
export PVD_FFMPEG_VERSION="__FFMPEG__"
export PVD_FFPROBE_VERSION="__FFPROBE__"

exec /usr/bin/sh "__INSTALL__"
'@
        $runner = $runner.Replace('__BIN__', $posixBin)
        $runner = $runner.Replace('__CALLLOG__', $Environment['PVD_CALL_LOG'])
        $runner = $runner.Replace('__UID__', $Environment['PVD_UID'])
        $runner = $runner.Replace('__UNAME__', $Environment['PVD_UNAME'])
        $runner = $runner.Replace('__PWSH__', $Environment['PVD_PWSH_VERSION'])
        $runner = $runner.Replace('__YTDLP__', $Environment['PVD_YTDLP_VERSION'])
        $runner = $runner.Replace('__FFMPEG__', $Environment['PVD_FFMPEG_VERSION'])
        $runner = $runner.Replace('__FFPROBE__', $Environment['PVD_FFPROBE_VERSION'])
        $runner = $runner.Replace('__INSTALL__', $posixScript)
        Set-Content -LiteralPath $runnerPath -Value $runner -Encoding Ascii

        $startArgs = @{
            FilePath = $sh
            ArgumentList = @($posixRunner)
            PassThru = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
        }
        $proc = Start-Process @startArgs
        $null = $proc.WaitForExit(120000)
        $proc.Refresh()
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            throw 'Installer scenario timed out after 120 seconds.'
        }

        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode -or $exitCode -eq '') {
            $exitCode = 0
        }

        $outputText = ''
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) {
                $chunk = Get-FileText -Path $path
                if ($chunk) {
                    if ($outputText) { $outputText += "`n" }
                    $outputText += $chunk
                }
            }
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $outputText
        }
    }
    finally {
        foreach ($entry in $Environment.GetEnumerator()) {
            [System.Environment]::SetEnvironmentVariable($entry.Key, $savedEnv[$entry.Key])
        }
    }
}

function New-InstallerScenario {
    param(
        [Parameter(Mandatory)][string]$Uname,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][hashtable]$Environment
    )

    $binDir = Join-Path $Workspace 'bin'
    $installRoot = Join-Path (Join-Path $RootPath 'test-artifacts') ('runtime install root ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    foreach ($name in @('install.sh', 'professional-video-downloader.ps1', 'VERSION')) {
        Copy-Item -LiteralPath (Join-Path $RootPath $name) -Destination $Workspace -Force
    }
    $callLogPath = Join-Path $Workspace 'calls.log'
    Set-Content -LiteralPath $callLogPath -Value '' -Encoding Ascii

    Write-ShellShimSet -BinDir $binDir
    Set-ExecutableBits -BinDir $binDir

    $sh = Get-GitBashSh
    $posixInstall = Convert-ToGitBashPath -Path (Join-Path $Workspace 'install.sh')
    & $sh -lc "chmod +x '$posixInstall'"
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to mark the temp install.sh executable.'
    }

    $envMap = @{
        PVD_BIN_DIR = Convert-ToGitBashPath -Path $binDir
        PVD_CALL_LOG = Convert-ToGitBashPath -Path $callLogPath
        PVD_UID = '0'
        PVD_UNAME = $Uname
        PVD_PWSH_VERSION = '7.4.0'
        PVD_YTDLP_VERSION = 'yt-dlp 2026.08.19'
        PVD_FFMPEG_VERSION = 'ffmpeg version 7.1'
        PVD_FFPROBE_VERSION = 'ffprobe version 7.1'
        PVD_INSTALL_ROOT = Convert-ToGitBashPath -Path $installRoot
    }

    foreach ($entry in $Environment.GetEnumerator()) {
        $envMap[$entry.Key] = $entry.Value
    }
    try {
        $run = Invoke-InstallerRun -Workspace $Workspace -Environment $envMap
        $callLog = if (Test-Path -LiteralPath $callLogPath) {
            Get-FileText -Path $callLogPath
        } else {
            ''
        }

        return [pscustomobject]@{
            ExitCode = $run.ExitCode
            Output   = $run.Output
            CallLog  = $callLog
            BinDir   = $binDir
            InstallRoot = $installRoot
        }
    }
    finally { }
}

function Assert-PositivePackageManagerRun {
    param(
        [Parameter(Mandatory)][string]$ManagerLabel,
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$CallLog,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $ytDlpInstallPattern = if ($CommandName -eq 'apt-get') { 'apt-get install -y yt-dlp' } else { "$CommandName install yt-dlp" }
    $ffmpegInstallPattern = if ($CommandName -eq 'apt-get') { 'apt-get install -y ffmpeg' } else { "$CommandName install ffmpeg" }
    $posixInstallRoot = Convert-ToGitBashPath -Path $InstallRoot
    $installedPs1Path = Convert-ToGitBashPath -Path (Join-Path $InstallRoot 'professional-video-downloader.ps1')

    Assert-True ($Output -match [regex]::Escape("Package manager: $ManagerLabel")) "Did not detect the expected package manager: $ManagerLabel.`n$Output"
    Assert-True ($Output -match [regex]::Escape("Install root: $posixInstallRoot")) 'The install root banner did not reflect the requested runtime path.'
    Assert-True ($Output -match [regex]::Escape("Runtime files installed: $posixInstallRoot")) 'The runtime copy step did not report the requested install root.'
    Assert-True (Test-Path -LiteralPath (Join-Path $InstallRoot 'professional-video-downloader.ps1')) 'The installed runtime script was not copied to disk.'
    Assert-True (Test-Path -LiteralPath (Join-Path $InstallRoot 'VERSION')) 'The VERSION file was not copied to disk.'
    Assert-True ($Output -match 'yt-dlp installed: yt-dlp 2026\.08\.19') "yt-dlp success line was missing.`n$Output"
    Assert-True ($Output -match 'ffmpeg installed: ffmpeg version 7\.1') "ffmpeg success line was missing.`n$Output"
    Assert-True ($Output -match 'Verification') 'Verification block was missing.'
    Assert-True ($Output -match 'yt-dlp\s+-> yt-dlp 2026\.08\.19') 'yt-dlp version check was missing.'
    Assert-True ($Output -match 'ffmpeg\s+-> ffmpeg version 7\.1') 'ffmpeg version check was missing.'
    Assert-True ($Output -match 'ffprobe\s+-> ffprobe version 7\.1') 'ffprobe version check was missing.'
    Assert-True ($Output -match 'Launching Professional Video Downloader') 'Installer did not reach the launch step.'
    Assert-True ($CallLog -match [regex]::Escape("$CommandName update")) "Did not call $CommandName update.`n$CallLog"
    Assert-True ($CallLog -match [regex]::Escape($ytDlpInstallPattern)) "Did not call $ytDlpInstallPattern.`n$CallLog"
    Assert-True ($CallLog -match [regex]::Escape($ffmpegInstallPattern)) "Did not call $ffmpegInstallPattern.`n$CallLog"
    Assert-True ($CallLog -match 'pwsh -NoProfile -Command') 'PowerShell version check was not recorded.'
    Assert-True ($CallLog -match [regex]::Escape("pwsh -NoProfile -ExecutionPolicy Bypass -File $installedPs1Path")) 'Final launch handoff did not target the installed runtime script.'
}

function Invoke-AptSuccessScenario {
    $workspace = New-TestWorkspace
    try {
        $result = New-InstallerScenario -Uname 'Linux' -Workspace $workspace -Environment @{
            PVD_APT_UPDATE_EXIT = '0'
            PVD_APT_YTDLP_EXIT = '0'
            PVD_APT_FFMPEG_EXIT = '0'
        }

        Assert-True ($result.ExitCode -eq 0) "Apt success scenario failed.`n$($result.Output)"
        Assert-PositivePackageManagerRun -ManagerLabel 'apt' -CommandName 'apt-get' -Output $result.Output -CallLog $result.CallLog -InstallRoot $result.InstallRoot
    }
    finally {
        Remove-TestWorkspace -Path $workspace
        if ($result -and $result.InstallRoot) {
            Remove-ScenarioInstallRoot -Path $result.InstallRoot
        }
    }
}

function Invoke-BrewSuccessScenario {
    $workspace = New-TestWorkspace
    try {
        $result = New-InstallerScenario -Uname 'Darwin' -Workspace $workspace -Environment @{
            PVD_BREW_UPDATE_EXIT = '0'
            PVD_BREW_YTDLP_EXIT = '0'
            PVD_BREW_FFMPEG_EXIT = '0'
        }

        Assert-True ($result.ExitCode -eq 0) "Brew success scenario failed.`n$($result.Output)"
        Assert-PositivePackageManagerRun -ManagerLabel 'brew' -CommandName 'brew' -Output $result.Output -CallLog $result.CallLog -InstallRoot $result.InstallRoot
    }
    finally {
        Remove-TestWorkspace -Path $workspace
        if ($result -and $result.InstallRoot) {
            Remove-ScenarioInstallRoot -Path $result.InstallRoot
        }
    }
}

function Invoke-AptFallbackScenario {
    $workspace = New-TestWorkspace
    try {
        $result = New-InstallerScenario -Uname 'Linux' -Workspace $workspace -Environment @{
            PVD_APT_UPDATE_EXIT = '0'
            PVD_APT_YTDLP_EXIT = '42'
            PVD_APT_CREATE_YTDLP = '0'
            PVD_APT_FFMPEG_EXIT = '0'
            PVD_PIP3_INSTALL_EXIT = '0'
        }

        Assert-True ($result.ExitCode -eq 0) "Apt fallback scenario failed.`n$($result.Output)"
        Assert-True ($result.Output -match 'apt-get install -y yt-dlp failed with exit code 42') "The failing apt command was not surfaced.`n$($result.Output)"
        Assert-True ($result.Output -match 'Package-manager install failed for yt-dlp; checking pip fallback\.') 'The installer did not explain the fallback decision.'
        Assert-True ($result.Output -match 'Falling back to pip3 install --user yt-dlp') 'pip3 fallback was not announced.'
        Assert-True ($result.Output -match 'yt-dlp installed: yt-dlp 2026\.08\.19') 'yt-dlp success line was missing after the fallback.'
        Assert-True ($result.Output -match 'ffmpeg installed: ffmpeg version 7\.1') 'ffmpeg should still install successfully after the yt-dlp failure.'
        Assert-True ($result.CallLog -match 'apt-get install -y yt-dlp') 'Apt yt-dlp install was not recorded.'
        Assert-True ($result.CallLog -match 'pip3 install --user --upgrade yt-dlp') 'pip3 fallback was not recorded.'
        Assert-PositivePackageManagerRun -ManagerLabel 'apt' -CommandName 'apt-get' -Output $result.Output -CallLog $result.CallLog -InstallRoot $result.InstallRoot
    }
    finally {
        Remove-TestWorkspace -Path $workspace
        if ($result -and $result.InstallRoot) {
            Remove-ScenarioInstallRoot -Path $result.InstallRoot
        }
    }
}

function Invoke-YtDlpVersionGateScenario {
    param(
        [Parameter(Mandatory)][string]$VersionText,
        [Parameter(Mandatory)][bool]$ShouldPass,
        [Parameter(Mandatory)][string]$ScenarioName
    )

    $workspace = New-TestWorkspace
    try {
        $result = New-InstallerScenario -Uname 'Linux' -Workspace $workspace -Environment @{
            PVD_APT_UPDATE_EXIT = '0'
            PVD_APT_YTDLP_EXIT = '0'
            PVD_YTDLP_VERSION = $VersionText
        }

        if ($ShouldPass) {
            Assert-True ($result.ExitCode -eq 0) "$ScenarioName should pass the yt-dlp version gate.`n$($result.Output)"
            Assert-True ($result.Output -match [regex]::Escape("yt-dlp installed: $VersionText")) "$ScenarioName did not report the supported yt-dlp version."
            Assert-True ($result.Output -match 'Launching Professional Video Downloader') "$ScenarioName did not continue through runtime installation."
        }
        else {
            Assert-True ($result.ExitCode -ne 0) "$ScenarioName should fail the yt-dlp version gate."
            Assert-True ($result.Output -match '2026\.08\.19') "$ScenarioName did not identify the required yt-dlp version.`n$($result.Output)"
            Assert-True ($result.Output -notmatch 'yt-dlp installed:') "$ScenarioName printed a misleading yt-dlp success line."
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $result.InstallRoot 'professional-video-downloader.ps1'))) "$ScenarioName copied the runtime before rejecting yt-dlp."
            Assert-True ($result.Output -notmatch 'Launching Professional Video Downloader') "$ScenarioName launched after rejecting yt-dlp."
            Assert-True ($result.CallLog -notmatch 'pwsh -NoProfile -ExecutionPolicy Bypass -File') "$ScenarioName handed off to PowerShell after rejecting yt-dlp."
        }
    }
    finally {
        Remove-TestWorkspace -Path $workspace
        if ($result -and $result.InstallRoot) {
            Remove-ScenarioInstallRoot -Path $result.InstallRoot
        }
    }
}

function Invoke-MissingPackageManagerScenario {
    $workspace = New-TestWorkspace
    try {
        $result = New-InstallerScenario -Uname 'MSYS_NT-10.0-26200' -Workspace $workspace -Environment @{}

        Assert-True ($result.ExitCode -ne 0) 'Missing package manager scenario should fail.'
        Assert-True ($result.Output -match 'install\.sh is not supported on native Windows-hosted POSIX shells') 'Unsupported Windows-hosted shell error was not surfaced.'
        Assert-True ($result.Output -match 'Use install\.bat on Windows or run this script inside Linux, macOS, or WSL') 'Unsupported shell guidance was not surfaced.'
        Assert-True ($result.Output -notmatch '\[ OK \] Package manager:') 'No misleading package manager success message should be printed.'
        Assert-True ($result.Output -notmatch 'Launching Professional Video Downloader') 'Launch step should not run when no package manager is detected.'
        Assert-True ($result.CallLog -notmatch 'apt-get|brew') 'No package-manager commands should run when none are available.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
        if ($result -and $result.InstallRoot) {
            Remove-ScenarioInstallRoot -Path $result.InstallRoot
        }
    }
}

function Invoke-InstallRootPermissionFailureScenario {
    $workspace = New-TestWorkspace
    try {
        $permissionRoot = Join-Path $workspace 'permission failure install root'
        $result = New-InstallerScenario -Uname 'Linux' -Workspace $workspace -Environment @{
            PVD_UID = '1000'
            PVD_INSTALL_ROOT = Convert-ToGitBashPath -Path $permissionRoot
        }

        Assert-True ($result.ExitCode -ne 0) 'Permission failure scenario should fail when the install root is not writable.'
        Assert-True ($result.Output -match 'Install root .* requires sudo or root access') 'The installer did not explain why the install root was rejected.'
        Assert-True ($result.Output -notmatch 'Launching Professional Video Downloader') 'Launch step should not run when the install root cannot be created.'
        Assert-True ($result.CallLog -notmatch 'pwsh -NoProfile -ExecutionPolicy Bypass -File') 'The runtime script should not launch after the install-root failure.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
        if ($result -and $result.InstallRoot) {
            Remove-ScenarioInstallRoot -Path $result.InstallRoot
        }
    }
}

Write-Step 'Positive: apt-based install succeeds and reports version checks'
Invoke-AptSuccessScenario

Write-Step 'Positive: brew-based install succeeds and reports version checks'
Invoke-BrewSuccessScenario

Write-Step 'Negative/regression: package-manager failure names the real failing command and falls back when pip is available'
Invoke-AptFallbackScenario

Write-Step 'Negative: POSIX installer rejects yt-dlp below the current stable release before copying or launching'
Invoke-YtDlpVersionGateScenario -VersionText 'yt-dlp 2026.08.18' -ShouldPass:$false -ScenarioName 'old-version'

Write-Step 'Boundary: POSIX installer accepts patch releases above the stable release floor'
Invoke-YtDlpVersionGateScenario -VersionText 'yt-dlp 2026.08.19.1' -ShouldPass:$true -ScenarioName 'patch-level-version'

Write-Step 'Boundary: POSIX installer rejects a prerelease at the stable release floor'
Invoke-YtDlpVersionGateScenario -VersionText 'yt-dlp 2026.08.19-alpha' -ShouldPass:$false -ScenarioName 'prerelease-version'

Write-Step 'Boundary: POSIX installer rejects an unparseable yt-dlp version'
Invoke-YtDlpVersionGateScenario -VersionText 'unknown' -ShouldPass:$false -ScenarioName 'unparseable-version'

Write-Step 'Boundary: missing package manager fails before any misleading success message'
Invoke-MissingPackageManagerScenario

Write-Step 'Negative: non-root install root failures surface a clear permission message'
Invoke-InstallRootPermissionFailureScenario

Write-Host '[PASS] POSIX installer validation passed.' -ForegroundColor Green
