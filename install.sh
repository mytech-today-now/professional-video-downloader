#!/usr/bin/env sh
# ============================================================================
#  Professional Video Downloader - POSIX Installer (Linux / macOS / WSL)
#  Idempotent dependency bootstrap: PowerShell 7+, yt-dlp, ffmpeg + ffprobe.
#  Detects the platform package manager (apt, dnf, brew, snap, pacman, zypper)
#  and installs only what is missing. Verifies each binary with --version,
#  copies the runtime into the platform install root, then hands off to the
#  installed professional-video-downloader.ps1 via pwsh.
# ============================================================================
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PS1_PATH="${SCRIPT_DIR}/professional-video-downloader.ps1"
VERSION_FILE="${SCRIPT_DIR}/VERSION"

log_step() { printf '\033[36m[STEP]\033[0m %s\n' "$*"; }
log_ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
log_info() { printf '\033[90m[INFO]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; }
have()     { command -v "$1" >/dev/null 2>&1; }
run_step() {
    step_desc="$1"
    shift
    if "$@"; then
        return 0
    else
        status=$?
        log_err "${step_desc} failed with exit code ${status}."
        return "${status}"
    fi
}

if [ ! -f "${VERSION_FILE}" ]; then
    log_err "VERSION file not found: ${VERSION_FILE}"
    exit 1
fi

APP_VERSION="$(sed -n '1{s/[[:space:]]*$//;p;q}' "${VERSION_FILE}")"
if [ -z "${APP_VERSION}" ]; then
    log_err "VERSION file is empty: ${VERSION_FILE}"
    exit 1
fi
MIN_YTDLP_VERSION='2026.08.19'

[ -f "${PS1_PATH}" ] || { log_err "Downloader script not found: ${PS1_PATH}"; exit 1; }

# Native Windows-hosted POSIX shells are not a supported launch path.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
        log_err "install.sh is not supported on native Windows-hosted POSIX shells. Use install.bat on Windows or run this script inside Linux, macOS, or WSL."
        exit 1
        ;;
esac

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

INSTALL_ROOT="${PVD_INSTALL_ROOT:-}"
if [ -z "${INSTALL_ROOT}" ]; then
    case "$(uname -s)" in
        Darwin)
            INSTALL_ROOT='/Applications/mytech-today/professional-video-downloader'
            ;;
        Linux)
            INSTALL_ROOT='/usr/bin/mytech-today/professional-video-downloader'
            ;;
        *)
            INSTALL_ROOT='/usr/bin/mytech-today/professional-video-downloader'
            ;;
    esac
fi

install_runtime() {
    if [ "$(id -u)" -eq 0 ]; then
        run_step "mkdir -p ${INSTALL_ROOT}" mkdir -p "${INSTALL_ROOT}" || {
            log_err "Install root ${INSTALL_ROOT} requires sudo or root access. Re-run with sudo/root, or set PVD_INSTALL_ROOT to a writable path."
            exit 1
        }
        run_step "copy runtime files to ${INSTALL_ROOT}" cp -f "${PS1_PATH}" "${VERSION_FILE}" "${INSTALL_ROOT}/" || {
            log_err "Install root ${INSTALL_ROOT} requires sudo or root access. Re-run with sudo/root, or set PVD_INSTALL_ROOT to a writable path."
            exit 1
        }
        log_ok "Runtime files installed: ${INSTALL_ROOT}"
        return 0
    fi

    if [ -n "${SUDO}" ]; then
        run_step "mkdir -p ${INSTALL_ROOT}" ${SUDO} mkdir -p "${INSTALL_ROOT}" || {
            log_err "Install root ${INSTALL_ROOT} requires sudo or root access. Re-run with sudo/root, or set PVD_INSTALL_ROOT to a writable path."
            exit 1
        }
        run_step "copy runtime files to ${INSTALL_ROOT}" ${SUDO} cp -f "${PS1_PATH}" "${VERSION_FILE}" "${INSTALL_ROOT}/" || {
            log_err "Install root ${INSTALL_ROOT} requires sudo or root access. Re-run with sudo/root, or set PVD_INSTALL_ROOT to a writable path."
            exit 1
        }
        log_ok "Runtime files installed: ${INSTALL_ROOT}"
        return 0
    fi

    run_step "mkdir -p ${INSTALL_ROOT}" mkdir -p "${INSTALL_ROOT}" || {
        log_err "Install root ${INSTALL_ROOT} requires sudo or root access. Re-run with sudo/root, or set PVD_INSTALL_ROOT to a writable path."
        exit 1
    }
    run_step "copy runtime files to ${INSTALL_ROOT}" cp -f "${PS1_PATH}" "${VERSION_FILE}" "${INSTALL_ROOT}/" || {
        log_err "Install root ${INSTALL_ROOT} requires sudo or root access. Re-run with sudo/root, or set PVD_INSTALL_ROOT to a writable path."
        exit 1
    }
    log_ok "Runtime files installed: ${INSTALL_ROOT}"
}

