#!/usr/bin/env bash
# gadgets.sh
# Install CLI utilities system-wide (default: /usr/local/bin)
# Supports: uv, flyctl, zoxide, ast-grep, curlie, duf, fzf, hexyl, jq, yq, ripgrep, ruff
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

# ---- Defaults ----
BIN_DIR="/usr/local/bin"
INSTALL_PREFIX="/usr/local/lib/gadgets"
TMP_DIR="/tmp/gadgets-install-$$"
COMP_DIR_BASH="/usr/local/share/bash-completion/completions"
COMP_DIR_ZSH="/usr/local/share/zsh/site-functions"
COMP_DIR_FISH="/usr/local/share/fish/vendor_completions.d"
AUTO_YES=0
INSTALLED_THIS_RUN=()

# Tool flags (1 = install, 0 = skip)
INSTALL_JQ=1
INSTALL_UV=1
INSTALL_FLYCTL=1
INSTALL_ZOXIDE=1
INSTALL_ASTGREP=1
INSTALL_CURLIE=1
INSTALL_DOGGO=1
INSTALL_DUF=1
INSTALL_FZF=1
INSTALL_HEXYL=1
INSTALL_YQ=1
INSTALL_RIPGREP=1
INSTALL_RUFF=1

# Track if only-mode is active
ONLY_MODE=0

# ---- CLI Argument Parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only-jq)       ONLY_MODE=1; shift ;;
    --skip-jq)       INSTALL_JQ=0; shift ;;
    --skip-uv)       INSTALL_UV=0; shift ;;
    --skip-flyctl)   INSTALL_FLYCTL=0; shift ;;
    --skip-zoxide)   INSTALL_ZOXIDE=0; shift ;;
    --skip-ast-grep) INSTALL_ASTGREP=0; shift ;;
    --skip-curlie)   INSTALL_CURLIE=0; shift ;;
    --skip-doggo)    INSTALL_DOGGO=0; shift ;;
    --skip-duf)      INSTALL_DUF=0; shift ;;
    --skip-fzf)      INSTALL_FZF=0; shift ;;
    --skip-hexyl)    INSTALL_HEXYL=0; shift ;;
    --skip-yq)       INSTALL_YQ=0; shift ;;
    --skip-ripgrep)  INSTALL_RIPGREP=0; shift ;;
    --skip-ruff)     INSTALL_RUFF=0; shift ;;
    --prefix)        INSTALL_PREFIX="${2:?}"; shift 2 ;;
    --bindir)        BIN_DIR="${2:?}"; shift 2 ;;
    -y|--yes)        AUTO_YES=1; shift ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [OPTIONS]

Install CLI utilities system-wide (default: /usr/local/bin)

Options:
  --only-jq         Install only jq (useful for bootstrapping)
  --skip-{tool}     Skip installation of specific tool
                    Tools: jq, uv, flyctl, zoxide, ast-grep, curlie, doggo,
                           duf, fzf, hexyl, yq, ripgrep, ruff
  --prefix <dir>    Install prefix (default: /usr/local/lib/gadgets)
  --bindir <dir>    Binary directory (default: /usr/local/bin)
  -y, --yes         Auto-confirm all prompts
  -h, --help        Show this help

Examples:
  $0                           # Install all tools to /usr/local/bin
  $0 --only-jq                 # Install only jq (bootstrap dependency)
  $0 --skip-ruff --skip-hexyl  # Skip specific tools
  $0 --bindir ~/.local/bin     # Install to user directory (no sudo)
  $0 --yes                     # Auto-confirm all prompts

Environment Variables:
  GITHUB_TOKEN  GitHub Personal Access Token (increases API rate limits)
USAGE
      exit 0
      ;;
    *) error "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# If --only-jq mode, disable all other tools
if [[ "${ONLY_MODE}" -eq 1 ]]; then
  INSTALL_UV=0
  INSTALL_FLYCTL=0
  INSTALL_ZOXIDE=0
  INSTALL_ASTGREP=0
  INSTALL_CURLIE=0
  INSTALL_DOGGO=0
  INSTALL_DUF=0
  INSTALL_FZF=0
  INSTALL_HEXYL=0
  INSTALL_YQ=0
  INSTALL_RIPGREP=0
  INSTALL_RUFF=0
