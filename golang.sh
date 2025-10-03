#!/usr/bin/env bash
# golang.sh
# Linux (x86_64/aarch64): install Go (latest or pinned) and gopls (matching or pinned)
# Per-user, no sudo: installs under ~/.local by default and updates ~/.local/bin/{go,gofmt,...}
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
success() { echo -e "${GREEN}${NC} $1"; }

# ---- defaults / CLI ----
GO_VER_SPEC="latest"      # e.g. "latest" or "1.25.1"
GOPLS_VER_SPEC="auto"     # "auto"=latest; or specific like "v0.20.0"
INSTALL_PREFIX="${HOME}/.local"
BIN_DIR="${HOME}/.local/bin"
INSTALL_GOPLS=1
AUTO_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --go)         GO_VER_SPEC="${2:?}"; shift 2 ;;
    --gopls)      GOPLS_VER_SPEC="${2:?}"; shift 2 ;;
    --skip-gopls) INSTALL_GOPLS=0; shift ;;
    --prefix)     INSTALL_PREFIX="${2:?}"; shift 2 ;;
    --bindir)     BIN_DIR="${2:?}"; shift 2 ;;
    -y|--yes)     AUTO_YES=1; shift ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--go <version|latest>] [--gopls <auto|latest|version>] [--skip-gopls]
          [--prefix <dir>] [--bindir <dir>] [-y|--yes]

Options:
  -y, --yes    Auto-confirm all prompts (for scripting)

Examples:
  $0
  $0 --go 1.25.1
  $0 --go 1.25.1 --gopls v0.20.0
  $0 --skip-gopls
  $0 --yes

Environment Variables:
  GITHUB_TOKEN  A GitHub Personal Access Token to increase API rate limits.
USAGE
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"; }
for c in tar uname jq; do need "$c"; done

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

# Prepare auth header for GitHub API calls
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  log "Using GITHUB_TOKEN for authenticated API requests"
  AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  GO_ARCH="amd64" ;;
  aarch64|arm64) GO_ARCH="arm64" ;;
  i686|i386) GO_ARCH="386" ;;
  armv6l)  GO_ARCH="armv6l" ;;
  *) echo "Unsupported arch: ${ARCH} (supported: x86_64, aarch64, arm64, i686, armv6l)" >&2; exit 1 ;;
esac

# Detect OS
OS="$(uname -s)"
case "$OS" in
  Linux)  GO_OS="linux" ;;
  Darwin) GO_OS="darwin" ;;
  *) echo "Unsupported OS: ${OS} (supported: Linux, macOS)" >&2; exit 1 ;;
esac

# ---- resolve Go version ----
if [[ "$GO_VER_SPEC" == "latest" ]]; then
  log "Fetching latest Go version..."
  GO_INDEX_JSON="$(curl -fsSL 'https://go.dev/dl/?mode=json')"
  GO_VER="$(echo "$GO_INDEX_JSON" | jq -r '[.[] | select(.stable == true)][0].version' | sed 's/^go//')"
  [[ -z "${GO_VER}" ]] && error "Could not determine latest stable Go version"
else
  GO_VER="$GO_VER_SPEC"
fi

# Ensure GO_VER doesn't have 'go' prefix
GO_VER="${GO_VER#go}"

# ---- Check for existing Go ----
SKIP_GO=0
if command -v go >/dev/null 2>&1; then
  EXISTING_VER="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || echo '')"
  if [[ "${EXISTING_VER}" == "${GO_VER}" ]]; then
    EXISTING_PATH="$(command -v go)"
    log "Go ${GO_VER} already installed at ${EXISTING_PATH}"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping Go installation"; SKIP_GO=1; }
    else
      log "Auto-confirming reinstall (--yes flag)"
    fi
  else
    log "Found Go ${EXISTING_VER}, will install ${GO_VER}"
  fi
fi