pm_update() {
    case "${PM}" in
        apt)    run_step 'apt-get update -y' ${SUDO} apt-get update -y ;;
        dnf)    : ;;
        zypper) run_step 'zypper --non-interactive refresh' ${SUDO} zypper --non-interactive refresh ;;
        pacman) run_step 'pacman -Sy --noconfirm' ${SUDO} pacman -Sy --noconfirm ;;
        brew)   run_step 'brew update' brew update ;;
        snap)   : ;;
    esac
}

pm_install() {
    pkg="$1"
    case "${PM}" in
        apt)    run_step "apt-get install -y ${pkg}" ${SUDO} apt-get install -y "${pkg}" ;;
        dnf)    run_step "dnf install -y ${pkg}" ${SUDO} dnf install -y "${pkg}" ;;
        zypper) run_step "zypper --non-interactive install ${pkg}" ${SUDO} zypper --non-interactive install "${pkg}" ;;
        pacman) run_step "pacman -S --noconfirm ${pkg}" ${SUDO} pacman -S --noconfirm "${pkg}" ;;
        brew)   run_step "brew install ${pkg}" brew install "${pkg}" ;;
        snap)   run_step "snap install ${pkg}" ${SUDO} snap install "${pkg}" ;;
    esac
}

ensure_pwsh() {
    log_step 'Checking PowerShell 7+'
    if have pwsh; then
        log_ok "pwsh already installed: $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo unknown)"
        return
    fi
    log_info 'pwsh not found; installing via package manager...'
    if ! pm_update; then
        log_warn "Continuing after ${PM} update failure."
    fi
    case "${PM}" in
        brew)
            if ! run_step 'brew install --cask powershell' brew install --cask powershell; then
                log_info 'Trying brew install powershell as a fallback.'
                if ! run_step 'brew install powershell' brew install powershell; then
                    :
                fi
            fi
            ;;
        snap)
            if ! run_step 'snap install powershell --classic' ${SUDO} snap install powershell --classic; then
                :
            fi
            ;;
        apt|dnf|zypper|pacman)
            if ! pm_install powershell; then
                log_warn 'powershell package not in default repos; consult https://aka.ms/powershell'
            fi
            ;;
    esac
    have pwsh || { log_err 'PowerShell 7+ installation failed. See https://aka.ms/powershell'; exit 1; }
    log_ok "pwsh installed: $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
}

yt_dlp_version_status() {
    printf '%s\n' "$1" | awk -v required="${MIN_YTDLP_VERSION}" '
        BEGIN { required_count = split(required, required_parts, /[.]/) }
        {
            candidate = ""
            for (field = 1; field <= NF; field++) {
                if ($field ~ /^[0-9]+[.][0-9]+/) {
                    candidate = $field
                    break
                }
            }
            if (candidate == "") {
                print "unknown"
                next
            }

            version = ""
            suffix = ""
            for (position = 1; position <= length(candidate); position++) {
                character = substr(candidate, position, 1)
                if (character ~ /^[0-9]$/ || (character == "." && position < length(candidate) && substr(candidate, position + 1, 1) ~ /^[0-9]$/)) {
                    version = version character
                } else {
                    suffix = substr(candidate, position)
                    break
                }
            }
            if (version !~ /^[0-9]+([.][0-9]+)+$/) {
                print "unknown"
                next
            }

            installed_count = split(version, installed_parts, /[.]/)
            part_count = installed_count > required_count ? installed_count : required_count
            comparison = 0
            for (part = 1; part <= part_count; part++) {
                installed = part <= installed_count ? installed_parts[part] + 0 : 0
                minimum = part <= required_count ? required_parts[part] + 0 : 0
                if (installed > minimum) {
                    comparison = 1
                    break
                }
                if (installed < minimum) {
                    comparison = -1
                    break
                }
            }

            if (comparison < 0 || (comparison == 0 && suffix != "")) {
                print "old"
            } else {
                print "ok"
            }
        }
    '
}