fi

# ---- Cleanup on exit ----
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

# ---- Dependency Checks ----
need() { command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"; }
for cmd in tar uname file; do need "$cmd"; done

# Detect SHA256 tool (macOS uses shasum, Linux uses sha256sum)
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  error "Neither sha256sum nor shasum found. Please install one."
fi

# Detect download tool
if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  error "Neither curl nor wget found. Please install one."
fi

# ---- Setup directories ----
mkdir -p "${TMP_DIR}"

# Determine if sudo is needed
SUDO=""
if [[ "$BIN_DIR" == /usr/* ]] || [[ "$BIN_DIR" == /opt/* ]]; then
  if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
    log "System-wide installation requires sudo"
  fi
fi

$SUDO mkdir -p "${BIN_DIR}" "${INSTALL_PREFIX}"

# ---- GitHub Auth Header ----
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  log "Using GITHUB_TOKEN for authenticated API requests"
  AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

# ---- OS/Architecture Detection ----
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)  OS_TYPE="linux" ;;
  Darwin) OS_TYPE="darwin" ;;
  *) error "Unsupported OS: ${OS}" ;;
esac

case "$ARCH" in
  x86_64)  ARCH_TYPE="x86_64" ;;
  aarch64) ARCH_TYPE="aarch64" ;;
  arm64)   ARCH_TYPE="arm64" ;;
  *) error "Unsupported architecture: ${ARCH}" ;;
esac

log "Detected: ${OS_TYPE}/${ARCH_TYPE}"

# Bootstrap jq (needed for parsing GitHub API responses)
bootstrap_jq() {
  if [[ "${INSTALL_JQ}" -eq 0 ]]; then
    warn "Skipping jq installation (--skip-jq specified)"
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local existing_ver="$(jq --version 2>/dev/null || echo 'unknown')"
    log "jq already installed: ${existing_ver} ($(command -v jq))"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall jq? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping jq installation"; return 0; }
    fi
  fi

  log "Installing jq..."

  local jq_binary
  case "${OS_TYPE}-${ARCH_TYPE}" in
    linux-x86_64)   jq_binary="jq-linux-amd64" ;;
    linux-aarch64)  jq_binary="jq-linux-arm64" ;;
    darwin-x86_64)  jq_binary="jq-macos-amd64" ;;
    darwin-arm64)   jq_binary="jq-macos-arm64" ;;
    *) error "Unsupported platform for jq: ${OS_TYPE}-${ARCH_TYPE}" ;;
  esac

  local jq_url="https://github.com/jqlang/jq/releases/latest/download/${jq_binary}"
  local jq_file="${TMP_DIR}/jq"

  log "Downloading ${jq_binary}..."
  if [[ "$DOWNLOADER" == "curl" ]]; then
    curl -fL# -o "${jq_file}" "${jq_url}" || error "Failed to download jq"
  else
    wget --show-progress -q -O "${jq_file}" "${jq_url}" || error "Failed to download jq"
  fi

  chmod +x "${jq_file}"
  $SUDO install -m 755 "${jq_file}" "${BIN_DIR}/jq" || error "Failed to install jq"

  INSTALLED_THIS_RUN+=("jq: $(jq --version)")
  success "jq installed: $(jq --version)"
}

# Generic GitHub binary installer
install_github_binary() {
  local repo="$1"
  local tool="$2"
  local asset_pattern="$3"
  local binary_name="${4:-$tool}"

  log "Fetching latest ${tool} release..."
  local release_json
  if [[ "$DOWNLOADER" == "curl" ]]; then
    release_json=$(curl -fsSL ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} "https://api.github.com/repos/${repo}/releases/latest")
  else
    release_json=$(wget ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} -qO- "https://api.github.com/repos/${repo}/releases/latest")
  fi

  local version=$(echo "$release_json" | jq -r '.tag_name // .name')
  local download_url=$(echo "$release_json" | jq -r ".assets[] | select(.name | test(\"${asset_pattern}\")) | .browser_download_url" | head -n1)

  [[ -z "$download_url" ]] && error "Could not find ${tool} asset matching: ${asset_pattern}"

  local filename="${download_url##*/}"
  local download_file="${TMP_DIR}/${filename}"

  log "Downloading ${tool} ${version}..."
  if [[ "$DOWNLOADER" == "curl" ]]; then
    curl -fL# -o "${download_file}" "${download_url}" || error "Download failed"
  else
    wget --show-progress -q -O "${download_file}" "${download_url}" || error "Download failed"
  fi

  # Extract based on file type
  local extract_dir="${TMP_DIR}/${tool}-extract"
  mkdir -p "${extract_dir}"

  if [[ "$filename" == *.tar.gz ]]; then
    tar -xzf "${download_file}" -C "${extract_dir}" || error "Extraction failed"
  elif [[ "$filename" == *.zip ]]; then
    unzip -q "${download_file}" -d "${extract_dir}" || error "Extraction failed"
  else
    # Single binary file
    cp "${download_file}" "${extract_dir}/${binary_name}" || error "Copy failed"
  fi

  # Find and install the binary (macOS find doesn't support -executable)
  local binary_path
  if [[ "$OS_TYPE" == "darwin" ]]; then
    binary_path=$(find "${extract_dir}" -type f -name "${binary_name}" -perm +111 2>/dev/null | head -n1)
  else
    binary_path=$(find "${extract_dir}" -type f -name "${binary_name}" -executable 2>/dev/null | head -n1)
  fi

  if [[ -z "$binary_path" ]]; then
    # Try without executable check (for files that aren't +x yet)
    binary_path=$(find "${extract_dir}" -type f -name "${binary_name}" 2>/dev/null | head -n1)
  fi

  [[ -z "$binary_path" ]] && error "Could not find ${binary_name} binary after extraction"

  chmod +x "${binary_path}"
  $SUDO install -m 755 "${binary_path}" "${BIN_DIR}/${binary_name}" || error "Failed to install ${tool}"

  INSTALLED_THIS_RUN+=("${tool}: ${version}")
  success "${tool} ${version} installed"
}

# Official installer: uv
install_uv() {
  [[ "${INSTALL_UV}" -eq 0 ]] && { warn "Skipping uv"; return 0; }

  if command -v uv >/dev/null 2>&1; then
    log "uv already installed: $(uv --version 2>/dev/null || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall uv? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping uv"; return 0; }
    fi
  fi

  log "Installing uv..."
  local install_script="${TMP_DIR}/uv-installer.sh"
  curl -fsSL https://astral.sh/uv/install.sh -o "${install_script}" || error "Failed to download uv installer"

  # Run installer with custom paths
  UV_INSTALL_DIR="${BIN_DIR%/*}" sh "${install_script}" || error "uv installation failed"

  # Move binary to correct location if needed
  if [[ -f "${HOME}/.local/bin/uv" ]] && [[ "${BIN_DIR}" != "${HOME}/.local/bin" ]]; then
    $SUDO mv "${HOME}/.local/bin/uv" "${BIN_DIR}/uv"
  fi

  INSTALLED_THIS_RUN+=("uv: $(uv --version)")
  success "uv installed: $(uv --version)"
}

