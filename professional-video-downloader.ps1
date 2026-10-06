#Requires -Version 5.1

<#
.SYNOPSIS
    Professional Video Downloader — a yt-dlp wrapper supporting 1,800+ sites.

.DESCRIPTION
    Robust, user-friendly PowerShell wrapper around yt-dlp. Accepts any well-formed
    http(s) URL and lets yt-dlp's extractor registry decide what it can extract.
    A curated platform registry drives friendly platform detection and advisory
    warnings (DRM-protected services, cookie-gated content, region-locked content,
    NSFW). Supports audio-only extraction, optional playlist/channel mode, and
    cookie passthrough for login-gated content.

    Known categories (non-exhaustive):
      Video        : YouTube (incl. Shorts, Playlists, Channels), Vimeo, Dailymotion,
                     Twitch (streams/VODs/clips), Facebook/Meta, Instagram, TikTok,
                     X/Twitter, Reddit, Bilibili, Rumble, Odysee/LBRY, Snapchat,
                     Substack, PeerTube (any instance, via generic extractor).
      Adult/NSFW   : Pornhub, XVideos, XNXX, YouPorn, RedTube, Tube8, SpankBang,
                     Motherless, Heavy-R, Eporner, TNAFlix, and others.
      Streaming/TV : Netflix, Disney+, Hulu, Amazon Prime Video, Paramount+,
                     Discovery+, Apple TV+, Crunchyroll, Funimation (DRM-protected;
                     see DRM note below).
      News & Media : CNN, BBC, NBC, ABC, CBS, Al Jazeera, New York Times, Reuters,
                     ARD, ZDF, France TV, TF1.
      Music/Audio  : SoundCloud, Bandcamp, Vevo, Spotify (metadata only — DRM),
                     Apple Music (previews only — DRM).
      Education    : TED, Coursera, Udemy, Khan Academy.
      Other        : 9GAG, Imgur, Tumblr, Pinterest, LinkedIn, VK, Rutube, Newgrounds.

.VERSION
    1.0.0   # Single source of truth: VERSION file.

.AUTHOR
    Built as a world-class automation solution.

.NOTES
    Prerequisite: yt-dlp must be installed and available in PATH.
        winget install yt-dlp      (or)   choco install yt-dlp
        See https://github.com/yt-dlp/yt-dlp/releases/latest

    Login-gated / paywalled content (Instagram private, Reddit NSFW, Substack
    subscriber-only posts, news paywalls, Twitch sub-only VODs, Coursera/Udemy
    courses): use -CookiesFromBrowser to forward an existing browser session,
    e.g. -CookiesFromBrowser firefox.

    DRM-protected streaming services (Netflix, Disney+, Hulu, Prime Video,
    Paramount+, Discovery+, Apple TV+, Crunchyroll, Funimation, Spotify, Apple
    Music) use Widevine/FairPlay encryption. yt-dlp cannot decrypt these streams;
    downloads from those services will almost always fail. This is a fundamental
    DRM limitation, not a script bug.

    Cloudflare anti-bot challenge (HTTP 403): some sites — particularly those
    handled by yt-dlp's generic extractor — sit behind Cloudflare. The script
    auto-detects the failure and transparently retries once with browser TLS
    impersonation (yt-dlp's --impersonate / --extractor-args impersonate). Use
    -Impersonate to enable this from the first attempt. Requires a recent yt-dlp
    build with curl_cffi support.

    Unquoted multi-URL input: -Url accepts one or many raw URLs without quotes.
    If a URL contains '&', wrap the raw URL in quotes before passing it.
    Do not paste Markdown link text like [https://...](...), because PowerShell
    will treat '&' as the call operator before this script receives the URL.
    Separate URLs with one or more spaces, a comma, a semicolon, and/or newlines.
    Semicolons inside a single URL stay intact; only semicolons between URLs are
    treated as list separators.
    Each URL is downloaded in turn, with per-URL retry handling, and a summary is
    printed at the end. Interactive mode prompts for URLs and ends on a blank line.

    PowerShell tokenization caveat: a bare URL containing '&' (e.g. YouTube
    'watch?v=X&t=10') must be quoted on the command line because PowerShell
    treats '&' as the call operator. Paste the raw URL, not Markdown link text.
    URLs with '#fragments' are fine unquoted —
    PowerShell strips the fragment, which yt-dlp ignores anyway.

.USAGE
    .\professional-video-downloader.ps1
    .\professional-video-downloader.ps1 https://youtube.com/watch?v=ABC
    .\professional-video-downloader.ps1 https://vimeo.com/123 https://rumble.com/v456 https://tiktok.com/@u/video/789
    .\professional-video-downloader.ps1 -Url https://a.com/x,https://b.com/y;https://c.com/z
    .\professional-video-downloader.ps1 -InputFile .\urls.txt
    .\professional-video-downloader.ps1 -InputFile https://example.com/list.txt
    .\professional-video-downloader.ps1 -Url "https://soundcloud.com/artist/track" -AudioOnly
    .\professional-video-downloader.ps1 -Url "https://www.youtube.com/playlist?list=..." -AllowPlaylist
    .\professional-video-downloader.ps1 -Url "https://www.instagram.com/p/..." -CookiesFromBrowser firefox
    .\professional-video-downloader.ps1 -Url "https://www.heavy-r.com/video/..." -Impersonate
#>

[CmdletBinding()]
param(
    # Accepts one or many URLs. ValueFromRemainingArguments lets the user pass
    # multiple positional URLs unquoted, separated by spaces. Each element is
    # then normalized by Expand-UrlList, which preserves valid URL punctuation
    # and only treats separators as lists when they clearly sit between URLs.
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    [Alias('Urls','U')]
    [string[]]$Url,

    # Local path or http(s) URL pointing to a text file containing URLs
    # delimited by any of: commas, semicolons, whitespace, tabs, newlines, CRLF.
    [Parameter()]
    [Alias('BatchFile','F')]
    [string]$InputFile,

    [Parameter()]
    [string]$DownloadPath,

    [Parameter()]
    [ValidateSet('chrome','chromium','edge','firefox','brave','opera','vivaldi','safari')]
    [string]$CookiesFromBrowser,

    [Parameter()]
    [switch]$AudioOnly,

    [Parameter()]
    [switch]$AllowPlaylist,

    [Parameter()]
    [switch]$Impersonate,

    # Keep the console open briefly at exit when a human explicitly wants the
    # legacy pause behavior. Automation and CI stay fast by default.
    [Parameter()]
    [switch]$PauseOnExit
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ====================== CONFIGURATION & CONSTANTS ======================
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

    $match = [regex]::Match($trimmed, '^\s*(?:yt-dlp(?:\s+version)?\s+)?(?<core>\d+(?:\.\d+){0,3})(?<suffix>[-+.]?[A-Za-z][A-Za-z0-9.-]*)?\s*$')
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
        throw ("Unable to determine yt-dlp version from '{0}'. Update yt-dlp through the same package manager or Python interpreter that installed it, then rerun the downloader." -f $InstalledVersionText)
    }

    if ($versionInfo.Version -lt $MinimumVersion -or ($versionInfo.Version -eq $MinimumVersion -and $versionInfo.Suffix)) {
        throw ("yt-dlp {0} is too old. Minimum required is {1}. Update it through the same package manager or Python interpreter that installed it, then rerun the downloader." -f $versionInfo.Raw, $MinimumVersionText)
    }

    return $versionInfo
}

function Get-YtDlpExecutablePath {
    $command = Get-Command -Name 'yt-dlp' -ErrorAction SilentlyContinue
    if (-not $command) {
        throw 'yt-dlp was not found in PATH. Install it, then rerun the downloader.'
    }
    if ($command.CommandType -ne [System.Management.Automation.CommandTypes]::Application) {
        throw ("yt-dlp resolves to a PowerShell {0}, so its executable cannot be identified safely. Remove the shadowing command or expose the intended yt-dlp executable in PATH, then rerun." -f $command.CommandType)
    }
    if ([string]::IsNullOrWhiteSpace($command.Source)) {
        throw 'The yt-dlp command resolved without an executable path. Restore a normal executable in PATH, then rerun.'
    }

    return $command.Source
}

function Get-YtDlpVersionText {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    try {
        $output = @(& $ExecutablePath --version 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        throw ("Could not run the yt-dlp version check for the resolved executable. {0}" -f $_.Exception.Message)
    }

    if ($exitCode -ne 0) {
        throw ("The yt-dlp executable did not return a version successfully (exit code {0}). Check that executable's permissions and runtime requirements, then rerun." -f $exitCode)
    }

    $versionText = $output | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ToString()) } | Select-Object -First 1
    if (-not $versionText) {
        throw 'The yt-dlp executable returned no version text. Restore or reinstall it through its owner, then rerun.'
    }

    return $versionText.ToString().Trim()
}