assert_ytdlp_version() {
    version_text="$1"
    version_status="$(yt_dlp_version_status "${version_text}")"
    case "${version_status}" in
        ok) return 0 ;;
        unknown)
            log_err "Unable to determine yt-dlp version from '${version_text}'. Minimum required is ${MIN_YTDLP_VERSION}."
            ;;
        *)
            log_err "yt-dlp ${version_text} is older than required ${MIN_YTDLP_VERSION}. Update yt-dlp with the package manager or pip used to install it, or run 'yt-dlp -U' for standalone release binaries, then rerun install.sh."
            ;;
    esac
    exit 1
}

ensure_ytdlp() {
    log_step 'Checking yt-dlp'
    if have yt-dlp; then
        version_text="$(yt-dlp --version 2>/dev/null | head -n 1 || true)"
        [ -n "${version_text}" ] || version_text='unknown'
        assert_ytdlp_version "${version_text}"
        log_ok "yt-dlp already installed: ${version_text}"
        return
    fi
    log_info 'yt-dlp not found; installing...'
    if ! pm_update; then
        log_warn "Continuing after ${PM} update failure."
    fi
    if ! pm_install yt-dlp; then
        log_warn "Package-manager install failed for yt-dlp; checking pip fallback."
    fi
    if ! have yt-dlp; then
        if   have pip3; then
            log_info 'Falling back to pip3 install --user yt-dlp'
            if run_step 'pip3 install --user --upgrade yt-dlp' pip3 install --user --upgrade yt-dlp; then
                export PATH="${HOME}/.local/bin:${PATH}"
            fi
        elif have pip; then
            log_info 'Falling back to pip install --user yt-dlp'
            if run_step 'pip install --user --upgrade yt-dlp' pip install --user --upgrade yt-dlp; then
                export PATH="${HOME}/.local/bin:${PATH}"
            fi
        else
            log_err 'Neither pip3 nor pip is available for the yt-dlp fallback.'
        fi
    fi
    have yt-dlp || { log_err 'yt-dlp installation failed.'; exit 1; }
    version_text="$(yt-dlp --version 2>/dev/null | head -n 1 || true)"
    [ -n "${version_text}" ] || version_text='unknown'
    assert_ytdlp_version "${version_text}"
    log_ok "yt-dlp installed: ${version_text}"
}

ensure_ffmpeg() {
    log_step 'Checking ffmpeg + ffprobe'
    if have ffmpeg && have ffprobe; then
        log_ok "ffmpeg already installed: $(ffmpeg -version 2>/dev/null | head -n 1)"
        return
    fi
    log_info 'ffmpeg/ffprobe not found; installing...'
    if ! pm_update; then
        log_warn "Continuing after ${PM} update failure."
    fi
    if ! pm_install ffmpeg; then
        log_warn 'Package-manager install failed for ffmpeg; checking installed binaries.'
    fi
    if ! have ffmpeg || ! have ffprobe; then
        log_err 'ffmpeg/ffprobe installation failed.'
        exit 1
    fi
    log_ok "ffmpeg installed: $(ffmpeg -version | head -n 1)"
}

printf '\n'
log_step "Professional Video Downloader v${APP_VERSION} - Setup"
log_step "Install root: ${INSTALL_ROOT}"
printf '\n'

ensure_pwsh
ensure_ytdlp
ensure_ffmpeg
install_runtime

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

exec pwsh -NoProfile -ExecutionPolicy Bypass -File "${INSTALL_ROOT}/professional-video-downloader.ps1" "$@"
