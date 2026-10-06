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

$script:TestIsWindowsPlatformOverride = $null
$script:BlockComLookup = $false
$script:MockDownloadFolderPlatform = $null
$script:MockXdgDownloads = $null
$script:MockMacDownloads = $null
$script:FakeShellDownloadsPath = $null

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

function Test-CurrentHostIsWindows {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Test-IsWindowsPlatform {
    if ($null -ne $script:TestIsWindowsPlatformOverride) {
        return [bool]$script:TestIsWindowsPlatformOverride
    }

    return (Test-CurrentHostIsWindows)
}

function uname {
    if ($script:MockDownloadFolderPlatform) {
        return $script:MockDownloadFolderPlatform
    }
}

function xdg-user-dir {
    if ($script:MockXdgDownloads) {
        return $script:MockXdgDownloads
    }
}

function osascript {
    if ($script:MockMacDownloads) {
        return $script:MockMacDownloads
    }
}

function New-Object {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$RemainingArgs
    )

    if ($script:BlockComLookup -and ($RemainingArgs -contains '-ComObject')) {
        throw 'COM lookup should not run in this scenario.'
    }

    if (($RemainingArgs -contains '-ComObject') -and $script:FakeShellDownloadsPath) {
        $downloadsPath = $script:FakeShellDownloadsPath
        $namespaceMethod = {
            param($Name)
            if ($Name -eq 'shell:Downloads') {
                return [pscustomobject]@{ Self = [pscustomobject]@{ Path = $downloadsPath } }
            }
            return $null
        }.GetNewClosure()
        $fakeShell = [pscustomobject]@{}
        $fakeShell | Add-Member -MemberType ScriptMethod -Name Namespace -Value $namespaceMethod
        return $fakeShell
    }

    & (Get-Command Microsoft.PowerShell.Utility\New-Object) @RemainingArgs
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

function Copy-SourceFixture {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string[]]$FileNames
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-download-path-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    foreach ($fileName in $FileNames) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $fileName) -Destination $tempRoot -Force
    }

    return $tempRoot
}

function New-TestWorkspace {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-download-workspace-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestWorkspace {
    param([Parameter(Mandatory)][string]$Path)

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-AppStateRoot {
    param([Parameter(Mandatory)][string]$BasePath)

    $root = Join-Path $BasePath 'myTech.Today'
    return (Join-Path $root 'professional-video-downloader')
}

function Import-DownloaderHelpers {
    param([Parameter(Mandatory)][string]$ScriptPath)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "Failed to parse helper script: $($errors[0].Message)"
    }

    $functionNames = @(
        'Get-UserHomeDirectory',
        'Get-DownloadsFolder'
    )
    $definitions = [System.Collections.Generic.List[string]]::new()
    foreach ($functionName in $functionNames) {
        $node = $ast.FindAll({
                param($candidate)
                $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $functionName
            }, $true) | Select-Object -First 1
        if (-not $node) {
            throw "Missing helper definition: $functionName"
        }

        [void]$definitions.Add($node.Extent.Text)
    }

    $helperPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-download-helper-" + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $helperPath -Value ($definitions -join "`r`n`r`n") -Encoding Ascii
    return $helperPath
}

function New-TestYtDlpExecutable {
    param([Parameter(Mandatory)][string]$RootPath)

    $binPath = Join-Path $RootPath 'fake-yt-dlp-bin'
    New-Item -ItemType Directory -Path $binPath -Force | Out-Null
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $executablePath = Join-Path $binPath 'yt-dlp.cmd'
        $scriptText = @'
@echo off
if "%~1"=="--version" (
  >>"%PVD_FAKE_YTDLP_LOG%" echo %*
  echo %PVD_FAKE_YTDLP_VERSION%
  exit /b 0
)
>>"%PVD_FAKE_YTDLP_LOG%" echo %*
echo [download] Destination: %PVD_FAKE_DOWNLOAD%\fake.mp4
exit /b 0
'@
    }
    else {
        $executablePath = Join-Path $binPath 'yt-dlp'
        $scriptText = @'
#!/usr/bin/env pwsh
if ($args -contains '--version') {
    Add-Content -LiteralPath $env:PVD_FAKE_YTDLP_LOG -Value ($args -join ' ') -Encoding Ascii
    [Console]::WriteLine($env:PVD_FAKE_YTDLP_VERSION)
    exit 0
}
Add-Content -LiteralPath $env:PVD_FAKE_YTDLP_LOG -Value ($args -join ' ') -Encoding Ascii
[Console]::WriteLine('[download] Destination: {0}/fake.mp4' -f $env:PVD_FAKE_DOWNLOAD)
exit 0
'@
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($executablePath, ($scriptText -replace "`r`n", "`n"), $utf8NoBom)
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        & chmod +x $executablePath
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not mark the fake yt-dlp executable as executable.'
        }
    }

    return [pscustomobject]@{ BinPath = $binPath; Path = $executablePath }
}

