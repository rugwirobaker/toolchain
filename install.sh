#!/bin/sh
# install.sh
# Master orchestrator for toolchain installation
# Usage:
#   curl -fsSL https://toolchain.acodechef.dev/install.sh | sh
#   curl -fsSL https://toolchain.acodechef.dev/install.sh | sh -s -- --yes
#   curl -fsSL https://toolchain.acodechef.dev/install.sh | sh -s -- --only-rust --only-go
set -e
set -u

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; exit 1; }
success() { printf "${GREEN}✓${NC} %s\n" "$1"; }

# ---- Configuration ----
TOOLCHAIN_DIR="${HOME}/.toolchain"
BASE_URL="https://toolchain.acodechef.dev"
AUTO_YES=0

# Tool flags (1 = install, 0 = skip)
INSTALL_ZIG=1
INSTALL_RUST=1
INSTALL_GOLANG=1
INSTALL_BUN=1
INSTALL_GADGETS=1

# Track which tools to install (space-separated strings for POSIX compatibility)
REQUESTED_TOOLS=""
GADGETS_ARGS=""

# ---- CLI Argument Parsing ----
while [ $# -gt 0 ]; do
  case "$1" in
    --only-zig)     REQUESTED_TOOLS="${REQUESTED_TOOLS} zig"; shift ;;
    --only-rust)    REQUESTED_TOOLS="${REQUESTED_TOOLS} rust"; shift ;;
    --only-golang)  REQUESTED_TOOLS="${REQUESTED_TOOLS} golang"; shift ;;
    --only-go)      REQUESTED_TOOLS="${REQUESTED_TOOLS} golang"; shift ;;
    --only-bun)     REQUESTED_TOOLS="${REQUESTED_TOOLS} bun"; shift ;;
    --only-gadgets) REQUESTED_TOOLS="${REQUESTED_TOOLS} gadgets"; shift ;;
    --only-jq)      REQUESTED_TOOLS="${REQUESTED_TOOLS} gadgets"; GADGETS_ARGS="${GADGETS_ARGS} --only-jq"; shift ;;
    --skip-zig)     INSTALL_ZIG=0; shift ;;
    --skip-rust)    INSTALL_RUST=0; shift ;;
    --skip-golang)  INSTALL_GOLANG=0; shift ;;
    --skip-go)      INSTALL_GOLANG=0; shift ;;
    --skip-bun)     INSTALL_BUN=0; shift ;;
    --skip-gadgets) INSTALL_GADGETS=0; shift ;;
    -y|--yes)       AUTO_YES=1; shift ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [OPTIONS]

Master installer for development toolchain. Installs languages (Zig, Rust, Go, Bun)
and CLI utilities (via gadgets.sh).

Options:
  --only-<tool>     Install only specific tool(s)
                    Tools: zig, rust, golang/go, bun, gadgets, jq
  --skip-<tool>     Skip installation of specific tool(s)
  -y, --yes         Auto-confirm all prompts (non-interactive mode)
  -h, --help        Show this help

Examples:
  # Install everything
  curl -fsSL ${BASE_URL}/install.sh | sh

  # Bootstrap jq only (useful for initial setup)
  curl -fsSL ${BASE_URL}/install.sh | sh -s -- --only-jq

  # Non-interactive installation
  curl -fsSL ${BASE_URL}/install.sh | sh -s -- --yes

  # Install only specific tools
  curl -fsSL ${BASE_URL}/install.sh | sh -s -- --only-rust --only-go

  # Install all except gadgets
  curl -fsSL ${BASE_URL}/install.sh | sh -s -- --skip-gadgets

  # Install individual tools directly
  curl -fsSL ${BASE_URL}/zig.sh | bash
  curl -fsSL ${BASE_URL}/rust.sh | bash
  curl -fsSL ${BASE_URL}/golang.sh | bash

Environment Variables:
  GITHUB_TOKEN  GitHub Personal Access Token (increases API rate limits)

USAGE
      exit 0
      ;;
    *) error "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# If any --only-* flags were provided, switch to "only" mode
if [ -n "${REQUESTED_TOOLS}" ]; then
  # Disable all tools first
  INSTALL_ZIG=0
  INSTALL_RUST=0
  INSTALL_GOLANG=0
  INSTALL_BUN=0
  INSTALL_GADGETS=0

  # Enable only requested tools
  for tool in ${REQUESTED_TOOLS}; do
    case "$tool" in
      zig)     INSTALL_ZIG=1 ;;
      rust)    INSTALL_RUST=1 ;;
      golang)  INSTALL_GOLANG=1 ;;
      bun)     INSTALL_BUN=1 ;;
      gadgets) INSTALL_GADGETS=1 ;;
    esac
  done
fi