function Get-YtDlpStableReleaseVersionInfo {
    param([Parameter(Mandatory)][string]$ReleaseTag)

    $match = [regex]::Match($ReleaseTag, '^(?<date>\d{4}\.\d{2}\.\d{2})(?:\.(?<revision>\d+))?$')
    if (-not $match.Success) {
        throw 'GitHub returned a release tag that is not a stable yt-dlp version.'
    }

    $releaseDate = [datetime]::MinValue
    $dateParsed = [datetime]::TryParseExact(
        $match.Groups['date'].Value,
        'yyyy.MM.dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$releaseDate
    )
    if (-not $dateParsed) {
        throw 'GitHub returned a yt-dlp release tag with an invalid calendar date.'
    }

    $versionInfo = Get-YtDlpVersionInfo -VersionText $ReleaseTag
    if ($versionInfo.Suffix) {
        throw 'GitHub returned a release tag with a prerelease suffix.'
    }

    return $versionInfo
}

function Get-LatestStableYtDlpRelease {
    $releaseUri = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'
    try {
        $originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $response = Invoke-WebRequest -Uri $releaseUri -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 3 -Headers @{
                Accept = 'application/vnd.github+json'
                'User-Agent' = 'ProfessionalVideoDownloader'
            } -ErrorAction Stop
        }
        finally {
            [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
        }
        if ($null -eq $response) {
            throw 'GitHub returned no response object.'
        }

        $statusProperty = $response.PSObject.Properties['StatusCode']
        $contentProperty = $response.PSObject.Properties['Content']
        if (-not $statusProperty -or -not $contentProperty -or $statusProperty.Value -isnot [int] -or $contentProperty.Value -isnot [string]) {
            throw 'GitHub returned a malformed HTTP response.'
        }
        if ($statusProperty.Value -ne 200) {
            throw ("GitHub returned HTTP status {0}." -f $statusProperty.Value)
        }

        $content = $contentProperty.Value
        if (-not $content -or $content.Length -gt 1MB) {
            throw 'GitHub returned an empty or unexpectedly large release response.'
        }
        $release = $content | ConvertFrom-Json -ErrorAction Stop

        if ($null -eq $release -or $release -is [System.Array] -or $release -is [string]) {
            throw 'GitHub returned release data that was not a JSON object.'
        }
        $tagProperty = $release.PSObject.Properties['tag_name']
        $draftProperty = $release.PSObject.Properties['draft']
        $prereleaseProperty = $release.PSObject.Properties['prerelease']
        if (-not $tagProperty -or -not $draftProperty -or -not $prereleaseProperty) {
            throw 'GitHub release data is missing tag_name, draft, or prerelease.'
        }
        if ($tagProperty.Value -isnot [string] -or $draftProperty.Value -isnot [bool] -or $prereleaseProperty.Value -isnot [bool]) {
            throw 'GitHub release data has invalid tag_name, draft, or prerelease types.'
        }
        if ($draftProperty.Value -or $prereleaseProperty.Value) {
            throw 'GitHub latest release endpoint returned a draft or prerelease.'
        }

        $tag = $tagProperty.Value
        $versionInfo = Get-YtDlpStableReleaseVersionInfo -ReleaseTag $tag

        return [pscustomobject]@{
            Tag     = $tag
            Version = $versionInfo.Version
        }
    }
    catch {
        throw ("Unable to retrieve and validate the latest stable yt-dlp release from GitHub. Check network access and rerun. {0}" -f $_.Exception.Message)
    }
}

function Get-YtDlpInstallOwner {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return 'unknown'
    }

    try {
        $resolvedPath = [System.IO.Path]::GetFullPath($ExecutablePath)
        $wingetLinkPath = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\yt-dlp.exe'))
        if ([string]::Equals($resolvedPath, $wingetLinkPath, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $wingetLinkPath)) {
            $linkItem = Get-Item -LiteralPath $wingetLinkPath -Force -ErrorAction Stop
            if (($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return 'winget'
            }
        }
    }
    catch {}

    return 'unknown'
}

function Invoke-YtDlpOwnerUpdate {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$InstalledVersion
    )

    if ($Owner -ne 'winget') {
        throw 'This yt-dlp installation owner is not supported for automatic updates.'
    }
    if ((Get-YtDlpInstallOwner -ExecutablePath $ExecutablePath) -ne $Owner) {
        throw 'The resolved yt-dlp executable no longer matches the WinGet links path. No update was attempted.'
    }

    $winget = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget -or [string]::IsNullOrWhiteSpace($winget.Source)) {
        throw 'The executable is in the WinGet links directory, but WinGet is unavailable. Restore WinGet, then rerun.'
    }

    $listOutput = @(& $winget.Source list --id 'yt-dlp.yt-dlp' --exact --source 'winget' --disable-interactivity 2>&1)
    $listExitCode = $LASTEXITCODE
    if ($listExitCode -ne 0 -or (($listOutput -join "`n") -notmatch '(?i)yt-dlp\.yt-dlp')) {
        throw 'WinGet did not confirm the installed yt-dlp package. No update was attempted. Repair or reinstall yt-dlp with WinGet, then rerun.'
    }

    Write-Colored ("Updating yt-dlp {0} to latest stable {1} through WinGet..." -f $InstalledVersion, $ExpectedVersion) -Color $ColorInfo
    Write-Log -Message 'yt-dlp update started' -Context @{
        version = $InstalledVersion
        target  = $ExpectedVersion
        owner   = $Owner
    }

    $arguments = @(
        'upgrade', '--id', 'yt-dlp.yt-dlp', '--exact', '--version', $ExpectedVersion,
        '--source', 'winget', '--scope', 'user', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    )
    $null = @(& $winget.Source @arguments 2>&1)
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
    }
}

function Invoke-YtDlpUpdatePreflight {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [scriptblock]$VersionReader,
        [scriptblock]$ReleaseReader,
        [scriptblock]$OwnerResolver,
        [scriptblock]$ExecutableResolver,
        [scriptblock]$UpdateAction
    )

    if (-not $VersionReader) {
        $VersionReader = { param($Path) Get-YtDlpVersionText -ExecutablePath $Path }
    }
    if (-not $ReleaseReader) {
        $ReleaseReader = { Get-LatestStableYtDlpRelease }
    }
    if (-not $OwnerResolver) {
        $OwnerResolver = { param($Path) Get-YtDlpInstallOwner -ExecutablePath $Path }
    }
    if (-not $ExecutableResolver) {
        $ExecutableResolver = { Get-YtDlpExecutablePath }
    }
    if (-not $UpdateAction) {
        $UpdateAction = { param($DetectedOwner, $Path, $TargetVersion, $InstalledVersion) Invoke-YtDlpOwnerUpdate -Owner $DetectedOwner -ExecutablePath $Path -ExpectedVersion $TargetVersion -InstalledVersion $InstalledVersion }
    }

    try {
        $installedText = [string](& $VersionReader $ExecutablePath)
        $installedInfo = Get-YtDlpVersionInfo -VersionText $installedText
    }
    catch {
        throw ("Unable to determine a valid version from the yt-dlp executable at '{0}'. Media processing has been stopped. Restore or update that executable through its installation owner, then rerun. {1}" -f $ExecutablePath, $_.Exception.Message)
    }

    try {
        $release = & $ReleaseReader
        $targetTag = [string]$release.Tag
        $targetInfo = Get-YtDlpStableReleaseVersionInfo -ReleaseTag $targetTag
    }
    catch {
        throw ("Could not establish the latest stable yt-dlp version. Media processing has been stopped. {0}" -f $_.Exception.Message)
    }

    if (-not $installedInfo.Suffix -and $installedInfo.CoreText -eq $targetTag) {
        return [pscustomobject]@{
            ExecutablePath = $ExecutablePath
            InstalledText = $installedInfo.Raw
            TargetVersion = $targetTag
            Owner         = 'current'
            Updated       = $false
        }
    }

    if ($installedInfo.Version -gt $targetInfo.Version) {
        throw ("Installed yt-dlp {0} is newer than the latest stable release {1}. The downloader will not replace a newer or custom build automatically. Install the stable release through its owner, then rerun." -f $installedInfo.CoreText, $targetTag)
    }

    $owner = [string](& $OwnerResolver $ExecutablePath)
    if ($owner -ne 'winget') {
        throw ("yt-dlp {0} at '{1}' is behind latest stable {2}, but this script could not identify its installation owner or Python interpreter. No update or download was attempted. Use the same package manager or Python interpreter that installed it. On Windows, use 'winget upgrade --id yt-dlp.yt-dlp --exact --version {2}' only for WinGet installs, or 'choco upgrade yt-dlp -y' only for Chocolatey installs. On POSIX, use the installing package manager's documented update command. For pip installs, use the same interpreter that created this command with '-m pip install --upgrade yt-dlp'. Do not substitute another Python interpreter." -f $installedInfo.CoreText, $ExecutablePath, $targetTag)
    }

    try {
        $updateResult = & $UpdateAction $owner $ExecutablePath $targetTag $installedInfo.CoreText
    }
    catch {
        throw ("WinGet could not update yt-dlp {0} to latest stable {1}. Media processing has been stopped. Check WinGet availability, source data, and write permissions, then rerun. {2}" -f $installedInfo.CoreText, $targetTag, $_.Exception.Message)
    }
    if (-not $updateResult -or [int]$updateResult.ExitCode -ne 0) {
        $updateExitCode = if ($updateResult) { [int]$updateResult.ExitCode } else { -1 }
        throw ("WinGet could not update yt-dlp {0} to latest stable {1} (exit code {2}). Media processing has been stopped. Run 'winget upgrade --id yt-dlp.yt-dlp --exact --version {1}' and rerun." -f $installedInfo.CoreText, $targetTag, $updateExitCode)
    }

    try {
        $verifiedExecutablePath = [string](& $ExecutableResolver)
        if ([string]::IsNullOrWhiteSpace($verifiedExecutablePath)) {
            throw 'No yt-dlp executable was found after the WinGet update.'
        }
        $verifiedOwner = [string](& $OwnerResolver $verifiedExecutablePath)
        if ($verifiedOwner -ne $owner) {
            throw ("After the WinGet update, yt-dlp resolved to '{0}' with owner '{1}' instead of the original WinGet package." -f $verifiedExecutablePath, $verifiedOwner)
        }
        $verifiedText = [string](& $VersionReader $verifiedExecutablePath)
        $verifiedInfo = Get-YtDlpVersionInfo -VersionText $verifiedText
    }
    catch {
        throw ("WinGet reported an update, but the refreshed WinGet yt-dlp executable could not be resolved and verified. Media processing has been stopped. Restore the package through WinGet and rerun. {0}" -f $_.Exception.Message)
    }
    if ($verifiedInfo.Suffix -or $verifiedInfo.CoreText -ne $targetTag) {
        throw ("WinGet reported an update to yt-dlp {0}, but the executable used by the downloader reports {1}. Media processing has been stopped. Run 'winget upgrade --id yt-dlp.yt-dlp --exact --version {0}' and rerun." -f $targetTag, $verifiedInfo.Raw)
    }

    return [pscustomobject]@{
        ExecutablePath = $verifiedExecutablePath
        InstalledText = $verifiedInfo.Raw
        TargetVersion = $targetTag
        Owner         = $owner
        Updated       = $true
    }
}

