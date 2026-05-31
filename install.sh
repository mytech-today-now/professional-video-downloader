#!/usr/bin/env sh
# ============================================================================
#  Professional Video Downloader - POSIX Installer (Linux / macOS / WSL)
#  Idempotent dependency bootstrap: PowerShell 7+, yt-dlp, ffmpeg + ffprobe.
#  Detects the platform package manager (apt, dnf, brew, snap, pacman, zypper)
#  and installs only what is missing. Verifies each binary with --version,
#  then hands off to professional-video-downloader.ps1 via pwsh.
# ============================================================================
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PS1_PATH="${SCRIPT_DIR}/professional-video-downloader.ps1"

log_step() { printf '\033[36m[STEP]\033[0m %s\n' "$*"; }
log_ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
log_info() { printf '\033[90m[INFO]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; }
have()     { command -v "$1" >/dev/null 2>&1; }

[ -f "${PS1_PATH}" ] || { log_err "Downloader script not found: ${PS1_PATH}"; exit 1; }

# Detect sudo wrapper.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if have sudo; then SUDO="sudo"; fi
fi

# Detect package manager.
PM=""
case "$(uname -s)" in
    Darwin)
        if have brew; then PM="brew"; fi
        ;;
    Linux)
        if   have apt-get; then PM="apt"
        elif have dnf;     then PM="dnf"
        elif have zypper;  then PM="zypper"
        elif have pacman;  then PM="pacman"
        elif have snap;    then PM="snap"
        fi
        ;;
    *)
        log_warn "Unrecognized OS: $(uname -s). Will attempt best-effort install."
        ;;
esac

if [ -z "${PM}" ]; then
    log_err "No supported package manager found (apt/dnf/zypper/pacman/snap/brew)."
    log_err "Install PowerShell 7+, yt-dlp and ffmpeg manually, then re-run this script."
    exit 1
fi
log_ok "Package manager: ${PM}"

pm_update() {
    case "${PM}" in
        apt)    ${SUDO} apt-get update -y ;;
        dnf)    : ;;
        zypper) ${SUDO} zypper --non-interactive refresh ;;
        pacman) ${SUDO} pacman -Sy --noconfirm ;;
        brew)   brew update ;;
        snap)   : ;;
    esac
}

pm_install() {
    pkg="$1"
    case "${PM}" in
        apt)    ${SUDO} apt-get install -y "${pkg}" ;;
        dnf)    ${SUDO} dnf install -y "${pkg}" ;;
        zypper) ${SUDO} zypper --non-interactive install "${pkg}" ;;
        pacman) ${SUDO} pacman -S --noconfirm "${pkg}" ;;
        brew)   brew install "${pkg}" ;;
        snap)   ${SUDO} snap install "${pkg}" ;;
    esac
}

ensure_pwsh() {
    log_step 'Checking PowerShell 7+'
    if have pwsh; then
        log_ok "pwsh already installed: $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo unknown)"
        return
    fi
    log_info 'pwsh not found; installing via package manager...'
    pm_update || true
    case "${PM}" in
        brew)                  brew install --cask powershell || brew install powershell ;;
        snap)                  ${SUDO} snap install powershell --classic ;;
        apt|dnf|zypper|pacman) pm_install powershell || log_warn 'powershell package not in default repos; consult https://aka.ms/powershell' ;;
    esac
    have pwsh || { log_err 'PowerShell 7+ installation failed. See https://aka.ms/powershell'; exit 1; }
    log_ok "pwsh installed: $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
}

ensure_ytdlp() {
    log_step 'Checking yt-dlp'
    if have yt-dlp; then
        log_ok "yt-dlp already installed: $(yt-dlp --version 2>/dev/null || echo unknown)"
        return
    fi
    log_info 'yt-dlp not found; installing...'
    pm_update || true
    pm_install yt-dlp || true
    if ! have yt-dlp; then
        log_info 'Falling back to pip install --user yt-dlp'
        if   have pip3; then pip3 install --user --upgrade yt-dlp || true
        elif have pip;  then pip  install --user --upgrade yt-dlp || true
        fi
        export PATH="${HOME}/.local/bin:${PATH}"
    fi
    have yt-dlp || { log_err 'yt-dlp installation failed.'; exit 1; }
    log_ok "yt-dlp installed: $(yt-dlp --version)"
}

ensure_ffmpeg() {
    log_step 'Checking ffmpeg + ffprobe'
    if have ffmpeg && have ffprobe; then
        log_ok "ffmpeg already installed: $(ffmpeg -version 2>/dev/null | head -n 1)"
        return
    fi
    log_info 'ffmpeg/ffprobe not found; installing...'
    pm_update || true
    pm_install ffmpeg || true
    if ! have ffmpeg || ! have ffprobe; then
        log_err 'ffmpeg/ffprobe installation failed.'
        exit 1
    fi
    log_ok "ffmpeg installed: $(ffmpeg -version | head -n 1)"
}

printf '\n'
log_step "Install root: ${SCRIPT_DIR}"
printf '\n'

ensure_pwsh
ensure_ytdlp
ensure_ffmpeg

printf '\n'
log_step 'Verification'
for tool in pwsh yt-dlp ffmpeg ffprobe; do
    if have "${tool}"; then
        ver="$(${tool} --version 2>/dev/null | head -n 1 || true)"
        [ -z "${ver}" ] && ver="$(${tool} -version 2>/dev/null | head -n 1 || true)"
        printf '\033[32m[ OK ]\033[0m %-9s -> %s\n' "${tool}" "${ver}"
    else
        printf '\033[31m[ERR ]\033[0m %-9s -> NOT FOUND\n' "${tool}" >&2
    fi
done

printf '\n'
log_step 'Launching Professional Video Downloader'
printf '\n'

exec pwsh -NoProfile -ExecutionPolicy Bypass -File "${PS1_PATH}" "$@"