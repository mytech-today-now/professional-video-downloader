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
$script:WebResponses = @{}
$script:WebRequestCalls = [System.Collections.Generic.List[string]]::new()
$script:ReadHostQueue = [System.Collections.Generic.Queue[string]]::new()
$script:ColorInfo = 'Cyan'
$script:ColorMuted = 'DarkGray'
$script:ColorWarning = 'Yellow'
$script:ColorError = 'Red'

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
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-batch-source-" + [guid]::NewGuid().ToString('N'))
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

function Convert-ToQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function New-TestWebResponse {
    param(
        [string]$Body,
        [string]$ContentType = 'text/plain; charset=utf-8'
    )

    return [pscustomobject]@{
        Content       = $Body
        Headers       = @{ 'Content-Type' = $ContentType }
        BaseResponse   = [pscustomobject]@{ ContentType = $ContentType }
        ContentType   = $ContentType
    }
}

function Set-WebResponse {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body,
        [string]$ContentType = 'text/plain; charset=utf-8'
    )

    $script:WebResponses[$Uri] = [pscustomobject]@{
        Response     = New-TestWebResponse -Body $Body -ContentType $ContentType
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

function Write-TestWebResponseBody {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Body
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Body, $utf8NoBom)
}

function Invoke-TestWebRequest {
    [CmdletBinding()]
    param(
        [string]$Uri,
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

    Write-TestWebResponseBody -Path $OutFile -Body ([string]$entry.Response.Content)
    return $entry.Response
}

function Clear-TestState {
    $script:HostMessages.Clear()
    $script:WebResponses = @{}
    $script:WebRequestCalls = [System.Collections.Generic.List[string]]::new()
    $script:ReadHostQueue = [System.Collections.Generic.Queue[string]]::new()
}

function global:Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [switch]$UseBasicParsing,
        [int]$TimeoutSec,
        [int]$OperationTimeoutSeconds,
        [int]$MaximumRedirection,
        [string]$OutFile
    )

    Invoke-TestWebRequest @PSBoundParameters
}

function Export-WebResponseFixture {
    param([Parameter(Mandatory)][string]$Path)

    $items = foreach ($uri in $script:WebResponses.Keys) {
        $entry = $script:WebResponses[$uri]
        [pscustomobject]@{
            Uri          = $uri
            Body         = if ($entry.Response) { $entry.Response.Content } else { $null }
            ContentType  = if ($entry.Response) { $entry.Response.ContentType } else { $null }
            ThrowMessage = $entry.ThrowMessage
        }
    }

    $json = @($items) | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $Path -Value $json -Encoding Ascii
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
        'Read-UrlsFromSource'
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

    $helperPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pvd-batch-helper-" + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $helperPath -Value ($definitions -join "`r`n`r`n") -Encoding Ascii
    return $helperPath
}

function Invoke-InteractiveReadScenario {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$QueuedResponses
    )

    Clear-TestState
    foreach ($response in $QueuedResponses) {
        [void]$script:ReadHostQueue.Enqueue($response)
    }

    function global:Write-Colored {
        param(
            [string]$Message,
            [string]$Color
        )

        [void]$script:HostMessages.Add($Message)
    }

    function global:Read-Host {
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [object[]]$RemainingArgs
        )

        if ($script:ReadHostQueue.Count -eq 0) { return '' }
        return $script:ReadHostQueue.Dequeue()
    }

    function global:Invoke-WebRequest {
        [CmdletBinding()]
        param(
            [string]$Uri,
            [switch]$UseBasicParsing,
            [int]$TimeoutSec,
            [int]$OperationTimeoutSeconds,
            [int]$MaximumRedirection,
            [string]$OutFile
        )

        Invoke-TestWebRequest @PSBoundParameters
    }

    $result = Read-UrlListInteractive
    return [pscustomobject]@{
        Result = $result
        Messages = @($script:HostMessages)
        WebRequests = @($script:WebRequestCalls)
    }
}