function Get-HomeDirectory {
    foreach ($root in @($env:HOME, $env:USERPROFILE)) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            return $root
        }
    }

    try {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
            return $userProfile
        }
    }
    catch {}

    return [System.IO.Path]::GetTempPath()
}

function Get-DownloaderStateRoot {
    $isWinPlatform = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $isMac = $false

    if (-not $isWinPlatform) {
        try {
            $isMac = ((& uname -s 2>$null | Select-Object -First 1).ToString().Trim() -eq 'Darwin')
        }
        catch {
            $isMac = $false
        }
    }

    if ($isWinPlatform) {
        $base = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($base)) {
            try {
                $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            }
            catch {}
        }
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path (Get-HomeDirectory) 'AppData'
            $base = Join-Path $base 'Local'
        }
    }
    elseif ($isMac) {
        $base = Join-Path (Get-HomeDirectory) 'Library'
        $base = Join-Path $base 'Application Support'
    }
    else {
        $base = $env:XDG_STATE_HOME
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path (Get-HomeDirectory) '.local'
            $base = Join-Path $base 'state'
        }
    }

    $base = Join-Path $base 'myTech.Today'
    return (Join-Path $base 'professional-video-downloader')
}

$ScriptVersion = Get-ProjectVersion -RootPath $PSScriptRoot
$MinYtDlpVersion = [version]'2024.01.01'
$MinYtDlpVersionText = '2024.01.01'
$Script:YtDlpExecutable = $null
# Default browser fingerprint used by -Impersonate and by the Cloudflare auto-retry.
# Requires a recent yt-dlp with curl_cffi (bundled in modern builds).
$DefaultImpersonateTarget = "chrome"
$Script:StateRoot = Get-DownloaderStateRoot
$Script:ConfigFile = Join-Path $Script:StateRoot 'VideoDownloaderConfig.json'
$Script:LegacyConfigFile = Join-Path $PSScriptRoot 'VideoDownloaderConfig.json'
$Script:ConfigReadFile = $Script:ConfigFile
$MaxAttempts = 3
# Remote batch lists are fetched with explicit guardrails so a slow or oversized
# endpoint cannot stall the full downloader run.
$RemoteBatchSourceTimeoutSec = 15
$RemoteBatchSourceMaxRedirections = 5
$RemoteBatchSourceMaxBytes = 1MB

# Color constants
$ColorInfo    = 'Cyan'
$ColorSuccess = 'Green'
$ColorWarning = 'Yellow'
$ColorError   = 'Red'
$ColorMuted   = 'DarkGray'
$script:DownloadPathFallbackLogged = $false
$script:LogFailureWarningShown     = $false

