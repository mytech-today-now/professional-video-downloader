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

function Get-AppStateRoot {
    param([Parameter(Mandatory)][string]$BasePath)

    $root = Join-Path $BasePath 'myTech.Today'
    return (Join-Path $root 'professional-video-downloader')
}

function Get-ProjectVersion {
    param([Parameter(Mandatory)][string]$VersionFilePath)

    $version = (Get-FileText -Path $VersionFilePath).Trim()
    if (-not $version) {
        throw "Version file is empty: $VersionFilePath"
    }

    return $version
}

function Get-MainScriptHeaderVersion {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ScriptText
    )

    $match = [regex]::Match($ScriptText, '(?ms)^\s*\.VERSION\s*$\s*(?<version>[^\s#]+)')
    if (-not $match.Success) {
        throw "Could not find .VERSION header in $ScriptPath"
    }

    return $match.Groups['version'].Value.Trim()
}

function Get-PowerShellHost {
    foreach ($name in @('pwsh.exe', 'pwsh', 'powershell.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            return $cmd.Source
        }
    }

    throw 'No PowerShell host found on PATH.'
}

function Test-IsWindowsPlatform {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Invoke-MainScriptProcess {
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$TranscriptPath,
        [string]$StdoutPath,
        [string]$StderrPath,
        [Parameter(Mandatory)][string]$ElapsedPath,
        [int]$TimeoutMilliseconds = 90000
    )

    $hostExe = Get-PowerShellHost
    $startArgs = @{
        FilePath               = $hostExe
        ArgumentList           = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WrapperPath)
        PassThru               = $true
    }
    if ($StdoutPath) {
        $startArgs.RedirectStandardOutput = $StdoutPath
    }
    if ($StderrPath) {
        $startArgs.RedirectStandardError = $StderrPath
    }
    if (Test-IsWindowsPlatform) {
        $startArgs.WindowStyle = 'Hidden'
    }

    $proc = Start-Process @startArgs

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = $proc.WaitForExit($TimeoutMilliseconds)
    $proc.Refresh()
    $stopwatch.Stop()

    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw "Main script wrapper timed out after $TimeoutMilliseconds milliseconds."
    }

    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode -or $exitCode -eq '') {
        $exitCode = 0
    }

    $elapsedMilliseconds = $null
    if (Test-Path -LiteralPath $ElapsedPath) {
        $elapsedText = (Get-Content -LiteralPath $ElapsedPath -Raw -ErrorAction Stop).Trim()
        $parsedElapsed = 0
        if ($elapsedText -and [int]::TryParse($elapsedText, [ref]$parsedElapsed)) {
            $elapsedMilliseconds = $parsedElapsed
        }
    }
    if ($null -eq $elapsedMilliseconds) {
        $elapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds
    }

    $outputText = ''
    foreach ($path in @($TranscriptPath, $StdoutPath, $StderrPath)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        if (Test-Path -LiteralPath $path) {
            $chunk = Get-FileText -Path $path
            if ($chunk) {
                if ($outputText) { $outputText += "`n" }
                $outputText += $chunk
            }
        }
    }

    return [pscustomobject]@{
        ExitCode           = $exitCode
        OutputText         = $outputText
        ElapsedMilliseconds = $elapsedMilliseconds
    }
}

function Copy-SourceFixture {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string[]]$FileNames
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-version-sync-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    foreach ($fileName in $FileNames) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $fileName) -Destination $tempRoot -Force
    }

    return $tempRoot
}

