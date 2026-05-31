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
    2.0.0   # Major refactor: registry-based platform detection covering 60+ named
            # sites and 1,800+ via yt-dlp passthrough; DRM/cookie/NSFW advisories;
            # -CookiesFromBrowser, -AudioOnly, -AllowPlaylist options.

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

    Unquoted & multi-URL input: -Url accepts one or many URLs without quotes.
    Separate URLs with one or more spaces, a comma, a semicolon, and/or newlines.
    Each URL is downloaded in turn, with per-URL retry handling, and a summary is
    printed at the end. Interactive mode prompts for URLs and ends on a blank line.

    PowerShell tokenization caveat: a bare URL containing '&' (e.g. YouTube
    'watch?v=X&t=10') must be quoted on the command line because PowerShell
    treats '&' as the call operator. URLs with '#fragments' are fine unquoted —
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
    # then further split on whitespace/comma/semicolon/newline by Expand-UrlList.
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
    [switch]$Impersonate
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ====================== CONFIGURATION & CONSTANTS ======================
$ScriptVersion = "3.0.0"
# Default browser fingerprint used by -Impersonate and by the Cloudflare auto-retry.
# Requires a recent yt-dlp with curl_cffi (bundled in modern builds).
$DefaultImpersonateTarget = "chrome"
$ConfigFile = Join-Path $PSScriptRoot "VideoDownloaderConfig.json"
$MaxAttempts = 3

# Color constants
$ColorInfo    = 'Cyan'
$ColorSuccess = 'Green'
$ColorWarning = 'Yellow'
$ColorError   = 'Red'
$ColorMuted   = 'DarkGray'

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
    # Accepts any mix of: a single URL, multiple URLs joined by whitespace,
    # commas, semicolons, or newlines, and array elements containing any of
    # the above. Empty/whitespace tokens are discarded; order is preserved.
    param([Parameter()][string[]]$Raw)

    if (-not $Raw -or $Raw.Count -eq 0) { return @() }

    $combined = ($Raw -join "`n")
    $tokens   = $combined -split '[\s,;]+' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }

    $seen   = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $tokens) {
        if ($seen.Add($t)) { [void]$result.Add($t) }
    }
    return ,$result.ToArray()
}

function Read-UrlListInteractive {
    # Reads URLs from the console. Accepts paste-style input: one or more URLs
    # per line, separated by spaces/commas/semicolons. An empty line terminates
    # input. If the user pastes a single token that resolves to a file path or
    # an http(s) URL whose body is text, it is treated as a batch file and the
    # contents are returned in lieu of the raw line.
    param([string]$Prompt = "Enter one or more URLs (separate by space/comma/semicolon; blank line to finish).`nA local file path or http(s) URL to a text file works too.")

    Write-Colored $Prompt -Color $ColorInfo
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = Read-Host ">"
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $trimmed = $line.Trim()
        if (Test-IsBatchSource $trimmed) {
            try {
                $fetched = Read-UrlsFromSource -Source $trimmed
                foreach ($f in $fetched) { [void]$lines.Add($f) }
                Write-Colored ("  Loaded {0} token(s) from '{1}'." -f $fetched.Count, $trimmed) -Color $ColorMuted
                continue
            }
            catch {
                Write-Colored ("  Could not read '{0}': {1}" -f $trimmed, $_.Exception.Message) -Color $ColorWarning
            }
        }
        [void]$lines.Add($line)
    }
    return ,$lines.ToArray()
}

function Test-IsBatchSource {
    # Detects whether a single user token looks like a file path or an http(s) URL
    # pointing at a non-video resource (used to decide whether to fetch its body
    # as a URL list rather than treating it as a download target).
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    if (Test-Path -LiteralPath $Token -PathType Leaf) { return $true }
    if ($Token -match '^(?i)https?://.+\.(txt|list|csv|tsv|md)(\?.*)?$') { return $true }
    return $false
}

