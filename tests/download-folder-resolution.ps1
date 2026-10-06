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

$script:HostMessages = [System.Collections.Generic.List[string]]::new()
$script:LogEntries   = [System.Collections.Generic.List[object]]::new()
$script:TestIsWindowsPlatformOverride = $null
$script:BlockComLookup = $false
$script:DownloadPathFallbackLogged = $false
$script:ColorWarning = 'Yellow'

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

function Write-Colored {
    param(
        [string]$Message,
        [string]$Color
    )

    [void]$script:HostMessages.Add($Message)
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'INFO',
        [hashtable]$Context
    )

    [void]$script:LogEntries.Add([pscustomobject]@{
        Message = $Message
        Level   = $Level
        Context = $Context
    })
}

function New-Object {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$RemainingArgs
    )

    if ($script:BlockComLookup -and ($RemainingArgs -contains '-ComObject')) {
        throw 'COM lookup should not run in this scenario.'
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
        'Get-PredictableDownloadPath',
        'Write-DownloadFallbackNotice',
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

    $environmentLines = New-Object System.Collections.Generic.List[string]
    [void]$environmentLines.Add('Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue')
    [void]$environmentLines.Add("`$env:LOCALAPPDATA = '$($StateRoot.Replace("'", "''"))'")
    if ($HomePath) {
        [void]$environmentLines.Add("`$env:HOME = '$($HomePath.Replace("'", "''"))'")
    }
    else {
        [void]$environmentLines.Add('Remove-Item Env:HOME -ErrorAction SilentlyContinue')
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
function global:yt-dlp {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $global:LASTEXITCODE = 0
    if ($Args -contains '--version') {
        Write-Output 'yt-dlp 2026.08.19'
        return
    }
    Write-Output '[download] Destination: __EXPECTED__/fake.mp4'
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
    $wrapper = $wrapper.Replace('__EXPECTED__', $ExpectedDownloadPath.Replace("'", "''"))
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

function Invoke-HelperPositiveScenario {
    $workspace = New-TestWorkspace
    $homeRoot = Join-Path $workspace 'home'
    New-Item -ItemType Directory -Path (Join-Path $homeRoot 'Downloads') -Force | Out-Null

    $originalHome = [Environment]::GetEnvironmentVariable('HOME', 'Process')
    $originalUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
    $script:HostMessages = [System.Collections.Generic.List[string]]::new()
    $script:LogEntries = [System.Collections.Generic.List[object]]::new()
    $script:TestIsWindowsPlatformOverride = $false
    $script:BlockComLookup = $true
    $env:HOME = $homeRoot
    Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue

    try {
        $result = Get-DownloadsFolder
        Assert-True ($result -eq (Join-Path $homeRoot 'Downloads')) "Helper did not return the HOME downloads path. Got '$result'."
        Assert-True ($script:HostMessages.Count -eq 0) 'Helper logged a fallback even though the HOME downloads folder already existed.'
        Assert-True ($script:LogEntries.Count -eq 0) 'Helper wrote a fallback log even though the HOME downloads folder already existed.'
    }
    finally {
        if ($null -eq $originalHome) {
            Remove-Item Env:HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:HOME = $originalHome
        }

        if ($null -eq $originalUserProfile) {
            Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue
        }
        else {
            $env:USERPROFILE = $originalUserProfile
        }

        $script:TestIsWindowsPlatformOverride = $null
        $script:BlockComLookup = $false
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-HelperFallbackScenario {
    $workspace = New-TestWorkspace
    $homeRoot = Join-Path $workspace 'home'
    New-Item -ItemType Directory -Path $homeRoot -Force | Out-Null

    $originalHome = [Environment]::GetEnvironmentVariable('HOME', 'Process')
    $originalUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
    $script:HostMessages = [System.Collections.Generic.List[string]]::new()
    $script:LogEntries = [System.Collections.Generic.List[object]]::new()
    $script:TestIsWindowsPlatformOverride = $false
    $script:BlockComLookup = $true
    $script:DownloadPathFallbackLogged = $false
    $env:HOME = $homeRoot
    Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue

    $expectedPath = Join-Path (Join-Path $homeRoot 'Professional Video Downloader') 'Downloads'

    try {
        $result = Get-DownloadsFolder
        Assert-True ($result -eq $expectedPath) "Helper did not return the predictable profile fallback path. Got '$result'."
        Assert-True (Test-Path -LiteralPath $result) 'Helper did not create the fallback download directory.'

        $fallbackMessage = $script:HostMessages | Where-Object { $_ -match [regex]::Escape($expectedPath) } | Select-Object -First 1
        Assert-True ($null -ne $fallbackMessage) 'Helper did not log the fallback download path.'
        Assert-True ($script:LogEntries.Count -eq 1) 'Helper should log the fallback path once.'
        Assert-True ($script:LogEntries[0].Level -eq 'WARN') 'Fallback log should be a warning.'
        Assert-True ($script:LogEntries[0].Context.path -eq $expectedPath) 'Fallback log context did not include the selected path.'
    }
    finally {
        if ($null -eq $originalHome) {
            Remove-Item Env:HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:HOME = $originalHome
        }

        if ($null -eq $originalUserProfile) {
            Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue
        }
        else {
            $env:USERPROFILE = $originalUserProfile
        }

        $script:TestIsWindowsPlatformOverride = $null
        $script:BlockComLookup = $false
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-MainScriptSmokeScenario {
    $fixtureRoot = Copy-SourceFixture -SourceRoot $RootPath -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $homeRoot = Join-Path $fixtureRoot 'home'
    $stateRoot = Join-Path $fixtureRoot 'state'
    New-Item -ItemType Directory -Path $homeRoot -Force | Out-Null
    $expectedDownloadPath = Join-Path (Join-Path $homeRoot 'Professional Video Downloader') 'Downloads'

    try {
        $result = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $expectedDownloadPath -Url 'https://example.com/video' -HomePath $homeRoot

        Assert-True ($result.ExitCode -eq 0) "Main script smoke run failed with exit code $($result.ExitCode).`n$($result.Output)"
        Assert-True (Test-Path -LiteralPath $expectedDownloadPath) 'Main script did not create the fallback downloads path.'
        Assert-True ($result.Output -match [regex]::Escape("Downloads folder unavailable. Using app folder under your profile: $expectedDownloadPath")) 'Main script did not announce the fallback download path.'
        Assert-True ($result.Output -match [regex]::Escape("Download folder: $expectedDownloadPath")) 'Main script did not use the fallback download path on a run without -DownloadPath.'

        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'VideoDownloaderConfig.json'))) 'Main script still wrote config into the install tree.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'logs'))) 'Main script still wrote logs into the install tree.'
        Assert-True (Test-Path -LiteralPath $result.ConfigPath) 'Main script did not persist the fallback path to the user state directory.'
        Assert-True (Test-Path -LiteralPath $result.LogDir) 'Main script did not create the user state log directory.'
        Assert-True (Test-Path -LiteralPath (Join-Path $result.LogDir ("{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')))) 'Main script did not write a dated log file into the user state directory.'

        $config = Get-Content -LiteralPath $result.ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        Assert-True ($config.DownloadPath -eq $expectedDownloadPath) 'Default fallback run did not store the effective download path.'
    }
    finally {
        Remove-TestWorkspace -Path $fixtureRoot
    }
}

function Invoke-SavedConfigScenario {
    $fixtureRoot = Copy-SourceFixture -SourceRoot $RootPath -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $stateRoot = Join-Path $fixtureRoot 'state'
    $firstDownloadRoot = Join-Path $fixtureRoot 'first-downloads'
    $secondHomeRoot = Join-Path $fixtureRoot 'second-home'
    New-Item -ItemType Directory -Path $firstDownloadRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $secondHomeRoot -Force | Out-Null

    try {
        $firstRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $firstDownloadRoot -Url 'https://example.com/video' -DownloadPathArg $firstDownloadRoot -HomePath $secondHomeRoot
        Assert-True ($firstRun.ExitCode -eq 0) "Main script did not complete the initial config-writing run.`n$($firstRun.Output)"
        Assert-True ($firstRun.Output -match [regex]::Escape("Download folder: $firstDownloadRoot")) 'Main script did not honor the custom -DownloadPath.'
        Assert-True ($firstRun.Output -notmatch 'app folder under your profile') 'Custom -DownloadPath should not trigger fallback messaging.'

        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'VideoDownloaderConfig.json'))) 'Main script still wrote config into the install tree.'
        Assert-True (Test-Path -LiteralPath $firstRun.ConfigPath) 'Main script did not write the config file to the user state directory after -DownloadPath was supplied.'

        $config = Get-Content -LiteralPath $firstRun.ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        Assert-True ($config.DownloadPath -eq $firstDownloadRoot) 'Saved config did not contain the expected download path.'

        $secondRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $firstDownloadRoot -Url 'https://example.com/video' -HomePath $secondHomeRoot
        Assert-True ($secondRun.ExitCode -eq 0) "Main script did not reuse the saved config path.`n$($secondRun.Output)"
        Assert-True ($secondRun.Output -match [regex]::Escape("Using previously saved folder: $firstDownloadRoot")) 'Second run did not announce the saved config folder.'
        Assert-True ($secondRun.Output -match [regex]::Escape("Download folder: $firstDownloadRoot")) 'Second run did not resolve the saved config folder.'
    }
    finally {
        Remove-TestWorkspace -Path $fixtureRoot
    }
}

function Invoke-StaleConfigRecoveryScenario {
    $fixtureRoot = Copy-SourceFixture -SourceRoot $RootPath -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $homeRoot = Join-Path $fixtureRoot 'home'
    $stateRoot = Join-Path $fixtureRoot 'state'
    New-Item -ItemType Directory -Path $homeRoot -Force | Out-Null

    $missingPreference = Join-Path $fixtureRoot 'missing-preference'
    $configPath = Join-Path (Get-AppStateRoot -BasePath $stateRoot) 'VideoDownloaderConfig.json'
    $expectedDownloadPath = Join-Path (Join-Path $homeRoot 'Professional Video Downloader') 'Downloads'

    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
        @{ DownloadPath = $missingPreference } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding Ascii

        $firstRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $expectedDownloadPath -Url 'https://example.com/video' -HomePath $homeRoot
        Assert-True ($firstRun.ExitCode -eq 0) "Main script did not recover from the stale config path.`n$($firstRun.Output)"
        Assert-True ($firstRun.Output -match [regex]::Escape("Saved folder unavailable: $missingPreference. Using $expectedDownloadPath instead.")) 'Main script did not explain the stale config fallback.'
        Assert-True ($firstRun.Output -match [regex]::Escape("Download folder: $expectedDownloadPath")) 'Main script did not resolve the effective fallback path.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'VideoDownloaderConfig.json'))) 'Main script still wrote stale-recovery config into the install tree.'

        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
        Assert-True ($config.DownloadPath -eq $expectedDownloadPath) 'Config file did not store the effective fallback path.'

        New-Item -ItemType Directory -Path (Join-Path $homeRoot 'Downloads') -Force | Out-Null

        $secondRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $expectedDownloadPath -Url 'https://example.com/video' -HomePath $homeRoot
        Assert-True ($secondRun.ExitCode -eq 0) "Main script did not reuse the saved fallback path.`n$($secondRun.Output)"
        Assert-True ($secondRun.Output -match [regex]::Escape("Using previously saved folder: $expectedDownloadPath")) 'Second run did not announce the saved fallback folder.'
        Assert-True ($secondRun.Output -match [regex]::Escape("Download folder: $expectedDownloadPath")) 'Second run did not resolve the saved fallback folder.'
    }
    finally {
        Remove-TestWorkspace -Path $fixtureRoot
    }
}

function Invoke-LegacyConfigMigrationScenario {
    $fixtureRoot = Copy-SourceFixture -SourceRoot $RootPath -FileNames @('professional-video-downloader.ps1', 'VERSION')
    $stateRoot = Join-Path $fixtureRoot 'state'
    $homeRoot = Join-Path $fixtureRoot 'home'
    New-Item -ItemType Directory -Path $homeRoot -Force | Out-Null

    $legacyConfigPath = Join-Path $fixtureRoot 'VideoDownloaderConfig.json'
    $currentConfigPath = Join-Path (Get-AppStateRoot -BasePath $stateRoot) 'VideoDownloaderConfig.json'
    $legacyDownloadPath = Join-Path $fixtureRoot 'legacy-downloads'

    try {
        @{ DownloadPath = $legacyDownloadPath } | ConvertTo-Json | Set-Content -LiteralPath $legacyConfigPath -Encoding Ascii

        $firstRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -StateRoot $stateRoot -ExpectedDownloadPath $legacyDownloadPath -Url 'https://example.com/video' -HomePath $homeRoot
        Assert-True ($firstRun.ExitCode -eq 0) "Main script did not migrate the legacy config path.`n$($firstRun.Output)"
        Assert-True ($firstRun.Output -match [regex]::Escape("Using previously saved folder: $legacyDownloadPath")) 'Main script did not read the legacy config file.'
        Assert-True (Test-Path -LiteralPath $currentConfigPath) 'Main script did not migrate the legacy config file into the user state directory.'

        $migrated = Get-Content -LiteralPath $currentConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        Assert-True ($migrated.DownloadPath -eq $legacyDownloadPath) 'Migrated config did not preserve the legacy download path.'
    }
    finally {
        Remove-TestWorkspace -Path $fixtureRoot
    }
}

$helperPath = Import-DownloaderHelpers -ScriptPath (Join-Path $RootPath 'professional-video-downloader.ps1')
. $helperPath
try {
    Write-Step 'Positive: helper uses HOME when USERPROFILE is missing'
    Invoke-HelperPositiveScenario

    Write-Step 'Negative: helper falls back to a predictable writable directory and logs it once'
    Invoke-HelperFallbackScenario

    Write-Step 'Positive: custom -DownloadPath is honored and reused'
    Invoke-SavedConfigScenario

    Write-Step 'Regression: stale config heals to the effective fallback path and persists it'
    Invoke-StaleConfigRecoveryScenario

    Write-Step 'Boundary: main script default run creates the fallback folder'
    Invoke-MainScriptSmokeScenario

    Write-Host '[PASS] Download-folder resolution validation passed.' -ForegroundColor Green
}
finally {
    if ($helperPath -and (Test-Path -LiteralPath $helperPath)) {
        Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
    }
}