# Curated platform registry. yt-dlp supports 1,800+ sites natively; this table only
# drives friendly display names and advisory notes. Any well-formed http(s) URL is
# forwarded to yt-dlp, which makes the final extractor decision. Patterns are matched
# (case-insensitive) against the lower-cased URL string. Order matters: place more
# specific patterns before more general ones.
$PlatformRegistry = @(
    # --- Mainstream video / social ---
    [pscustomobject]@{ Pattern = '//(www\.|m\.|music\.)?youtube(-nocookie)?\.com|//youtu\.be/';  Name = 'YouTube';            Category = 'Video';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.|player\.)?vimeo\.com';                                Name = 'Vimeo';              Category = 'Video';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?(dailymotion\.com|dai\.ly)';                         Name = 'Dailymotion';        Category = 'Video';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.|m\.|clips\.|go\.)?twitch\.tv';                        Name = 'Twitch';             Category = 'Video';     Note = 'Some VODs are sub-only and need cookies.' }
    [pscustomobject]@{ Pattern = '//(www\.|m\.|web\.)?(facebook\.com|fb\.com)|//fb\.watch';      Name = 'Facebook/Meta';      Category = 'Video';     Note = 'Private videos require cookies.' }
    [pscustomobject]@{ Pattern = '//(www\.|m\.)?instagram\.com';                                 Name = 'Instagram';          Category = 'Video';     Note = 'Private accounts/stories require cookies.' }
    [pscustomobject]@{ Pattern = '//(www\.|vm\.|vt\.|m\.)?tiktok\.com';                          Name = 'TikTok';             Category = 'Video';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.|mobile\.)?(x|twitter)\.com|//(www\.)?t\.co/';         Name = 'X/Twitter';          Category = 'Video';     Note = 'Spaces & protected tweets require cookies.' }
    [pscustomobject]@{ Pattern = '//(www\.|old\.|new\.|m\.|np\.)?reddit\.com|//(v\.|i\.)?redd\.it'; Name = 'Reddit';          Category = 'Video';     Note = 'NSFW & age-gated posts require cookies.' }
    [pscustomobject]@{ Pattern = '//(www\.|m\.|space\.|live\.)?bilibili\.com|//b23\.tv';         Name = 'Bilibili';           Category = 'Video';     Note = 'Region-locked content may fail; cookies help.' }
    [pscustomobject]@{ Pattern = '//(www\.)?rumble\.com';                                        Name = 'Rumble';             Category = 'Video';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?(odysee\.com|lbry\.tv)';                             Name = 'Odysee/LBRY';        Category = 'Video';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?snapchat\.com';                                      Name = 'Snapchat';           Category = 'Video';     Note = 'Stories require cookies.' }
    [pscustomobject]@{ Pattern = '//[a-z0-9-]+\.substack\.com|//(www\.)?substack\.com';          Name = 'Substack';           Category = 'Video';     Note = 'Subscriber-only posts require cookies.' }

    # --- Adult / NSFW (yt-dlp supports many; representative subset) ---
    [pscustomobject]@{ Pattern = '//(www\.|[a-z]+\.)?pornhub\.com';                              Name = 'Pornhub';            Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?xvideos\.com';                                       Name = 'XVideos';            Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?xnxx\.com';                                          Name = 'XNXX';               Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?youporn\.com';                                       Name = 'YouPorn';            Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?redtube\.com';                                       Name = 'RedTube';            Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?tube8\.com';                                         Name = 'Tube8';              Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?spankbang\.com';                                     Name = 'SpankBang';          Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?motherless\.com';                                    Name = 'Motherless';         Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?heavy-r\.com';                                       Name = 'Heavy-R';            Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?eporner\.com';                                       Name = 'Eporner';            Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?tnaflix\.com';                                       Name = 'TNAFlix';            Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?keezmovies\.com';                                    Name = 'KeezMovies';         Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?drtuber\.com';                                       Name = 'DrTuber';            Category = 'Adult';     Note = 'NSFW' }
    [pscustomobject]@{ Pattern = '//(www\.)?sunporno\.com';                                      Name = 'SunPorno';           Category = 'Adult';     Note = 'NSFW' }

    # --- Streaming / TV (mostly DRM-protected — see DRM note) ---
    [pscustomobject]@{ Pattern = '//(www\.)?netflix\.com';                                       Name = 'Netflix';            Category = 'Streaming'; Note = 'DRM (Widevine) — yt-dlp cannot decrypt. Downloads will almost certainly fail.' }
    [pscustomobject]@{ Pattern = '//(www\.)?disneyplus\.com';                                    Name = 'Disney+';            Category = 'Streaming'; Note = 'DRM (Widevine) — yt-dlp cannot decrypt. Downloads will almost certainly fail.' }
    [pscustomobject]@{ Pattern = '//(www\.)?hulu\.com';                                          Name = 'Hulu';               Category = 'Streaming'; Note = 'DRM (Widevine) — yt-dlp cannot decrypt.' }
    [pscustomobject]@{ Pattern = '//(www\.)?(primevideo\.com)|//(www\.)?amazon\.[a-z.]+/.*gp/video'; Name = 'Amazon Prime Video'; Category = 'Streaming'; Note = 'DRM (Widevine) — yt-dlp cannot decrypt.' }
    [pscustomobject]@{ Pattern = '//(www\.)?paramountplus\.com';                                 Name = 'Paramount+';         Category = 'Streaming'; Note = 'DRM (Widevine) — yt-dlp cannot decrypt.' }
    [pscustomobject]@{ Pattern = '//(www\.)?discoveryplus\.com';                                 Name = 'Discovery+';         Category = 'Streaming'; Note = 'DRM (Widevine) — yt-dlp cannot decrypt.' }
    [pscustomobject]@{ Pattern = '//(www\.|beta\.)?crunchyroll\.com';                            Name = 'Crunchyroll';        Category = 'Streaming'; Note = 'DRM-protected for paid content; free episodes sometimes work. Cookies often required.' }
    [pscustomobject]@{ Pattern = '//(www\.)?funimation\.com';                                    Name = 'Funimation';         Category = 'Streaming'; Note = 'Merged into Crunchyroll. DRM-protected.' }
    [pscustomobject]@{ Pattern = '//tv\.apple\.com|//(www\.)?appletv\.com';                      Name = 'Apple TV+';          Category = 'Streaming'; Note = 'DRM (FairPlay/Widevine) — yt-dlp cannot decrypt.' }

    # --- News & Media ---
    [pscustomobject]@{ Pattern = '//(www\.|edition\.|us\.|money\.)?cnn\.com';                    Name = 'CNN';                Category = 'News';      Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.|news\.|m\.)?bbc\.(com|co\.uk)';                       Name = 'BBC';                Category = 'News';      Note = 'Some content is region-locked to the UK.' }
    [pscustomobject]@{ Pattern = '//(www\.)?nbc(news)?\.com';                                    Name = 'NBC';                Category = 'News';      Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?abc\.(com|net\.au)|//abcnews\.go\.com';              Name = 'ABC';                Category = 'News';      Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?cbs(news|sports)?\.com';                             Name = 'CBS';                Category = 'News';      Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?aljazeera\.com';                                     Name = 'Al Jazeera';         Category = 'News';      Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?nytimes\.com';                                       Name = 'The New York Times'; Category = 'News';      Note = 'Paywalled videos require cookies.' }
    [pscustomobject]@{ Pattern = '//(www\.)?reuters\.com';                                       Name = 'Reuters';            Category = 'News';      Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?(ardmediathek\.de|ard\.de)';                         Name = 'ARD (Germany)';      Category = 'News';      Note = 'Region-locked to Germany; cookies may help.' }
    [pscustomobject]@{ Pattern = '//(www\.)?zdf\.de';                                            Name = 'ZDF (Germany)';      Category = 'News';      Note = 'Region-locked to Germany.' }
    [pscustomobject]@{ Pattern = '//(www\.)?(france\.tv|francetvinfo\.fr|france24\.com)';        Name = 'France TV';          Category = 'News';      Note = 'Some content is region-locked to France.' }
    [pscustomobject]@{ Pattern = '//(www\.)?tf1\.fr';                                            Name = 'TF1 (France)';       Category = 'News';      Note = 'Region-locked to France.' }

    # --- Music / Audio ---
    [pscustomobject]@{ Pattern = '//(www\.|m\.|api\.|on\.)?soundcloud\.com|//snd\.sc';           Name = 'SoundCloud';         Category = 'Music';     Note = '' }
    [pscustomobject]@{ Pattern = '//[a-z0-9-]+\.bandcamp\.com|//(www\.)?bandcamp\.com';          Name = 'Bandcamp';           Category = 'Music';     Note = 'Some albums are stream-only and may fail.' }
    [pscustomobject]@{ Pattern = '//(open\.|www\.|play\.)?spotify\.com';                         Name = 'Spotify';            Category = 'Music';     Note = 'DRM-protected audio cannot be downloaded. Only podcast/metadata access may work.' }
    [pscustomobject]@{ Pattern = '//music\.apple\.com';                                          Name = 'Apple Music';        Category = 'Music';     Note = 'DRM-protected audio cannot be downloaded. Only previews may work.' }
    [pscustomobject]@{ Pattern = '//(www\.)?vevo\.com';                                          Name = 'Vevo';               Category = 'Music';     Note = '' }

    # --- Education ---
    [pscustomobject]@{ Pattern = '//(www\.)?ted\.com';                                           Name = 'TED Talks';          Category = 'Education'; Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?coursera\.org';                                      Name = 'Coursera';           Category = 'Education'; Note = 'Course videos require an enrolled-user cookie.' }
    [pscustomobject]@{ Pattern = '//(www\.)?udemy\.com';                                         Name = 'Udemy';              Category = 'Education'; Note = 'Course videos require a logged-in cookie.' }
    [pscustomobject]@{ Pattern = '//(www\.|[a-z]+\.)?khanacademy\.org';                          Name = 'Khan Academy';       Category = 'Education'; Note = '' }

    # --- Social / Misc ---
    [pscustomobject]@{ Pattern = '//(www\.|img-9gag-fun\.|m\.)?9gag\.com';                       Name = '9GAG';               Category = 'Other';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.|i\.|m\.)?imgur\.com';                                 Name = 'Imgur';              Category = 'Other';     Note = '' }
    [pscustomobject]@{ Pattern = '//[a-z0-9-]+\.tumblr\.com|//(www\.)?tumblr\.com';              Name = 'Tumblr';             Category = 'Other';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.|[a-z]+\.)?pinterest\.(com|ca|co\.uk|fr|de|jp|au)|//pin\.it'; Name = 'Pinterest';    Category = 'Other';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?linkedin\.com';                                      Name = 'LinkedIn';           Category = 'Other';     Note = 'Some posts require a logged-in cookie.' }
    [pscustomobject]@{ Pattern = '//(www\.|m\.)?vk\.(com|ru)';                                   Name = 'VK';                 Category = 'Other';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?rutube\.ru';                                         Name = 'Rutube';             Category = 'Other';     Note = '' }
    [pscustomobject]@{ Pattern = '//(www\.)?newgrounds\.com';                                    Name = 'Newgrounds';         Category = 'Other';     Note = '' }
)

# ====================== HELPER FUNCTIONS ======================

function Write-Colored {
    param(
        [string]$Message,
        [string]$Color = $ColorInfo
    )
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-ExitPause {
    param([int]$Seconds = 4)

    if (-not $script:PauseOnExit) {
        return
    }

    Write-Colored ("`nWindow will close in {0} seconds..." -f $Seconds) -Color $ColorInfo
    Start-Sleep -Seconds $Seconds
}

function Test-IsHttpUrl {
    # Validates a well-formed http(s) URL with a non-empty host. yt-dlp decides
    # whether the URL is actually extractable; we don't second-guess it here.
    param([string]$InputUrl)

    if ([string]::IsNullOrWhiteSpace($InputUrl)) { return $false }

    try {
        $uri = [System.Uri]::new($InputUrl.Trim())
        if ($uri.Scheme -notin @('http', 'https')) { return $false }
        if ([string]::IsNullOrWhiteSpace($uri.Host)) { return $false }
        return $true
    }
    catch { return $false }
}

function Expand-UrlList {
    # Flattens caller-supplied URL inputs into a deduplicated ordered array.
    # URLs are extracted conservatively so valid punctuation inside a single URL
    # is preserved. Commas and semicolons only act as separators when they sit
    # between URL tokens, which keeps paste-friendly list syntax working.
    param([Parameter()][string[]]$Raw)

    if (-not $Raw -or $Raw.Count -eq 0) { return @() }

    $urlPattern = '(?i)https?://(?:[;,](?!\s*https?://)|[^\s,;])+'
    $seen   = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $Raw) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }

        $matches = [regex]::Matches($entry, $urlPattern)
        if ($matches.Count -eq 0) {
            foreach ($token in ($entry -split '[\s,;]+')) {
                $candidate = $token.Trim()
                if ($candidate -and $seen.Add($candidate)) {
                    [void]$result.Add($candidate)
                }
            }
            continue
        }

        foreach ($match in $matches) {
            $candidate = $match.Value.Trim()
            if (-not $candidate) { continue }

            if (-not (Test-IsHttpUrl $candidate)) {
                $trimmed = $candidate.TrimEnd(',', ';')
                if (Test-IsHttpUrl $trimmed) {
                    $candidate = $trimmed
                }
            }

            if ((Test-IsHttpUrl $candidate) -and $seen.Add($candidate)) {
                [void]$result.Add($candidate)
            }
        }
    }

    return ,$result.ToArray()
}

function Get-RemoteResponseContentType {
    param([Parameter(Mandatory)]$Response)

    $contentType = $null
    if ($Response.PSObject.Properties['BaseResponse'] -and $Response.BaseResponse) {
        $baseResponse = $Response.BaseResponse
        if ($baseResponse.PSObject.Properties['ContentType'] -and $baseResponse.ContentType) {
            $contentType = [string]$baseResponse.ContentType
        }
    }

    if (-not $contentType -and $Response.PSObject.Properties['Headers'] -and $Response.Headers) {
        $headerValue = $Response.Headers['Content-Type']
        if ($headerValue) {
            $contentType = [string]$headerValue
        }
    }

    if (-not $contentType -and $Response.PSObject.Properties['ContentType'] -and $Response.ContentType) {
        $contentType = [string]$Response.ContentType
    }

    return $contentType
}

function Get-RemoteResponseBody {
    param([Parameter(Mandatory)]$Response)

    if ($Response.PSObject.Properties['Content']) {
        return [string]$Response.Content
    }

    return [string]$Response
}

function Get-InvokeWebRequestTimeoutParameterName {
    # PowerShell 5.1 exposes -TimeoutSec, while PowerShell 7 uses
    # -OperationTimeoutSeconds for the same request timeout behavior.
    $cmd = Get-Command -Name Invoke-WebRequest -CommandType Cmdlet -ErrorAction Stop
    if ($cmd.Parameters.ContainsKey('OperationTimeoutSeconds')) {
        return 'OperationTimeoutSeconds'
    }

    return 'TimeoutSec'
}

function Test-IsBinaryLikeText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    if ($Text.IndexOf([char]0) -ge 0) { return $true }

    $sampleSize = [Math]::Min($Text.Length, 256)
    if ($sampleSize -le 0) { return $false }

    $controlCount = 0
    for ($i = 0; $i -lt $sampleSize; $i++) {
        $codePoint = [int][char]$Text[$i]
        if (($codePoint -lt 32 -and $codePoint -notin 9, 10, 13) -or $codePoint -eq 127) {
            $controlCount++
        }
    }

    return ($controlCount -ge 8 -and $controlCount -ge [Math]::Ceiling($sampleSize / 4))
}