function Invoke-MainScriptRun {
    param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][string[]]$UrlArgs,
        [Parameter(Mandatory)][string]$ResponsesJsonPath
    )

    $hostExe = Get-PowerShellHost
    $scriptPath = (Join-Path $FixtureRoot 'professional-video-downloader.ps1').Replace("'", "''")
    $transcriptPath = Join-Path $FixtureRoot 'run.transcript.log'
    $stdoutPath = Join-Path $FixtureRoot 'run.stdout.log'
    $stderrPath = Join-Path $FixtureRoot 'run.stderr.log'
    $wrapperPath = Join-Path $FixtureRoot 'run-wrapper.ps1'
    $urlLiteral = '@(' + (($UrlArgs | ForEach-Object { Convert-ToQuotedLiteral $_ }) -join ',') + ')'

    $wrapper = @'
Start-Transcript -LiteralPath '__TRANSCRIPT__' -Force | Out-Null
$global:WebRequestCount = 0
$webResponses = Get-Content -LiteralPath '__RESPONSES__' -Raw -ErrorAction Stop | ConvertFrom-Json
$webResponseMap = @{}
foreach ($entry in @($webResponses)) {
    $webResponseMap[$entry.Uri] = $entry
}
function Write-TestWebResponseBody {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Body
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Body, $utf8NoBom)
}
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [switch]$UseBasicParsing,
        [int]$TimeoutSec,
        [int]$OperationTimeoutSeconds,
        [int]$MaximumRedirection,
        [string]$OutFile
    )

    $global:WebRequestCount++
    if (-not $webResponseMap.ContainsKey($Uri)) {
        throw "Unexpected web request: $Uri"
    }

    $entry = $webResponseMap[$Uri]
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
        Write-TestWebResponseBody -Path $OutFile -Body ([string]$entry.Body)
    }

    return [pscustomobject]@{
        Content     = $entry.Body
        Headers     = @{ 'Content-Type' = $entry.ContentType }
        BaseResponse = [pscustomobject]@{ ContentType = $entry.ContentType }
        ContentType = $entry.ContentType
    }
}
function global:yt-dlp {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $global:LASTEXITCODE = 0
    if ($Args -contains '--version') {
        Write-Output 'yt-dlp 2026.08.19'
        return
    }
    Write-Output '[download] Destination: __DOWNLOAD__/fake.mp4'
}
& '__SCRIPT__' -Url __URL_ARGS__
Write-Output ("WEBREQUEST_COUNT:{0}" -f $global:WebRequestCount)
$childExitCodeVar = Get-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue
if ($childExitCodeVar -and $null -ne $childExitCodeVar.Value) {
    exit $childExitCodeVar.Value
}
exit ([int](-not $?))
'@
    $wrapper = $wrapper.Replace('__TRANSCRIPT__', $transcriptPath.Replace("'", "''"))
    $wrapper = $wrapper.Replace('__RESPONSES__', $ResponsesJsonPath.Replace("'", "''"))
    $wrapper = $wrapper.Replace('__SCRIPT__', $scriptPath)
    $wrapper = $wrapper.Replace('__URL_ARGS__', $urlLiteral)
    $wrapper = $wrapper.Replace('__DOWNLOAD__', (Join-Path $FixtureRoot 'downloads').Replace("'", "''"))
    Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding Ascii

    $startArgs = @{
        FilePath = $hostExe
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperPath)
        PassThru = $true
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError = $stderrPath
    }
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $startArgs.WindowStyle = 'Hidden'
    }

    $proc = Start-Process @startArgs
    $null = $proc.WaitForExit(90000)
    $proc.Refresh()
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw 'Main script run timed out after 90 seconds.'
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
    }
}

$helperPath = Import-DownloaderHelpers -ScriptPath (Join-Path $RootPath 'professional-video-downloader.ps1')
. $helperPath
$RemoteBatchSourceTimeoutSec = 15
$RemoteBatchSourceMaxRedirections = 5
$RemoteBatchSourceMaxBytes = 1MB