# Official installer: flyctl
install_flyctl() {
  [[ "${INSTALL_FLYCTL}" -eq 0 ]] && { warn "Skipping flyctl"; return 0; }

  if command -v flyctl >/dev/null 2>&1; then
    log "flyctl already installed: $(flyctl version 2>/dev/null | head -n1 || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall flyctl? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping flyctl"; return 0; }
    fi
  fi

  log "Installing flyctl..."
  local install_script="${TMP_DIR}/flyctl-installer.sh"
  curl -fsSL https://fly.io/install.sh -o "${install_script}" || error "Failed to download flyctl installer"

  # Run installer (installs to ~/.fly by default)
  sh "${install_script}" || error "flyctl installation failed"

  # Move to system location
  if [[ -f "${HOME}/.fly/bin/flyctl" ]]; then
    $SUDO install -m 755 "${HOME}/.fly/bin/flyctl" "${BIN_DIR}/flyctl"
    [[ -f "${HOME}/.fly/bin/fly" ]] && $SUDO install -m 755 "${HOME}/.fly/bin/fly" "${BIN_DIR}/fly"
  fi

  INSTALLED_THIS_RUN+=("flyctl: $(flyctl version | head -n1)")
  success "flyctl installed: $(flyctl version | head -n1)"
}

