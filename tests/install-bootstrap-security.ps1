[CmdletBinding()]
param(
    [string]$RootPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $RootPath) {
    $RootPath = Split-Path -Parent $PSScriptRoot
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
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-bootstrap-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestWorkspace {
    param([Parameter(Mandatory)][string]$Path)

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-YtDlpShim {
    param([Parameter(Mandatory)][string]$Path)

    Set-Content -LiteralPath $Path -Encoding Ascii -Value @'
@echo off
if /I "%~1"=="--version" (
    echo yt-dlp 2026.08.19
    exit /b 0
)
echo yt-dlp 2026.08.19
exit /b 0
'@
}

$bootstrapPath = Join-Path $RootPath 'install-bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrapPath)) {
    throw "Missing bootstrap script: $bootstrapPath"
}

. $bootstrapPath

function Get-ShortcutProperties {
    param([Parameter(Mandatory)][string]$Path)

    $shell = New-Object -ComObject WScript.Shell
    return $shell.CreateShortcut($Path)
}

function Invoke-HostExecutableResolutionScenario {
    param(
        [Parameter(Mandatory)][string]$ScenarioName,
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)][string]$RootName,
        [Parameter(Mandatory)][string]$ExecutableName,
        [switch]$ExpectFailure
    )

    $workspace = New-TestWorkspace
    try {
        $psHomePath = Join-Path $workspace $RootName
        New-Item -ItemType Directory -Path $psHomePath -Force | Out-Null

        $expectedExecutablePath = Join-Path $psHomePath $ExecutableName
        if (-not $ExpectFailure) {
            Set-Content -LiteralPath $expectedExecutablePath -Encoding Ascii -Value ''
        }

        $resolved = $null
        $caught = $null
        try {
            $resolved = Get-PowerShellHostExecutable -Edition $Edition -PsHomePath $PsHomePath
        }
        catch {
            $caught = $_.Exception.Message
        }

        if ($ExpectFailure) {
            Assert-True ($null -ne $caught) "$ScenarioName should have failed closed."
            Assert-True ($caught -match 'PowerShell host executable not found') "$ScenarioName did not report the missing host path."
            return
        }

        Assert-True ($null -eq $caught) "$ScenarioName unexpectedly failed: $caught"
        Assert-True ($resolved -eq $expectedExecutablePath) "$ScenarioName resolved the wrong host executable."
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-ShortcutRuntimeScenario {
    param(
        [Parameter(Mandatory)][string]$ScenarioName,
        [Parameter(Mandatory)][string]$HostExecutablePath,
        [Parameter(Mandatory)][string]$RootName
    )

    $workspace = New-TestWorkspace
    try {
        $scriptRoot = Join-Path $workspace $RootName
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null

        $ps1Path = Join-Path $scriptRoot 'professional-video-downloader.ps1'
        $lnkPath = Join-Path $scriptRoot 'professional-video-downloader.lnk'
        Set-Content -LiteralPath $ps1Path -Encoding Ascii -Value '# shortcut test script'

        Set-DownloaderShortcut -LnkPath $lnkPath -Ps1Path $ps1Path -HostExecutablePath $HostExecutablePath

        $shortcut = Get-ShortcutProperties -Path $lnkPath
        Assert-True ($shortcut.TargetPath -eq $HostExecutablePath) "$ScenarioName shortcut target did not match the validated host."
        Assert-True ($shortcut.IconLocation -eq ($HostExecutablePath + ',0')) "$ScenarioName shortcut icon did not match the validated host."
        Assert-True ($shortcut.WorkingDirectory -eq $scriptRoot) "$ScenarioName shortcut working directory changed."
        Assert-True ($shortcut.Arguments -eq ('-NoExit -ExecutionPolicy Bypass -File "{0}"' -f $ps1Path)) "$ScenarioName shortcut arguments were not preserved."
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-ShortcutDefaultHostScenario {
    param(
        [Parameter(Mandatory)][string]$ScenarioName,
        [Parameter(Mandatory)][string]$DefaultHostPath,
        [Parameter(Mandatory)][string]$RootName
    )

    $workspace = New-TestWorkspace
    try {
        $scriptRoot = Join-Path $workspace $RootName
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null

        $ps1Path = Join-Path $scriptRoot 'professional-video-downloader.ps1'
        $lnkPath = Join-Path $scriptRoot 'professional-video-downloader.lnk'
        Set-Content -LiteralPath $ps1Path -Encoding Ascii -Value '# shortcut test script'

        function Get-PowerShellHostExecutable {
            return $DefaultHostPath
        }

        Set-DownloaderShortcut -LnkPath $lnkPath -Ps1Path $ps1Path

        $shortcut = Get-ShortcutProperties -Path $lnkPath
        Assert-True ($shortcut.TargetPath -eq $DefaultHostPath) "$ScenarioName shortcut target did not use the validated host by default."
        Assert-True ($shortcut.IconLocation -eq ($DefaultHostPath + ',0')) "$ScenarioName shortcut icon did not use the validated host by default."
        Assert-True ($shortcut.WorkingDirectory -eq $scriptRoot) "$ScenarioName shortcut working directory changed."
        Assert-True ($shortcut.Arguments -eq ('-NoExit -ExecutionPolicy Bypass -File "{0}"' -f $ps1Path)) "$ScenarioName shortcut arguments were not preserved."
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-InstallerLayoutScenario {
    $workspace = New-TestWorkspace
    try {
        $sourceRoot = $RootPath
        $installRoot = Join-Path $workspace 'Program Files\myTech.Today\professional-video-downloader'
        $shortcutDir = Join-Path $workspace 'ProgramData\Microsoft\Windows\Start Menu\Programs\myTech.Today'
        $hostExecutable = 'C:\Validated Host\pwsh.exe'
        $script:InstallerLaunchFilePath = $null
        $script:InstallerLaunchArgs = $null
        $script:InstallerLaunchWorkingDirectory = $null

        function Test-IsAdmin { return $true }
        function Get-PackageManager { return 'choco' }
        function Ensure-YtDlp { }
        function Ensure-Ffmpeg { }
        function Get-PowerShellHostExecutable {
            return $hostExecutable
        }
        function Start-Process {
            [CmdletBinding()]
            param(
                [string]$FilePath,
                [object]$ArgumentList,
                [string]$WorkingDirectory,
                [switch]$NoNewWindow,
                [switch]$PassThru,
                [switch]$Wait
            )

            $script:InstallerLaunchFilePath = $FilePath
            $script:InstallerLaunchArgs = $ArgumentList
            $script:InstallerLaunchWorkingDirectory = $WorkingDirectory
            return [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Invoke-Installer -SourceDir $sourceRoot -InstallRoot $installRoot -ShortcutDir $shortcutDir -Forwarded @('-AudioOnly')

        $shortcutPath = Join-Path $shortcutDir 'professional-video-downloader.lnk'
        $installedPs1 = Join-Path $installRoot 'professional-video-downloader.ps1'
        $installedVersion = Join-Path $installRoot 'VERSION'

        Assert-True ($result -eq 0) 'Installer layout scenario did not return success.'
        Assert-True (Test-Path -LiteralPath $installedPs1) 'Runtime script was not copied into the requested install root.'
        Assert-True (Test-Path -LiteralPath $installedVersion) 'VERSION was not copied into the requested install root.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot 'install-bootstrap.ps1'))) 'Bootstrap script should not be copied into the runtime install root.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot 'install.bat'))) 'Batch launcher should not be copied into the runtime install root.'
        Assert-True (Test-Path -LiteralPath $shortcutPath) 'Shortcut was not created in the machine-wide Start Menu path.'
        Assert-True ($script:InstallerLaunchFilePath -eq $hostExecutable) 'Installer launched the wrong PowerShell host.'
        Assert-True ($script:InstallerLaunchWorkingDirectory -eq $installRoot) 'Installer did not launch from the installed runtime root.'
        $expectedLaunchArguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installedPs1,'-AudioOnly')
        Assert-True ($script:InstallerLaunchArgs -is [string]) 'Installer did not pass a single serialized command-line string.'
        Assert-True ($script:InstallerLaunchArgs -eq (ConvertTo-WindowsCommandLine -Arguments $expectedLaunchArguments)) 'Installer did not preserve the exact downloader launch arguments.'

        $shortcut = Get-ShortcutProperties -Path $shortcutPath
        Assert-True ($shortcut.TargetPath -eq $hostExecutable) 'Shortcut target did not use the validated host.'
        Assert-True ($shortcut.IconLocation -eq ($hostExecutable + ',0')) 'Shortcut icon did not use the validated host.'
        Assert-True ($shortcut.WorkingDirectory -eq $installRoot) 'Shortcut working directory did not point at the installed runtime root.'
        Assert-True ($shortcut.Arguments -eq ('-NoExit -ExecutionPolicy Bypass -File "{0}"' -f $installedPs1)) 'Shortcut arguments did not launch the installed downloader script.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
        Remove-Item function:\Test-IsAdmin -ErrorAction SilentlyContinue
        Remove-Item function:\Get-PackageManager -ErrorAction SilentlyContinue
        Remove-Item function:\Ensure-YtDlp -ErrorAction SilentlyContinue
        Remove-Item function:\Ensure-Ffmpeg -ErrorAction SilentlyContinue
        Remove-Item function:\Get-PowerShellHostExecutable -ErrorAction SilentlyContinue
        Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
    }
}

function Get-TestWindowsPowerShellHosts {
    $hostPaths = @()

    $pwshCommand = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($pwshCommand) {
        $hostPaths += [pscustomobject]@{
            Name = 'PowerShell 7'
            Path = $pwshCommand.Source
        }
    }

    $windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShellPath) {
        $hostPaths += [pscustomobject]@{
            Name = 'Windows PowerShell 5.1'
            Path = $windowsPowerShellPath
        }
    }

    Assert-True (@($hostPaths | Where-Object { $_.Name -eq 'PowerShell 7' }).Count -eq 1) 'PowerShell 7 was not available for argument round-trip validation.'
    Assert-True (@($hostPaths | Where-Object { $_.Name -eq 'Windows PowerShell 5.1' }).Count -eq 1) 'Windows PowerShell 5.1 was not available for argument round-trip validation.'
    return $hostPaths
}

function Assert-ArgumentArrayEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Actual,
        [Parameter(Mandatory)][string]$ScenarioName
    )

    Assert-True ($Actual.Count -eq $Expected.Count) "$ScenarioName received $($Actual.Count) arguments; expected $($Expected.Count)."
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-True ($Actual[$index] -ceq $Expected[$index]) "$ScenarioName argument $index did not round-trip exactly."
    }
}