function Invoke-ProbeMatrixScenario {
    Clear-TestState

    $localFile = Join-Path (New-TestWorkspace) 'urls.txt'
    Set-Content -LiteralPath $localFile -Encoding Ascii -Value "https://example.com/local-one`nhttps://example.com/local-two"

    Set-WebResponse -Uri 'https://example.com/raw' -Body "https://example.com/raw-one`nhttps://example.com/raw-two" -ContentType 'text/plain; charset=utf-8'
    Set-WebResponse -Uri 'https://example.com/content' -Body "https://example.com/content-one`nhttps://example.com/content-two" -ContentType 'text/plain; charset=utf-8'
    Set-WebResponse -Uri 'https://example.com/empty' -Body '' -ContentType 'text/plain; charset=utf-8'
    Set-WebResponse -Uri 'https://example.com/binary' -Body "binary$([char]0)value" -ContentType 'application/octet-stream'

    try {
        Assert-True ((Get-BatchSourceProbe -Token $localFile).IsBatchSource) 'Local files should remain valid batch sources.'
        Assert-True ((Get-BatchSourceProbe -Token 'https://example.com/raw').IsBatchSource) 'Generic /raw endpoints should be recognized as batch sources.'
        Assert-True ((Get-BatchSourceProbe -Token 'https://example.com/content').IsBatchSource) 'Generic /content endpoints should be recognized as batch sources.'
        Assert-True (-not (Get-BatchSourceProbe -Token 'https://www.youtube.com/watch?v=dQw4w9WgXcQ').ShouldProbe) 'Normal video URLs should stay direct download targets.'
        Assert-True ($script:WebRequestCalls.Count -eq 2) 'Only the raw batch candidates should have been probed.'
    }
    finally {
        Remove-TestWorkspace -Path (Split-Path -Parent $localFile)
    }
}

function Invoke-UrlListExpansionScenario {
    $empty = Expand-UrlList -Raw @()
    Assert-True (($null -eq $empty) -or ($empty.Count -eq 0)) 'Empty URL input should expand to an empty list.'

    $expanded = Expand-UrlList -Raw @(
        'https://example.com/raw',
        'https://example.com/path;foo=bar',
        'https://example.com/raw',
        'https://example.com/alpha https://example.com/beta',
        'https://example.com/gamma,https://example.com/delta;https://example.com/epsilon',
        '   '
    )

    $expected = @(
        'https://example.com/raw',
        'https://example.com/path;foo=bar',
        'https://example.com/alpha',
        'https://example.com/beta',
        'https://example.com/gamma',
        'https://example.com/delta',
        'https://example.com/epsilon'
    )

    Assert-True ($expanded.Count -eq $expected.Count) ("Expanded URL list count mismatch. Expected {0} but got {1}." -f $expected.Count, $expanded.Count)
    for ($i = 0; $i -lt $expected.Count; $i++) {
        Assert-True ($expanded[$i] -eq $expected[$i]) ("Expanded URL order mismatch at index {0}. Expected {1} but got {2}." -f $i, $expected[$i], $expanded[$i])
    }

    $semicolonBatch = Expand-UrlList -Raw @('https://example.com/left;https://example.com/right')
    Assert-True (($semicolonBatch -join '|') -eq 'https://example.com/left|https://example.com/right') 'Semicolon-delimited URLs should still expand.'

    $commaBatch = Expand-UrlList -Raw @('https://example.com/one,https://example.com/two')
    Assert-True (($commaBatch -join '|') -eq 'https://example.com/one|https://example.com/two') 'Comma-delimited URLs should still expand.'

    $dedup = Expand-UrlList -Raw @(
        'https://example.com/first',
        'https://example.com/second',
        'https://example.com/first',
        'https://example.com/third',
        'https://example.com/second'
    )
    Assert-True (($dedup -join '|') -eq 'https://example.com/first|https://example.com/second|https://example.com/third') 'Duplicate URLs should preserve first-seen order.'
}