# Official installer: zoxide
install_zoxide() {
  [[ "${INSTALL_ZOXIDE}" -eq 0 ]] && { warn "Skipping zoxide"; return 0; }

  if command -v zoxide >/dev/null 2>&1; then
    log "zoxide already installed: $(zoxide --version 2>/dev/null || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall zoxide? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping zoxide"; return 0; }
    fi
  fi

  log "Installing zoxide..."
  local install_script="${TMP_DIR}/zoxide-installer.sh"
  curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh -o "${install_script}" || error "Failed to download zoxide installer"

  # Run installer
  sh "${install_script}" || error "zoxide installation failed"

  # Move to system location if needed
  if [[ -f "${HOME}/.local/bin/zoxide" ]] && [[ "${BIN_DIR}" != "${HOME}/.local/bin" ]]; then
    $SUDO install -m 755 "${HOME}/.local/bin/zoxide" "${BIN_DIR}/zoxide"
  fi

  INSTALLED_THIS_RUN+=("zoxide: $(zoxide --version)")
  success "zoxide installed: $(zoxide --version)"
}

# Individual tool installers using install_github_binary
install_astgrep() {
  [[ "${INSTALL_ASTGREP}" -eq 0 ]] && { warn "Skipping ast-grep"; return 0; }

  if command -v sg >/dev/null 2>&1; then
    log "ast-grep already installed: $(sg --version 2>/dev/null | head -n1 || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall ast-grep? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping ast-grep"; return 0; }
    fi
  fi

  local pattern
  case "${OS_TYPE}-${ARCH_TYPE}" in
    linux-x86_64)   pattern="app-x86_64-unknown-linux-gnu\\\\.zip" ;;
    linux-aarch64)  pattern="app-aarch64-unknown-linux-gnu\\\\.zip" ;;
    darwin-x86_64)  pattern="app-x86_64-apple-darwin\\\\.zip" ;;
    darwin-arm64)   pattern="app-aarch64-apple-darwin\\\\.zip" ;;
    *) error "Unsupported platform for ast-grep: ${OS_TYPE}-${ARCH_TYPE}" ;;
  esac

  install_github_binary "ast-grep/ast-grep" "ast-grep" "$pattern" "sg"
}

install_curlie() {
  [[ "${INSTALL_CURLIE}" -eq 0 ]] && { warn "Skipping curlie"; return 0; }

  if command -v curlie >/dev/null 2>&1; then
    log "curlie already installed: $(curlie --version 2>/dev/null || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall curlie? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping curlie"; return 0; }
    fi
  fi

  local os_name="${OS_TYPE}"
  local arch_name="${ARCH_TYPE}"
  [[ "$arch_name" == "aarch64" ]] && arch_name="arm64"

  local pattern="curlie_.*_${os_name}_${arch_name}\\\\.tar\\\\.gz"
  install_github_binary "rs/curlie" "curlie" "$pattern"
}

install_doggo() {
  [[ "${INSTALL_DOGGO}" -eq 0 ]] && { warn "Skipping doggo"; return 0; }

  if command -v doggo >/dev/null 2>&1; then
    log "doggo already installed: $(doggo version 2>/dev/null || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall doggo? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping doggo"; return 0; }
    fi
  fi

  # Capitalize first letter for doggo naming (Darwin, Linux)
  local os_name
  case "${OS_TYPE}" in
    linux)  os_name="Linux" ;;
    darwin) os_name="Darwin" ;;
    *) error "Unsupported OS for doggo: ${OS_TYPE}" ;;
  esac
  local arch_name="${ARCH_TYPE}"

  local pattern="doggo_.*_${os_name}_${arch_name}\\\\.tar\\\\.gz"
  install_github_binary "mr-karan/doggo" "doggo" "$pattern"
}