function Read-UrlsFromSource {
    # Reads the raw contents of a local file or http(s) URL and returns it as a
    # single-element string array (Expand-UrlList does the actual tokenization).
    param([Parameter(Mandatory)][string]$Source)

    if ($Source -match '^(?i)https?://') {
        $resp = Invoke-WebRequest -Uri $Source -UseBasicParsing -ErrorAction Stop
        $body = if ($resp.PSObject.Properties['Content']) { [string]$resp.Content } else { [string]$resp }
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

function Get-DownloadsFolder {
    # Most reliable cross-Windows method for Downloads folder
    try {
        $shell = New-Object -ComObject Shell.Application
        $downloads = $shell.Namespace('shell:Downloads').Self.Path
        if ($downloads) { return $downloads }
    }
    catch {}

    # Fallbacks
    $userProfile = $env:USERPROFILE
    $possible = @(
        (Join-Path $userProfile "Downloads"),
        (Join-Path $userProfile "My Downloads"),
        [Environment]::GetFolderPath("MyVideos")  # fallback
    )

    foreach ($path in $possible) {
        if (Test-Path $path) { return $path }
    }

    return Join-Path $userProfile "Downloads"  # final fallback
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

    & yt-dlp @Arguments 2>&1 | ForEach-Object {
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
# Plain-text log per spec: ./logs/YYYY-MM-DD.log next to the script.
# Logging is always on; the path is resolved via $PSScriptRoot so the script
# runs in-place wherever install.bat/install.sh placed it.
$Script:LogDir = Join-Path $PSScriptRoot 'logs'

function Write-Log {
    # Appends one timestamped line to today's log file. Never throws.
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
        # Never let logging break the run.
    }
}

Write-Log -Message 'Script started' -Context @{
    pwsh      = $PSVersionTable.PSVersion.ToString()
    script    = $PSCommandPath
    cwd       = (Get-Location).Path
    audioOnly = [bool]$AudioOnly
    playlist  = [bool]$AllowPlaylist
}

# ====================== MAIN SCRIPT ======================

Write-Colored "=== Video Downloader (yt-dlp) v$ScriptVersion ===" -Color $ColorInfo
Write-Colored "Supports 1,800+ sites via yt-dlp. Curated platforms include:" -Color $ColorMuted
Write-Colored "  Video : YouTube, Vimeo, Dailymotion, Twitch, Facebook, Instagram, TikTok," -Color $ColorMuted
Write-Colored "          X/Twitter, Reddit, Bilibili, Rumble, Odysee, Snapchat, Substack"   -Color $ColorMuted
Write-Colored "  Audio : SoundCloud, Bandcamp, Vevo  |  News: BBC, CNN, NBC, ABC, CBS, NYT" -Color $ColorMuted
Write-Colored "  Other : TED, Pinterest, LinkedIn, VK, Rutube, Imgur, Tumblr, 9GAG, +adult" -Color $ColorMuted
Write-Colored "  DRM   : Netflix, Disney+, Hulu, Prime, Paramount+, Apple TV+ (cannot decrypt)`n" -Color $ColorMuted

# --------------------- DOWNLOAD PATH MANAGEMENT ---------------------
if (-not $DownloadPath) {
    # Load saved custom path if exists
    if (Test-Path $ConfigFile) {
        try {
            $config = Get-Content $ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $savedPath = $null
            if ($config -and $config.PSObject.Properties['DownloadPath']) {
                $savedPath = $config.DownloadPath
            }
            if ($savedPath -and (Test-Path $savedPath)) {
                $DownloadPath = $savedPath
                Write-Colored "Using previously saved folder: $DownloadPath" -Color $ColorWarning
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
if (-not (Test-Path $DownloadPath)) {
    try {
        New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
        Write-Colored "Created download directory: $DownloadPath" -Color $ColorInfo
    }
    catch {
        Write-Colored "Warning: Could not create folder. Falling back to user profile." -Color $ColorWarning
        $DownloadPath = $env:USERPROFILE
    }
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
        Start-Sleep -Seconds 3
        exit 1
    }
}

if ($Url -and $Url.Count -gt 0) {
    foreach ($u in $Url) {
        $trimmed = if ($u) { $u.Trim() } else { '' }
        if ($trimmed -and (Test-IsBatchSource $trimmed)) {
            try {
                $fetched = Read-UrlsFromSource -Source $trimmed
                foreach ($f in $fetched) { [void]$rawUrlInput.Add($f) }
                Write-Log -Message 'Loaded URL list from -Url batch source' -Context @{ source = $trimmed }
                continue
            }
            catch {
                Write-Colored "Warning: Could not read '$trimmed' as a URL list: $($_.Exception.Message)" -Color $ColorWarning
            }
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
            Write-Colored "Examples (one per line, or space/comma/semicolon-separated):" -Color $ColorWarning
            Write-Colored "  https://youtube.com/watch?v=..."             -Color $ColorWarning
            Write-Colored "  https://vimeo.com/123456789"                 -Color $ColorWarning
            Write-Colored "  https://www.tiktok.com/@user/video/..."      -Color $ColorWarning
            Write-Colored "  C:\path\to\urls.txt   (or)   https://host/list.txt" -Color $ColorWarning
        }
    }
    if ($rawUrlInput.Count -eq 0) {
        Write-Colored "Maximum attempts reached. Exiting." -Color $ColorError
        Write-Log -Level 'ERROR' -Message 'No URLs provided after max attempts'
        Start-Sleep -Seconds 3
        exit 1
    }
}

# Flatten the raw input into individual URL tokens (handles every separator
# the caller might use: spaces, tabs, commas, semicolons, newlines).
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
    Start-Sleep -Seconds 4
    exit 1
}

Write-Colored "Queued $($urlList.Count) URL(s) for download." -Color $ColorInfo

# --------------------- CHECK FOR YT-DLP ---------------------
if (-not (Get-Command "yt-dlp" -ErrorAction SilentlyContinue)) {
    Write-Colored "ERROR: yt-dlp not found in PATH." -Color $ColorError
    Write-Colored "`nInstall with:" -Color $ColorWarning
    Write-Colored "   winget install yt-dlp" -Color $ColorInfo
    Write-Colored "Then restart PowerShell and try again." -Color $ColorInfo
    Start-Sleep -Seconds 6
    exit 1
}

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

# Persist custom path (once, after all URLs have been processed).
if ($PSBoundParameters.ContainsKey('DownloadPath')) {
    try { @{ DownloadPath = $DownloadPath } | ConvertTo-Json | Set-Content $ConfigFile -Force } catch {}
}

# --------------------- SUMMARY ---------------------
$successCount = ($summary | Where-Object { $_.Success }).Count
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
Write-Colored "`nWindow will close in 4 seconds..." -Color $ColorInfo
Start-Sleep -Seconds 4
exit ([int]($failureCount -gt 0))