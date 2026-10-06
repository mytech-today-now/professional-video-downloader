# Professional Video Downloader

A production-grade PowerShell wrapper around [yt-dlp](https://github.com/yt-dlp/yt-dlp)
with cross-platform installers, batch URL processing, structured logging, and a
curated platform registry covering 60+ named sites plus the 1,800+ sites yt-dlp
supports natively.

powershell 
```
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/mytech-today-now/professional-video-downloader/v1.0.0/install-bootstrap.ps1 | iex"
```

cmd 
```
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/mytech-today-now/professional-video-downloader/v1.0.0/install-bootstrap.ps1' | iex"
```

> Trust boundary: these one-liners fetch `install-bootstrap.ps1` from the tagged `v1.0.0` release and execute it in the local PowerShell process. That makes the install reproducible and easier to mirror than `main`, but it still trusts downloaded PowerShell. For the lowest-risk path, clone the repo and run `install.bat` or `install.sh` locally.

---

## Contents

| File                                | Purpose                                                    |
| ----------------------------------- | ---------------------------------------------------------- |
| `professional-video-downloader.ps1` | Main downloader script (PowerShell 5.1+).                  |
| `professional-video-downloader.lnk` | Windows shortcut launcher installed in the Start Menu by the installer. |
| `install.bat`                       | Windows entry point: dependency bootstrap, machine-wide install, and launch. |
| `install-bootstrap.ps1`             | Internal: detect/install winget, yt-dlp, ffmpeg; refresh the machine-wide shortcut. |
| `install.sh`                        | POSIX entry point for Linux / macOS / WSL. Installs into the platform runtime root. |
| `VERSION`                           | Authoritative semantic version for this distribution. Used by the script banner and installers. |

---

## Installation

### Windows

1. Double-click `install.bat`, **or** from a terminal:
   ```bat
   install.bat
   ```
2. The installer detects `winget` / `Chocolatey` (bootstrapping Chocolatey if
   neither is present), then installs only the missing dependencies:
   - **yt-dlp** (latest stable)
   - **ffmpeg + ffprobe**
   - **Python 3.10+** (only as a pip fallback for yt-dlp)
3. The runtime files are copied to `%ProgramFiles%\myTech.Today\professional-video-downloader`.
4. `professional-video-downloader.lnk` is installed for all users under `%ProgramData%\Microsoft\Windows\Start Menu\Programs\myTech.Today` and launches the installed script from Program Files.
5. The script launches immediately with any arguments you passed to `install.bat`.

Re-running is safe: anything already installed is detected and skipped with a
`[ OK ]` line.

Because this is a machine-wide Windows install, the installer may prompt for
UAC when it needs to write into Program Files or the all-users Start Menu.

### Linux / macOS / WSL

```sh
chmod +x ./install.sh
./install.sh
```

The installer auto-detects the platform package manager (`apt`, `dnf`, `zypper`,
`pacman`, `snap`, `brew`) and installs only the missing dependencies:

- **PowerShell 7+** (`pwsh`)
- **yt-dlp**
- **ffmpeg + ffprobe**

On macOS it copies the runtime to `/Applications/mytech-today/professional-video-downloader/`.
On Linux it copies the runtime to `/usr/bin/mytech-today/professional-video-downloader/`.
It then hands off to the installed `professional-video-downloader.ps1` and forwards
all arguments.

Those install roots are machine-wide, so the copy step may require `sudo` or
root privileges if the directories are not already writable.

---

## Usage

The downloader accepts URLs three ways:

### 1. Interactive prompt (no arguments)

```powershell
.\professional-video-downloader.ps1
```

Paste one or more URLs (delimited by spaces, commas, semicolons, tabs, or
newlines) and press **Enter on a blank line** to begin.

### 2. `-Url` parameter (positional, multi-value)

```powershell
.\professional-video-downloader.ps1 https://youtu.be/dQw4w9WgXcQ
.\professional-video-downloader.ps1 -Url "https://a.com/x","https://b.com/y"
.\professional-video-downloader.ps1 https://a.com/x https://b.com/y https://c.com/z
.\professional-video-downloader.ps1 -Url "https://a.com/x,https://b.com/y;https://c.com/z"
```

URLs are split, validated against `^https?://`, de-duplicated, and processed
sequentially. A failed URL never aborts the batch.

> **PowerShell quoting note:** A bare URL containing `&` (e.g.
> `watch?v=X&t=10`) **must be quoted**, because PowerShell treats `&` as the
> call operator. Paste the raw URL only, not Markdown link text like
> `[https://...](...)`. URLs with `#fragments` are safe unquoted.

### 3. `-InputFile` parameter (local path **or** http(s) URL)

```powershell
.\professional-video-downloader.ps1 -InputFile .\urls.txt
.\professional-video-downloader.ps1 -InputFile https://example.com/list.txt
```

The file is fetched (if remote) or read (if local), URLs are extracted using the
same delimiter rules as above, de-duplicated against any URLs already supplied
via `-Url`, and queued.

### Common options

| Switch / Param            | Effect                                                                          |
| ------------------------- | ------------------------------------------------------------------------------- |
| `-AudioOnly`              | Extract best-quality audio only (yt-dlp `-x`).                                  |
| `-AllowPlaylist`          | Download every entry of a playlist/channel URL (default downloads only the first item). |
| `-CookiesFromBrowser <b>` | Reuse an existing browser session for login-gated content. `<b>`: `chrome`, `chromium`, `edge`, `firefox`, `brave`, `opera`, `vivaldi`, `safari`. |
| `-Impersonate`            | Enable browser TLS impersonation from the first attempt (Cloudflare-protected sites). Requires recent yt-dlp with `curl_cffi`. |
| `-PauseOnExit`            | Opt in to the legacy 4-second exit pause for interactive console use. |
| `-DownloadPath <path>`    | Override the system Downloads folder for this invocation only.                  |

### Examples

```powershell
# Audio extraction from SoundCloud
.\professional-video-downloader.ps1 -Url "https://soundcloud.com/artist/track" -AudioOnly

# Whole playlist
.\professional-video-downloader.ps1 -Url "https://www.youtube.com/playlist?list=PL..." -AllowPlaylist

# Login-gated Instagram post via Firefox session
.\professional-video-downloader.ps1 -Url "https://www.instagram.com/p/..." -CookiesFromBrowser firefox

# Cloudflare-protected site
.\professional-video-downloader.ps1 -Url "https://example.com/video" -Impersonate

# Batch from a remote URL list
.\professional-video-downloader.ps1 -InputFile https://pastebin.com/raw/abc -AudioOnly
```

---

## Output & Logging

- **Downloads** go to the current user's system Downloads folder. Windows uses
  the Windows Downloads known folder, macOS uses its system Downloads folder,
  and Linux follows `xdg-user-dir DOWNLOAD` or the user's XDG directory config.
  The folder is created when needed. `-DownloadPath` overrides it for one run.
- **Logs** live in the user-writable app state directory. On Windows that is
  `%LOCALAPPDATA%\myTech.Today\professional-video-downloader\`; on macOS and
  Linux the script uses the matching user data or state directory. Logs roll
  daily under `logs/YYYY-MM-DD.log` in that root.
- **Progress** is shown live via `Write-Progress`; a summary table
  (success / failure / per-URL status) is printed when the batch completes.

---

## yt-dlp Update Check

Before processing URLs, the downloader checks the official GitHub latest stable
release and verifies the version reported by the exact executable it will use.
The response must contain a valid dated yt-dlp release tag and explicit draft
and prerelease flags. It does not reinstall an already current stable release
or downgrade a version newer than the advertised release. On Windows, an outdated
installation is updated only when the executable resolves through the user's
WinGet links directory and WinGet confirms the `yt-dlp.yt-dlp` package. The
downloader requests that exact stable version and verifies the same executable
path again before continuing.

The updater does not replace Chocolatey, pip, virtual environment, or POSIX
package-manager installations with a different distribution. If an outdated
installation has another or unknown owner, the downloader stops before media
processing. Update yt-dlp with the same package manager or Python interpreter
that installed it, then rerun. The downloader does not upgrade Python. This
avoids changing a Python runtime shared by other applications.

The release check requires HTTPS access to the GitHub API on every invocation.
If that check, the owner update, or post-update verification fails, the
downloader stops and reports the reason instead of using an older executable.

---

## Troubleshooting

| Symptom                                                | Likely cause / Fix                                                                                                                                                |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `'yt-dlp' is not recognized` after install             | The current shell still has the old `PATH`. Open a **new** terminal, or just re-run `install.bat` / `install.sh` — they refresh the session PATH automatically.    |
| HTTP 403 on a Cloudflare-protected site                | Re-run with `-Impersonate`. The script auto-retries once with impersonation; this flag enables it from the first attempt.                                          |
| Login-gated content fails (Instagram private, Reddit NSFW, Substack subscriber-only, paywalled news, sub-only Twitch VODs) | Sign in to the site in your browser, then use `-CookiesFromBrowser <browser>`.                                                                                     |
| Netflix / Disney+ / Hulu / Prime Video / Spotify fails | Those services use Widevine/FairPlay DRM. yt-dlp cannot decrypt DRM streams. This is a fundamental limitation, not a script bug.                                   |
| `ffmpeg not found` during merge                        | Re-run the installer — it will detect the missing binary and install ffmpeg.                                                                                       |
| Execution policy blocks the script                     | The bundled `.bat` / `.sh` launchers already pass `-ExecutionPolicy Bypass`. If running the `.ps1` directly: `powershell -ExecutionPolicy Bypass -File .\professional-video-downloader.ps1`. |

To enable verbose diagnostics, append `-Verbose` to any invocation.

---

## Dependencies

| Tool        | Minimum     | Purpose                                            |
| ----------- | ----------- | -------------------------------------------------- |
| PowerShell  | 5.1 (Win) / 7+ (Linux/macOS) | Script host                       |
| yt-dlp      | Latest stable | Checked before media processing on every invocation |
| ffmpeg      | any recent  | Container muxing / remuxing                        |
| ffprobe     | any recent  | Media inspection (shipped with ffmpeg)             |
| Python      | 3.10+       | Needed by the installer's `pip` fallback; the downloader does not update Python |
| winget / Chocolatey | n/a | Windows package manager (one is required; installer bootstraps Chocolatey if neither is present) |

## Versioning

`VERSION` is the single source of truth for release metadata. The PowerShell banner, log lines, and both installers read from it, and `tests/version-sync.ps1` fails if the values drift.

---

## License

MIT — see the project root for the full license text.