function Invoke-ElevationArgumentRoundTripScenario {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$HostPath
    )

    $workspace = New-TestWorkspace
    $previousCapturePath = $env:PVD_BOOTSTRAP_ARG_CAPTURE
    try {
        $scriptRoot = Join-Path $workspace 'Setup Source With Spaces'
        $receiverDir = Join-Path $workspace 'Elevation Receiver With Spaces'
        $inputDir = Join-Path $workspace 'Input Files With Spaces'
        $installRoot = Join-Path $workspace 'Program Files\myTech.Today\professional-video-downloader'
        $shortcutDir = Join-Path $workspace 'ProgramData\Microsoft\Windows\Start Menu\Programs\myTech.Today'
        New-Item -ItemType Directory -Path $scriptRoot,$receiverDir,$inputDir -Force | Out-Null

        $receiverScript = Join-Path $receiverDir 'capture setup arguments.ps1'
        $capturePath = Join-Path $workspace 'elevation-child-arguments.json'
        $stdoutPath = Join-Path $workspace 'elevation-child.stdout.txt'
        $stderrPath = Join-Path $workspace 'elevation-child.stderr.txt'
        $inputPath = Join-Path $inputDir 'urls list.txt'
        Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'https://example.invalid/watch?v=one&list=two'
        Set-Content -LiteralPath $receiverScript -Encoding UTF8 -Value @'
param(
    [string]$ScriptDir,
    [string]$InstallRoot,
    [string]$ShortcutDir,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Forwarded
)
$received = [pscustomobject]@{
    ScriptDir = $ScriptDir
    InstallRoot = $InstallRoot
    ShortcutDir = $ShortcutDir
    Forwarded = @($Forwarded)
}
Set-Content -LiteralPath $env:PVD_BOOTSTRAP_ARG_CAPTURE -Value (ConvertTo-Json -InputObject $received -Depth 5 -Compress)
exit 0
'@

        $forwarded = @(
            '-InputFile',
            $inputPath,
            '-Url',
            'https://example.invalid/watch?v=one&list=two',
            '-AudioOnly',
            '-QuotedValue',
            'value with "quotes" and trailing\',
            '-EmptyValue',
            ''
        )
        $elevationParameters = @{
            ScriptPath = $receiverScript
            ScriptDir = $scriptRoot
            InstallRoot = $installRoot
            ShortcutDir = $shortcutDir
            Forwarded = $forwarded
        }
        $elevationArguments = New-SelfElevationArgumentList @elevationParameters
        $encodedArguments = ConvertTo-WindowsCommandLine -Arguments $elevationArguments

        $env:PVD_BOOTSTRAP_ARG_CAPTURE = $capturePath
        $process = Start-Process -FilePath $HostPath -ArgumentList $encodedArguments -PassThru -Wait -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $childStdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
        $childStderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        Assert-True (Test-Path -LiteralPath $capturePath) "$HostName elevation argument child did not write its received arguments. Exit=$($process.ExitCode); stdout=$childStdout; stderr=$childStderr"
        Assert-True ($process.ExitCode -eq 0) "$HostName elevation argument child exited with $($process.ExitCode)."

        $received = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
        Assert-True ($received.ScriptDir -ceq $scriptRoot) "$HostName elevation split or changed ScriptDir."
        Assert-True ($received.InstallRoot -ceq $installRoot) "$HostName elevation split or changed InstallRoot."
        Assert-True ($received.ShortcutDir -ceq $shortcutDir) "$HostName elevation split or changed ShortcutDir."
        Assert-ArgumentArrayEqual -Expected $forwarded -Actual @($received.Forwarded) -ScenarioName "$HostName elevation"
    }
    finally {
        if ($null -eq $previousCapturePath) {
            Remove-Item Env:\PVD_BOOTSTRAP_ARG_CAPTURE -ErrorAction SilentlyContinue
        }
        else {
            $env:PVD_BOOTSTRAP_ARG_CAPTURE = $previousCapturePath
        }
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-FinalLaunchArgumentRoundTripScenario {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$HostPath,
        [switch]$NoSpaceCompatibility
    )

    $workspace = New-TestWorkspace
    $previousCapturePath = $env:PVD_BOOTSTRAP_ARG_CAPTURE
    try {
        if ($NoSpaceCompatibility) {
            $scenarioName = "$HostName no-space compatibility"
            $sourceRoot = Join-Path $workspace 'SourceCheckout'
            $installRoot = Join-Path $workspace 'InstallRoot'
            $shortcutDir = Join-Path $workspace 'ShortcutDir'
            $inputDir = Join-Path $workspace 'InputFiles'
        }
        else {
            $scenarioName = "$HostName final launch"
            $sourceRoot = Join-Path $workspace 'Source Checkout With Spaces'
            $installRoot = Join-Path $workspace 'Program Files\myTech.Today\professional-video-downloader'
            $shortcutDir = Join-Path $workspace 'ProgramData\Microsoft\Windows\Start Menu\Programs\myTech.Today'
            $inputDir = Join-Path $workspace 'Input Files With Spaces'
        }
        New-Item -ItemType Directory -Path $sourceRoot,$inputDir -Force | Out-Null

        $sourceScript = Join-Path $sourceRoot 'professional-video-downloader.ps1'
        $capturePath = Join-Path $workspace 'final-child-arguments.json'
        $inputPath = Join-Path $inputDir 'urls list.txt'
        Set-Content -LiteralPath (Join-Path $sourceRoot 'VERSION') -Encoding Ascii -Value '1.0.0'
        Set-Content -LiteralPath $sourceScript -Encoding UTF8 -Value @'
$received = [pscustomobject]@{
    Arguments = @($args)
    WorkingDirectory = (Get-Location).Path
}
Set-Content -LiteralPath $env:PVD_BOOTSTRAP_ARG_CAPTURE -Value (ConvertTo-Json -InputObject $received -Depth 5 -Compress)
exit 23
'@

        if ($NoSpaceCompatibility) {
            $forwarded = @('-AudioOnly')
        }
        else {
            Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'https://example.invalid/watch?v=one&list=two'
            $forwarded = @(
                '-InputFile',
                $inputPath,
                '-Url',
                'https://example.invalid/watch?v=one&list=two',
                '-AudioOnly',
                '-QuotedValue',
                'value with "quotes" and trailing\',
                '-EmptyValue',
                ''
            )
        }
        $env:PVD_BOOTSTRAP_ARG_CAPTURE = $capturePath

        function Test-IsAdmin { return $true }
        function Get-PackageManager { return 'choco' }
        function Ensure-YtDlp { }
        function Ensure-Ffmpeg { }
        function Test-Command { return $false }
        function Get-PowerShellHostExecutable { return $HostPath }

        $result = Invoke-Installer -SourceDir $sourceRoot -InstallRoot $installRoot -ShortcutDir $shortcutDir -Forwarded $forwarded
        Assert-True ($result -eq 23) "$scenarioName did not return the child's exit code."
        Assert-True (Test-Path -LiteralPath $capturePath) "$scenarioName child did not write its received arguments."

        $received = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
        Assert-ArgumentArrayEqual -Expected $forwarded -Actual @($received.Arguments) -ScenarioName $scenarioName
        Assert-True ($received.WorkingDirectory -ceq $installRoot) "$scenarioName changed the installed working directory."

        $shortcutPath = Join-Path $shortcutDir 'professional-video-downloader.lnk'
        $shortcut = Get-ShortcutProperties -Path $shortcutPath
        Assert-True ($shortcut.TargetPath -eq $HostPath) "$scenarioName changed the shortcut target."
        Assert-True ($shortcut.IconLocation -eq ($HostPath + ',0')) "$scenarioName changed the shortcut icon."
        Assert-True ($shortcut.WorkingDirectory -eq $installRoot) "$scenarioName changed the shortcut working directory."
        Assert-True ($shortcut.Arguments -eq ('-NoExit -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $installRoot 'professional-video-downloader.ps1'))) "$scenarioName changed shortcut arguments."
    }
    finally {
        if ($null -eq $previousCapturePath) {
            Remove-Item Env:\PVD_BOOTSTRAP_ARG_CAPTURE -ErrorAction SilentlyContinue
        }
        else {
            $env:PVD_BOOTSTRAP_ARG_CAPTURE = $previousCapturePath
        }
        Remove-Item function:\Test-IsAdmin -ErrorAction SilentlyContinue
        Remove-Item function:\Get-PackageManager -ErrorAction SilentlyContinue
        Remove-Item function:\Ensure-YtDlp -ErrorAction SilentlyContinue
        Remove-Item function:\Ensure-Ffmpeg -ErrorAction SilentlyContinue
        Remove-Item function:\Test-Command -ErrorAction SilentlyContinue
        Remove-Item function:\Get-PowerShellHostExecutable -ErrorAction SilentlyContinue
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-LaunchFailureScenario {
    $workspace = New-TestWorkspace
    $sourceRoot = Join-Path $workspace 'Source Checkout With Spaces'
    $installRoot = Join-Path $workspace 'Program Files\myTech.Today\professional-video-downloader'
    $shortcutDir = Join-Path $workspace 'ProgramData\Microsoft\Windows\Start Menu\Programs\myTech.Today'
    New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sourceRoot 'VERSION') -Encoding Ascii -Value '1.0.0'
    Set-Content -LiteralPath (Join-Path $sourceRoot 'professional-video-downloader.ps1') -Encoding Ascii -Value '# launch failure fixture'
    $script:LaunchFailureSecretUrl = 'https://example.invalid/private?token=do-not-log'
    $script:LaunchFailureStartProcessCalled = $false
    $script:CapturedInstallerErrors = @()

    function Test-IsAdmin { return $true }
    function Get-PackageManager { return 'choco' }
    function Ensure-YtDlp { }
    function Ensure-Ffmpeg { }
    function Test-Command { return $false }
    function Get-PowerShellHostExecutable { return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
    function Write-Err2 {
        param([string]$Message)
        $script:CapturedInstallerErrors += $Message
    }
    function Start-Process {
        [CmdletBinding()]
        param([string]$FilePath, [object]$ArgumentList, [string]$WorkingDirectory, [switch]$NoNewWindow, [switch]$PassThru, [switch]$Wait)
        $script:LaunchFailureStartProcessCalled = $true
        throw "Child launch failed for $script:LaunchFailureSecretUrl"
    }

    $result = Invoke-Installer -SourceDir $sourceRoot -InstallRoot $installRoot -ShortcutDir $shortcutDir -Forwarded @('-Url', $script:LaunchFailureSecretUrl)

    try {
        $shortcutPath = Join-Path $shortcutDir 'professional-video-downloader.lnk'
        $shortcut = Get-ShortcutProperties -Path $shortcutPath
        $launchOutput = $script:CapturedInstallerErrors -join [Environment]::NewLine
        Assert-True ($result -ne 0) 'A child launch failure incorrectly returned success.'
        Assert-True ($script:LaunchFailureStartProcessCalled) 'The child launch failure scenario did not invoke its Start-Process failure.'
        Assert-True ($launchOutput -match [regex]::Escape('Setup completed, but the downloader could not be launched. Open the installed shortcut or rerun setup with the same options.')) 'The requested launch failure message was not printed.'
        Assert-True ($launchOutput -notmatch [regex]::Escape($script:LaunchFailureSecretUrl)) 'The launch failure diagnostic exposed a forwarded URL.'
        Assert-True (Test-Path -LiteralPath $shortcutPath) 'The launch failure removed the installed shortcut.'
        Assert-True ($shortcut.WorkingDirectory -eq $installRoot) 'The launch failure left an invalid shortcut working directory.'
    }
    finally {
        Remove-Item function:\Test-IsAdmin -ErrorAction SilentlyContinue
        Remove-Item function:\Get-PackageManager -ErrorAction SilentlyContinue
        Remove-Item function:\Ensure-YtDlp -ErrorAction SilentlyContinue
        Remove-Item function:\Ensure-Ffmpeg -ErrorAction SilentlyContinue
        Remove-Item function:\Test-Command -ErrorAction SilentlyContinue
        Remove-Item function:\Get-PowerShellHostExecutable -ErrorAction SilentlyContinue
        Remove-Item function:\Write-Err2 -ErrorAction SilentlyContinue
        Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-PositiveScenario {
    $workspace = New-TestWorkspace
    $fakeBin = Join-Path $workspace 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeBin 'choco.cmd') -Encoding Ascii -Value @'
@echo off
echo choco stub %*
exit /b 0
'@

    $transcriptPath = Join-Path $workspace 'positive.transcript.log'
    $originalPath = $env:Path
    $script:BootstrapInstalled = $false
    $script:UpdateSessionPathCalled = $false
    $script:DownloadUri = $null
    $script:DownloadOutFile = $null
    $script:HashCheckedFile = $null
    $script:StartProcessFile = $null
    $script:StartProcessArgs = $null

    function Test-IsAdmin { return $true }
    function Set-ExecutionPolicy {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$Args
        )
    }
    function Get-PackageManager {
        if ($script:BootstrapInstalled) { return 'choco' }
        return $null
    }
    function Invoke-WebRequest {
        [CmdletBinding()]
        param([string]$Uri, [string]$OutFile)

        $script:DownloadUri = $Uri
        $script:DownloadOutFile = $OutFile
        Set-Content -LiteralPath $OutFile -Encoding Ascii -Value 'fake-msi'
    }
    function Get-FileHash {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Algorithm)

        $script:HashCheckedFile = $LiteralPath
        return [pscustomobject]@{ Hash = $ChocolateyBootstrapSha256.ToUpperInvariant() }
    }
    function Start-Process {
        [CmdletBinding()]
        param([string]$FilePath, [object]$ArgumentList, [switch]$PassThru, [switch]$Wait)

        $script:StartProcessFile = $FilePath
        $script:StartProcessArgs = @($ArgumentList)
        $script:BootstrapInstalled = $true
        return [pscustomobject]@{ ExitCode = 0 }
    }
    function Update-SessionPath {
        $script:UpdateSessionPathCalled = $true
        $env:Path = "$fakeBin;$env:Path"
    }

    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    try {
        $result = Install-Package -WingetId 'Chocolatey.Chocolatey' -ChocoId 'dummy-package' -DisplayName 'Dummy package'
    }
    finally {
        Stop-Transcript | Out-Null
    }

    $transcript = Get-FileText -Path $transcriptPath
    try {
        Assert-True ($result -eq $true) 'Install-Package did not report success on the verified bootstrap path.'
        Assert-True ($script:UpdateSessionPathCalled) 'Update-SessionPath was not called after Chocolatey bootstrap.'
        Assert-True ($script:DownloadUri -eq $ChocolateyBootstrapSourceUrl) 'Chocolatey bootstrap download URL did not match the pinned source.'
        Assert-True ($script:HashCheckedFile -eq $script:DownloadOutFile) 'Bootstrap hash was not checked against the downloaded MSI.'
        Assert-True (Test-Command 'choco') 'Chocolatey was not visible in PATH after bootstrap.'
        Assert-True ($transcript -match [regex]::Escape($ChocolateyBootstrapSourceUrl)) 'Bootstrap source was not visible in the transcript.'
        Assert-True ($transcript -match [regex]::Escape($ChocolateyBootstrapSha256)) 'Bootstrap hash was not visible in the transcript.'
        Assert-True ($transcript -match 'Chocolatey MSI verified:') 'Verification step was not logged.'
        Assert-True ($transcript -match 'choco stub install dummy-package -y --no-progress') 'Chocolatey package install did not reach the PATH-refreshed choco shim.'
    }
    finally {
        $env:Path = $originalPath
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-HashMismatchScenario {
    $workspace = New-TestWorkspace
    $transcriptPath = Join-Path $workspace 'hash-mismatch.transcript.log'
    $script:StartProcessCalled = $false
    $script:UpdateSessionPathCalled = $false

    function Test-IsAdmin { return $true }
    function Set-ExecutionPolicy {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$Args
        )
    }
    function Invoke-WebRequest {
        [CmdletBinding()]
        param([string]$Uri, [string]$OutFile)

        Set-Content -LiteralPath $OutFile -Encoding Ascii -Value 'fake-msi'
    }
    function Get-FileHash {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Algorithm)

        return [pscustomobject]@{ Hash = ('0' * 64) }
    }
    function Start-Process {
        $script:StartProcessCalled = $true
        throw 'Start-Process should not be called when bootstrap verification fails.'
    }
    function Update-SessionPath {
        $script:UpdateSessionPathCalled = $true
        throw 'Update-SessionPath should not be called when bootstrap verification fails.'
    }

    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $caught = $null
    try {
        Install-Chocolatey
    }
    catch {
        $caught = $_.Exception.Message
    }
    finally {
        Stop-Transcript | Out-Null
    }

    $transcript = Get-FileText -Path $transcriptPath
    try {
        Assert-True ($caught -match 'Chocolatey bootstrap verification failed') 'Hash mismatch did not fail with the verification message.'
        Assert-True ($caught -match 'Expected SHA256') 'Hash mismatch message did not mention the expected checksum.'
        Assert-True (-not $script:StartProcessCalled) 'Chocolatey installer was launched even though the checksum did not match.'
        Assert-True (-not $script:UpdateSessionPathCalled) 'PATH refresh ran even though the checksum did not match.'
        Assert-True ($transcript -match [regex]::Escape($ChocolateyBootstrapSourceUrl)) 'Bootstrap source was not visible before the checksum failure.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-OfflineScenario {
    $workspace = New-TestWorkspace
    $transcriptPath = Join-Path $workspace 'offline.transcript.log'
    $script:StartProcessCalled = $false
    $script:HashChecked = $false

    function Test-IsAdmin { return $true }
    function Set-ExecutionPolicy {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$Args
        )
    }
    function Invoke-WebRequest {
        [CmdletBinding()]
        param([string]$Uri, [string]$OutFile)

        throw 'Offline test: network unavailable.'
    }
    function Get-FileHash {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Algorithm)

        $script:HashChecked = $true
        throw 'Get-FileHash should not be called when the download fails.'
    }
    function Start-Process {
        $script:StartProcessCalled = $true
        throw 'Start-Process should not be called when the download fails.'
    }
    function Update-SessionPath {
        throw 'Update-SessionPath should not be called when the download fails.'
    }

    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $caught = $null
    try {
        Install-Chocolatey
    }
    catch {
        $caught = $_.Exception.Message
    }
    finally {
        Stop-Transcript | Out-Null
    }

    $transcript = Get-FileText -Path $transcriptPath
    try {
        Assert-True ($caught -match 'Chocolatey bootstrap download failed') 'Offline bootstrap did not fail with the download message.'
        Assert-True ($caught -match [regex]::Escape($ChocolateyBootstrapSourceUrl)) 'Offline bootstrap failure did not name the pinned source.'
        Assert-True (-not $script:StartProcessCalled) 'Installer launched even though the download failed.'
        Assert-True (-not $script:HashChecked) 'Checksum validation ran even though the download failed.'
        Assert-True ($transcript -match 'Chocolatey bootstrap source:') 'Bootstrap source was not visible in the transcript.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-IdempotentScenario {
    $workspace = New-TestWorkspace
    $fakeBin = Join-Path $workspace 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeBin 'choco.cmd') -Encoding Ascii -Value @'
@echo off
echo choco shim %*
exit /b 0
'@

    $transcriptPath = Join-Path $workspace 'idempotent.transcript.log'
    $originalPath = $env:Path
    $env:Path = "$fakeBin;$env:Path"

    function Test-IsAdmin { return $true }
    function Set-ExecutionPolicy {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$Args
        )
    }
    function Get-PackageManager { return 'choco' }
    function Install-Chocolatey {
        throw 'Chocolatey bootstrap should not run when choco is already available.'
    }
    function Invoke-WebRequest {
        throw 'Download should not run when choco is already available.'
    }
    function Get-FileHash {
        throw 'Hash verification should not run when choco is already available.'
    }
    function Start-Process {
        throw 'Process launch should not run when choco is already available.'
    }
    function Update-SessionPath {
        $env:Path = "$fakeBin;$env:Path"
    }

    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    try {
        $result = Install-Package -WingetId 'Chocolatey.Chocolatey' -ChocoId 'dummy-package' -DisplayName 'Dummy package'
    }
    finally {
        Stop-Transcript | Out-Null
    }

    $transcript = Get-FileText -Path $transcriptPath
    try {
        Assert-True ($result -eq $true) 'Install-Package did not succeed when Chocolatey was already available.'
        Assert-True ($transcript -notmatch 'Installing Chocolatey from verified MSI') 'Bootstrap ran even though Chocolatey was already available.'
        Assert-True ($transcript -match 'choco shim install dummy-package -y --no-progress') 'Existing Chocolatey PATH entry did not remain usable.'
    }
    finally {
        $env:Path = $originalPath
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-YtDlpVersionGateScenario {
    param(
        [Parameter(Mandatory)][string]$VersionText,
        [Parameter(Mandatory)][bool]$ShouldFail,
        [Parameter(Mandatory)][string]$ScenarioName
    )

    $workspace = New-TestWorkspace
    $transcriptPath = Join-Path $workspace 'yt-dlp-version-gate.transcript.log'
    $script:VersionGateCaptureCount = 0
    $script:VersionGateInstallCalled = $false

    function Test-IsAdmin { return $true }
    function Set-ExecutionPolicy {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$Args
        )
    }
    function Test-Command {
        param([string]$Name)

        return ($Name -eq 'yt-dlp')
    }
    function Invoke-Capture {
        [CmdletBinding()]
        param([string]$Exe, [string[]]$ArgList)

        $script:VersionGateCaptureCount++
        Assert-True ($Exe -eq 'yt-dlp') 'Version gate test unexpectedly queried a different executable.'
        Assert-True (($ArgList -join ' ') -eq '--version') 'Version gate test should only capture yt-dlp --version.'
        return $VersionText
    }
    function Install-Package {
        $script:VersionGateInstallCalled = $true
        throw 'Install-Package should not run during yt-dlp version gate tests.'
    }
    function Update-SessionPath {
        throw 'Update-SessionPath should not run during yt-dlp version gate tests.'
    }

    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $caught = $null
    try {
        $null = Ensure-YtDlp
    }
    catch {
        $caught = $_.Exception.Message
    }
    finally {
        Stop-Transcript | Out-Null
    }

    $transcript = Get-FileText -Path $transcriptPath
    try {
        Assert-True (-not $script:VersionGateInstallCalled) "$ScenarioName unexpectedly reached the install path."
        Assert-True ($script:VersionGateCaptureCount -eq 1) "$ScenarioName should capture the yt-dlp version exactly once."
        if ($ShouldFail) {
            Assert-True ($null -ne $caught) "$ScenarioName should have failed closed."
            Assert-True ($caught -match 'too old|Unable to determine') "$ScenarioName did not surface a version-gate failure."
            Assert-True ($caught -match [regex]::Escape("run 'yt-dlp -U' for standalone release binaries")) "$ScenarioName did not include the upgrade path."
        }
        else {
            Assert-True ($null -eq $caught) "$ScenarioName should have succeeded with a supported yt-dlp version."
            Assert-True ($transcript -match [regex]::Escape("yt-dlp already installed: $VersionText")) "$ScenarioName did not log the accepted yt-dlp version."
        }
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-PipFallbackScenario {
    $workspace = New-TestWorkspace
    $fakeBin = Join-Path $workspace 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null

    $transcriptPath = Join-Path $workspace 'pip-fallback.transcript.log'
    $originalPath = $env:Path
    $script:UpdateSessionPathCalled = $false
    $script:YtDlpInstalled = $false
    $script:PythonVersionChecks = 0
    $script:PythonPipChecks = 0
    $script:PythonInstallCalls = 0

    function Test-IsAdmin { return $true }
    function Set-ExecutionPolicy {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$Args
        )
    }
    function Test-Command {
        param([string]$Name)

        switch ($Name) {
            'python' { return $true }
            'py'     { return $false }
            'yt-dlp' { return $script:YtDlpInstalled }
            default  { return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue) }
        }
    }
    function Install-Package {
        [CmdletBinding()]
        param(
            [string]$WingetId,
            [string]$ChocoId,
            [string]$DisplayName
        )

        return $false
    }
    function python {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

        $joined = $Args -join ' '
        switch ($joined) {
            '--version' {
                $script:PythonVersionChecks++
                $global:LASTEXITCODE = 0
                Write-Output 'Python 3.12.8'
                return
            }
            '-m pip --version' {
                $script:PythonPipChecks++
                $global:LASTEXITCODE = 0
                Write-Output 'pip 24.0 from C:\Users\tester\AppData\Roaming\Python\Python312\site-packages\pip (python 3.12)'
                return
            }
            '-m pip install --user --upgrade yt-dlp' {
                $script:PythonInstallCalls++
                $global:LASTEXITCODE = 0
                New-YtDlpShim -Path (Join-Path $fakeBin 'yt-dlp.cmd')
                $script:YtDlpInstalled = $true
                Write-Output 'Successfully installed yt-dlp'
                return
            }
            default {
                $global:LASTEXITCODE = 1
                throw "Unexpected python invocation: $joined"
            }
        }
    }
    function Update-SessionPath {
        $script:UpdateSessionPathCalled = $true
        $env:Path = "$fakeBin;$env:Path"
    }

    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $caught = $null
    try {
        Ensure-YtDlp
    }
    catch {
        $caught = $_.Exception.Message
    }
    finally {
        Stop-Transcript | Out-Null
    }

    $transcript = Get-FileText -Path $transcriptPath
    try {
        Assert-True (-not $caught) "Python fallback scenario failed: $caught"
        Assert-True ($script:UpdateSessionPathCalled) 'PATH refresh was not called after python -m pip install.'
        Assert-True ($script:PythonVersionChecks -eq 1) 'Python version was not checked before the fallback.'
        Assert-True ($script:PythonPipChecks -eq 1) 'python -m pip was not verified before installing yt-dlp.'
        Assert-True ($script:PythonInstallCalls -eq 1) 'python -m pip install was not used.'
        Assert-True ($transcript -match 'Python module runner verified: python -m pip') 'Runner verification was not logged.'
        Assert-True ($transcript -match 'Falling back to python -m pip install --user --upgrade yt-dlp') 'Fallback log did not name python -m pip.'
        Assert-True ($transcript -match 'yt-dlp installed via python -m pip: yt-dlp 2026.08.19') 'Success log did not name python -m pip.'
        Assert-True ((Get-Command 'yt-dlp' -ErrorAction SilentlyContinue) -ne $null) 'yt-dlp shim was not resolvable after PATH refresh.'
    }
    finally {
        $env:Path = $originalPath
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-PipDualRunnerScenario {
    $workspace = New-TestWorkspace
    $fakeBin = Join-Path $workspace 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null

    $transcriptPath = Join-Path $workspace 'pip-dual-runner.transcript.log'
    $originalPath = $env:Path
    $script:UpdateSessionPathCalled = $false
    $script:YtDlpInstalled = $false
    $script:PythonVersionChecks = 0
    $script:PythonPipChecks = 0
    $script:PyVersionChecks = 0
    $script:PyPipChecks = 0
    $script:PythonInstallCalls = 0

    function Test-IsAdmin { return $true }
    function Set-ExecutionPolicy {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$Args
        )
    }
    function Test-Command {
        param([string]$Name)

        switch ($Name) {
            'python' { return $true }
            'py'     { return $true }
            'yt-dlp' { return $script:YtDlpInstalled }
            default  { return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue) }
        }
    }
    function Install-Package {
        [CmdletBinding()]
        param(
            [string]$WingetId,
            [string]$ChocoId,
            [string]$DisplayName
        )

        return $false
    }
    function python {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

        $joined = $Args -join ' '
        switch ($joined) {
            '--version' {
                $script:PythonVersionChecks++
                $global:LASTEXITCODE = 0
                Write-Output 'Python 3.12.8'
                return
            }
            '-m pip --version' {
                $script:PythonPipChecks++
                $global:LASTEXITCODE = 0
                Write-Output 'pip 24.0 from C:\Users\tester\AppData\Roaming\Python\Python312\site-packages\pip (python 3.12)'
                return
            }
            '-m pip install --user --upgrade yt-dlp' {
                $script:PythonInstallCalls++
                $global:LASTEXITCODE = 0
                New-YtDlpShim -Path (Join-Path $fakeBin 'yt-dlp.cmd')
                $script:YtDlpInstalled = $true
                Write-Output 'Successfully installed yt-dlp'
                return
            }
            default {
                $global:LASTEXITCODE = 1
                throw "Unexpected python invocation: $joined"
            }
        }
    }
    function py {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

        $joined = $Args -join ' '
        switch ($joined) {
            '--version' {
                $script:PyVersionChecks++
                $global:LASTEXITCODE = 0
                Write-Output 'Python 3.12.8'
                return
            }
            '-m pip --version' {
                $script:PyPipChecks++
                $global:LASTEXITCODE = 0
                Write-Output 'pip 24.0 from C:\Users\tester\AppData\Roaming\Python\Python312\site-packages\pip (python 3.12)'
                return
            }
            default {
                $global:LASTEXITCODE = 1
                throw "Unexpected py invocation: $joined"
            }
        }
    }
    function Update-SessionPath {
        $script:UpdateSessionPathCalled = $true
        $env:Path = "$fakeBin;$env:Path"
    }

    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $caught = $null
    try {
        Ensure-YtDlp
    }
    catch {
        $caught = $_.Exception.Message
    }
    finally {
        Stop-Transcript | Out-Null
    }

    $transcript = Get-FileText -Path $transcriptPath
    try {
        Assert-True (-not $caught) "Dual-runner fallback scenario failed: $caught"
        Assert-True ($script:UpdateSessionPathCalled) 'PATH refresh was not called after the fallback install.'
        Assert-True ($script:PythonVersionChecks -eq 1) 'Python version was not checked before the fallback.'
        Assert-True ($script:PythonPipChecks -eq 1) 'python -m pip was not verified before installing yt-dlp.'
        Assert-True ($script:PyVersionChecks -eq 0) 'py should not have been consulted when python already worked.'
        Assert-True ($script:PyPipChecks -eq 0) 'py -m pip should not have been used when python -m pip worked.'
        Assert-True ($script:PythonInstallCalls -eq 1) 'python -m pip install was not used in the dual-runner case.'
        Assert-True ($transcript -match 'Falling back to python -m pip install --user --upgrade yt-dlp') 'Fallback log did not prefer python -m pip.'
        Assert-True ($transcript -match 'yt-dlp installed via python -m pip: yt-dlp 2026.08.19') 'Success log did not name python -m pip.'
        Assert-True ((Get-Command 'yt-dlp' -ErrorAction SilentlyContinue) -ne $null) 'yt-dlp shim was not resolvable after PATH refresh.'
    }
    finally {
        $env:Path = $originalPath
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-PipModuleFailureScenario {
    $workspace = New-TestWorkspace
    $transcriptPath = Join-Path $workspace 'pip-module-failure.transcript.log'
    $script:UpdateSessionPathCalled = $false
    $script:YtDlpInstalled = $false
    $script:PythonVersionChecks = 0
    $script:PythonPipChecks = 0
    $script:PyVersionChecks = 0
    $script:PyPipChecks = 0
    $script:PythonInstallCalls = 0
    $script:PyInstallCalls = 0

    function Test-IsAdmin { return $true }
    function Set-ExecutionPolicy {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$Args
        )
    }
    function Test-Command {
        param([string]$Name)

        switch ($Name) {
            'python' { return $true }
            'py'     { return $true }
            'yt-dlp' { return $script:YtDlpInstalled }
            default  { return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue) }
        }
    }
    function Install-Package {
        [CmdletBinding()]
        param(
            [string]$WingetId,
            [string]$ChocoId,
            [string]$DisplayName
        )

        return $false
    }
    function python {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

        $joined = $Args -join ' '
        switch ($joined) {
            '--version' {
                $script:PythonVersionChecks++
                $global:LASTEXITCODE = 0
                Write-Output 'Python 3.12.8'
                return
            }
            '-m pip --version' {
                $script:PythonPipChecks++
                $global:LASTEXITCODE = 1
                return
            }
            '-m pip install --user --upgrade yt-dlp' {
                $script:PythonInstallCalls++
                $global:LASTEXITCODE = 0
                $script:YtDlpInstalled = $true
                return
            }
            default {
                $global:LASTEXITCODE = 1
                throw "Unexpected python invocation: $joined"
            }
        }
    }
    function py {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

        $joined = $Args -join ' '
        switch ($joined) {
            '--version' {
                $script:PyVersionChecks++
                $global:LASTEXITCODE = 0
                Write-Output 'Python 3.12.8'
                return
            }
            '-m pip --version' {
                $script:PyPipChecks++
                $global:LASTEXITCODE = 1
                return
            }
            '-m pip install --user --upgrade yt-dlp' {
                $script:PyInstallCalls++
                $global:LASTEXITCODE = 0
                $script:YtDlpInstalled = $true
                return
            }
            default {
                $global:LASTEXITCODE = 1
                throw "Unexpected py invocation: $joined"
            }
        }
    }
    function Update-SessionPath {
        $script:UpdateSessionPathCalled = $true
    }

    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $caught = $null
    try {
        Ensure-YtDlp
    }
    catch {
        $caught = $_.Exception.Message
    }
    finally {
        Stop-Transcript | Out-Null
    }

    $transcript = Get-FileText -Path $transcriptPath
    try {
        Assert-True ($caught -match 'Python is installed, but neither python -m pip nor py -m pip is available') 'Fallback did not fail with the runner verification message.'
        Assert-True (-not $script:UpdateSessionPathCalled) 'PATH refresh ran even though no module runner worked.'
        Assert-True ($script:PythonVersionChecks -eq 1) 'Python version was not checked before the clean failure.'
        Assert-True ($script:PythonPipChecks -eq 1) 'python -m pip was not probed before the clean failure.'
        Assert-True ($script:PyPipChecks -eq 1) 'py -m pip was not probed after python failed.'
        Assert-True ($script:PythonInstallCalls -eq 0) 'python -m pip install ran even though the module runner check failed.'
        Assert-True ($script:PyInstallCalls -eq 0) 'py -m pip install ran even though the module runner check failed.'
        Assert-True ($transcript -notmatch 'Falling back to') 'Fallback install started even though no module runner worked.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

Write-Step 'Positive: verified bootstrap installs Chocolatey and refreshes PATH'
Invoke-PositiveScenario

Write-Step 'Negative: hash mismatch fails closed'
Invoke-HashMismatchScenario

Write-Step 'Boundary: offline bootstrap failure is explicit'
Invoke-OfflineScenario

Write-Step 'Boundary: existing Chocolatey skips the bootstrap path'
Invoke-IdempotentScenario

Write-Step 'Positive: supported yt-dlp versions continue through the bootstrap gate'
Invoke-YtDlpVersionGateScenario -VersionText 'yt-dlp 2026.08.19' -ShouldFail:$false -ScenarioName 'supported-version'

Write-Step 'Negative: old yt-dlp versions fail before the installer uses them'
Invoke-YtDlpVersionGateScenario -VersionText 'yt-dlp 2026.08.18' -ShouldFail:$true -ScenarioName 'old-version'

Write-Step 'Boundary: patch-level yt-dlp versions still pass the gate'
Invoke-YtDlpVersionGateScenario -VersionText 'yt-dlp 2026.08.19.1' -ShouldFail:$false -ScenarioName 'patch-level-version'

Write-Step 'Boundary: prerelease yt-dlp versions at the minimum fail closed'
Invoke-YtDlpVersionGateScenario -VersionText 'yt-dlp 2026.08.19-alpha' -ShouldFail:$true -ScenarioName 'prerelease-version'

Write-Step 'Positive/regression: python -m pip fallback works without pip on PATH'
Invoke-PipFallbackScenario

Write-Step 'Boundary: dual python and py availability still prefers python -m pip'
Invoke-PipDualRunnerScenario

Write-Step 'Negative: clean failure when neither python -m pip nor py -m pip works'
Invoke-PipModuleFailureScenario

Write-Step 'Positive: pwsh host executable is resolved from PSHOME'
Invoke-HostExecutableResolutionScenario -ScenarioName 'pwsh-host' -Edition 'Core' -RootName 'Host Resolution\pwsh-home' -ExecutableName 'pwsh.exe'

Write-Step 'Boundary: powershell.exe remains the fallback when Desktop edition is active'
Invoke-HostExecutableResolutionScenario -ScenarioName 'powershell-host' -Edition 'Desktop' -RootName 'Host Resolution\powershell-home' -ExecutableName 'powershell.exe'

Write-Step 'Negative: missing host executable fails closed'
Invoke-HostExecutableResolutionScenario -ScenarioName 'missing-host' -Edition 'Core' -RootName 'Host Resolution\missing-host' -ExecutableName 'pwsh.exe' -ExpectFailure

Write-Step 'Positive/regression: shortcut generation preserves the validated pwsh host'
Invoke-ShortcutRuntimeScenario -ScenarioName 'pwsh-shortcut' -HostExecutablePath 'C:\Program Files\PowerShell\7\pwsh.exe' -RootName 'Shortcut Validation\Portable Path With Spaces\Nested Segment One\Nested Segment Two'

Write-Step 'Positive/regression: shortcut generation uses the validated host by default'
Invoke-ShortcutDefaultHostScenario -ScenarioName 'default-host-shortcut' -DefaultHostPath 'C:\Validated Host\pwsh.exe' -RootName 'Shortcut Validation\Default Host With Spaces\Nested Segment Four'

Write-Step 'Boundary: shortcut generation still works when Windows PowerShell is the validated host'
Invoke-ShortcutRuntimeScenario -ScenarioName 'powershell-shortcut' -HostExecutablePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -RootName 'Shortcut Validation\Fallback Host With Spaces\Nested Segment Three'

Write-Step 'Positive/regression: installer copies runtime files to Program Files and uses the Start Menu shortcut path'
Invoke-InstallerLayoutScenario

Write-Step 'Integration: elevation arguments round-trip through PowerShell 7 and Windows PowerShell 5.1'
Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
Assert-True (-not (Get-Command Start-Process -CommandType Function -ErrorAction SilentlyContinue)) 'A Start-Process test mock remained active during real child-process validation.'
$testPowerShellHosts = Get-TestWindowsPowerShellHosts
foreach ($testPowerShellHost in $testPowerShellHosts) {
    Invoke-ElevationArgumentRoundTripScenario -HostName $testPowerShellHost.Name -HostPath $testPowerShellHost.Path
}

Write-Step 'Integration: installed launch preserves argv and shortcut settings with spaced and no-space roots on both hosts'
foreach ($testPowerShellHost in $testPowerShellHosts) {
    Invoke-FinalLaunchArgumentRoundTripScenario -HostName $testPowerShellHost.Name -HostPath $testPowerShellHost.Path
    Invoke-FinalLaunchArgumentRoundTripScenario -HostName $testPowerShellHost.Name -HostPath $testPowerShellHost.Path -NoSpaceCompatibility
}

Write-Step 'Boundary: final launch failure keeps the shortcut and does not print forwarded values'
Invoke-LaunchFailureScenario

$bootstrapText = Get-FileText -Path $bootstrapPath
Assert-True ($bootstrapText -match [regex]::Escape($ChocolateyBootstrapSourceUrl)) 'Bootstrap no longer pins the Chocolatey MSI source.'
Assert-True ($bootstrapText -match [regex]::Escape($ChocolateyBootstrapSha256)) 'Bootstrap no longer pins the Chocolatey MSI hash.'
Assert-True ($bootstrapText -match 'Get-FileHash -Algorithm SHA256') 'Bootstrap no longer verifies the Chocolatey MSI hash.'
Assert-True ($bootstrapText -match 'msiexec\.exe') 'Bootstrap no longer launches the Chocolatey MSI installer.'
Assert-True ($bootstrapText -match [regex]::Escape('Assert-YtDlpMinimumVersion')) 'Bootstrap no longer enforces the yt-dlp minimum version.'
Assert-True ($bootstrapText -match [regex]::Escape('Get-YtDlpVersionInfo')) 'Bootstrap no longer parses yt-dlp versions before comparing them.'
Assert-True ($bootstrapText -match [regex]::Escape('Get-PowerShellHostExecutable')) 'Bootstrap no longer resolves the validated PowerShell host executable.'
Assert-True ($bootstrapText -notmatch [regex]::Escape('Get-Command powershell.exe')) 'Bootstrap still hardcodes powershell.exe instead of using the validated host.'
Assert-True ($bootstrapText -notmatch 'DownloadString\(') 'Bootstrap still contains a raw PowerShell download path.'
Assert-True ($bootstrapText -notmatch 'Invoke-Expression') 'Bootstrap still executes downloaded text.'

Write-Host '[PASS] Bootstrap security validation passed.' -ForegroundColor Green
