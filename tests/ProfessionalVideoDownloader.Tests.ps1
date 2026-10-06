#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RootPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $RootPath) {
    $RootPath = Split-Path -Parent $PSScriptRoot
}

$script:HostMessages = [System.Collections.Generic.List[string]]::new()
$script:WebResponses = @{}
$script:WebRequestCalls = [System.Collections.Generic.List[string]]::new()
$script:ReadHostQueue = [System.Collections.Generic.Queue[string]]::new()
$script:ColorInfo = 'Cyan'
$script:ColorMuted = 'DarkGray'
$script:ColorWarning = 'Yellow'
$script:ColorError = 'Red'
$script:ColorSuccess = 'Green'

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

function New-TestWorkspace {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-pester-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestWorkspace {
    param([Parameter(Mandatory)][string]$Path)

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
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

function Import-DownloaderFunctions {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$FunctionNames
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "Failed to parse helper script: $($errors[0].Message)"
    }

    $definitions = [System.Collections.Generic.List[string]]::new()
    foreach ($functionName in $FunctionNames) {
        $node = $ast.FindAll({
                param($candidate)
                $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $functionName
            }, $true) | Select-Object -First 1
        if (-not $node) {
            throw "Missing helper definition: $functionName"
        }

        [void]$definitions.Add($node.Extent.Text)
    }

    return ($definitions -join "`r`n`r`n")
}

function Clear-TestState {
    $script:HostMessages.Clear()
    $script:WebResponses = @{}
    $script:WebRequestCalls = [System.Collections.Generic.List[string]]::new()
    $script:ReadHostQueue = [System.Collections.Generic.Queue[string]]::new()
}

function Set-WebResponse {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200
    )

    $script:WebResponses[$Uri] = [pscustomobject]@{
        Response     = [pscustomobject]@{
            StatusCode  = $StatusCode
            Content     = $Body
            Headers     = @{ 'Content-Type' = $ContentType }
            BaseResponse = [pscustomobject]@{ ContentType = $ContentType }
            ContentType  = $ContentType
        }
        ThrowMessage = $null
    }
}

function Set-WebResponseError {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Message
    )

    $script:WebResponses[$Uri] = [pscustomobject]@{
        Response     = $null
        ThrowMessage = $Message
    }
}

function Invoke-TestWebRequest {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [switch]$UseBasicParsing,
        [int]$TimeoutSec,
        [int]$OperationTimeoutSeconds,
        [int]$MaximumRedirection,
        [string]$OutFile
    )

    [void]$script:WebRequestCalls.Add($Uri)
    if (-not $script:WebResponses.ContainsKey($Uri)) {
        throw "Unexpected web request: $Uri"
    }

    $entry = $script:WebResponses[$Uri]
    if ($Uri -eq 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest') {
        if (-not $PSBoundParameters.ContainsKey('Headers') -or
            $Headers['Accept'] -ne 'application/vnd.github+json' -or
            $Headers['User-Agent'] -ne 'ProfessionalVideoDownloader') {
            throw 'Latest-release request is missing the expected GitHub headers.'
        }
        if (-not $PSBoundParameters.ContainsKey('TimeoutSec') -or $TimeoutSec -ne 20 -or
            -not $PSBoundParameters.ContainsKey('MaximumRedirection') -or $MaximumRedirection -ne 3) {
            throw 'Latest-release request is missing the expected timeout or redirect limits.'
        }
        if ($entry.ThrowMessage) {
            throw $entry.ThrowMessage
        }

        return [pscustomobject]@{
            StatusCode = $entry.Response.StatusCode
            Content    = $entry.Response.Content
        }
    }

    if (-not $PSBoundParameters.ContainsKey('OutFile')) {
        throw "Missing OutFile guard in batch-source fetch: $Uri"
    }
    if (-not ($PSBoundParameters.ContainsKey('TimeoutSec') -or $PSBoundParameters.ContainsKey('OperationTimeoutSeconds'))) {
        throw "Missing timeout guard in batch-source fetch: $Uri"
    }
    if (-not $PSBoundParameters.ContainsKey('MaximumRedirection')) {
        throw "Missing redirect guard in batch-source fetch: $Uri"
    }
    if ($entry.ThrowMessage) {
        throw $entry.ThrowMessage
    }

    if ($OutFile) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($OutFile, [string]$entry.Response.Content, $utf8NoBom)
    }

    return $entry.Response
}

function global:Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [switch]$UseBasicParsing,
        [int]$TimeoutSec,
        [int]$OperationTimeoutSeconds,
        [int]$MaximumRedirection,
        [string]$OutFile
    )

    Invoke-TestWebRequest @PSBoundParameters
}

function global:Read-Host {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$RemainingArgs
    )

    if ($script:ReadHostQueue.Count -eq 0) {
        return ''
    }

    return $script:ReadHostQueue.Dequeue()
}

function global:Write-Colored {
    param(
        [string]$Message,
        [string]$Color
    )

    [void]$script:HostMessages.Add($Message)
}