# ---- Dependency checks ----
need() { command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"; }

# Detect download tool
if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  error "Neither curl nor wget found. Please install one."
fi

# ---- Setup toolchain directory ----
mkdir -p "${TOOLCHAIN_DIR}"
cd "${TOOLCHAIN_DIR}"

log "Toolchain directory: ${TOOLCHAIN_DIR}"

# ---- Download helper function ----
download_script() {
  local script_name="$1"
  local script_path="${TOOLCHAIN_DIR}/${script_name}"
  local script_url="${BASE_URL}/${script_name}"

  log "Downloading ${script_name}..."
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL -o "${script_path}" "${script_url}" || error "Failed to download ${script_name}"
  else
    wget -q -O "${script_path}" "${script_url}" || error "Failed to download ${script_name}"
  fi

  chmod +x "${script_path}"
  success "Downloaded ${script_name}"
}

# ---- Installation orchestration ----
INSTALLED_TOOLS=""
SKIPPED_TOOLS=""

install_tool() {
  local tool_name="$1"
  local script_name="$2"
  local install_flag="$3"
  shift 3
  # extra_args stored as space-separated string (remaining args after shift)
  local extra_args="$*"

  if [ "${install_flag}" -eq 0 ]; then
    log "Skipping ${tool_name} (install_flag=${install_flag})"
    SKIPPED_TOOLS="${SKIPPED_TOOLS} ${tool_name}"
    return 0
  fi

  log "Installing ${tool_name}..."
  echo ""

  # Check if script needs updating by comparing checksums
  local script_path="${TOOLCHAIN_DIR}/${script_name}"
  local needs_download=0

  if [ ! -f "${script_path}" ]; then
    needs_download=1
  else
    # Get remote checksum (optional - gracefully handle missing checksums.txt)
    local remote_sum=""
    if [ "$DOWNLOADER" = "curl" ]; then
      remote_sum=$(curl -fsSL "${BASE_URL}/checksums.txt" 2>/dev/null | grep "${script_name}" | awk '{print $1}' || echo "")
    else
      remote_sum=$(wget -qO- "${BASE_URL}/checksums.txt" 2>/dev/null | grep "${script_name}" | awk '{print $1}' || echo "")
    fi

    # If we have a remote checksum, verify it
    if [ -n "${remote_sum}" ]; then
      # Get local checksum
      local local_sum=""
      if command -v sha256sum >/dev/null 2>&1; then
        local_sum=$(sha256sum "${script_path}" | awk '{print $1}')
      elif command -v shasum >/dev/null 2>&1; then
        local_sum=$(shasum -a 256 "${script_path}" | awk '{print $1}')
      fi

      if [ -z "${local_sum}" ]; then
        warn "Failed to calculate local checksum for ${script_name}"
        needs_download=1
      elif [ "${remote_sum}" != "${local_sum}" ]; then
        log "Script has been updated, downloading latest version..."
        needs_download=1
      fi
    else
      # No checksum available, always re-download to be safe
      log "No checksum available for ${script_name}, re-downloading..."
      needs_download=1
    fi
  fi

  if [ "${needs_download}" -eq 1 ]; then
    download_script "${script_name}"
  else
    log "Using cached ${script_name}"
  fi

  # Execute installer
  # Always pass --yes since subscripts run non-interactively (stdin is /dev/null)
  local installer_args="--yes"

  # Add any extra args (e.g., --only-jq for gadgets.sh)
  if [ -n "${extra_args}" ]; then
    installer_args="${installer_args} ${extra_args}"
  fi

  # Run the installer as executable (respects shebang)
  # Redirect stdin from /dev/null to prevent subscripts from consuming parent script's stdin
  if "${TOOLCHAIN_DIR}/${script_name}" ${installer_args} </dev/null; then
    INSTALLED_TOOLS="${INSTALLED_TOOLS} ${tool_name}"
    success "${tool_name} installation completed"
  else
    local exit_code=$?
    printf "${RED}[ERROR]${NC} ❌ ${tool_name} installation FAILED with exit code ${exit_code}\n"
    echo "Script location: ${TOOLCHAIN_DIR}/${script_name}"
    echo "Try running it manually to see the error:"
    echo "  bash ${TOOLCHAIN_DIR}/${script_name}"
    SKIPPED_TOOLS="${SKIPPED_TOOLS} ${tool_name}"
    return 1
  fi

  echo ""
}

# ---- Main installation sequence ----
echo ""
log "Starting toolchain installation..."
echo ""

# Install in order
log "Debug: INSTALL_ZIG=${INSTALL_ZIG}, INSTALL_RUST=${INSTALL_RUST}, INSTALL_GOLANG=${INSTALL_GOLANG}, INSTALL_BUN=${INSTALL_BUN}, INSTALL_GADGETS=${INSTALL_GADGETS}"
log "About to install Zig..."
install_tool "Zig" "zig.sh" "${INSTALL_ZIG}" || warn "Zig installation returned error, continuing..."
log "About to install Rust..."
install_tool "Rust" "rust.sh" "${INSTALL_RUST}" || warn "Rust installation returned error, continuing..."
log "About to install Go..."
install_tool "Go" "golang.sh" "${INSTALL_GOLANG}" || warn "Go installation returned error, continuing..."
log "About to install Bun..."
install_tool "Bun" "bun.sh" "${INSTALL_BUN}" || warn "Bun installation returned error, continuing..."
log "About to install Gadgets..."
install_tool "Gadgets" "gadgets.sh" "${INSTALL_GADGETS}" "--bindir ${BIN_DIR}" ${GADGETS_ARGS} || warn "Gadgets installation returned error, continuing..."

# ---- Summary ----
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "Toolchain installation complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -n "${INSTALLED_TOOLS}" ]; then
  log "Tools installed:"
  for tool in ${INSTALLED_TOOLS}; do
    echo "  ✓ ${tool}"
  done
  echo ""
fi

if [ -n "${SKIPPED_TOOLS}" ]; then
  log "Tools skipped:"
  for tool in ${SKIPPED_TOOLS}; do
    echo "  - ${tool}"
  done
  echo ""
fi

log "Toolchain directory: ${TOOLCHAIN_DIR}"
log "Scripts are cached and can be re-run individually:"
for script in zig.sh rust.sh golang.sh bun.sh gadgets.sh; do
  if [ -f "${TOOLCHAIN_DIR}/${script}" ]; then
    echo "  ${TOOLCHAIN_DIR}/${script}"
  fi
done

echo ""
log "Ensure ~/.local/bin is in your PATH:"
echo "  export PATH=\"\${HOME}/.local/bin:\$PATH\""
echo ""
success "Happy coding! 🚀"