function Test-IsLikelyBatchSourceUrl {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    if ($Token -notmatch '^(?i)https?://') { return $false }

    if ($Token -match '(?i)\.(txt|list|csv|tsv|md|url|uri|json|xml|m3u|m3u8)(?:[?#].*)?$') {
        return $true
    }

    if ($Token -match '(?i)/(raw|content|contents|text|list|lists|urls?|links?|export|paste)(?:/|$|[?#])') {
        return $true
    }

    if ($Token -match '(?i)[?&](?:raw|text|output|format|download)=?(?:1|true|text)?(?:&|$)') {
        return $true
    }

    return $false
}

function Get-UrlLikeTokensFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $tokens = Expand-UrlList -Raw @($Text)
    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($token in $tokens) {
        if (Test-IsHttpUrl $token) {
            [void]$matches.Add($token)
        }
    }

    return $matches.ToArray()
}

function Get-BatchSourceProbe {
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$ForceRemoteProbe
    )

    $probe = [pscustomobject]@{
        Token         = $Token
        SourceType    = 'Unknown'
        ShouldProbe   = $false
        IsBatchSource = $false
        ContentType   = $null
        Body          = $null
        Reason        = $null
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        $probe.Reason = 'Token is empty.'
        return $probe
    }

    if (Test-Path -LiteralPath $Token -PathType Leaf) {
        $probe.SourceType = 'LocalFile'
        $probe.IsBatchSource = $true
        return $probe
    }

    if ($Token -notmatch '^(?i)https?://') {
        $probe.Reason = 'Token is not a local file path or http(s) URL.'
        return $probe
    }

    $probe.SourceType = 'RemoteUrl'
    $probe.ShouldProbe = [bool]($ForceRemoteProbe -or (Test-IsLikelyBatchSourceUrl $Token))
    if (-not $probe.ShouldProbe) {
        return $probe
    }

    $tempFile = $null
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $requestParams = @{
            Uri                = $Token
            UseBasicParsing    = $true
            MaximumRedirection = $RemoteBatchSourceMaxRedirections
            OutFile            = $tempFile
            ErrorAction        = 'Stop'
        }
        $timeoutParam = Get-InvokeWebRequestTimeoutParameterName
        $requestParams[$timeoutParam] = $RemoteBatchSourceTimeoutSec

        $resp = Invoke-WebRequest @requestParams
        $probe.ContentType = Get-RemoteResponseContentType -Response $resp

        if (-not (Test-Path -LiteralPath $tempFile -PathType Leaf)) {
            $probe.Reason = 'Remote response did not produce a body.'
            return $probe
        }

        $fileInfo = Get-Item -LiteralPath $tempFile -ErrorAction Stop
        if ($fileInfo.Length -gt $RemoteBatchSourceMaxBytes) {
            $probe.Reason = ("Remote response exceeded the {0:N0} byte limit ({1:N0} bytes)." -f $RemoteBatchSourceMaxBytes, $fileInfo.Length)
            return $probe
        }

        $probe.Body = Get-Content -LiteralPath $tempFile -Raw -Encoding UTF8 -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($probe.Body)) {
            $probe.Reason = 'Remote response was empty.'
            return $probe
        }

        if (Test-IsBinaryLikeText -Text $probe.Body) {
            $probe.Reason = 'Remote response looked binary.'
            return $probe
        }

        if ($probe.ContentType) {
            $mediaType = ($probe.ContentType -split ';', 2)[0].Trim().ToLowerInvariant()
            if ($mediaType -eq 'text/html' -or $mediaType -eq 'application/xhtml+xml') {
                $probe.Reason = 'Remote response was HTML, not a plain-text URL list.'
                return $probe
            }
        }

        $urlTokens = Get-UrlLikeTokensFromText -Text $probe.Body
        if ($urlTokens.Count -gt 0) {
            $probe.IsBatchSource = $true
            return $probe
        }

        $probe.Reason = 'Plain-text response did not contain any URL-like tokens.'
        return $probe
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match '(?i)timed? out|timeout') {
            $probe.Reason = ("Remote batch source request timed out after {0} seconds." -f $RemoteBatchSourceTimeoutSec)
        }
        elseif ($message -match '(?i)redirection|redirect') {
            $probe.Reason = ("Remote batch source exceeded the {0} redirect limit." -f $RemoteBatchSourceMaxRedirections)
        }
        else {
            $probe.Reason = "Could not read remote source: $message"
        }
        return $probe
    }
    finally {
        if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-UrlListInteractive {
    # Reads URLs from the console. Accepts paste-style input: one or more URLs
    # per line, with space/comma/semicolon separators between URLs. Semicolons
    # that belong to a single URL are preserved. An empty line terminates input.
    # If the user pastes a single token that resolves to a file path or an
    # http(s) URL whose body is text, it is treated as a batch file and the
    # contents are returned in lieu of the raw line.
    param([string]$Prompt = "Enter one or more URLs (space/comma/semicolon lists are supported; semicolons inside a single URL are preserved).`nA local file path or raw http(s) text URL works too.")

    Write-Colored $Prompt -Color $ColorInfo
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = Read-Host ">"
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $trimmed = $line.Trim()
        $probe = Get-BatchSourceProbe -Token $trimmed
        if ($probe.IsBatchSource) {
            try {
                $fetched = Read-UrlsFromSource -Source $trimmed -Probe $probe
                foreach ($f in $fetched) { [void]$lines.Add($f) }
                Write-Colored ("  Loaded {0} token(s) from '{1}'." -f $fetched.Count, $trimmed) -Color $ColorMuted
                continue
            }
            catch {
                Write-Colored ("  Warning: {0}" -f $_.Exception.Message) -Color $ColorWarning
                continue
            }
        }
        elseif ($probe.ShouldProbe -and $probe.Reason) {
            Write-Colored ("  Warning: Remote URL '{0}' is not a valid batch source: {1}" -f $trimmed, $probe.Reason) -Color $ColorWarning
            [void]$lines.Add($line)
            continue
        }
        [void]$lines.Add($line)
    }
    return ,$lines.ToArray()
}

function Test-IsBatchSource {
    # Detects whether a single user token is a local file path or a remote text
    # URL whose contents contain URL-like tokens.
    param([string]$Token)
    $probe = Get-BatchSourceProbe -Token $Token
    return [bool]$probe.IsBatchSource
}

function Read-UrlsFromSource {
    # Reads the raw contents of a local file or http(s) URL and returns it as a
    # single-element string array (Expand-UrlList does the actual tokenization).
    param(
        [Parameter(Mandatory)][string]$Source,
        [psobject]$Probe
    )

    if ($Source -match '^(?i)https?://') {
        if (-not $Probe -or $Probe.Token -ne $Source) {
            $Probe = Get-BatchSourceProbe -Token $Source -ForceRemoteProbe
        }

        if (-not $Probe.IsBatchSource) {
            $reason = if ($Probe.Reason) { $Probe.Reason } else { 'Remote response did not contain a usable URL list.' }
            throw ("Remote URL '{0}' is not a valid batch source: {1}" -f $Source, $reason)
        }

        $body = if ($Probe.PSObject.Properties['Body'] -and $Probe.Body) { [string]$Probe.Body } else { '' }
        return ,@($body)
    }

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Input file not found: $Source"
    }
    $body = Get-Content -LiteralPath $Source -Raw -ErrorAction Stop
    return ,@($body)
}