function Invoke-ValidationScript {
    param([Parameter(Mandatory)][string]$FileName)

    $scriptPath = Join-Path $PSScriptRoot $FileName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Missing validation script: $scriptPath"
    }

    $hostExe = Get-PowerShellHost
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -RootPath $RootPath
    if ($LASTEXITCODE -ne 0) {
        throw "Validation script failed: $FileName"
    }
}

$mainScriptPath = Join-Path $RootPath 'professional-video-downloader.ps1'
$downloaderHelperCode = Import-DownloaderFunctions -ScriptPath $mainScriptPath -FunctionNames @(
    'Get-RemoteResponseContentType',
    'Get-RemoteResponseBody',
    'Get-InvokeWebRequestTimeoutParameterName',
    'Test-IsBinaryLikeText',
    'Test-IsLikelyBatchSourceUrl',
    'Get-UrlLikeTokensFromText',
    'Get-BatchSourceProbe',
    'Expand-UrlList',
    'Test-IsHttpUrl',
    'Read-UrlListInteractive',
    'Test-IsBatchSource',
    'Read-UrlsFromSource',
    'Build-YtDlpArgumentList',
    'Invoke-ExitPause',
    'Get-YtDlpVersionInfo',
    'Assert-YtDlpMinimumVersion',
    'Get-YtDlpExecutablePath',
    'Get-YtDlpVersionText',
    'Get-YtDlpStableReleaseVersionInfo',
    'Get-LatestStableYtDlpRelease',
    'Get-YtDlpInstallOwner',
    'Invoke-YtDlpOwnerUpdate',
    'Invoke-YtDlpUpdatePreflight'
)
. ([scriptblock]::Create($downloaderHelperCode))

$RemoteBatchSourceTimeoutSec = 15
$RemoteBatchSourceMaxRedirections = 5
$RemoteBatchSourceMaxBytes = 1MB
$DefaultImpersonateTarget = 'chrome'

function Invoke-UrlValidationScenario {
    Assert-True (Test-IsHttpUrl 'https://example.com/watch?v=abc') 'https URLs should be accepted.'
    Assert-True (Test-IsHttpUrl 'http://example.com/watch?v=abc') 'http URLs should be accepted.'
    Assert-True (-not (Test-IsHttpUrl 'ftp://example.com/video')) 'Unsupported schemes should be rejected.'
    Assert-True (-not (Test-IsHttpUrl 'example.com/video')) 'Bare host names should be rejected.'

    $expanded = Expand-UrlList -Raw @(
        'https://example.com/raw',
        'https://example.com/alpha,https://example.com/beta',
        'https://example.com/path;session=1',
        'https://example.com/raw',
        '   '
    )

    $expected = @(
        'https://example.com/raw',
        'https://example.com/alpha',
        'https://example.com/beta',
        'https://example.com/path;session=1'
    )

    Assert-True ($expanded.Count -eq $expected.Count) ('Expanded URL list count mismatch. Expected {0} but got {1}.' -f $expected.Count, $expanded.Count)
    for ($i = 0; $i -lt $expected.Count; $i++) {
        Assert-True ($expanded[$i] -eq $expected[$i]) ('Expanded URL order mismatch at index {0}. Expected {1} but got {2}.' -f $i, $expected[$i], $expanded[$i])
    }
}