install_duf() {
  [[ "${INSTALL_DUF}" -eq 0 ]] && { warn "Skipping duf"; return 0; }

  if command -v duf >/dev/null 2>&1; then
    log "duf already installed: $(duf --version 2>/dev/null | head -n1 || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall duf? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping duf"; return 0; }
    fi
  fi

  local os_name="${OS_TYPE}"
  local arch_name
  case "${ARCH_TYPE}" in
    x86_64)   arch_name="x86_64" ;;
    aarch64)  arch_name="arm64" ;;
    arm64)    arch_name="arm64" ;;
  esac

  local pattern="duf_.*_${os_name}_${arch_name}\\\\.tar\\\\.gz"
  install_github_binary "muesli/duf" "duf" "$pattern"
}

install_fzf() {
  [[ "${INSTALL_FZF}" -eq 0 ]] && { warn "Skipping fzf"; return 0; }

  if command -v fzf >/dev/null 2>&1; then
    log "fzf already installed: $(fzf --version 2>/dev/null || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall fzf? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping fzf"; return 0; }
    fi
  fi

  local os_name="${OS_TYPE}"
  local arch_name
  case "${ARCH_TYPE}" in
    x86_64)   arch_name="amd64" ;;
    aarch64)  arch_name="arm64" ;;
    arm64)    arch_name="arm64" ;;
  esac

  local pattern="fzf-.*-${os_name}_${arch_name}\\\\.tar\\\\.gz"
  install_github_binary "junegunn/fzf" "fzf" "$pattern"
}

install_hexyl() {
  [[ "${INSTALL_HEXYL}" -eq 0 ]] && { warn "Skipping hexyl"; return 0; }

  if command -v hexyl >/dev/null 2>&1; then
    log "hexyl already installed: $(hexyl --version 2>/dev/null | head -n1 || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall hexyl? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping hexyl"; return 0; }
    fi
  fi

  local pattern
  case "${OS_TYPE}-${ARCH_TYPE}" in
    linux-x86_64)   pattern="hexyl-v.*-x86_64-unknown-linux-musl\\\\.tar\\\\.gz" ;;
    linux-aarch64)  pattern="hexyl-v.*-aarch64-unknown-linux-musl\\\\.tar\\\\.gz" ;;
    darwin-x86_64)  pattern="hexyl-v.*-x86_64-apple-darwin\\\\.tar\\\\.gz" ;;
    darwin-arm64)   pattern="hexyl-v.*-aarch64-apple-darwin\\\\.tar\\\\.gz" ;;
    *) error "Unsupported platform for hexyl: ${OS_TYPE}-${ARCH_TYPE}" ;;
  esac

  install_github_binary "sharkdp/hexyl" "hexyl" "$pattern"
}

install_yq() {
  [[ "${INSTALL_YQ}" -eq 0 ]] && { warn "Skipping yq"; return 0; }

  if command -v yq >/dev/null 2>&1; then
    log "yq already installed: $(yq --version 2>/dev/null || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall yq? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping yq"; return 0; }
    fi
  fi

  local os_name="${OS_TYPE}"
  local arch_name
  case "${ARCH_TYPE}" in
    x86_64)   arch_name="amd64" ;;
    aarch64)  arch_name="arm64" ;;
    arm64)    arch_name="arm64" ;;
  esac

  # yq has simple single binary naming
  local pattern="yq_${os_name}_${arch_name}$"
  install_github_binary "mikefarah/yq" "yq" "$pattern"
}

install_ripgrep() {
  [[ "${INSTALL_RIPGREP}" -eq 0 ]] && { warn "Skipping ripgrep"; return 0; }

  if command -v rg >/dev/null 2>&1; then
    log "ripgrep already installed: $(rg --version 2>/dev/null | head -n1 || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall ripgrep? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping ripgrep"; return 0; }
    fi
  fi

  local pattern
  case "${OS_TYPE}-${ARCH_TYPE}" in
    linux-x86_64)   pattern="ripgrep-.*-x86_64-unknown-linux-musl\\\\.tar\\\\.gz" ;;
    linux-aarch64)  pattern="ripgrep-.*-aarch64-unknown-linux-gnu\\\\.tar\\\\.gz" ;;
    darwin-x86_64)  pattern="ripgrep-.*-x86_64-apple-darwin\\\\.tar\\\\.gz" ;;
    darwin-arm64)   pattern="ripgrep-.*-aarch64-apple-darwin\\\\.tar\\\\.gz" ;;
    *) error "Unsupported platform for ripgrep: ${OS_TYPE}-${ARCH_TYPE}" ;;
  esac

  install_github_binary "BurntSushi/ripgrep" "ripgrep" "$pattern" "rg"
}