function Invoke-MainScriptRun {
    param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ExpectedDownloadPath,
        [Parameter(Mandatory)][string]$Url,
        [string]$DownloadPathArg,
        [string]$HomePath
    )

    $hostExe = Get-PowerShellHost
    $scriptPath = (Join-Path $FixtureRoot 'professional-video-downloader.ps1').Replace("'", "''")
    $transcriptPath = Join-Path $FixtureRoot 'run.transcript.log'
    $stdoutPath = Join-Path $FixtureRoot 'run.stdout.log'
    $stderrPath = Join-Path $FixtureRoot 'run.stderr.log'
    $wrapperPath = Join-Path $FixtureRoot 'run-wrapper.ps1'
    $fakeYtDlp = New-TestYtDlpExecutable -RootPath $FixtureRoot
    $callLogPath = Join-Path $FixtureRoot 'yt-dlp-calls.log'

    $environmentLines = New-Object System.Collections.Generic.List[string]
    [void]$environmentLines.Add("`$env:PATH = '$($fakeYtDlp.BinPath.Replace("'", "''"))' + [System.IO.Path]::PathSeparator + `$env:PATH")
    [void]$environmentLines.Add("`$env:PVD_FAKE_YTDLP_VERSION = 'yt-dlp 2026.08.19'")
    [void]$environmentLines.Add("`$env:PVD_FAKE_YTDLP_LOG = '$($callLogPath.Replace("'", "''"))'")
    [void]$environmentLines.Add("`$env:PVD_FAKE_DOWNLOAD = '$($ExpectedDownloadPath.Replace("'", "''"))'")
    [void]$environmentLines.Add('Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue')
    [void]$environmentLines.Add("`$env:LOCALAPPDATA = '$($StateRoot.Replace("'", "''"))'")
    if ($HomePath) {
        [void]$environmentLines.Add("`$env:HOME = '$($HomePath.Replace("'", "''"))'")
        $xdgConfigPath = Join-Path $HomePath '.config'
        [void]$environmentLines.Add("`$env:XDG_CONFIG_HOME = '$($xdgConfigPath.Replace("'", "''"))'")
    }
    else {
        [void]$environmentLines.Add('Remove-Item Env:HOME -ErrorAction SilentlyContinue')
        [void]$environmentLines.Add('Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue')
    }

    $downloadArgText = ''
    if ($PSBoundParameters.ContainsKey('DownloadPathArg')) {
        $downloadArgText = "-DownloadPath '$($DownloadPathArg.Replace("'", "''"))'"
    }

    $wrapper = @'
__ENV__
Start-Transcript -LiteralPath '__TRANSCRIPT__' -Force | Out-Null
function global:New-Object {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$RemainingArgs)
    if ($RemainingArgs -contains '-ComObject') {
        throw 'COM lookup disabled by test harness.'
    }
    & (Get-Command Microsoft.PowerShell.Utility\New-Object) @RemainingArgs
}
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSec, [int]$MaximumRedirection, [switch]$UseBasicParsing)
    if ($Uri -eq 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest') {
        return [pscustomobject]@{ StatusCode = 200; Content = '{"tag_name":"2026.08.19","draft":false,"prerelease":false}' }
    }
    throw ("Unexpected network request: {0}" -f $Uri)
}
& '__SCRIPT__' -Url @('__URL__') __DOWNLOADARG__
$childExitCodeVar = Get-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue
if ($childExitCodeVar -and $null -ne $childExitCodeVar.Value) {
    exit $childExitCodeVar.Value
}
exit ([int](-not $?))
'@
    $wrapper = $wrapper.Replace('__ENV__', ($environmentLines -join "`r`n"))
    $wrapper = $wrapper.Replace('__TRANSCRIPT__', $transcriptPath.Replace("'", "''"))
    $wrapper = $wrapper.Replace('__SCRIPT__', $scriptPath)
    $wrapper = $wrapper.Replace('__URL__', $Url.Replace("'", "''"))
    $wrapper = $wrapper.Replace('__DOWNLOADARG__', $downloadArgText)

    Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding Ascii

    $startArgs = @{
        FilePath = $hostExe
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperPath)
        PassThru = $true
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError = $stderrPath
    }
    if (Test-CurrentHostIsWindows) {
        $startArgs.WindowStyle = 'Hidden'
    }

    $proc = Start-Process @startArgs
    $null = $proc.WaitForExit(90000)
    $proc.Refresh()
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw 'Main script smoke run timed out after 90 seconds.'
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

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $outputText
        Wrapper  = $wrapperPath
        Root     = $FixtureRoot
        StateRoot = $StateRoot
        ConfigPath = Join-Path (Get-AppStateRoot -BasePath $StateRoot) 'VideoDownloaderConfig.json'
        LogDir = Join-Path (Get-AppStateRoot -BasePath $StateRoot) 'logs'
    }
}