# ---- Install Go ----
if [[ "${SKIP_GO}" -eq 0 ]]; then
  if [[ -z "${GO_INDEX_JSON:-}" ]]; then
    GO_INDEX_JSON="$(curl -fsSL 'https://go.dev/dl/?mode=json')"
  fi

  # Find the release for our version
  GO_RELEASE="$(echo "$GO_INDEX_JSON" | jq -r --arg v "go${GO_VER}" '.[] | select(.version == $v)')"
  [[ -z "${GO_RELEASE}" ]] && error "Could not find Go version ${GO_VER}"

  # Find the file for our OS/arch
  GO_FILE_INFO="$(echo "$GO_RELEASE" | jq -r --arg os "$GO_OS" --arg arch "$GO_ARCH" \
    '.files[] | select(.os == $os and .arch == $arch and .kind == "archive")')"
  [[ -z "${GO_FILE_INFO}" ]] && error "Could not find Go ${GO_VER} for ${GO_OS}-${GO_ARCH}"

  GO_FILENAME="$(echo "$GO_FILE_INFO" | jq -r '.filename')"
  GO_SHA256="$(echo "$GO_FILE_INFO" | jq -r '.sha256')"
  GO_URL="https://go.dev/dl/${GO_FILENAME}"
  GO_FILE="${INSTALL_PREFIX}/tmp/${GO_FILENAME}"

  log "Installing Go ${GO_VER} for ${GO_ARCH}"
  log "Downloading ${GO_FILENAME}..."
  if [[ "$DOWNLOADER" == "wget" ]]; then
    wget --show-progress -q -O "${GO_FILE}" "${GO_URL}" || error "Download failed"
  else
    curl -fL# -o "${GO_FILE}" "${GO_URL}" || error "Download failed"
  fi

  if [[ -n "${GO_SHA256}" ]]; then
    log "Verifying checksum..."
    echo "${GO_SHA256}  ${GO_FILE}" | $SHA256_CMD -c - >/dev/null 2>&1 || error "Checksum verification failed"
    success "Checksum verified"
  else
    warn "No checksum available for this version"
  fi

  TARGET_DIR="${INSTALL_PREFIX}/go-${GO_VER}"
  log "Extracting to ${TARGET_DIR}..."
  rm -rf "${TARGET_DIR}"
  mkdir -p "${TARGET_DIR}"
  tar -C "${TARGET_DIR}" --strip-components=1 -xzf "${GO_FILE}" || error "Failed to extract Go"

  # Symlink all binaries from go/bin/
  log "Creating symlinks for Go binaries..."
  for binary in "${TARGET_DIR}/bin/"*; do
    if [[ -f "$binary" && -x "$binary" ]]; then
      binary_name="$(basename "$binary")"
      ln -sfn "$binary" "${BIN_DIR}/${binary_name}" || error "Failed to create symlink for ${binary_name}"
    fi
  done

  if ! printf '%s' "$PATH" | grep -q -F "${BIN_DIR}"; then
    SHELLRC="${HOME}/.bashrc"; [[ "$SHELL" == */zsh ]] && SHELLRC="${HOME}/.zshrc"
    if ! grep -q -F "export PATH=\"${BIN_DIR}:\$PATH\"" "${SHELLRC}" &>/dev/null; then
        echo "" >> "${SHELLRC}"
        echo "# Added by golang.sh" >> "${SHELLRC}"
        echo "export PATH=\"${BIN_DIR}:\$PATH\"" >> "${SHELLRC}"
        success "Added ${BIN_DIR} to PATH in ${SHELLRC}"
    fi
  fi

  success "Go $("${BIN_DIR}/go" version | awk '{print $3}') installed"
  log "Symlink: ${BIN_DIR}/go -> ${TARGET_DIR}/bin/go"
else
  log "Using existing Go installation"
fi

# ---- gopls (optional) ----
SKIP_GOPLS=0
GOPLS_TAG=""