function Invoke-InteractiveLocalFileScenario {
    Clear-TestState

    $workspace = New-TestWorkspace
    $filePath = Join-Path $workspace 'interactive-urls.txt'
    Set-Content -LiteralPath $filePath -Encoding Ascii -Value "https://example.com/interactive-one`nhttps://example.com/interactive-two"

    try {
        $result = Invoke-InteractiveReadScenario -FilePath $filePath -QueuedResponses @($filePath, '')
        Assert-True ($result.Result.Count -eq 1) 'Interactive helper should return the raw file body as a single batch token.'
        Assert-True ($result.Result[0] -match 'interactive-one') 'Interactive helper did not read the local file body.'
        Assert-True ($result.Result[0] -match 'interactive-two') 'Interactive helper did not preserve the full local file body.'
        Assert-True ($result.WebRequests.Count -eq 0) 'Local file interactive input should not trigger web requests.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-InteractiveBatchSourceFailureScenario {
    Clear-TestState

    $workspace = New-TestWorkspace
    $filePath = Join-Path $workspace 'broken-batch.txt'
    Set-Content -LiteralPath $filePath -Encoding Ascii -Value "https://example.com/ignored"

    try {
        [void]$script:ReadHostQueue.Enqueue($filePath)
        [void]$script:ReadHostQueue.Enqueue('https://example.com/keep-me')
        [void]$script:ReadHostQueue.Enqueue('')

        function global:Write-Colored {
            param(
                [string]$Message,
                [string]$Color
            )

            [void]$script:HostMessages.Add($Message)
        }

        function global:Read-Host {
            param(
                [Parameter(ValueFromRemainingArguments = $true)]
                [object[]]$RemainingArgs
            )

            if ($script:ReadHostQueue.Count -eq 0) { return '' }
            return $script:ReadHostQueue.Dequeue()
        }

        function Read-UrlsFromSource {
            param(
                [Parameter(Mandatory)][string]$Source,
                [psobject]$Probe
            )

            if ($Source -eq $filePath) {
                throw "Input file not found: $Source"
            }

            throw "Unexpected batch source in test: $Source"
        }

        $result = Read-UrlListInteractive
        $messageText = ($script:HostMessages -join "`n")
        $warningCount = ([regex]::Matches($messageText, [regex]::Escape($filePath))).Count

        Assert-True (($result -join '|') -eq 'https://example.com/keep-me') 'Interactive batch-source failure should skip the broken token and keep later URLs.'
        Assert-True ($warningCount -eq 1) 'Interactive batch-source failure should surface the original source once.'
        Assert-True ($messageText -match [regex]::Escape("Warning: Input file not found: $filePath")) 'Interactive batch-source failure did not report the original read error.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-MainScriptRoutingScenario {
    $workspace = New-TestWorkspace
    $fixtureRoot = Join-Path $workspace 'fixture'
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RootPath 'professional-video-downloader.ps1') -Destination $fixtureRoot -Force
    Copy-Item -LiteralPath (Join-Path $RootPath 'VERSION') -Destination $fixtureRoot -Force

    $responsesPath = Join-Path $workspace 'responses.json'
    $rawUrl = 'https://example.com/raw'
    $contentUrl = 'https://example.com/content'
    Set-WebResponse -Uri $rawUrl -Body "https://example.com/raw-one`nhttps://example.com/raw-two" -ContentType 'text/plain; charset=utf-8'
    Set-WebResponse -Uri $contentUrl -Body "https://example.com/content-one`nhttps://example.com/content-two" -ContentType 'text/plain; charset=utf-8'
    Export-WebResponseFixture -Path $responsesPath

    $localList = Join-Path $workspace 'urls.txt'
    Set-Content -LiteralPath $localList -Encoding Ascii -Value "https://example.com/local-one`nhttps://example.com/local-two"

    try {
        $rawRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -UrlArgs @($rawUrl) -ResponsesJsonPath $responsesPath
        Assert-True ($rawRun.ExitCode -eq 0) "Raw batch URL run failed.`n$($rawRun.Output)"
        Assert-True ($rawRun.Output -match [regex]::Escape('https://example.com/raw-one')) 'Raw endpoint contents were not queued for download.'
        Assert-True ($rawRun.Output -match 'WEBREQUEST_COUNT:1') 'Raw endpoint should have been fetched once.'

        $contentRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -UrlArgs @($contentUrl) -ResponsesJsonPath $responsesPath
        Assert-True ($contentRun.ExitCode -eq 0) "Content endpoint run failed.`n$($contentRun.Output)"
        Assert-True ($contentRun.Output -match [regex]::Escape('https://example.com/content-one')) 'Content endpoint contents were not queued for download.'
        Assert-True ($contentRun.Output -match 'WEBREQUEST_COUNT:1') 'Content endpoint should have been fetched once.'

        $localRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -UrlArgs @($localList) -ResponsesJsonPath $responsesPath
        Assert-True ($localRun.ExitCode -eq 0) "Local -Url file run failed.`n$($localRun.Output)"
        Assert-True ($localRun.Output -match [regex]::Escape('https://example.com/local-one')) 'Local -Url input did not load the file contents.'
        Assert-True ($localRun.Output -match 'WEBREQUEST_COUNT:0') 'Local -Url file input should not trigger web requests.'

        $videoRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -UrlArgs @('https://www.youtube.com/watch?v=dQw4w9WgXcQ') -ResponsesJsonPath $responsesPath
        Assert-True ($videoRun.ExitCode -eq 0) "Video URL run failed.`n$($videoRun.Output)"
        Assert-True ($videoRun.Output -match 'https://www.youtube.com/watch\?v=dQw4w9WgXcQ') 'Video URL should be routed directly.'
        Assert-True ($videoRun.Output -match 'WEBREQUEST_COUNT:0') 'Direct video URLs should not be probed as batch sources.'

        $mixedList = Join-Path $workspace 'mixed-urls.txt'
        Set-Content -LiteralPath $mixedList -Encoding Ascii -Value "https://example.com/file-one`nhttps://example.com/file-two"

        $mixedRun = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -UrlArgs @(
            'https://example.com/raw;session=1',
            $mixedList,
            'https://example.com/batch-one,https://example.com/batch-two;https://example.com/batch-three'
        ) -ResponsesJsonPath $responsesPath
        Assert-True ($mixedRun.ExitCode -eq 0) "Mixed input run failed.`n$($mixedRun.Output)"
        Assert-True ($mixedRun.Output -match [regex]::Escape('https://example.com/raw;session=1')) 'Mixed input run split a semicolon-bearing raw URL.'
        Assert-True ($mixedRun.Output -match [regex]::Escape('https://example.com/file-one')) 'Mixed input run did not load the file path contents.'
        Assert-True ($mixedRun.Output -match [regex]::Escape('https://example.com/file-two')) 'Mixed input run did not load the full file path contents.'
        Assert-True ($mixedRun.Output -match [regex]::Escape('https://example.com/batch-one')) 'Mixed input run did not expand the inline batch list.'
        Assert-True ($mixedRun.Output -match [regex]::Escape('https://example.com/batch-two')) 'Mixed input run did not keep comma-delimited entries.'
        Assert-True ($mixedRun.Output -match [regex]::Escape('https://example.com/batch-three')) 'Mixed input run did not keep semicolon-delimited entries.'
        Assert-True ($mixedRun.Output -match 'WEBREQUEST_COUNT:0') 'Mixed input run should not trigger web requests.'

        $rawPos = $mixedRun.Output.IndexOf('https://example.com/raw;session=1')
        $filePos = $mixedRun.Output.IndexOf('https://example.com/file-one')
        $batchPos = $mixedRun.Output.IndexOf('https://example.com/batch-one')
        Assert-True ($rawPos -ge 0 -and $filePos -gt $rawPos -and $batchPos -gt $filePos) 'Mixed inputs did not preserve first-seen order.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-MainScriptBatchSourceFailureScenario {
    Clear-TestState

    $workspace = New-TestWorkspace
    $fixtureRoot = Join-Path $workspace 'fixture'
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RootPath 'professional-video-downloader.ps1') -Destination $fixtureRoot -Force
    Copy-Item -LiteralPath (Join-Path $RootPath 'VERSION') -Destination $fixtureRoot -Force

    $responsesPath = Join-Path $workspace 'responses.json'
    Export-WebResponseFixture -Path $responsesPath

    $badList = Join-Path $workspace 'broken-batch.txt'
    Set-Content -LiteralPath $badList -Encoding Ascii -Value "https://example.com/ignored"

    $scriptCopy = Join-Path $fixtureRoot 'professional-video-downloader.ps1'
    $scriptText = Get-Content -LiteralPath $scriptCopy -Raw -ErrorAction Stop
    $escapedBadList = $badList.Replace("'", "''")
    $overrideText = @'
function Read-UrlsFromSource {
    param(
        [Parameter(Mandatory)][string]$Source,
        [psobject]$Probe
    )

    if ($Source -eq '__BAD_LIST__') {
        throw "Input file not found: $Source"
    }

    throw "Unexpected batch source in test: $Source"
}
'@
    $overrideText = $overrideText.Replace('__BAD_LIST__', $escapedBadList)
    $scriptText = $scriptText.Replace('# ====================== MAIN SCRIPT ======================', ($overrideText + "`r`n# ====================== MAIN SCRIPT ======================"))
    Set-Content -LiteralPath $scriptCopy -Value $scriptText -Encoding UTF8

    try {
        $result = Invoke-MainScriptRun -FixtureRoot $fixtureRoot -UrlArgs @($badList, 'https://example.com/keep-me') -ResponsesJsonPath $responsesPath
        $consoleOutput = $result.Output
        $transcriptEnd = 'PowerShell transcript end'
        $consoleIndex = $consoleOutput.LastIndexOf($transcriptEnd)
        if ($consoleIndex -ge 0) {
            $consoleOutput = $consoleOutput.Substring($consoleIndex + $transcriptEnd.Length)
        }
        $badCount = ([regex]::Matches($consoleOutput, [regex]::Escape($badList))).Count

        Assert-True ($result.ExitCode -eq 0) "Main script -Url failure scenario did not complete cleanly.`n$($result.Output)"
        Assert-True ($result.Output -match [regex]::Escape('https://example.com/keep-me')) 'Main script -Url failure scenario did not keep later valid URLs.'
        Assert-True ($result.Output -match [regex]::Escape("Warning: Input file not found: $badList")) 'Main script -Url failure scenario did not report the original read error.'
        Assert-True ($badCount -eq 1) ("Main script -Url failure scenario should mention the broken source exactly once. Count={0}`n{1}" -f $badCount, $result.Output)
        Assert-True ($result.Output -match 'WEBREQUEST_COUNT:0') 'Main script -Url failure scenario should not trigger web requests.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-InvalidBatchSourceScenario {
    Clear-TestState

    $workspace = New-TestWorkspace
    $filePath = Join-Path $workspace 'urls.txt'
    Set-Content -LiteralPath $filePath -Encoding Ascii -Value "https://example.com/local-one"

    Set-WebResponse -Uri 'https://example.com/empty' -Body '' -ContentType 'text/plain; charset=utf-8'
    Set-WebResponse -Uri 'https://example.com/binary' -Body "binary$([char]0)value" -ContentType 'application/octet-stream'
    Set-WebResponse -Uri 'https://example.com/plain' -Body 'notes without urls' -ContentType 'text/plain; charset=utf-8'

    try {
        $emptyCaught = $false
        try {
            Read-UrlsFromSource -Source 'https://example.com/empty' | Out-Null
        }
        catch {
            $emptyCaught = $_.Exception.Message -match 'not a valid batch source'
        }
        Assert-True $emptyCaught 'Empty remote responses should be rejected with a clear batch-source message.'

        $binaryCaught = $false
        try {
            Read-UrlsFromSource -Source 'https://example.com/binary' | Out-Null
        }
        catch {
            $binaryCaught = $_.Exception.Message -match 'not a valid batch source'
        }
        Assert-True $binaryCaught 'Binary remote responses should be rejected with a clear batch-source message.'

        $plainCaught = $false
        try {
            Read-UrlsFromSource -Source 'https://example.com/plain' | Out-Null
        }
        catch {
            $plainCaught = $_.Exception.Message -match 'not a valid batch source'
        }
        Assert-True $plainCaught 'Plain-text responses without URL-like tokens should be rejected clearly.'
    }
    finally {
        Remove-TestWorkspace -Path $workspace
    }
}

function Invoke-RemoteTimeoutScenario {
    Clear-TestState

    Set-WebResponseError -Uri 'https://example.com/slow.txt' -Message 'The request timed out after 15 seconds.'

    $probe = Get-BatchSourceProbe -Token 'https://example.com/slow.txt' -ForceRemoteProbe
    Assert-True (-not $probe.IsBatchSource) 'Slow remote responses should not be accepted as batch sources.'
    Assert-True ($probe.Reason -match 'timed out after 15 seconds') 'Slow remote responses should surface a timeout message.'
    Assert-True ($probe.Reason -match 'batch source') 'Slow remote response error text should stay batch-source specific.'
    Assert-True ($script:WebRequestCalls.Count -eq 1) 'Slow remote response should be attempted once.'
}

function Invoke-RemoteOversizeScenario {
    Clear-TestState

    $oversizeUrl = 'https://example.com/large.txt'
    $oversizeBody = "https://example.com/one`n" + ('a' * (1MB + 1))
    Set-WebResponse -Uri $oversizeUrl -Body $oversizeBody -ContentType 'text/plain; charset=utf-8'

    $probe = Get-BatchSourceProbe -Token $oversizeUrl -ForceRemoteProbe
    Assert-True (-not $probe.IsBatchSource) 'Oversize remote responses should be rejected as batch sources.'
    Assert-True ($probe.Reason -match 'exceeded the .* byte limit') 'Oversize remote responses should mention the byte ceiling.'
    Assert-True ($probe.Reason -match '1,048,576') 'Oversize remote responses should report the configured size limit.'
    Assert-True ($script:WebRequestCalls.Count -eq 1) 'Oversize remote response should be fetched once.'
}

function Invoke-RemoteRedirectScenario {
    Clear-TestState

    Set-WebResponseError -Uri 'https://example.com/redirect-heavy.txt' -Message 'Maximum redirection count exceeded.'

    $probe = Get-BatchSourceProbe -Token 'https://example.com/redirect-heavy.txt' -ForceRemoteProbe
    Assert-True (-not $probe.IsBatchSource) 'Redirect-heavy remote responses should not be accepted as batch sources.'
    Assert-True ($probe.Reason -match 'redirect limit') 'Redirect-heavy remote responses should surface the redirect ceiling.'
    Assert-True ($script:WebRequestCalls.Count -eq 1) 'Redirect-heavy remote response should be attempted once.'
}

function Invoke-RemoteSmallListScenario {
    Clear-TestState

    $smallUrl = 'https://example.com/small-list.txt'
    $smallBody = "https://example.com/alpha`nhttps://example.com/bravo"
    Set-WebResponse -Uri $smallUrl -Body $smallBody -ContentType 'text/plain; charset=utf-8'

    $probe = Get-BatchSourceProbe -Token $smallUrl -ForceRemoteProbe
    Assert-True $probe.IsBatchSource 'Normal small remote lists should still be accepted.'

    $body = Read-UrlsFromSource -Source $smallUrl -Probe $probe
    Assert-True ($body.Count -eq 1) 'Normal small remote lists should still load as a single batch body.'
    Assert-True ($body[0] -match 'https://example.com/alpha') 'Normal small remote lists should keep the first URL.'
    Assert-True ($body[0] -match 'https://example.com/bravo') 'Normal small remote lists should keep the second URL.'
    Assert-True ($script:WebRequestCalls.Count -eq 1) 'Normal small remote lists should be fetched once.'
}

try {
    Write-Step 'Positive: raw-text URLs are recognized without a file-like suffix'
    Invoke-ProbeMatrixScenario

    Write-Step 'Positive: URL list expansion preserves punctuation and first-seen order'
    Invoke-UrlListExpansionScenario

    Write-Step 'Positive: interactive local file paths still load URL batches'
    Invoke-InteractiveLocalFileScenario

    Write-Step 'Negative: unreadable batch sources are skipped in the interactive prompt'
    Invoke-InteractiveBatchSourceFailureScenario

    Write-Step 'Positive: -Url mode keeps raw files, raw endpoints, and video URLs on the right path'
    Invoke-MainScriptRoutingScenario

    Write-Step 'Negative: unreadable batch sources are skipped in the -Url path'
    Invoke-MainScriptBatchSourceFailureScenario

    Write-Step 'Negative: empty, binary, and non-list text responses fail with a clear batch-source message'
    Invoke-InvalidBatchSourceScenario

    Write-Step 'Negative: slow remote sources fail with a timeout message'
    Invoke-RemoteTimeoutScenario

    Write-Step 'Negative: oversize remote sources fail with a size limit message'
    Invoke-RemoteOversizeScenario

    Write-Step 'Negative: redirect-heavy remote sources fail with a redirect limit message'
    Invoke-RemoteRedirectScenario

    Write-Step 'Positive: normal small remote lists still load successfully'
    Invoke-RemoteSmallListScenario

    Write-Host '[PASS] Batch-source detection validation passed.' -ForegroundColor Green
}
finally {
    if ($helperPath -and (Test-Path -LiteralPath $helperPath)) {
        Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
    }
}