function Invoke-PlatformResolverScenarios {
    $workspace = New-TestWorkspace
    $homeRoot = Join-Path $workspace 'home'
    $configRoot = Join-Path $workspace 'config'
    New-Item -ItemType Directory -Path $homeRoot, $configRoot -Force | Out-Null

    $originalHome = [Environment]::GetEnvironmentVariable('HOME', 'Process')
    $originalUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
    $originalXdgConfigHome = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', 'Process')

    try {
        $env:HOME = $homeRoot
        $env:XDG_CONFIG_HOME = $configRoot
        Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue
        $script:TestIsWindowsPlatformOverride = $false
        $script:BlockComLookup = $true
        $script:FakeShellDownloadsPath = $null
        $script:MockXdgDownloads = $null
        $script:MockMacDownloads = $null

        $script:MockDownloadFolderPlatform = 'Linux'
        $result = Get-DownloadsFolder
        $expected = Join-Path $homeRoot 'Downloads'
        Assert-True ($result -eq $expected) "Linux resolver did not use the default HOME Downloads folder. Got '$result'."
        Assert-True (-not (Test-Path -LiteralPath $result)) 'Resolver should not create the Downloads folder before the main script ensures it exists.'

        $script:MockXdgDownloads = Join-Path $workspace 'localized downloads'
        $result = Get-DownloadsFolder
        Assert-True ($result -eq $script:MockXdgDownloads) "Linux resolver did not honor xdg-user-dir DOWNLOAD. Got '$result'."

        $script:MockXdgDownloads = $null
        New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $configRoot 'user-dirs.dirs') -Value 'XDG_DOWNLOAD_DIR="$HOME/Localized Downloads"' -Encoding Ascii
        $expected = "$homeRoot/Localized Downloads"
        $result = Get-DownloadsFolder
        Assert-True ($result -eq $expected) "Linux resolver did not honor XDG_DOWNLOAD_DIR in user-dirs.dirs. Got '$result'."

        $script:MockDownloadFolderPlatform = 'Darwin'
        $script:MockMacDownloads = Join-Path $workspace 'macOS default downloads'
        $result = Get-DownloadsFolder
        Assert-True ($result -eq $script:MockMacDownloads) "macOS resolver did not use the system Downloads folder. Got '$result'."

        $script:TestIsWindowsPlatformOverride = $true
        $script:BlockComLookup = $false
        $script:FakeShellDownloadsPath = Join-Path $workspace 'Windows known Downloads'
        $result = Get-DownloadsFolder
        Assert-True ($result -eq $script:FakeShellDownloadsPath) "Windows resolver did not use shell:Downloads. Got '$result'."
    }
    finally {
        [Environment]::SetEnvironmentVariable('HOME', $originalHome, 'Process')
        [Environment]::SetEnvironmentVariable('USERPROFILE', $originalUserProfile, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $originalXdgConfigHome, 'Process')
        $script:TestIsWindowsPlatformOverride = $null
        $script:BlockComLookup = $false
        $script:MockDownloadFolderPlatform = $null
        $script:MockXdgDownloads = $null
        $script:MockMacDownloads = $null
        $script:FakeShellDownloadsPath = $null
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-MainScriptSmokeScenario {
    $fixtureRoot = Copy-SourceFixture -SourceRoot $RootPath -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $homeRoot = Join-Path $fixtureRoot 'home'
    $stateRoot = Join-Path $fixtureRoot 'state'
    New-Item -ItemType Directory -Path $homeRoot -Force | Out-Null
    $expectedDownloadPath = Join-Path $homeRoot 'Downloads'

    try {
        $result = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $expectedDownloadPath -Url 'https://example.com/video' -HomePath $homeRoot

        Assert-True ($result.ExitCode -eq 0) "Main script smoke run failed with exit code $($result.ExitCode).`n$($result.Output)"
        Assert-True (Test-Path -LiteralPath $expectedDownloadPath -PathType Container) 'Main script did not create the user Downloads folder.'
        Assert-True ($result.Output -match [regex]::Escape("Download folder: $expectedDownloadPath")) 'Main script did not use the user Downloads folder on a run without -DownloadPath.'

        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'VideoDownloaderConfig.json'))) 'Main script still wrote config into the install tree.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'logs'))) 'Main script still wrote logs into the install tree.'
        Assert-True (-not (Test-Path -LiteralPath $result.ConfigPath)) 'Main script still persisted a download path preference.'
        Assert-True (Test-Path -LiteralPath $result.LogDir) 'Main script did not create the user state log directory.'
        Assert-True (Test-Path -LiteralPath (Join-Path $result.LogDir ("{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')))) 'Main script did not write a dated log file into the user state directory.'
    }
    finally {
        Remove-TestWorkspace -Path $fixtureRoot
    }
}

function Invoke-PathOverrideScenario {
    $fixtureRoot = Copy-SourceFixture -SourceRoot $RootPath -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $stateRoot = Join-Path $fixtureRoot 'state'
    $firstDownloadRoot = Join-Path $fixtureRoot 'first-downloads'
    $homeRoot = Join-Path $fixtureRoot 'home'
    New-Item -ItemType Directory -Path $firstDownloadRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $homeRoot -Force | Out-Null
    $configPath = Join-Path (Get-AppStateRoot -BasePath $stateRoot) 'VideoDownloaderConfig.json'

    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
        @{ DownloadPath = $firstDownloadRoot } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding Ascii

        $firstRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $firstDownloadRoot -Url 'https://example.com/video' -DownloadPathArg $firstDownloadRoot -HomePath $homeRoot
        Assert-True ($firstRun.ExitCode -eq 0) "Main script did not honor the explicit -DownloadPath override.`n$($firstRun.Output)"
        Assert-True ($firstRun.Output -match [regex]::Escape("Download folder: $firstDownloadRoot")) 'Main script did not honor the custom -DownloadPath.'
        Assert-True ((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).DownloadPath -eq $firstDownloadRoot) 'Script changed an existing saved path preference.'

        $expectedDefaultPath = Join-Path $homeRoot 'Downloads'
        $secondRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $expectedDefaultPath -Url 'https://example.com/video' -HomePath $homeRoot
        Assert-True ($secondRun.ExitCode -eq 0) "Main script did not return to the system Downloads folder on the next run.`n$($secondRun.Output)"
        Assert-True ($secondRun.Output -match [regex]::Escape("Download folder: $expectedDefaultPath")) 'A previously saved path overrode the current system Downloads folder.'
        Assert-True ($secondRun.Output -notmatch 'Using previously saved folder') 'Main script still read a saved download path preference.'
        Assert-True ((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).DownloadPath -eq $firstDownloadRoot) 'Script modified the legacy saved path preference.'
    }
    finally {
        Remove-TestWorkspace -Path $fixtureRoot
    }
}