# ruff (installed via uv)
install_ruff() {
  [[ "${INSTALL_RUFF}" -eq 0 ]] && { warn "Skipping ruff"; return 0; }

  if ! command -v uv >/dev/null 2>&1; then
    error "uv is required to install ruff. Install uv first or use --skip-ruff"
  fi

  if command -v ruff >/dev/null 2>&1; then
    log "ruff already installed: $(ruff --version 2>/dev/null || echo 'unknown')"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall ruff? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping ruff"; return 0; }
    fi
  fi

  log "Installing ruff via uv..."
  uv tool install ruff || error "Failed to install ruff"

  # Move to system location if needed
  local ruff_path="$(command -v ruff 2>/dev/null || echo '')"
  if [[ -n "$ruff_path" ]] && [[ "$ruff_path" != "${BIN_DIR}/ruff" ]]; then
    $SUDO install -m 755 "$ruff_path" "${BIN_DIR}/ruff"
  fi

  INSTALLED_THIS_RUN+=("ruff: $(ruff --version)")
  success "ruff installed: $(ruff --version)"
}

# Shell completion setup
setup_completions() {
  log "Setting up shell completions..."

  # Detect available shells
  local shells=()
  [[ -f ~/.bashrc ]] && shells+=("bash")
  [[ -f ~/.zshrc ]] && shells+=("zsh")
  [[ -f ~/.config/fish/config.fish ]] && shells+=("fish")

  [[ ${#shells[@]} -eq 0 ]] && { warn "No supported shell rc files found"; return 0; }

  for shell in "${shells[@]}"; do
    setup_shell_completions "$shell"
  done
}

setup_shell_completions() {
  local shell=$1
  local comp_dir

  case "$shell" in
    bash) comp_dir="$COMP_DIR_BASH" ;;
    zsh)  comp_dir="$COMP_DIR_ZSH" ;;
    fish) comp_dir="$COMP_DIR_FISH" ;;
    *) return 0 ;;
  esac

  $SUDO mkdir -p "$comp_dir" || { warn "Failed to create completion dir: $comp_dir"; return 0; }

  log "Generating $shell completions..."

  # uv + uvx
  if command -v uv >/dev/null 2>&1; then
    case "$shell" in
      bash) uv generate-shell-completion bash | $SUDO tee "$comp_dir/uv.bash" >/dev/null ;;
      zsh)  uv generate-shell-completion zsh | $SUDO tee "$comp_dir/_uv" >/dev/null ;;
      fish) uv generate-shell-completion fish | $SUDO tee "$comp_dir/uv.fish" >/dev/null ;;
    esac
  fi

  # flyctl
  if command -v flyctl >/dev/null 2>&1; then
    case "$shell" in
      bash) flyctl completion bash | $SUDO tee "$comp_dir/flyctl.bash" >/dev/null 2>&1 || true ;;
      zsh)  flyctl completion zsh | $SUDO tee "$comp_dir/_flyctl" >/dev/null 2>&1 || true ;;
      fish) flyctl completion fish | $SUDO tee "$comp_dir/flyctl.fish" >/dev/null 2>&1 || true ;;
    esac
  fi

  # zoxide (special: init includes completions)
  if command -v zoxide >/dev/null 2>&1; then
    local rc_file
    case "$shell" in
      bash) rc_file=~/.bashrc ;;
      zsh)  rc_file=~/.zshrc ;;
      fish) rc_file=~/.config/fish/config.fish ;;
    esac

    if [[ -f "$rc_file" ]] && ! grep -q "zoxide init" "$rc_file" 2>/dev/null; then
      case "$shell" in
        bash|zsh)
          echo "" >> "$rc_file"
          echo "# zoxide init" >> "$rc_file"
          echo "eval \"\$(zoxide init $shell)\"" >> "$rc_file"
          ;;
        fish)
          echo "" >> "$rc_file"
          echo "# zoxide init" >> "$rc_file"
          echo "zoxide init fish | source" >> "$rc_file"
          ;;
      esac
      success "Added zoxide init to $rc_file"
    fi
  fi

  # fzf
  if command -v fzf >/dev/null 2>&1; then
    case "$shell" in
      bash) fzf --bash 2>/dev/null | $SUDO tee "$comp_dir/fzf.bash" >/dev/null || true ;;
      zsh)  fzf --zsh 2>/dev/null | $SUDO tee "$comp_dir/fzf.zsh" >/dev/null || true ;;
      fish) fzf --fish 2>/dev/null | $SUDO tee "$comp_dir/fzf.fish" >/dev/null || true ;;
    esac
  fi

  # ast-grep
  if command -v sg >/dev/null 2>&1; then
    case "$shell" in
      bash) sg completions bash 2>/dev/null | $SUDO tee "$comp_dir/sg.bash" >/dev/null || true ;;
      zsh)  sg completions zsh 2>/dev/null | $SUDO tee "$comp_dir/_sg" >/dev/null || true ;;
      fish) sg completions fish 2>/dev/null | $SUDO tee "$comp_dir/sg.fish" >/dev/null || true ;;
    esac
  fi

  # ripgrep
  if command -v rg >/dev/null 2>&1; then
    case "$shell" in
      bash) rg --generate complete-bash 2>/dev/null | $SUDO tee "$comp_dir/rg.bash" >/dev/null || true ;;
      zsh)  rg --generate complete-zsh 2>/dev/null | $SUDO tee "$comp_dir/_rg" >/dev/null || true ;;
      fish) rg --generate complete-fish 2>/dev/null | $SUDO tee "$comp_dir/rg.fish" >/dev/null || true ;;
    esac
  fi

  # yq
  if command -v yq >/dev/null 2>&1; then
    case "$shell" in
      bash) yq shell-completion bash 2>/dev/null | $SUDO tee "$comp_dir/yq.bash" >/dev/null || true ;;
      zsh)  yq shell-completion zsh 2>/dev/null | $SUDO tee "$comp_dir/_yq" >/dev/null || true ;;
      fish) yq shell-completion fish 2>/dev/null | $SUDO tee "$comp_dir/yq.fish" >/dev/null || true ;;
    esac
  fi

  # ruff
  if command -v ruff >/dev/null 2>&1; then
    case "$shell" in
      bash) ruff generate-shell-completion bash 2>/dev/null | $SUDO tee "$comp_dir/ruff.bash" >/dev/null || true ;;
      zsh)  ruff generate-shell-completion zsh 2>/dev/null | $SUDO tee "$comp_dir/_ruff" >/dev/null || true ;;
      fish) ruff generate-shell-completion fish 2>/dev/null | $SUDO tee "$comp_dir/ruff.fish" >/dev/null || true ;;
    esac
  fi

  success "Completions for $shell generated"
}