if [[ "${INSTALL_GOPLS}" -eq 1 ]]; then
  if [[ "${GOPLS_VER_SPEC}" == "auto" || "${GOPLS_VER_SPEC}" == "latest" ]]; then
    log "Fetching latest gopls version..."
    if [[ -n "${AUTH_HEADER[@]:-}" ]]; then
      GOPLS_JSON="$(curl -fsSL "${AUTH_HEADER[@]}" 'https://api.github.com/repos/golang/tools/releases')"
    else
      GOPLS_JSON="$(curl -fsSL 'https://api.github.com/repos/golang/tools/releases')"
    fi
    GOPLS_TAG="$(echo "$GOPLS_JSON" | jq -r '[.[] | select(.tag_name | startswith("gopls/"))][0].tag_name')"
    [[ -z "${GOPLS_TAG}" ]] && error "Could not find latest gopls version"
  else
    GOPLS_TAG="${GOPLS_VER_SPEC}"
    # Ensure it has gopls/ prefix
    [[ ! "${GOPLS_TAG}" =~ ^gopls/ ]] && GOPLS_TAG="gopls/${GOPLS_TAG}"
  fi

  # Check existing gopls
  if command -v gopls >/dev/null 2>&1; then
    EXISTING_GOPLS_VER="$(gopls version 2>/dev/null | head -n1 | awk '{print $2}' || echo '')"
    GOPLS_TAG_CLEAN="${GOPLS_TAG#gopls/}"
    if [[ "${EXISTING_GOPLS_VER}" == "${GOPLS_TAG_CLEAN}" || "${EXISTING_GOPLS_VER}" == "${GOPLS_TAG}" ]]; then
      EXISTING_PATH="$(command -v gopls)"
      log "gopls ${GOPLS_TAG_CLEAN} already installed at ${EXISTING_PATH}"
      if [[ "${AUTO_YES}" -eq 0 ]]; then
        read -p "Reinstall? [y/N] " -r REPLY
        [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping gopls installation"; SKIP_GOPLS=1; }
      else
        log "Auto-confirming reinstall (--yes flag)"
      fi
    else
      log "Found gopls ${EXISTING_GOPLS_VER}, will install ${GOPLS_TAG_CLEAN}"
    fi
  fi
fi

# ---- Install gopls ----
if [[ "${INSTALL_GOPLS}" -eq 1 && "${SKIP_GOPLS}" -eq 0 ]]; then
  GOPLS_TAG_CLEAN="${GOPLS_TAG#gopls/}"
  log "Installing gopls ${GOPLS_TAG_CLEAN} using Go..."

  # Use the installed Go binary
  GO_BIN="${BIN_DIR}/go"
  [[ ! -x "${GO_BIN}" ]] && error "Go binary not found at ${GO_BIN}"

  # Install gopls
  GOBIN="${BIN_DIR}" "${GO_BIN}" install "golang.org/x/tools/gopls@${GOPLS_TAG_CLEAN}" || error "Failed to install gopls"

  success "gopls $("${BIN_DIR}/gopls" version 2>/dev/null | head -n1 | awk '{print $2}' || echo 'installed') installed"
elif [[ "${INSTALL_GOPLS}" -eq 1 && "${SKIP_GOPLS}" -eq 1 ]]; then
    log "Using existing gopls installation"
else
  warn "Skipping gopls installation"
fi

# ---- Summary ----
echo ""
success "Installation complete!"
if command -v "${BIN_DIR}/go" >/dev/null 2>&1; then
  log "Go: $("${BIN_DIR}/go" version | awk '{print $3}')"
fi
if [[ "${INSTALL_GOPLS}" -eq 1 ]] && command -v "${BIN_DIR}/gopls" >/dev/null 2>&1; then
  log "gopls: $("${BIN_DIR}/gopls" version 2>/dev/null | head -n1 | awk '{print $2}' || echo 'installed')"
fi
log "Tip: To switch versions later, run this script again with --go <version>"