function Invoke-DownloadPathCreationFailureScenario {
    $fixtureRoot = Copy-SourceFixture -SourceRoot $RootPath -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $homeRoot = Join-Path $fixtureRoot 'home-is-a-file'
    $stateRoot = Join-Path $fixtureRoot 'state'

    $expectedDownloadPath = Join-Path $homeRoot 'Downloads'

    try {
        New-Item -ItemType File -Path $homeRoot -Force | Out-Null
        $result = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $expectedDownloadPath -Url 'https://example.com/video' -HomePath $homeRoot

        Assert-True ($result.Output -match 'ERROR: Could not create download directory') 'Main script did not report the Downloads folder creation failure.'
        Assert-True ($result.Output -notmatch 'Starting high-quality download with yt-dlp') 'Main script started a download after failing to create the Downloads folder.'
        Assert-True (-not (Test-Path -LiteralPath $expectedDownloadPath)) 'Main script created an alternate target instead of failing.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $homeRoot 'Professional Video Downloader'))) 'Main script redirected downloads into its old app-specific fallback folder.'
    }
    finally {
        Remove-TestWorkspace -Path $fixtureRoot
    }
}

$helperPath = Import-DownloaderHelpers -ScriptPath (Join-Path $RootPath 'professional-video-downloader.ps1')
. $helperPath
try {
    Write-Step 'Platform resolvers use Windows, macOS, Linux XDG, and conventional Downloads locations'
    Invoke-PlatformResolverScenarios

    Write-Step 'Positive: -DownloadPath overrides the system folder for one run only'
    Invoke-PathOverrideScenario

    Write-Step 'Boundary: main script creates and uses the system Downloads folder'
    Invoke-MainScriptSmokeScenario

    Write-Step 'Negative: main script fails instead of redirecting when Downloads cannot be created'
    Invoke-DownloadPathCreationFailureScenario

    Write-Host '[PASS] Download-folder resolution validation passed.' -ForegroundColor Green
}
finally {
    if ($helperPath -and (Test-Path -LiteralPath $helperPath)) {
        Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
    }
}
