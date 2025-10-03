#!/usr/bin/env bash
# install-zig-and-zls.sh
# Linux (x86_64/aarch64): install Zig (latest or pinned) and ZLS (matching or pinned)
# Per-user, no sudo: installs under ~/.local by default and updates ~/.local/bin/{zig,zls}
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
success() { echo -e "${GREEN}✓${NC} $1"; }

# ---- defaults / CLI ----
ZIG_VER_SPEC="latest"   # e.g. "latest" or "0.15.1"
ZLS_VER_SPEC="auto"     # "auto"=match Zig major.minor; or "latest"; or a tag like "0.14.0"
INSTALL_PREFIX="${HOME}/.local"
BIN_DIR="${HOME}/.local/bin"
INSTALL_ZLS=1
AUTO_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zig)        ZIG_VER_SPEC="${2:?}"; shift 2 ;;
    --zls)        ZLS_VER_SPEC="${2:?}"; shift 2 ;;
    --skip-zls)   INSTALL_ZLS=0; shift ;;
    --prefix)     INSTALL_PREFIX="${2:?}"; shift 2 ;;
    --bindir)     BIN_DIR="${2:?}"; shift 2 ;;
    -y|--yes)     AUTO_YES=1; shift ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--zig <version|latest>] [--zls <auto|latest|version>] [--skip-zls]
          [--prefix <dir>] [--bindir <dir>] [-y|--yes]

Options:
  -y, --yes    Auto-confirm all prompts (for scripting)

Examples:
  $0
  $0 --zig 0.14.1
  $0 --zig 0.14.1 --zls 0.14.0
  $0 --skip-zls
  $0 --yes

Environment Variables:
  GITHUB_TOKEN  A GitHub Personal Access Token to increase API rate limits.
USAGE
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"; }
for c in tar uname jq file; do need "$c"; done

# Detect SHA256 tool (macOS uses shasum, Linux uses sha256sum)
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  error "Neither sha256sum nor shasum found. Please install one."
fi

# Detect download tool
if command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
elif command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
else
  error "Neither wget nor curl found. Please install one."
fi

mkdir -p "${INSTALL_PREFIX}" "${BIN_DIR}" "${INSTALL_PREFIX}/tmp"

# [FIXED] Prepare auth header for GitHub API calls
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  log "Using GITHUB_TOKEN for authenticated API requests"
  AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ZIG_ARCH="x86_64" ;;
  aarch64|arm64) ZIG_ARCH="aarch64" ;;
  *) echo "Unsupported arch: ${ARCH} (supported: x86_64, aarch64, arm64)" >&2; exit 1 ;;
esac

# Detect OS
OS="$(uname -s)"
case "$OS" in
  Linux)  ZIG_OS="linux" ;;
  Darwin) ZIG_OS="macos" ;;
  *) echo "Unsupported OS: ${OS} (supported: Linux, macOS)" >&2; exit 1 ;;
esac