# Main execution
main() {
  log "Starting gadgets installation..."
  echo ""

  # Phase 0: Bootstrap jq
  bootstrap_jq
  echo ""

  # Phase 1: Official installers
  install_uv
  install_flyctl
  install_zoxide
  echo ""

  # Phase 2: GitHub binary downloads
  install_astgrep
  install_curlie
  install_doggo
  install_duf
  install_fzf
  install_hexyl
  install_yq
  install_ripgrep
  echo ""

  # Phase 3: Via uv
  install_ruff
  echo ""

  # Phase 4: Shell completions
  setup_completions
  echo ""

  # Summary
  echo ""
  success "Installation complete!"

  if [[ ${#INSTALLED_THIS_RUN[@]} -eq 0 ]]; then
    log "No new tools installed (all were skipped or already present)"
  else
    log "Tools installed this run:"
    for tool in "${INSTALLED_THIS_RUN[@]}"; do
      echo "  • $tool"
    done
  fi

  echo ""
  log "Binary directory: ${BIN_DIR}"
  log "To use these tools, ensure ${BIN_DIR} is in your PATH"

  if ! printf '%s' "$PATH" | grep -q -F "${BIN_DIR}"; then
    warn "${BIN_DIR} is not in your PATH!"
    log "Add this to your shell rc file:"
    log "  export PATH=\"${BIN_DIR}:\$PATH\""
  fi
}

main "$@"