function Get-PlatformInfo {
    # Looks up the URL in $PlatformRegistry and returns Name/Category/Note/IsKnown.
    # Falls back to a generic "let yt-dlp try" descriptor when no entry matches.
    param([string]$InputUrl)
    $urlLower = $InputUrl.ToLowerInvariant()
    foreach ($entry in $PlatformRegistry) {
        if ($urlLower -match $entry.Pattern) {
            return [pscustomobject]@{
                Name     = $entry.Name
                Category = $entry.Category
                Note     = $entry.Note
                IsKnown  = $true
            }
        }
    }
    return [pscustomobject]@{
        Name     = 'Generic / Unknown'
        Category = 'Unknown'
        Note     = 'Not in the curated registry. yt-dlp supports 1,800+ sites — the download may still succeed.'
        IsKnown  = $false
    }
}

# Back-compat wrappers for anyone dot-sourcing this script.
function Get-PlatformName { param([string]$InputUrl) (Get-PlatformInfo $InputUrl).Name }
function Is-ValidVideoUrl { param([string]$InputUrl) Test-IsHttpUrl $InputUrl }

function Test-IsWindowsPlatform {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Get-PredictableDownloadPath {
    $profileRoot = $null
    foreach ($root in @($env:USERPROFILE, $env:HOME)) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $profileRoot = $root
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($profileRoot)) {
        try {
            $profileRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        }
        catch {}
    }

    if ([string]::IsNullOrWhiteSpace($profileRoot)) {
        $profileRoot = [System.IO.Path]::GetTempPath()
    }

    return (Join-Path (Join-Path $profileRoot 'Professional Video Downloader') 'Downloads')
}

function Write-DownloadFallbackNotice {
    param([Parameter(Mandatory)][string]$FallbackPath)

    if ($script:DownloadPathFallbackLogged) {
        return
    }

    $script:DownloadPathFallbackLogged = $true
    Write-Colored "Downloads folder unavailable. Using app folder under your profile: $FallbackPath" -Color $ColorWarning
    Write-Log -Level 'WARN' -Message 'Downloads folder fallback selected' -Context @{ path = $FallbackPath }
}

function Get-DownloadsFolder {
    $downloads = $null
    if (Test-IsWindowsPlatform) {
        try {
            $shell = New-Object -ComObject Shell.Application
            $downloads = $shell.Namespace('shell:Downloads').Self.Path
            if ($downloads -and (Test-Path -LiteralPath $downloads)) {
                return $downloads
            }
        }
        catch {}
    }

    foreach ($root in @($env:USERPROFILE, $env:HOME)) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidate = Join-Path $root 'Downloads'
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    $fallbackPath = Get-PredictableDownloadPath
    Write-DownloadFallbackNotice -FallbackPath $fallbackPath
    if (-not (Test-Path -LiteralPath $fallbackPath)) {
        New-Item -ItemType Directory -Path $fallbackPath -Force -ErrorAction Stop | Out-Null
    }

    return $fallbackPath
}

function Build-YtDlpArgumentList {
    # Constructs a fresh argument list. Called once per attempt so the retry path
    # doesn't have to mutate state from the first attempt.
    param(
        [Parameter(Mandatory)][string]$TargetUrl,
        [Parameter(Mandatory)][string]$OutputTemplate,
        [bool]$AudioOnly,
        [bool]$AllowPlaylist,
        [string]$CookiesFromBrowser,
        [string]$ImpersonateTarget,
        [string]$ExtractorArgs
    )
    $a = [System.Collections.Generic.List[string]]::new()
    if ($AudioOnly) {
        [void]$a.Add('--format');        [void]$a.Add('bestaudio/best')
        [void]$a.Add('--extract-audio')
        [void]$a.Add('--audio-format');  [void]$a.Add('mp3')
        [void]$a.Add('--audio-quality'); [void]$a.Add('0')
    } else {
        [void]$a.Add('--format');               [void]$a.Add('bestvideo+bestaudio/best')
        [void]$a.Add('--merge-output-format');  [void]$a.Add('mp4')
        [void]$a.Add('--embed-thumbnail')
    }
    [void]$a.Add('--output'); [void]$a.Add($OutputTemplate)
    [void]$a.Add('--embed-metadata')
    [void]$a.Add('--progress')
    [void]$a.Add('--restrict-filenames')
    if (-not $AllowPlaylist) { [void]$a.Add('--no-playlist') }
    [void]$a.Add('--no-warnings')
    if ($CookiesFromBrowser) {
        [void]$a.Add('--cookies-from-browser'); [void]$a.Add($CookiesFromBrowser)
    }
    if ($ImpersonateTarget) {
        [void]$a.Add('--impersonate'); [void]$a.Add($ImpersonateTarget)
    }
    if ($ExtractorArgs) {
        [void]$a.Add('--extractor-args'); [void]$a.Add($ExtractorArgs)
    }
    [void]$a.Add($TargetUrl)
    return ,$a   # unary comma keeps the List<string> intact across the return boundary
}

function Invoke-YtDlpDownload {
    # Runs yt-dlp with the given argument list. Streams output to the console live
    # and inspects it to capture: the destination file path on success, and any
    # Cloudflare/anti-bot retry hint on failure.
    param([Parameter(Mandatory)][System.Collections.Generic.List[string]]$Arguments)

    $videoFilePath      = $null
    $retryExtractorArgs = $null
    $cloudflareDetected = $false

    & $Script:YtDlpExecutable @Arguments 2>&1 | ForEach-Object {
        $line = $_.ToString().Trim()
        Write-Host $line

        if ($line -match '\[download\].*Destination:\s*(.+)') {
            $videoFilePath = $matches[1].Trim()
        }
        # yt-dlp's own remediation hint, e.g.:
        #   ERROR: [generic] Got HTTP Error 403 caused by Cloudflare anti-bot
        #   challenge; try again with  --extractor-args "generic:impersonate"
        if ($line -match 'try again with\s+--extractor-args\s+"([^"]+)"') {
            $retryExtractorArgs = $matches[1]
        }
        if ($line -match 'Cloudflare anti-bot|HTTP Error 403') {
            $cloudflareDetected = $true
        }
    }

    return [pscustomobject]@{
        Success            = ($LASTEXITCODE -eq 0)
        ExitCode           = $LASTEXITCODE
        VideoFilePath      = $videoFilePath
        RetryExtractorArgs = $retryExtractorArgs
        CloudflareDetected = $cloudflareDetected
    }
}

# ====================== LOGGING ======================
# Plain-text log per spec lives under the user-writable app state root.
$Script:LogDir = Join-Path $Script:StateRoot 'logs'

function Write-LogFailureWarning {
    param([Parameter(Mandatory)][string]$Reason)

    if ($script:LogFailureWarningShown) {
        return
    }

    $script:LogFailureWarningShown = $true

    try {
        Write-Colored ("Warning: Unable to write log entry. Diagnostics will no longer be recorded for this run. Reason: {0}" -f $Reason) -Color $ColorWarning
    }
    catch {
        # Keep the logger non-throwing even if the warning path itself fails.
    }
}

function Write-Log {
    # Appends one timestamped line to today's log file. Never throws, but
    # emits one visible warning if logging stops working for this run.
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO',
        [hashtable]$Context
    )
    try {
        if (-not (Test-Path $Script:LogDir)) {
            New-Item -ItemType Directory -Path $Script:LogDir -Force -ErrorAction Stop | Out-Null
        }
        $now     = Get-Date
        $logFile = Join-Path $Script:LogDir ("{0}.log" -f $now.ToString('yyyy-MM-dd'))
        $stamp   = $now.ToString('yyyy-MM-dd HH:mm:ss.fff')
        $ctx     = ''
        if ($Context -and $Context.Count -gt 0) {
            $parts = foreach ($k in $Context.Keys) { "$k=$($Context[$k])" }
            $ctx = ' [' + ($parts -join ', ') + ']'
        }
        $line = "{0} [{1}] [PID {2}] [v{3}] {4}{5}" -f $stamp, $Level, $PID, $ScriptVersion, $Message, $ctx
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($logFile, ($line + [Environment]::NewLine), $utf8NoBom)
    }
    catch {
        $reason = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { 'Unknown logging failure' }
        Write-LogFailureWarning -Reason $reason
    }
}

Write-Log -Message 'Script started' -Context @{
    pwsh      = $PSVersionTable.PSVersion.ToString()
    script    = $PSCommandPath
    cwd       = (Get-Location).Path
    audioOnly = [bool]$AudioOnly
    playlist  = [bool]$AllowPlaylist
}