function Assert-StaticVersionSurface {
    param([Parameter(Mandatory)][string]$SourceRoot)

    $versionFilePath = Join-Path $SourceRoot 'VERSION'
    $mainScriptPath  = Join-Path $SourceRoot 'professional-video-downloader.ps1'
    $bootstrapPath   = Join-Path $SourceRoot 'install-bootstrap.ps1'
    $batchPath       = Join-Path $SourceRoot 'install.bat'
    $shellPath       = Join-Path $SourceRoot 'install.sh'
    $readmePath      = Join-Path $SourceRoot 'README.md'

    $version      = Get-ProjectVersion -VersionFilePath $versionFilePath
    $mainText     = Get-FileText -Path $mainScriptPath
    $bootstrap    = Get-FileText -Path $bootstrapPath
    $batch        = Get-FileText -Path $batchPath
    $shell        = Get-FileText -Path $shellPath
    $readme       = Get-FileText -Path $readmePath
    $headerVersion = Get-MainScriptHeaderVersion -ScriptPath $mainScriptPath -ScriptText $mainText

    Assert-True ($version -eq $headerVersion) "Main script header version '$headerVersion' does not match VERSION '$version'."
    Assert-True ($mainText -match [regex]::Escape('Get-ProjectVersion -RootPath $PSScriptRoot')) 'Main script does not read VERSION at runtime.'
    Assert-True ($mainText -match [regex]::Escape('Write-Colored "=== Video Downloader (yt-dlp) v$ScriptVersion ==="')) 'Runtime banner no longer comes from the shared version value.'
    Assert-True ($mainText -match [regex]::Escape('Assert-YtDlpMinimumVersion')) 'Main script no longer enforces the yt-dlp minimum version.'
    Assert-True ($mainText -match [regex]::Escape('Get-YtDlpVersionText')) 'Main script no longer probes yt-dlp version text before launching.'
    Assert-True ($mainText -match [regex]::Escape('[switch]$PauseOnExit')) 'Main script no longer exposes the opt-in exit pause switch.'
    Assert-True ($mainText -match [regex]::Escape('Invoke-ExitPause -Seconds 4')) 'Main script no longer routes the clean exit through the pause helper.'
    Assert-True ($bootstrap -match [regex]::Escape('Get-ProjectVersion -RootPath $SourceDir')) 'Bootstrap does not read VERSION at runtime.'
    Assert-True ($bootstrap -match [regex]::Escape('Professional Video Downloader v{0} - Setup')) 'Bootstrap banner does not include the shared version placeholder.'
    Assert-True ($bootstrap -match [regex]::Escape('Assert-YtDlpMinimumVersion')) 'Bootstrap no longer enforces the yt-dlp minimum version.'
    Assert-True ($shell -match [regex]::Escape("MIN_YTDLP_VERSION='2026.08.19'")) 'POSIX installer does not enforce the current yt-dlp minimum version.'
    Assert-True ($shell -match [regex]::Escape('assert_ytdlp_version')) 'POSIX installer no longer validates installed yt-dlp versions.'
    Assert-True ($batch -match [regex]::Escape('Professional Video Downloader v%APP_VERSION% - Setup')) 'Batch installer banner does not use the shared version placeholder.'
    Assert-True ($shell -match [regex]::Escape('Professional Video Downloader v${APP_VERSION} - Setup')) 'POSIX installer banner does not use the shared version placeholder.'
    Assert-True ($readme -match [regex]::Escape('`VERSION` is the single source of truth')) 'README no longer describes VERSION as the source of truth.'
    Assert-True ($readme -match [regex]::Escape('tests/version-sync.ps1')) 'README does not point at the version validation test.'
    Assert-True ($readme -match [regex]::Escape("https://raw.githubusercontent.com/mytech-today-now/professional-video-downloader/v$version/install-bootstrap.ps1")) 'README install example is not pinned to the current release tag.'
    Assert-True ($readme -notmatch 'refs/heads/main') 'README still references the moving main branch in the install example.'
    Assert-True ($readme -match [regex]::Escape('install-bootstrap.ps1')) 'README install example no longer names the bootstrap script.'
    Assert-True ($readme -match [regex]::Escape('powershell -ExecutionPolicy Bypass -Command')) 'README lost the Windows PowerShell install example.'
    Assert-True ($readme -match [regex]::Escape('powershell -NoProfile -ExecutionPolicy Bypass -Command')) 'README lost the Command Prompt install example.'

    return $version
}