# ---- resolve Zig version ----
if [[ "$ZIG_VER_SPEC" == "latest" ]]; then
  log "Fetching latest Zig version..."
  ZIG_INDEX_JSON="$(curl -fsSL 'https://ziglang.org/download/index.json')"
  ZIG_VER="$(echo "$ZIG_INDEX_JSON" | jq -r '
    to_entries
    | map(select(.key|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
    | sort_by(.key | split(".") | map(tonumber))
    | last.key')"
else
  ZIG_VER="$ZIG_VER_SPEC"
fi

# ---- Check for existing Zig ----
SKIP_ZIG=0
if command -v zig >/dev/null 2>&1; then
  EXISTING_VER="$(zig version 2>/dev/null || echo '')"
  if [[ "${EXISTING_VER}" == "${ZIG_VER}" ]]; then
    EXISTING_PATH="$(command -v zig)"
    log "Zig ${ZIG_VER} already installed at ${EXISTING_PATH}"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping Zig installation"; SKIP_ZIG=1; }
    else
      log "Auto-confirming reinstall (--yes flag)"
    fi
  else
    log "Found Zig ${EXISTING_VER}, will install ${ZIG_VER}"
  fi
fi

# ---- Install Zig ----
if [[ "${SKIP_ZIG}" -eq 0 ]]; then
  if [[ -z "${ZIG_INDEX_JSON:-}" ]]; then
    ZIG_INDEX_JSON="$(curl -fsSL 'https://ziglang.org/download/index.json')"
  fi
  OS_ARCH="${ZIG_ARCH}-${ZIG_OS}"
  ZIG_URL="$(echo "$ZIG_INDEX_JSON" | jq -r --arg v "$ZIG_VER" --arg os_arch "$OS_ARCH" '.[$v].[$os_arch].tarball // empty')"
  ZIG_SHA256="$(echo "$ZIG_INDEX_JSON" | jq -r --arg v "$ZIG_VER" --arg os_arch "$OS_ARCH" '.[$v].[$os_arch].shasum // empty')"
  if [[ -z "${ZIG_URL}" ]]; then
    ZIG_URL="https://ziglang.org/download/${ZIG_VER}/zig-${ZIG_OS}-${ZIG_ARCH}-${ZIG_VER}.tar.xz"
  fi
  ZIG_FILE="${INSTALL_PREFIX}/tmp/${ZIG_URL##*/}"
  log "Installing Zig ${ZIG_VER} for ${ZIG_ARCH}"
  log "Downloading $(basename "${ZIG_FILE}")..."
  if [[ "$DOWNLOADER" == "wget" ]]; then
    wget --show-progress -q -O "${ZIG_FILE}" "${ZIG_URL}" || error "Download failed"
  else
    curl -fL# -o "${ZIG_FILE}" "${ZIG_URL}" || error "Download failed"
  fi

  if [[ -n "${ZIG_SHA256}" ]]; then
    log "Verifying checksum..."
    echo "${ZIG_SHA256}  ${ZIG_FILE}" | $SHA256_CMD -c - >/dev/null 2>&1 || error "Checksum verification failed"
    success "Checksum verified"
  else
    warn "No checksum available for this version"
  fi

  TARGET_DIR="${INSTALL_PREFIX}/zig-${ZIG_VER}"
  log "Extracting to ${TARGET_DIR}..."
  rm -rf "${TARGET_DIR}"
  mkdir -p "${TARGET_DIR}"

  # Extract based on archive format
  if file "${ZIG_FILE}" | grep -qi 'XZ compressed'; then
    tar -C "${TARGET_DIR}" --strip-components=1 -xJf "${ZIG_FILE}" || error "Failed to extract Zig"
  elif file "${ZIG_FILE}" | grep -qi 'gzip compressed'; then
    tar -C "${TARGET_DIR}" --strip-components=1 -xzf "${ZIG_FILE}" || error "Failed to extract Zig"
  else
    error "Unknown Zig archive format: ${ZIG_FILE}"
  fi

  ln -sfn "${TARGET_DIR}/zig" "${BIN_DIR}/zig" || error "Failed to create symlink for zig"

  if ! printf '%s' "$PATH" | grep -q -F "${BIN_DIR}"; then
    SHELLRC="${HOME}/.bashrc"; [[ "$SHELL" == */zsh ]] && SHELLRC="${HOME}/.zshrc"
    if ! grep -q -F "export PATH=\"${BIN_DIR}:\$PATH\"" "${SHELLRC}" &>/dev/null; then
        echo "" >> "${SHELLRC}"
        echo "# Added by install-zig-and-zls.sh" >> "${SHELLRC}"
        echo "export PATH=\"${BIN_DIR}:\$PATH\"" >> "${SHELLRC}"
        success "Added ${BIN_DIR} to PATH in ${SHELLRC}"
    fi
  fi

  success "Zig $("${BIN_DIR}/zig" version) installed"
  log "Symlink: ${BIN_DIR}/zig -> ${TARGET_DIR}/zig"
else
  log "Using existing Zig installation"
fi

# ---- ZLS (optional) ----
SKIP_ZLS=0
if [[ "${INSTALL_ZLS}" -eq 1 ]]; then
  ZLS_TAG=""
  ZLS_JSON=""

  if [[ "${ZLS_VER_SPEC}" == "auto" ]]; then
    log "Fetching ZLS version compatible with Zig ${ZIG_VER}..."
    ZLS_JSON="$(curl -fsSL "https://releases.zigtools.org/v1/zls/select-version?zig_version=${ZIG_VER}&compatibility=only-runtime")"
    ZLS_TAG="$(echo "$ZLS_JSON" | jq -r '.version // empty')"
    [[ -z "${ZLS_TAG}" ]] && error "Could not find ZLS version compatible with Zig ${ZIG_VER}"
  elif [[ "${ZLS_VER_SPEC}" == "latest" ]]; then
    log "Fetching latest ZLS version..."
    ZLS_JSON="$(curl -fsSL "https://releases.zigtools.org/v1/zls/select-version?zig_version=${ZIG_VER}&compatibility=only-runtime")"
    ZLS_TAG="$(echo "$ZLS_JSON" | jq -r '.version // empty')"
    [[ -z "${ZLS_TAG}" ]] && error "Could not fetch latest ZLS version"
  else
    ZLS_TAG="${ZLS_VER_SPEC}"
    log "Using specified ZLS version ${ZLS_TAG}..."
    ZLS_JSON="$(curl -fsSL "https://releases.zigtools.org/v1/zls/select-version?zig_version=${ZLS_TAG}&compatibility=only-runtime")"
  fi

  if command -v zls >/dev/null 2>&1; then
    EXISTING_VER="$(zls --version 2>/dev/null | cut -d' ' -f2 || echo '')"
    if [[ "${EXISTING_VER}" == "${ZLS_TAG}" ]]; then
      EXISTING_PATH="$(command -v zls)"
      log "ZLS ${ZLS_TAG} already installed at ${EXISTING_PATH}"
      if [[ "${AUTO_YES}" -eq 0 ]]; then
        read -p "Reinstall? [y/N] " -r REPLY
        [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping ZLS installation"; SKIP_ZLS=1; }
      else
        log "Auto-confirming reinstall (--yes flag)"
      fi
    else
      log "Found ZLS ${EXISTING_VER}, will install ${ZLS_TAG}"
    fi
  fi
fi

# ---- Install ZLS ----
if [[ "${INSTALL_ZLS}" -eq 1 && "${SKIP_ZLS}" -eq 0 ]]; then
  log "Installing ZLS ${ZLS_TAG}"

  OS_ARCH="${ZIG_ARCH}-${ZIG_OS}"
  ZLS_TARBALL="$(echo "$ZLS_JSON" | jq -r --arg arch "$OS_ARCH" '.[$arch].tarball // empty')"
  ZLS_SHA256="$(echo "$ZLS_JSON" | jq -r --arg arch "$OS_ARCH" '.[$arch].shasum // empty')"

  [[ -z "${ZLS_TARBALL}" ]] && error "Could not find ZLS tarball for ${OS_ARCH}"

  ZLS_FILE="${INSTALL_PREFIX}/tmp/${ZLS_TARBALL##*/}"
  log "Downloading $(basename "${ZLS_FILE}")..."
  if [[ "$DOWNLOADER" == "wget" ]]; then
    wget --show-progress -q -O "${ZLS_FILE}" "${ZLS_TARBALL}" || error "Download failed"
  else
    curl -fL# -o "${ZLS_FILE}" "${ZLS_TARBALL}" || error "Download failed"
  fi

  if [[ -n "${ZLS_SHA256}" ]]; then
    log "Verifying checksum..."
    echo "${ZLS_SHA256}  ${ZLS_FILE}" | $SHA256_CMD -c - >/dev/null 2>&1 || error "Checksum verification failed"
    success "Checksum verified"
  fi

  ZLS_DIR="${INSTALL_PREFIX}/zls-${ZLS_TAG}"
  rm -rf "${ZLS_DIR}"
  mkdir -p "${ZLS_DIR}"

  if file "${ZLS_FILE}" | grep -qi 'XZ compressed'; then
    tar -C "${ZLS_DIR}" -xJf "${ZLS_FILE}" || error "Failed to extract ZLS tarball"
  elif file "${ZLS_FILE}" | grep -qi 'Zip archive'; then
    need unzip
    unzip -q "${ZLS_FILE}" -d "${ZLS_DIR}" || error "Failed to extract ZLS zip"
  else
    error "Unknown ZLS archive format: ${ZLS_FILE}"
  fi

  # Find ZLS binary (macOS find doesn't support -executable)
  if [[ "$ZIG_OS" == "macos" ]]; then
    ZLS_BIN="$(find "${ZLS_DIR}" -type f -name zls -perm +111 | head -n1 || true)"
  else
    ZLS_BIN="$(find "${ZLS_DIR}" -type f -name zls -executable | head -n1 || true)"
  fi
  [[ -z "${ZLS_BIN}" ]] && error "ZLS binary not found after extraction"
  ln -sfn "${ZLS_BIN}" "${BIN_DIR}/zls" || error "Failed to create symlink for zls"
  success "ZLS $("${BIN_DIR}/zls" --version 2>/dev/null || echo 'installed') installed"
elif [[ "${INSTALL_ZLS}" -eq 1 && "${SKIP_ZLS}" -eq 1 ]]; then
    log "Using existing ZLS installation"
else
  warn "Skipping ZLS installation"
fi

# ---- Summary ----
echo ""
success "Installation complete!"
if command -v "${BIN_DIR}/zig" >/dev/null 2>&1; then
  log "Zig: $("${BIN_DIR}/zig" version)"
fi
if [[ "${INSTALL_ZLS}" -eq 1 ]] && command -v "${BIN_DIR}/zls" >/dev/null 2>&1; then
  log "ZLS: $("${BIN_DIR}/zls" --version 2>/dev/null || echo 'installed')"
fi
log "Tip: To switch versions later, use: ln -sfn ${INSTALL_PREFIX}/zig-<ver>/zig ${BIN_DIR}/zig"