if (-not (Test-Path -LiteralPath $Script:ConfigFile) -and (Test-Path -LiteralPath $Script:LegacyConfigFile)) {
    $Script:ConfigReadFile = $Script:LegacyConfigFile
    try {
        $configDir = Split-Path -Parent $Script:ConfigFile
        if (-not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $Script:LegacyConfigFile -Destination $Script:ConfigFile -Force -ErrorAction Stop
        $Script:ConfigReadFile = $Script:ConfigFile
    }
    catch {
        $Script:ConfigReadFile = $Script:LegacyConfigFile
    }
}

# ====================== MAIN SCRIPT ======================

Write-Colored "=== Video Downloader (yt-dlp) v$ScriptVersion ===" -Color $ColorInfo
Write-Colored "Supports 1,800+ sites via yt-dlp. Curated platforms include:" -Color $ColorMuted
Write-Colored "  Video : YouTube, Vimeo, Dailymotion, Twitch, Facebook, Instagram, TikTok," -Color $ColorMuted
Write-Colored "          X/Twitter, Reddit, Bilibili, Rumble, Odysee, Snapchat, Substack"   -Color $ColorMuted
Write-Colored "  Audio : SoundCloud, Bandcamp, Vevo  |  News: BBC, CNN, NBC, ABC, CBS, NYT" -Color $ColorMuted
Write-Colored "  Other : TED, Pinterest, LinkedIn, VK, Rutube, Imgur, Tumblr, 9GAG, +adult" -Color $ColorMuted
Write-Colored "  DRM   : Netflix, Disney+, Hulu, Prime, Paramount+, Apple TV+ (cannot decrypt)`n" -Color $ColorMuted

# --------------------- YT-DLP UPDATE PREFLIGHT ---------------------
try {
    Write-Colored 'Checking yt-dlp against the latest stable release...' -Color $ColorInfo
    $Script:YtDlpExecutable = Get-YtDlpExecutablePath
    $ytDlpPreflight = Invoke-YtDlpUpdatePreflight -ExecutablePath $Script:YtDlpExecutable
    $Script:YtDlpExecutable = $ytDlpPreflight.ExecutablePath
    $null = Assert-YtDlpMinimumVersion -InstalledVersionText $ytDlpPreflight.InstalledText -MinimumVersion $MinYtDlpVersion

    if ($ytDlpPreflight.Updated) {
        Write-Colored ("Updated yt-dlp to latest stable {0} through WinGet. Processing will use the verified executable." -f $ytDlpPreflight.TargetVersion) -Color $ColorSuccess
        Write-Log -Message 'yt-dlp updated to latest stable' -Context @{
            version = $ytDlpPreflight.InstalledText
            target  = $ytDlpPreflight.TargetVersion
            owner   = $ytDlpPreflight.Owner
        }
    }
    else {
        Write-Colored ("yt-dlp is current at latest stable {0}." -f $ytDlpPreflight.TargetVersion) -Color $ColorSuccess
        Write-Log -Message 'yt-dlp is current at latest stable' -Context @{
            version = $ytDlpPreflight.InstalledText
            target  = $ytDlpPreflight.TargetVersion
        }
    }
}
catch {
    $preflightError = $_.Exception.Message
    Write-Colored ("ERROR: yt-dlp preflight failed. Media processing will not start. {0}" -f $preflightError) -Color $ColorError
    Write-Log -Level 'ERROR' -Message 'yt-dlp update preflight failed' -Context @{ error = $preflightError }
    $global:LASTEXITCODE = 1
    Invoke-ExitPause -Seconds 6
    exit 1
}

# --------------------- DOWNLOAD PATH MANAGEMENT ---------------------
$persistResolvedDownloadPath = $false
$staleSavedDownloadPath = $null

if (-not $DownloadPath) {
    # Load saved custom path if exists
    if (Test-Path -LiteralPath $Script:ConfigReadFile) {
        try {
            $config = Get-Content -LiteralPath $Script:ConfigReadFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $savedPath = $null
            if ($config -and $config.PSObject.Properties['DownloadPath']) {
                $savedPath = $config.DownloadPath
            }
            if ($savedPath -and (Test-Path -LiteralPath $savedPath)) {
                $DownloadPath = $savedPath
                Write-Colored "Using previously saved folder: $DownloadPath" -Color $ColorWarning
            }
            elseif ($savedPath) {
                $staleSavedDownloadPath = $savedPath
            }
        }
        catch {}
    }
}

# Use default Downloads if no custom path
if (-not $DownloadPath) {
    $DownloadPath = Get-DownloadsFolder
}

# Ensure folder exists
if (-not (Test-Path -LiteralPath $DownloadPath)) {
    try {
        New-Item -LiteralPath $DownloadPath -ItemType Directory -Force | Out-Null
        Write-Colored "Created download directory: $DownloadPath" -Color $ColorInfo
    }
    catch {
        $fallbackPath = Get-PredictableDownloadPath
        Write-DownloadFallbackNotice -FallbackPath $fallbackPath
        if (-not (Test-Path -LiteralPath $fallbackPath)) {
            try {
                New-Item -ItemType Directory -LiteralPath $fallbackPath -Force -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Colored "ERROR: Could not create fallback download directory: $fallbackPath" -Color $ColorError
                Write-Log -Level 'ERROR' -Message 'Fallback download directory creation failed' -Context @{ path = $fallbackPath; error = $_.Exception.Message }
                throw
            }
        }
        $DownloadPath = $fallbackPath
    }
}

if ($staleSavedDownloadPath) {
    Write-Colored "Saved folder unavailable: $staleSavedDownloadPath. Using $DownloadPath instead." -Color $ColorWarning
    $persistResolvedDownloadPath = $true
}

if ($script:DownloadPathFallbackLogged) {
    $persistResolvedDownloadPath = $true
}

if ($PSBoundParameters.ContainsKey('DownloadPath')) {
    $persistResolvedDownloadPath = $true
}

Write-Colored "Download folder: $DownloadPath`n" -Color $ColorInfo

# --------------------- URL COLLECTION & VALIDATION ---------------------
# Sources, in priority order:
#   1. -InputFile <path-or-URL>  (a batch file of URLs, any common delimiter)
#   2. -Url <one-or-many>        (positional or named, optionally a batch source token)
#   3. Interactive prompt        (a batch source token works at the prompt too)
$rawUrlInput = [System.Collections.Generic.List[string]]::new()

if ($InputFile) {
    Write-Colored "Reading URLs from input file: $InputFile" -Color $ColorInfo
    try {
        $fileContent = Read-UrlsFromSource -Source $InputFile
        foreach ($f in $fileContent) { [void]$rawUrlInput.Add($f) }
        Write-Log -Message 'Loaded URL list from -InputFile' -Context @{ source = $InputFile }
    }
    catch {
        Write-Colored "ERROR: Could not read -InputFile '$InputFile': $($_.Exception.Message)" -Color $ColorError
        Write-Log -Level 'ERROR' -Message 'Failed to read -InputFile' -Context @{ source = $InputFile; error = $_.Exception.Message }
        Invoke-ExitPause -Seconds 3
        exit 1
    }
}

if ($Url -and $Url.Count -gt 0) {
    foreach ($u in $Url) {
        $trimmed = if ($u) { $u.Trim() } else { '' }
        $probe = Get-BatchSourceProbe -Token $trimmed
        if ($probe.IsBatchSource) {
            try {
                $fetched = Read-UrlsFromSource -Source $trimmed -Probe $probe
                foreach ($f in $fetched) { [void]$rawUrlInput.Add($f) }
                Write-Log -Message 'Loaded URL list from -Url batch source' -Context @{ source = $trimmed }
                continue
            }
            catch {
                Write-Colored "Warning: $($_.Exception.Message)" -Color $ColorWarning
                continue
            }
        }
        elseif ($probe.ShouldProbe -and $probe.Reason) {
            Write-Colored ("Warning: Remote URL '{0}' is not a valid batch source: {1}" -f $trimmed, $probe.Reason) -Color $ColorWarning
            [void]$rawUrlInput.Add($u)
            continue
        }
        [void]$rawUrlInput.Add($u)
    }
}

if ($rawUrlInput.Count -eq 0) {
    $attempt = 0
    while ($rawUrlInput.Count -eq 0 -and $attempt -lt $MaxAttempts) {
        $attempt++
        $lines = Read-UrlListInteractive
        foreach ($l in $lines) { [void]$rawUrlInput.Add($l) }
        if ($rawUrlInput.Count -eq 0) {
            Write-Colored "ERROR: No URL entered ($attempt/$MaxAttempts)" -Color $ColorError
            Write-Colored "Examples (one per line, or space/comma/semicolon-separated lists):" -Color $ColorWarning
            Write-Colored "  https://youtube.com/watch?v=..."             -Color $ColorWarning
            Write-Colored "  https://vimeo.com/123456789"                 -Color $ColorWarning
            Write-Colored "  https://www.tiktok.com/@user/video/..."      -Color $ColorWarning
            Write-Colored "  C:\path\to\urls.txt   (or)   https://host/list.txt" -Color $ColorWarning
        }
    }
    if ($rawUrlInput.Count -eq 0) {
        Write-Colored "Maximum attempts reached. Exiting." -Color $ColorError
        Write-Log -Level 'ERROR' -Message 'No URLs provided after max attempts'
        Invoke-ExitPause -Seconds 3
        exit 1
    }
}

# Flatten the raw input into individual URL tokens while preserving semicolons
# and commas that belong to a single URL.
$allUrls = Expand-UrlList -Raw $rawUrlInput

# Partition into valid http(s) URLs and rejected tokens.
$urlList     = [System.Collections.Generic.List[string]]::new()
$rejectedUrl = [System.Collections.Generic.List[string]]::new()
foreach ($u in $allUrls) {
    if (Test-IsHttpUrl $u) { [void]$urlList.Add($u) }
    else                   { [void]$rejectedUrl.Add($u) }
}

if ($rejectedUrl.Count -gt 0) {
    Write-Colored "Skipping $($rejectedUrl.Count) invalid token(s):" -Color $ColorWarning
    foreach ($r in $rejectedUrl) { Write-Colored "  $r" -Color $ColorWarning }
}

if ($urlList.Count -eq 0) {
    Write-Colored "ERROR: No valid http(s) URLs to process." -Color $ColorError
    Invoke-ExitPause -Seconds 4
    exit 1
}

Write-Colored "Queued $($urlList.Count) URL(s) for download." -Color $ColorInfo

# --------------------- DOWNLOAD EXECUTION ---------------------
$downloadTemplate = Join-Path $DownloadPath "%(title)s [%(id)s].%(ext)s"

if ($CookiesFromBrowser) {
    Write-Colored "Using cookies from browser: $CookiesFromBrowser" -Color $ColorInfo
}
if ($Impersonate) {
    Write-Colored "Using browser impersonation: $DefaultImpersonateTarget" -Color $ColorInfo
}

# Per-URL outcome accumulator for the final summary.
$summary = [System.Collections.Generic.List[object]]::new()
$index   = 0

foreach ($currentUrl in $urlList) {
    $index++
    $pct = [int](($index - 1) * 100 / [Math]::Max(1, $urlList.Count))
    Write-Progress -Id 1 -Activity 'Professional Video Downloader' `
        -Status ("[{0}/{1}] {2}" -f $index, $urlList.Count, $currentUrl) `
        -PercentComplete $pct

    Write-Colored ("`n========== [{0}/{1}] {2} ==========" -f $index, $urlList.Count, $currentUrl) -Color $ColorInfo

    # Per-URL try/catch: one URL failing must never abort the batch.
    $result       = $null
    $platformInfo = $null
    $caughtError  = $null
    try {
        $platformInfo = Get-PlatformInfo $currentUrl
        Write-Colored "Detected platform: $($platformInfo.Name) [$($platformInfo.Category)]" -Color $ColorInfo
        if ($platformInfo.Note) {
            $noteColor = if ($platformInfo.Note -match 'DRM|NSFW') { $ColorError } else { $ColorWarning }
            Write-Colored "Note: $($platformInfo.Note)" -Color $noteColor
        }
        if ($platformInfo.Note -match 'cookies' -and -not $CookiesFromBrowser) {
            Write-Colored "Tip:  Re-run with -CookiesFromBrowser <chrome|firefox|edge|brave|...> to authenticate." -Color $ColorWarning
        }

        if ($AudioOnly) {
            Write-Colored "Starting audio-only extraction with yt-dlp..." -Color $ColorInfo
        } else {
            Write-Colored "Starting high-quality download with yt-dlp..." -Color $ColorInfo
        }

        Write-Log -Message 'Download start' -Context @{
            index    = $index
            total    = $urlList.Count
            url      = $currentUrl
            platform = $platformInfo.Name
        }

        # First attempt — honors caller-supplied flags as-is.
        $firstAttemptImpersonate = if ($Impersonate) { $DefaultImpersonateTarget } else { '' }
        $ytDlpArgs = Build-YtDlpArgumentList `
            -TargetUrl          $currentUrl `
            -OutputTemplate     $downloadTemplate `
            -AudioOnly          ([bool]$AudioOnly) `
            -AllowPlaylist      ([bool]$AllowPlaylist) `
            -CookiesFromBrowser $CookiesFromBrowser `
            -ImpersonateTarget  $firstAttemptImpersonate `
            -ExtractorArgs      ''

        $result = Invoke-YtDlpDownload -Arguments $ytDlpArgs

        # Auto-retry once on Cloudflare anti-bot detection.
        if (-not $result.Success -and -not $Impersonate `
            -and ($result.RetryExtractorArgs -or $result.CloudflareDetected)) {

            $extractorArgsValue = if ($result.RetryExtractorArgs) { $result.RetryExtractorArgs } else { 'generic:impersonate' }

            Write-Colored "`n⚠ Cloudflare anti-bot challenge detected." -Color $ColorWarning
            Write-Colored "Retrying with browser impersonation ($DefaultImpersonateTarget) and --extractor-args `"$extractorArgsValue`"..." -Color $ColorWarning

            $ytDlpArgs = Build-YtDlpArgumentList `
                -TargetUrl          $currentUrl `
                -OutputTemplate     $downloadTemplate `
                -AudioOnly          ([bool]$AudioOnly) `
                -AllowPlaylist      ([bool]$AllowPlaylist) `
                -CookiesFromBrowser $CookiesFromBrowser `
                -ImpersonateTarget  $DefaultImpersonateTarget `
                -ExtractorArgs      $extractorArgsValue

            $result = Invoke-YtDlpDownload -Arguments $ytDlpArgs
        }
    }
    catch {
        $caughtError = $_.Exception.Message
        Write-Colored "`n❌ Unhandled error: $caughtError" -Color $ColorError
        Write-Log -Level 'ERROR' -Message 'Per-URL exception' -Context @{ url = $currentUrl; error = $caughtError }
    }

    if ($result -and $result.Success) {
        Write-Colored "`n✅ Download completed successfully!" -Color $ColorSuccess
        if ($result.VideoFilePath -and (Test-Path $result.VideoFilePath)) {
            Write-Colored "Saved:" -Color $ColorSuccess
            Write-Colored $result.VideoFilePath -Color $ColorSuccess
        } else {
            Write-Colored "Saved to: $DownloadPath" -Color $ColorSuccess
        }
        Write-Log -Message 'Download success' -Context @{ url = $currentUrl; file = $result.VideoFilePath }
    }
    else {
        $ec = if ($result) { $result.ExitCode } else { -1 }
        Write-Colored "`n❌ Download failed (yt-dlp exit code $ec)." -Color $ColorError
        Write-Log -Level 'ERROR' -Message 'Download failed' -Context @{ url = $currentUrl; exit_code = $ec }
    }

    [void]$summary.Add([pscustomobject]@{
        Index    = $index
        Url      = $currentUrl
        Platform = if ($platformInfo) { $platformInfo.Name } else { 'Unknown' }
        Success  = [bool]($result -and $result.Success)
        ExitCode = if ($result) { $result.ExitCode } else { -1 }
        File     = if ($result) { $result.VideoFilePath } else { $null }
        Error    = $caughtError
    })
}