function Invoke-BatchSourceScenario {
    Clear-TestState

    $workspace = New-TestWorkspace
    $localFile = Join-Path $workspace 'urls.txt'
    Set-Content -LiteralPath $localFile -Encoding Ascii -Value "https://example.com/local-one`nhttps://example.com/local-two"

    try {
        $localProbe = Get-BatchSourceProbe -Token $localFile
        Assert-True $localProbe.IsBatchSource 'Local files should remain valid batch sources.'

        Set-WebResponse -Uri 'https://example.com/raw' -Body "https://example.com/raw-one`nhttps://example.com/raw-two" -ContentType 'text/plain; charset=utf-8'
        $remoteProbe = Get-BatchSourceProbe -Token 'https://example.com/raw' -ForceRemoteProbe
        Assert-True $remoteProbe.IsBatchSource 'Remote raw text should be recognized as a batch source.'

        $body = Read-UrlsFromSource -Source 'https://example.com/raw' -Probe $remoteProbe
        Assert-True ($body.Count -eq 1) 'Normal small remote lists should load as a single batch body.'
        Assert-True ($body[0] -match 'https://example.com/raw-one') 'Remote raw lists should preserve the first URL.'
        Assert-True ($body[0] -match 'https://example.com/raw-two') 'Remote raw lists should preserve the second URL.'

        Set-WebResponse -Uri 'https://example.com/plain' -Body 'notes without urls' -ContentType 'text/plain; charset=utf-8'
        $plainProbe = Get-BatchSourceProbe -Token 'https://example.com/plain' -ForceRemoteProbe
        Assert-True (-not $plainProbe.IsBatchSource) 'Plain text without URL-like tokens should be rejected.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-InteractiveLocalFileScenario {
    Clear-TestState

    $workspace = New-TestWorkspace
    $filePath = Join-Path $workspace 'interactive-urls.txt'
    Set-Content -LiteralPath $filePath -Encoding Ascii -Value "https://example.com/interactive-one`nhttps://example.com/interactive-two"

    try {
        [void]$script:ReadHostQueue.Enqueue($filePath)
        [void]$script:ReadHostQueue.Enqueue('')

        $result = Read-UrlListInteractive
        Assert-True ($result.Count -eq 1) 'Interactive helper should return the raw file body as a single batch token.'
        Assert-True ($result[0] -match 'interactive-one') 'Interactive helper did not read the local file body.'
        Assert-True ($result[0] -match 'interactive-two') 'Interactive helper did not preserve the full local file body.'
        Assert-True ($script:WebRequestCalls.Count -eq 0) 'Local file interactive input should not trigger web requests.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-InteractiveRemoteBatchScenario {
    Clear-TestState

    Set-WebResponse -Uri 'https://example.com/raw-list.txt' -Body "https://example.com/remote-one`nhttps://example.com/remote-two" -ContentType 'text/plain; charset=utf-8'

    [void]$script:ReadHostQueue.Enqueue('https://example.com/raw-list.txt')
    [void]$script:ReadHostQueue.Enqueue('')

    $result = Read-UrlListInteractive
    Assert-True ($result.Count -eq 1) 'Remote interactive input should remain a single batch token.'
    Assert-True ($result[0] -match 'remote-one') 'Remote interactive input did not preserve the first URL.'
    Assert-True ($result[0] -match 'remote-two') 'Remote interactive input did not preserve the second URL.'
    Assert-True ($script:WebRequestCalls.Count -eq 1) 'Remote interactive input should be fetched once.'
}

function Invoke-EmptyInteractiveInputScenario {
    Clear-TestState

    [void]$script:ReadHostQueue.Enqueue('')
    [void]$script:ReadHostQueue.Enqueue('')
    [void]$script:ReadHostQueue.Enqueue('')

    $attempt = 0
    $rawUrlInput = [System.Collections.Generic.List[string]]::new()
    $elapsed = Measure-Command {
        while ($rawUrlInput.Count -eq 0 -and $attempt -lt 3) {
            $attempt++
            $lines = Read-UrlListInteractive
            foreach ($l in $lines) { [void]$rawUrlInput.Add($l) }
        }
    }

    Assert-True ($rawUrlInput.Count -eq 0) 'Empty interactive input should still produce no URLs.'
    Assert-True ($elapsed.TotalMilliseconds -lt 1000) "Empty interactive input loop should return quickly, took $([int]$elapsed.TotalMilliseconds) ms."
}

function Invoke-ArgumentBuilderScenario {
    $arguments = Build-YtDlpArgumentList `
        -TargetUrl 'https://example.com/video' `
        -OutputTemplate 'C:\Downloads\%(title)s [%(id)s].%(ext)s' `
        -AudioOnly $true `
        -AllowPlaylist $true `
        -CookiesFromBrowser 'firefox' `
        -ImpersonateTarget 'chrome' `
        -ExtractorArgs 'generic:impersonate'

    $list = @($arguments)
    $argumentText = $list -join ' '

    Assert-True ($list -contains '--format') 'Audio-only format selector missing.'
    Assert-True ($list -contains 'bestaudio/best') 'Audio-only bestaudio selector missing.'
    Assert-True ($list -contains '--extract-audio') 'Audio-only extraction flag missing.'
    Assert-True ($list -contains '--audio-format') 'Audio-only format flag missing.'
    Assert-True ($list -contains 'mp3') 'Audio-only target format missing.'
    Assert-True ($list -contains '--audio-quality') 'Audio-only quality flag missing.'
    Assert-True ($list -contains '0') 'Audio-only quality value missing.'
    Assert-True (-not ($list -contains '--no-playlist')) 'Playlist disabling flag should be omitted when playlists are allowed.'
    Assert-True ($list -contains '--cookies-from-browser') 'Browser cookie flag missing.'
    Assert-True ($list -contains 'firefox') 'Browser cookie target missing.'
    Assert-True ($list -contains '--impersonate') 'Impersonation flag missing.'
    Assert-True ($list -contains '--extractor-args') 'Extractor args flag missing.'
    Assert-True ($list -contains 'generic:impersonate') 'Extractor args value missing.'
    Assert-True ($list -contains '--output') 'Output template flag missing.'
    Assert-True ($argumentText -match [regex]::Escape('C:\Downloads\%(title)s [%(id)s].%(ext)s')) 'Output template missing from yt-dlp arguments.'
    Assert-True ($argumentText -match [regex]::Escape('https://example.com/video')) 'Target URL missing from yt-dlp arguments.'
}

function Invoke-VersionGateScenario {
    $stable = Get-YtDlpVersionInfo -VersionText 'yt-dlp 2024.01.01'
    Assert-True ($stable.Raw -eq 'yt-dlp 2024.01.01') 'Version parser did not preserve the raw text.'
    Assert-True ($stable.CoreText -eq '2024.01.01') 'Version parser did not keep the numeric core text.'
    Assert-True ($stable.Suffix -eq '') 'Stable versions should not report a suffix.'

    $prerelease = Get-YtDlpVersionInfo -VersionText 'yt-dlp 2024.01.01-alpha'
    Assert-True ($prerelease.Suffix -eq '-alpha') 'Prerelease suffix should be preserved.'

    $plainVersion = Get-YtDlpVersionInfo -VersionText '2026.08.19'
    Assert-True ($plainVersion.CoreText -eq '2026.08.19') 'Plain yt-dlp version output should be accepted.'

    $invalidRejected = $false
    try {
        $null = Get-YtDlpVersionInfo -VersionText 'warning: yt-dlp 2026.08.19 failed'
    }
    catch {
        $invalidRejected = $true
    }
    Assert-True $invalidRejected 'Version parser should reject extra text around a version.'
}

function Assert-LatestStableReleaseRejected {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][string]$Scenario
    )

    $releaseUri = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'
    Clear-TestState
    Set-WebResponse -Uri $releaseUri -Body $Body -ContentType 'application/json'
    $rejected = $false
    try {
        $null = Get-LatestStableYtDlpRelease
    }
    catch {
        $rejected = $_.Exception.Message -match 'Unable to retrieve and validate the latest stable yt-dlp release'
    }

    Assert-True $rejected ("Malformed {0} should fail closed." -f $Scenario)
    Assert-True ($script:WebRequestCalls.Count -eq 1) ("{0} should use only the mocked GitHub release request." -f $Scenario)
}

function Invoke-LatestStableYtDlpReleaseScenarios {
    $releaseUri = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'
    Clear-TestState
    Set-WebResponse -Uri $releaseUri -Body '{"tag_name":"2026.08.19","draft":false,"prerelease":false}' -ContentType 'application/json'
    $release = Get-LatestStableYtDlpRelease
    Assert-True ($release.Tag -eq '2026.08.19') 'Latest stable release tag should be read from the GitHub response.'
    Assert-True ($release.Version -eq [version]'2026.08.19') 'Latest stable release version should be parsed from its tag.'
    Assert-True ($script:WebRequestCalls.Count -eq 1 -and $script:WebRequestCalls[0] -eq $releaseUri) 'Latest stable release lookup should call the official GitHub API once.'

    Assert-LatestStableReleaseRejected -Body '' -Scenario 'empty release response'
    Assert-LatestStableReleaseRejected -Body '{"tag_name":"2026.08.19","draft":false}' -Scenario 'release object missing prerelease metadata'
    Assert-LatestStableReleaseRejected -Body '{"tag_name":' -Scenario 'malformed JSON release data'
    Assert-LatestStableReleaseRejected -Body '{"tag_name":"2026.08.19-beta","draft":false,"prerelease":false}' -Scenario 'prerelease tag'
    Assert-LatestStableReleaseRejected -Body '{"tag_name":"2026.13.40","draft":false,"prerelease":false}' -Scenario 'invalid calendar release tag'
    Assert-LatestStableReleaseRejected -Body '{"tag_name":"2026.08.19","draft":false,"prerelease":true}' -Scenario 'prerelease release metadata'
    Assert-LatestStableReleaseRejected -Body '{"tag_name":"2026.08.19","draft":true,"prerelease":false}' -Scenario 'draft release metadata'

    Clear-TestState
    Set-WebResponse -Uri $releaseUri -StatusCode 503 -Body '{"message":"temporarily unavailable"}' -ContentType 'application/json'
    $httpFailureRejected = $false
    try {
        $null = Get-LatestStableYtDlpRelease
    }
    catch {
        $httpFailureRejected = $_.Exception.Message -match 'GitHub returned HTTP status 503'
    }
    Assert-True $httpFailureRejected 'A non-success GitHub status should fail closed.'

    Clear-TestState
    Set-WebResponseError -Uri $releaseUri -Message 'GitHub is unavailable in this offline test.'
    $networkFailureRejected = $false
    try {
        $null = Get-LatestStableYtDlpRelease
    }
    catch {
        $networkFailureRejected = $_.Exception.Message -match 'Unable to retrieve and validate the latest stable yt-dlp release'
    }
    Assert-True $networkFailureRejected 'A GitHub request failure should fail closed.'
}

function New-YtDlpPreflightTestDependencies {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [string]$Owner = 'winget',
        [scriptblock]$UpdateAction
    )

    $versionReader = {
        param($Path)
        $State.VersionCalls++
        $allowedPaths = @($State.ExecutablePath)
        if ($State.ContainsKey('VerifiedExecutablePath')) {
            $allowedPaths += $State.VerifiedExecutablePath
        }
        if ($Path -notin $allowedPaths) {
            throw 'Preflight used a different executable path.'
        }
        return ('yt-dlp {0}' -f $State.Version)
    }.GetNewClosure()
    $releaseReader = {
        [pscustomobject]@{ Tag = '2026.08.19' }
    }
    $ownerResolver = {
        param($Path)
        $allowedPaths = @($State.ExecutablePath)
        if ($State.ContainsKey('VerifiedExecutablePath')) {
            $allowedPaths += $State.VerifiedExecutablePath
        }
        if ($Path -notin $allowedPaths) {
            throw 'Owner check used a different executable path.'
        }
        if ($State.ContainsKey('VerifiedExecutablePath') -and $Path -eq $State.VerifiedExecutablePath -and $State.ContainsKey('VerifiedOwner')) {
            return $State.VerifiedOwner
        }
        return $Owner
    }.GetNewClosure()
    $executableResolver = {
        if ($State.ContainsKey('VerifiedExecutablePath')) {
            return $State.VerifiedExecutablePath
        }
        return $State.ExecutablePath
    }.GetNewClosure()

    if (-not $UpdateAction) {
        $UpdateAction = {
            param($DetectedOwner, $Path, $TargetVersion, $InstalledVersion)
            $State.UpdateCalls++
            if ($DetectedOwner -ne $Owner -or $Path -ne $State.ExecutablePath -or $TargetVersion -ne '2026.08.19' -or $InstalledVersion -ne '2026.01.01') {
                throw 'Update action received incorrect owner, executable, or target version.'
            }
            $State.Version = $TargetVersion
            return [pscustomobject]@{ ExitCode = 0 }
        }.GetNewClosure()
    }

    return [pscustomobject]@{
        VersionReader = $versionReader
        ReleaseReader = $releaseReader
        OwnerResolver = $ownerResolver
        ExecutableResolver = $executableResolver
        UpdateAction  = $UpdateAction
    }
}

function Invoke-YtDlpUpdatePreflightScenarios {
    $executablePath = Join-Path ([System.IO.Path]::GetTempPath()) 'fake-yt-dlp.exe'
    $state = @{ ExecutablePath = $executablePath; Version = '2026.08.19'; VersionCalls = 0; UpdateCalls = 0 }
    $dependencies = New-YtDlpPreflightTestDependencies -State $state
    $current = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
        -VersionReader $dependencies.VersionReader `
        -ReleaseReader $dependencies.ReleaseReader `
        -OwnerResolver $dependencies.OwnerResolver `
        -ExecutableResolver $dependencies.ExecutableResolver `
        -UpdateAction $dependencies.UpdateAction
    Assert-True (-not $current.Updated) 'Current stable yt-dlp should not be reinstalled.'
    Assert-True ($current.ExecutablePath -eq $executablePath) 'Current result should preserve the resolved executable path.'
    Assert-True ($state.UpdateCalls -eq 0) 'Current stable yt-dlp should not invoke an update.'
    Assert-True ($state.VersionCalls -eq 1) 'Current stable yt-dlp should only be queried once.'

    $updatedExecutablePath = Join-Path ([System.IO.Path]::GetTempPath()) 'updated-fake-yt-dlp.exe'
    $state = @{ ExecutablePath = $executablePath; VerifiedExecutablePath = $updatedExecutablePath; Version = '2026.01.01'; VersionCalls = 0; UpdateCalls = 0 }
    $dependencies = New-YtDlpPreflightTestDependencies -State $state
    $updated = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
        -VersionReader $dependencies.VersionReader `
        -ReleaseReader $dependencies.ReleaseReader `
        -OwnerResolver $dependencies.OwnerResolver `
        -ExecutableResolver $dependencies.ExecutableResolver `
        -UpdateAction $dependencies.UpdateAction
    Assert-True $updated.Updated 'Outdated yt-dlp should be updated.'
    Assert-True ($updated.InstalledText -eq 'yt-dlp 2026.08.19') 'Verified updated version should be returned.'
    Assert-True ($updated.ExecutablePath -eq $updatedExecutablePath) 'Update should return the refreshed executable path used for processing.'
    Assert-True ($state.VersionCalls -eq 2) 'Updated yt-dlp should be queried before and after the update.'
    Assert-True ($state.UpdateCalls -eq 1) 'Outdated yt-dlp should invoke one update.'

    $state = @{ ExecutablePath = $executablePath; VerifiedExecutablePath = $updatedExecutablePath; VerifiedOwner = 'python'; Version = '2026.01.01'; VersionCalls = 0; UpdateCalls = 0 }
    $dependencies = New-YtDlpPreflightTestDependencies -State $state
    $changedOwnerRejected = $false
    try {
        $null = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
            -VersionReader $dependencies.VersionReader `
            -ReleaseReader $dependencies.ReleaseReader `
            -OwnerResolver $dependencies.OwnerResolver `
            -ExecutableResolver $dependencies.ExecutableResolver `
            -UpdateAction $dependencies.UpdateAction
    }
    catch {
        $changedOwnerRejected = $_.Exception.Message -match 'instead of the original WinGet package'
    }
    Assert-True $changedOwnerRejected 'A refreshed executable from a different installation owner should stop preflight.'
    Assert-True ($state.VersionCalls -eq 1) 'A refreshed executable from a different owner must not be run for verification.'

    foreach ($newerVersion in @('2026.09.01', '2026.09.01-dev')) {
        $state = @{ ExecutablePath = $executablePath; Version = $newerVersion; VersionCalls = 0; UpdateCalls = 0 }
        $dependencies = New-YtDlpPreflightTestDependencies -State $state
        $downgradeRejected = $false
        try {
            $null = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
                -VersionReader $dependencies.VersionReader `
                -ReleaseReader $dependencies.ReleaseReader `
                -OwnerResolver $dependencies.OwnerResolver `
                -ExecutableResolver $dependencies.ExecutableResolver `
                -UpdateAction $dependencies.UpdateAction
        }
        catch {
            $downgradeRejected = $_.Exception.Message -match 'newer than the latest stable release'
        }
        Assert-True $downgradeRejected ("Newer installed version '{0}' should not be downgraded." -f $newerVersion)
        Assert-True ($state.UpdateCalls -eq 0) 'A newer stable or prerelease build must not invoke an update.'
    }

    $state = @{ ExecutablePath = $executablePath; Version = 'invalid output'; VersionCalls = 0; UpdateCalls = 0 }
    $releaseState = @{ Calls = 0 }
    $dependencies = New-YtDlpPreflightTestDependencies -State $state
    $invalidReleaseReader = { $releaseState.Calls++; [pscustomobject]@{ Tag = '2026.08.19' } }.GetNewClosure()
    $invalidVersionRejected = $false
    try {
        $null = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
            -VersionReader $dependencies.VersionReader `
            -ReleaseReader $invalidReleaseReader `
            -OwnerResolver $dependencies.OwnerResolver `
            -ExecutableResolver $dependencies.ExecutableResolver `
            -UpdateAction $dependencies.UpdateAction
    }
    catch {
        $invalidVersionRejected = $_.Exception.Message -match 'Unable to determine a valid version'
    }
    Assert-True $invalidVersionRejected 'Malformed yt-dlp version output should stop preflight.'
    Assert-True ($releaseState.Calls -eq 0) 'A malformed installed version should stop before a release or update check.'
    Assert-True ($state.UpdateCalls -eq 0) 'Malformed yt-dlp version output must not invoke an update.'

    $state = @{ ExecutablePath = $executablePath; Version = '2026.01.01'; VersionCalls = 0; UpdateCalls = 0 }
    $dependencies = New-YtDlpPreflightTestDependencies -State $state
    $unavailableReleaseReader = { throw 'GitHub unavailable in offline test.' }
    $releaseFailureRejected = $false
    try {
        $null = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
            -VersionReader $dependencies.VersionReader `
            -ReleaseReader $unavailableReleaseReader `
            -OwnerResolver $dependencies.OwnerResolver `
            -ExecutableResolver $dependencies.ExecutableResolver `
            -UpdateAction $dependencies.UpdateAction
    }
    catch {
        $releaseFailureRejected = $_.Exception.Message -match 'Could not establish the latest stable yt-dlp version'
    }
    Assert-True $releaseFailureRejected 'Unavailable latest-release metadata should stop preflight.'
    Assert-True ($state.UpdateCalls -eq 0) 'Release lookup failure must stop before an installation update.'

    $workspace = New-TestWorkspace
    try {
        $state = @{ ExecutablePath = $executablePath; Version = '2026.01.01'; VersionCalls = 0; UpdateCalls = 0; Workspace = $workspace }
        $failedUpdateAction = {
            param($DetectedOwner, $Path, $TargetVersion, $InstalledVersion)
            $State.UpdateCalls++
            return [pscustomobject]@{ ExitCode = 5 }
        }.GetNewClosure()
        $dependencies = New-YtDlpPreflightTestDependencies -State $state -UpdateAction $failedUpdateAction
        $installFailureRejected = $false
        try {
            $null = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
                -VersionReader $dependencies.VersionReader `
                -ReleaseReader $dependencies.ReleaseReader `
                -OwnerResolver $dependencies.OwnerResolver `
                -ExecutableResolver $dependencies.ExecutableResolver `
                -UpdateAction $dependencies.UpdateAction
        }
        catch {
            $installFailureRejected = $_.Exception.Message -match 'exit code 5'
        }
        Assert-True $installFailureRejected 'A failed package update should stop preflight.'
        Assert-True ($state.UpdateCalls -eq 1) 'A failed package update should be attempted once.'
        Assert-True (@(Get-ChildItem -LiteralPath $workspace -Force).Count -eq 0) 'The updater should not leave temporary artifacts.'

        $state = @{ ExecutablePath = $executablePath; Version = '2026.01.01'; VersionCalls = 0; UpdateCalls = 0 }
        $permissionDeniedAction = {
            param($DetectedOwner, $Path, $TargetVersion, $InstalledVersion)
            $State.UpdateCalls++
            throw 'Access is denied for this installation.'
        }.GetNewClosure()
        $dependencies = New-YtDlpPreflightTestDependencies -State $state -UpdateAction $permissionDeniedAction
        $permissionFailureRejected = $false
        try {
            $null = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
                -VersionReader $dependencies.VersionReader `
                -ReleaseReader $dependencies.ReleaseReader `
                -OwnerResolver $dependencies.OwnerResolver `
                -ExecutableResolver $dependencies.ExecutableResolver `
                -UpdateAction $dependencies.UpdateAction
        }
        catch {
            $permissionFailureRejected = $_.Exception.Message -match 'Access is denied'
        }
        Assert-True $permissionFailureRejected 'Permission-denied updates should stop with an actionable error.'
        Assert-True ($state.UpdateCalls -eq 1) 'Permission denial should not be retried through another installation path.'

        $state = @{ ExecutablePath = $executablePath; Version = '2026.01.01'; VersionCalls = 0; UpdateCalls = 0 }
        $successWithoutReplacement = {
            param($DetectedOwner, $Path, $TargetVersion, $InstalledVersion)
            $State.UpdateCalls++
            return [pscustomobject]@{ ExitCode = 0 }
        }.GetNewClosure()
        $dependencies = New-YtDlpPreflightTestDependencies -State $state -UpdateAction $successWithoutReplacement
        $staleAfterUpdateRejected = $false
        try {
            $null = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
                -VersionReader $dependencies.VersionReader `
                -ReleaseReader $dependencies.ReleaseReader `
                -OwnerResolver $dependencies.OwnerResolver `
                -ExecutableResolver $dependencies.ExecutableResolver `
                -UpdateAction $dependencies.UpdateAction
        }
        catch {
            $staleAfterUpdateRejected = $_.Exception.Message -match 'reports yt-dlp 2026\.01\.01'
        }
        Assert-True $staleAfterUpdateRejected 'A reported successful update must be verified against the effective executable.'

        $state = @{ ExecutablePath = $executablePath; Version = '2026.01.01'; VersionCalls = 0; UpdateCalls = 0 }
        $dependencies = New-YtDlpPreflightTestDependencies -State $state -Owner 'python'
        $unsupportedOwnerRejected = $false
        try {
            $null = Invoke-YtDlpUpdatePreflight -ExecutablePath $executablePath `
                -VersionReader $dependencies.VersionReader `
                -ReleaseReader $dependencies.ReleaseReader `
                -OwnerResolver $dependencies.OwnerResolver `
                -ExecutableResolver $dependencies.ExecutableResolver `
                -UpdateAction $dependencies.UpdateAction
        }
        catch {
            $unsupportedOwnerRejected = $_.Exception.Message -match 'same package manager or Python interpreter'
        }
        Assert-True $unsupportedOwnerRejected 'An unsupported Python-owned installation should fail with same-interpreter guidance.'
        Assert-True ($state.UpdateCalls -eq 0) 'An unsupported Python-owned installation must not run a package update.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-ExitPauseScenario {
    Clear-TestState

    $script:PauseOnExit = $false
    $script:PauseSleepSeconds = $null
    function global:Start-Sleep {
        param([int]$Seconds)
        $script:PauseSleepSeconds = $Seconds
    }

    try {
        Invoke-ExitPause -Seconds 4
        Assert-True ($null -eq $script:PauseSleepSeconds) 'Pause helper should not sleep when opt-in is disabled.'

        $script:PauseOnExit = $true
        Invoke-ExitPause -Seconds 4
        Assert-True ($script:PauseSleepSeconds -eq 4) "Pause helper should request a four-second sleep when opt-in is enabled, saw '$script:PauseSleepSeconds'."
    }
    finally {
        Remove-Item function:\global:Start-Sleep -ErrorAction SilentlyContinue
        $script:PauseOnExit = $false
        $script:PauseSleepSeconds = $null
    }
}

function Assert-StaticMetadata {
    $versionFilePath = Join-Path $RootPath 'VERSION'
    $mainScriptPath  = Join-Path $RootPath 'professional-video-downloader.ps1'
    $bootstrapPath   = Join-Path $RootPath 'install-bootstrap.ps1'
    $batchPath       = Join-Path $RootPath 'install.bat'
    $shellPath       = Join-Path $RootPath 'install.sh'
    $readmePath      = Join-Path $RootPath 'README.md'

    $version = (Get-FileText -Path $versionFilePath).Trim()
    $mainText = Get-FileText -Path $mainScriptPath
    $bootstrap = Get-FileText -Path $bootstrapPath
    $batch = Get-FileText -Path $batchPath
    $shell = Get-FileText -Path $shellPath
    $readme = Get-FileText -Path $readmePath
    $headerVersion = Get-MainScriptHeaderVersion -ScriptPath $mainScriptPath -ScriptText $mainText

    Assert-True ($version -eq $headerVersion) "Main script header version '$headerVersion' does not match VERSION '$version'."
    Assert-True ($mainText -match [regex]::Escape('Get-ProjectVersion -RootPath $PSScriptRoot')) 'Main script does not read VERSION at runtime.'
    Assert-True ($mainText -match [regex]::Escape('Get-DownloaderStateRoot')) 'Main script does not resolve writable runtime state separately from the install root.'
    Assert-True ($mainText -match [regex]::Escape('$Script:YtDlpExecutable = $ytDlpPreflight.ExecutablePath')) 'Main script does not use the executable path refreshed and verified by yt-dlp preflight.'
    $preflightPosition = $mainText.IndexOf('Invoke-YtDlpUpdatePreflight -ExecutablePath')
    $downloadPosition = $mainText.IndexOf('# --------------------- DOWNLOAD EXECUTION')
    Assert-True ($preflightPosition -ge 0 -and $preflightPosition -lt $downloadPosition) 'yt-dlp preflight must run before the download execution section.'
    Assert-True ($mainText -match [regex]::Escape('& $Script:YtDlpExecutable @Arguments')) 'Downloads do not use the executable resolved and verified by preflight.'
    Assert-True ($bootstrap -match [regex]::Escape('Get-ProjectVersion -RootPath $SourceDir')) 'Bootstrap does not read VERSION at runtime.'
    Assert-True ($batch -match [regex]::Escape('Professional Video Downloader v%APP_VERSION% - Setup')) 'Batch installer banner does not use the shared version placeholder.'
    Assert-True ($shell -match [regex]::Escape('Professional Video Downloader v${APP_VERSION} - Setup')) 'POSIX installer banner does not use the shared version placeholder.'
    Assert-True ($readme -match [regex]::Escape("https://raw.githubusercontent.com/mytech-today-now/professional-video-downloader/v$version/install-bootstrap.ps1")) 'README install example is not pinned to the current release tag.'
    Assert-True ($readme -notmatch 'refs/heads/main') 'README still references the moving main branch in the install example.'
    Assert-True ($readme -match [regex]::Escape('powershell -ExecutionPolicy Bypass -Command')) 'README lost the Windows PowerShell install example.'
    Assert-True ($readme -match [regex]::Escape('powershell -NoProfile -ExecutionPolicy Bypass -Command')) 'README lost the Command Prompt install example.'
    Assert-True ($readme -match [regex]::Escape('%ProgramFiles%\myTech.Today\professional-video-downloader')) 'README does not document the Windows machine-wide install root.'
    Assert-True ($readme -match [regex]::Escape('%ProgramData%\Microsoft\Windows\Start Menu\Programs\myTech.Today')) 'README does not document the machine-wide Start Menu shortcut path.'
    Assert-True ($readme -match [regex]::Escape('/Applications/mytech-today/professional-video-downloader/')) 'README does not document the macOS install root.'
    Assert-True ($readme -match [regex]::Escape('/usr/bin/mytech-today/professional-video-downloader/')) 'README does not document the Linux install root.'
    Assert-True ($readme -match 'LOCALAPPDATA|XDG_STATE_HOME|Application Support|local state') 'README does not describe the writable runtime-state location.'
}

Describe 'Downloader helpers' {
    It 'covers URL validation and list expansion' {
        Invoke-UrlValidationScenario
    }

    It 'covers batch-source detection for local files, remote lists, and plain text rejection' {
        Invoke-BatchSourceScenario
    }

    It 'covers interactive local-file intake' {
        Invoke-InteractiveLocalFileScenario
    }

    It 'covers interactive remote batch intake' {
        Invoke-InteractiveRemoteBatchScenario
    }

    It 'covers empty interactive input without delay' {
        Invoke-EmptyInteractiveInputScenario
    }

    It 'covers yt-dlp argument building' {
        Invoke-ArgumentBuilderScenario
    }

    It 'covers yt-dlp version parsing and minimum version checks' {
        Invoke-VersionGateScenario
    }

    It 'validates GitHub latest stable release responses without network access' {
        Invoke-LatestStableYtDlpReleaseScenarios
    }

    It 'covers the offline yt-dlp stable-release update preflight and failure boundaries' {
        Invoke-YtDlpUpdatePreflightScenarios
    }

    It 'covers the opt-in exit pause gate' {
        Invoke-ExitPauseScenario
    }
}

Describe 'Metadata' {
    It 'keeps README install commands and version metadata aligned' {
        Assert-StaticMetadata
    }
}

Describe 'Main script smoke' {
    It 'covers runtime logging format and warning behavior' {
        Invoke-ValidationScript 'version-sync.ps1'
    }
}

Describe 'Bootstrap' {
    It 'keeps the bootstrap installer security checks intact' {
        Invoke-ValidationScript 'install-bootstrap-security.ps1'
    }
}