function Assert-VersionFileTrimming {
    param([Parameter(Mandatory)][string]$ExpectedVersion)

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-version-trim-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $versionFile = Join-Path $tempDir 'VERSION'
        Set-Content -LiteralPath $versionFile -Value ("  {0}  `r`n" -f $ExpectedVersion) -Encoding Ascii

        $trimmed = Get-ProjectVersion -VersionFilePath $versionFile
        Assert-True ($trimmed -eq $ExpectedVersion) "Version trimming failed. Expected '$ExpectedVersion' but got '$trimmed'."
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MainScriptSmoke {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [switch]$ForceLogPathFailure
    )

    $fixtureRoot = Copy-SourceFixture -SourceRoot $SourceRoot -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $downloadRoot = Join-Path $fixtureRoot 'downloads'
    $stateRoot = Join-Path $fixtureRoot 'state'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $logPath = Join-Path (Get-AppStateRoot -BasePath $stateRoot) 'logs'
    try {
        if ($ForceLogPathFailure) {
            if (Test-Path -LiteralPath $logPath) {
                Remove-Item -LiteralPath $logPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
            Set-Content -LiteralPath $logPath -Value 'logging blocked for smoke validation' -Encoding Ascii
        }
        else {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }

        $hostExe = Get-PowerShellHost
        $scriptPath = (Join-Path $fixtureRoot 'professional-video-downloader.ps1').Replace("'", "''")
        $downloadDirArg = $downloadRoot.Replace("'", "''")
        $stateRootArg = $stateRoot.Replace("'", "''")
        $transcriptPath = Join-Path $fixtureRoot 'smoke.transcript.log'
        $stdoutPath = Join-Path $fixtureRoot 'smoke.stdout.log'
        $stderrPath = Join-Path $fixtureRoot 'smoke.stderr.log'
        $elapsedPath = Join-Path $fixtureRoot 'smoke.elapsed.txt'
        $wrapperPath = Join-Path $fixtureRoot 'smoke-wrapper.ps1'
        $wrapper = @'
$env:LOCALAPPDATA = '__STATE__'
Start-Transcript -LiteralPath '__TRANSCRIPT__' -Force | Out-Null
function global:yt-dlp {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $global:LASTEXITCODE = 0
    if ($Args -contains '--version') {
        Write-Output 'yt-dlp 2026.08.19'
        return
    }
Write-Output '[download] Destination: __DOWNLOAD__/fake.mp4'
}
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& '__SCRIPT__' -Url @('https://example.com/video') -DownloadPath '__DOWNLOAD__'
$stopwatch.Stop()
Set-Content -LiteralPath '__ELAPSED__' -Value $stopwatch.ElapsedMilliseconds -Encoding Ascii
$childExitCodeVar = Get-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue
if ($childExitCodeVar -and $null -ne $childExitCodeVar.Value) {
    exit $childExitCodeVar.Value
}
exit ([int](-not $?))
'@
        $wrapper = $wrapper.Replace('__TRANSCRIPT__', $transcriptPath)
        $wrapper = $wrapper.Replace('__DOWNLOAD__', $downloadDirArg)
        $wrapper = $wrapper.Replace('__STATE__', $stateRootArg)
        $wrapper = $wrapper.Replace('__SCRIPT__', $scriptPath)
        $wrapper = $wrapper.Replace('__ELAPSED__', $elapsedPath.Replace("'", "''"))
        Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding Ascii
        $result = Invoke-MainScriptProcess -WrapperPath $wrapperPath -TranscriptPath $transcriptPath -ElapsedPath $elapsedPath

        $script:LastSmokeResult = $result
        Assert-True ($result.ExitCode -eq 0) "Smoke run failed with exit code $($result.ExitCode).`n$($result.OutputText)"

        $outputText = $result.OutputText
        $bannerMatch = [regex]::Match($outputText, '=== Video Downloader \(yt-dlp\) v(?<version>[^=]+) ===')
        Assert-True $bannerMatch.Success "Smoke run did not print the runtime banner.`n$outputText"
        Assert-True ($bannerMatch.Groups['version'].Value.Trim() -eq $ExpectedVersion) "Banner version '$($bannerMatch.Groups['version'].Value.Trim())' does not match '$ExpectedVersion'."
        Assert-True ($outputText -notmatch "property 'Count' cannot be found on this object") 'Smoke run hit the single-item Count regression in the summary path.'

        if ($ForceLogPathFailure) {
            $warningText = 'Warning: Unable to write log entry. Diagnostics will no longer be recorded for this run.'
            $transcriptText = if (Test-Path -LiteralPath $transcriptPath) {
                Get-FileText -Path $transcriptPath
            } else {
                $outputText
            }
            $warningMatches = [regex]::Matches($transcriptText, [regex]::Escape($warningText))
            Assert-True ($warningMatches.Count -eq 1) "Expected exactly one log failure warning, saw $($warningMatches.Count).`n$outputText"
            Assert-True ($transcriptText -match '========== SUMMARY ==========' ) 'Smoke run with logging failure did not reach the summary output.'
            Assert-True ($transcriptText -match 'Download completed successfully!') 'Smoke run with logging failure did not complete the download path.'
            Assert-True (Test-Path -LiteralPath $logPath -PathType Leaf) 'The simulated logging failure path was not created as a file.'
        }
        else {
            $logDir = Join-Path (Get-AppStateRoot -BasePath $stateRoot) 'logs'
            $logFile = $null
            for ($attempt = 0; $attempt -lt 20 -and $null -eq $logFile; $attempt++) {
                $logFile = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($null -eq $logFile) {
                    Start-Sleep -Milliseconds 100
                }
            }
            if ($null -eq $logFile) {
                $entries = if (Test-Path -LiteralPath $logDir) {
                    Get-ChildItem -LiteralPath $logDir -Force | ForEach-Object { $_.Name }
                } else {
                    @('<missing log dir>')
                }
                throw "Smoke run did not create a log file. Contents of ${logDir}: $($entries -join ', ')`n$outputText"
            }
            Assert-True ($logFile.Name -match '^\d{4}-\d{2}-\d{2}\.log$') "Log file did not use the expected daily naming pattern: $($logFile.Name)."

            $logText = Get-FileText -Path $logFile.FullName
            Assert-True ($logText -match ("\[v{0}\]" -f [regex]::Escape($ExpectedVersion))) "Log file did not include the expected version marker [$ExpectedVersion]."

            $firstLine = ($logText -split "`r?`n" | Select-Object -First 1)
            $linePattern = '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[INFO\] \[PID \d+\] \[v' + [regex]::Escape($ExpectedVersion) + '\] Script started(?: \[.*\])?$'
            Assert-True ($firstLine -match $linePattern) "Log file did not use the expected line format.`n$firstLine"
        }
    }
    finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MainScriptFailureSmoke {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )

    $fixtureRoot = Copy-SourceFixture -SourceRoot $SourceRoot -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $downloadRoot = Join-Path $fixtureRoot 'downloads'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

    try {
        $scriptPath = (Join-Path $fixtureRoot 'professional-video-downloader.ps1').Replace("'", "''")
        $downloadDirArg = $downloadRoot.Replace("'", "''")
        $transcriptPath = Join-Path $fixtureRoot 'failure.transcript.log'
        $stdoutPath = Join-Path $fixtureRoot 'failure.stdout.log'
        $stderrPath = Join-Path $fixtureRoot 'failure.stderr.log'
        $elapsedPath = Join-Path $fixtureRoot 'failure.elapsed.txt'
        $wrapperPath = Join-Path $fixtureRoot 'failure-wrapper.ps1'
        $wrapper = @'
Start-Transcript -LiteralPath '__TRANSCRIPT__' -Force | Out-Null
function global:yt-dlp {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($Args -contains '--version') {
        $global:LASTEXITCODE = 0
        Write-Output 'yt-dlp 2026.08.19'
        return
    }

    $global:LASTEXITCODE = 1
    Write-Output 'ERROR: unable to download video data: HTTP Error 403: Forbidden'
}
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& '__SCRIPT__' -Url @('https://example.com/video') -DownloadPath '__DOWNLOAD__'
$stopwatch.Stop()
Set-Content -LiteralPath '__ELAPSED__' -Value $stopwatch.ElapsedMilliseconds -Encoding Ascii
$childExitCodeVar = Get-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue
if ($childExitCodeVar -and $null -ne $childExitCodeVar.Value) {
    exit $childExitCodeVar.Value
}
exit ([int](-not $?))
'@
        $wrapper = $wrapper.Replace('__TRANSCRIPT__', $transcriptPath)
        $wrapper = $wrapper.Replace('__DOWNLOAD__', $downloadDirArg)
        $wrapper = $wrapper.Replace('__SCRIPT__', $scriptPath)
        $wrapper = $wrapper.Replace('__ELAPSED__', $elapsedPath.Replace("'", "''"))
        Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding Ascii
        $result = Invoke-MainScriptProcess -WrapperPath $wrapperPath -TranscriptPath $transcriptPath -ElapsedPath $elapsedPath

        $outputText = $result.OutputText
        Assert-True ($result.ExitCode -eq 1) "Failure smoke run should exit with code 1.`n$outputText"
        Assert-True ($outputText -match 'Download failed \(yt-dlp exit code 1\)') "Failure smoke run did not report the yt-dlp failure.`n$outputText"
        Assert-True ($outputText -match '========== SUMMARY ==========' ) 'Failure smoke run did not reach the summary output.'
        Assert-True ($outputText -notmatch "property 'Count' cannot be found on this object") 'Failure smoke run hit the single-item Count regression in the summary path.'
    }
    finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MainScriptNoInputScenario {
    param(
        [Parameter(Mandatory)][string]$SourceRoot
    )

    $fixtureRoot = Copy-SourceFixture -SourceRoot $SourceRoot -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $downloadRoot = Join-Path $fixtureRoot 'downloads'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    try {
        $scriptPath = (Join-Path $fixtureRoot 'professional-video-downloader.ps1').Replace("'", "''")
        $downloadDirArg = $downloadRoot.Replace("'", "''")
        $transcriptPath = Join-Path $fixtureRoot 'noinput.transcript.log'
        $promptLogPath = Join-Path $fixtureRoot 'noinput.prompts.log'
        $elapsedPath = Join-Path $fixtureRoot 'noinput.elapsed.txt'
        $wrapperPath = Join-Path $fixtureRoot 'noinput-wrapper.ps1'
        $wrapper = @'
function global:Write-Colored {
    param(
        [string]$Message,
        [string]$Color
    )
}
function global:Read-UrlListInteractive {
    Add-Content -LiteralPath '__PROMPTS__' -Value 'prompt' -Encoding Ascii
    return @()
}
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& '__SCRIPT__' -DownloadPath '__DOWNLOAD__'
$stopwatch.Stop()
Set-Content -LiteralPath '__ELAPSED__' -Value $stopwatch.ElapsedMilliseconds -Encoding Ascii
$childExitCodeVar = Get-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue
if ($childExitCodeVar -and $null -ne $childExitCodeVar.Value) {
    exit $childExitCodeVar.Value
}
exit ([int](-not $?))
'@
        $wrapper = $wrapper.Replace('__DOWNLOAD__', $downloadDirArg)
        $wrapper = $wrapper.Replace('__SCRIPT__', $scriptPath)
        $wrapper = $wrapper.Replace('__ELAPSED__', $elapsedPath.Replace("'", "''"))
        $wrapper = $wrapper.Replace('__PROMPTS__', $promptLogPath.Replace("'", "''"))
        Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding Ascii

        $result = Invoke-MainScriptProcess -WrapperPath $wrapperPath -TranscriptPath $transcriptPath -ElapsedPath $elapsedPath

        $script:LastNoInputResult = $result
        Assert-True ($result.ExitCode -eq 1) "No-input run should fail with exit code 1.`n$($result.OutputText)"
        Assert-True (Test-Path -LiteralPath $promptLogPath) 'No-input helper did not record prompt attempts.'
        $promptCount = (Get-Content -LiteralPath $promptLogPath -ErrorAction Stop).Count
        Assert-True ($promptCount -eq 3) "No-input helper should have been called three times, saw $promptCount."
    }
    finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MainScriptVersionGateScenario {
    param([Parameter(Mandatory)][string]$SourceRoot)

    $fixtureRoot = Copy-SourceFixture -SourceRoot $SourceRoot -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $downloadRoot = Join-Path $fixtureRoot 'downloads'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    $callLogPath = Join-Path $fixtureRoot 'yt-dlp-calls.log'
    try {
        $hostExe = Get-PowerShellHost
        $scriptPath = (Join-Path $fixtureRoot 'professional-video-downloader.ps1').Replace("'", "''")
        $downloadDirArg = $downloadRoot.Replace("'", "''")
        $callLogArg = $callLogPath.Replace("'", "''")
        $transcriptPath = Join-Path $fixtureRoot 'gate.transcript.log'
        $stdoutPath = Join-Path $fixtureRoot 'gate.stdout.log'
        $stderrPath = Join-Path $fixtureRoot 'gate.stderr.log'
        $wrapperPath = Join-Path $fixtureRoot 'gate-wrapper.ps1'
        $wrapper = @'
Start-Transcript -LiteralPath '__TRANSCRIPT__' -Force | Out-Null
$callLogPath = '__CALLLOG__'
function global:yt-dlp {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $line = ($Args -join ' ')
    Add-Content -LiteralPath $callLogPath -Value $line -Encoding Ascii
    $global:LASTEXITCODE = 0
    if ($Args -contains '--version') {
        Write-Output 'yt-dlp 2026.08.18'
        return
    }
    throw 'yt-dlp should not receive download flags when the version gate fails.'
}
& '__SCRIPT__' -Url @('https://example.com/video') -DownloadPath '__DOWNLOAD__' -CookiesFromBrowser firefox -Impersonate
$childExitCodeVar = Get-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue
if ($childExitCodeVar -and $null -ne $childExitCodeVar.Value) {
    exit $childExitCodeVar.Value
}
exit ([int](-not $?))
'@
        $wrapper = $wrapper.Replace('__TRANSCRIPT__', $transcriptPath)
        $wrapper = $wrapper.Replace('__CALLLOG__', $callLogArg)
        $wrapper = $wrapper.Replace('__SCRIPT__', $scriptPath)
        $wrapper = $wrapper.Replace('__DOWNLOAD__', $downloadDirArg)
        Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding Ascii
        $startArgs = @{
            FilePath = $hostExe
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperPath)
            PassThru = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
        }
        if (Test-IsWindowsPlatform) {
            $startArgs.WindowStyle = 'Hidden'
        }
        $proc = Start-Process @startArgs

        $null = $proc.WaitForExit(90000)
        $proc.Refresh()
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            throw "Version gate run timed out after 90 seconds."
        }

        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode -or $exitCode -eq '') {
            $exitCode = 0
        }
        $outputText = ''
        foreach ($path in @($transcriptPath, $stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) {
                $chunk = Get-FileText -Path $path
                if ($chunk) {
                    if ($outputText) { $outputText += "`n" }
                    $outputText += $chunk
                }
            }
        }

        $callLog = if (Test-Path -LiteralPath $callLogPath) {
            Get-FileText -Path $callLogPath
        } else {
            ''
        }

        Assert-True ($outputText -match 'yt-dlp 2026\.08\.18 is too old') "Version-gate failure did not surface the upgrade message.`n$outputText"
        Assert-True ($outputText -match [regex]::Escape("run 'yt-dlp -U' for standalone release binaries")) "Version-gate failure did not include the upgrade path.`n$outputText"
        Assert-True ($callLog.Trim() -eq '--version') "Version gate should only query yt-dlp --version before exiting.`n$callLog"
        Assert-True ($outputText -notmatch 'Using cookies from browser: firefox') 'Version gate failure should happen before browser-cookie features are announced.'
        Assert-True ($outputText -notmatch 'Using browser impersonation: chrome') 'Version gate failure should happen before impersonation is announced.'
        Assert-True ($outputText -notmatch 'Starting high-quality download with yt-dlp') 'Version gate failure should happen before the download path starts.'
    }
    finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-DeliberateMismatchFails {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )

    $fixtureRoot = Copy-SourceFixture -SourceRoot $SourceRoot -FileNames @(
        'professional-video-downloader.ps1',
        'install-bootstrap.ps1',
        'install.bat',
        'install.sh',
        'README.md',
        'VERSION'
    )

    try {
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'VERSION') -Value '9.9.9' -Encoding Ascii

        $failed = $false
        try {
            [void](Assert-StaticVersionSurface -SourceRoot $fixtureRoot)
        }
        catch {
            $failed = $true
        }

        Assert-True $failed 'Validation did not fail after introducing a deliberate version mismatch.'
    }
    finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Positive: repository metadata matches the authoritative VERSION file"
$version = Assert-StaticVersionSurface -SourceRoot $RootPath

Write-Step "Positive: runtime banner and log line expose the same version"
Invoke-MainScriptSmoke -SourceRoot $RootPath -ExpectedVersion $version
$script:SmokeBaselineElapsedMs = $script:LastSmokeResult.ElapsedMilliseconds

Write-Step "Negative: failed downloads still reach the summary without Count errors"
Invoke-MainScriptFailureSmoke -SourceRoot $RootPath -ExpectedVersion $version

Write-Step "Negative: logging failures surface once without aborting the run"
Invoke-MainScriptSmoke -SourceRoot $RootPath -ExpectedVersion $version -ForceLogPathFailure

Write-Step "Boundary: VERSION values are trimmed before comparison"
Assert-VersionFileTrimming -ExpectedVersion $version

Write-Step "Negative: deliberate drift fails fast"
Assert-DeliberateMismatchFails -SourceRoot $RootPath -ExpectedVersion $version

Write-Host "[PASS] Version sync validation passed." -ForegroundColor Green