Write-Progress -Id 1 -Activity 'Professional Video Downloader' -Completed

# Persist the effective path when the script had to choose one or when the user
# explicitly supplied -DownloadPath. This keeps the next run on the same folder
# and heals stale config entries that pointed at missing locations.
if ($persistResolvedDownloadPath) {
    try {
        $configDir = Split-Path -Parent $Script:ConfigFile
        if (-not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force -ErrorAction Stop | Out-Null
        }
        @{ DownloadPath = $DownloadPath } | ConvertTo-Json | Set-Content -LiteralPath $Script:ConfigFile -Force
    }
    catch {}
}

# --------------------- SUMMARY ---------------------
$successCount = @($summary | Where-Object { $_.Success }).Count
$failureCount = $summary.Count - $successCount

Write-Colored "`n========== SUMMARY ==========" -Color $ColorInfo
Write-Colored ("Total: {0}  |  Succeeded: {1}  |  Failed: {2}" -f $summary.Count, $successCount, $failureCount) -Color $ColorInfo

# Structured summary table (alongside the colorized per-row listing below).
$summary |
    Select-Object Index,
                  @{Name='Status';   Expression={ if ($_.Success) { 'OK' } else { 'FAIL' } }},
                  Platform,
                  ExitCode,
                  @{Name='Url';      Expression={ if ($_.Url.Length -gt 60) { $_.Url.Substring(0,57) + '...' } else { $_.Url } }} |
    Format-Table -AutoSize | Out-Host

foreach ($entry in $summary) {
    $status = if ($entry.Success) { "OK  " } else { "FAIL" }
    $color  = if ($entry.Success) { $ColorSuccess } else { $ColorError }
    Write-Colored ("  [{0}] {1}  {2}  -  {3}" -f $entry.Index, $status, $entry.Platform, $entry.Url) -Color $color
}

if ($failureCount -gt 0) {
    Write-Colored "`nTroubleshooting tips for failed downloads:" -Color $ColorWarning
    Write-Colored "  - DRM protection (Netflix, Disney+, Hulu, Prime, Paramount+, Apple TV+, etc.) cannot be bypassed." -Color $ColorWarning
    Write-Colored "  - Login required: try -CookiesFromBrowser <chrome|firefox|edge|brave|...>"     -Color $ColorWarning
    Write-Colored "  - Cloudflare anti-bot: try -Impersonate (requires recent yt-dlp w/ curl_cffi)" -Color $ColorWarning
    Write-Colored "  - Age / region restriction, private content, or network issue"                 -Color $ColorWarning
    Write-Colored "  - yt-dlp out of date: run 'yt-dlp -U' and try again"                           -Color $ColorWarning
    Write-Colored "  - Playlist/channel URL without -AllowPlaylist (default downloads single item)" -Color $ColorWarning
}

Write-Log -Message 'Run finished' -Context @{
    total     = $summary.Count
    succeeded = $successCount
    failed    = $failureCount
}

# --------------------- CLEAN EXIT ---------------------
Invoke-ExitPause -Seconds 4
exit ([int]($failureCount -gt 0))
