#!/usr/bin/env bash
# rust.sh
# Linux/macOS: install Rust via rustup (official installer) and rust-analyzer
# Uses rustup toolchain manager, per-user installation (no sudo required)
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
RUST_TOOLCHAIN="stable"        # stable, beta, nightly, or specific version like "1.83.0"
RUST_ANALYZER_SPEC="auto"      # "auto"=via rustup component; "skip"=don't install
INSTALL_RUST_ANALYZER=1
AUTO_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rust)                RUST_TOOLCHAIN="${2:?}"; shift 2 ;;
    --rust-analyzer)       RUST_ANALYZER_SPEC="${2:?}"; shift 2 ;;
    --skip-rust-analyzer)  INSTALL_RUST_ANALYZER=0; shift ;;
    -y|--yes)              AUTO_YES=1; shift ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--rust <stable|beta|nightly|version>] [--rust-analyzer <auto|skip>]
          [--skip-rust-analyzer] [-y|--yes]

Options:
  --rust TOOLCHAIN         Install specific Rust toolchain (default: stable)
                           Examples: stable, beta, nightly, 1.83.0
  --rust-analyzer auto     Install rust-analyzer via rustup component (default)
  --skip-rust-analyzer     Don't install rust-analyzer
  -y, --yes                Auto-confirm all prompts (for scripting)

Examples:
  $0                                    # Install stable Rust + rust-analyzer
  $0 --rust nightly                     # Install nightly toolchain
  $0 --rust 1.83.0                      # Pin to specific version
  $0 --skip-rust-analyzer               # Skip rust-analyzer
  $0 --yes                              # Non-interactive mode

USAGE
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"; }
for c in curl; do need "$c"; done

CARGO_HOME="${CARGO_HOME:-${HOME}/.cargo}"
RUSTUP_HOME="${RUSTUP_HOME:-${HOME}/.rustup}"

# ---- Check for existing rustup/rust ----
SKIP_RUST=0
RUSTUP_EXISTS=0

if command -v rustup >/dev/null 2>&1; then
  RUSTUP_EXISTS=1
  log "rustup found at $(command -v rustup)"

  # Check if requested toolchain is already installed and active
  if rustup toolchain list | grep -q "^${RUST_TOOLCHAIN}"; then
    CURRENT_DEFAULT="$(rustup default 2>/dev/null | awk '{print $1}' || echo '')"
    if [[ "${CURRENT_DEFAULT}" == "${RUST_TOOLCHAIN}"* ]]; then
      log "Rust toolchain ${RUST_TOOLCHAIN} is already the default"
      if [[ "${AUTO_YES}" -eq 0 ]]; then
        read -p "Reinstall/update? [y/N] " -r REPLY
        [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping Rust installation"; SKIP_RUST=1; }
      else
        log "Auto-confirming update (--yes flag)"
      fi
    else
      log "Will set ${RUST_TOOLCHAIN} as default (current: ${CURRENT_DEFAULT})"
    fi
  else
    log "Toolchain ${RUST_TOOLCHAIN} not installed yet"
  fi
fi

# ---- Install/Update Rust via rustup ----
if [[ "${SKIP_RUST}" -eq 0 ]]; then
  if [[ "${RUSTUP_EXISTS}" -eq 0 ]]; then
    log "Installing Rust via rustup..."
    RUSTUP_INIT_URL="https://sh.rustup.rs"

    if [[ "${AUTO_YES}" -eq 1 ]]; then
      log "Running rustup installer (non-interactive)"
      curl --proto '=https' --tlsv1.2 -sSf "${RUSTUP_INIT_URL}" | \
        sh -s -- -y --default-toolchain "${RUST_TOOLCHAIN}" --profile default || \
        error "rustup installation failed"
    else
      log "Running rustup installer (interactive)"
      curl --proto '=https' --tlsv1.2 -sSf "${RUSTUP_INIT_URL}" | \
        sh -s -- --default-toolchain "${RUST_TOOLCHAIN}" --profile default || \
        error "rustup installation failed"
    fi

    # Source cargo env to make rustup/cargo available immediately
    if [[ -f "${CARGO_HOME}/env" ]]; then
      # shellcheck source=/dev/null
      source "${CARGO_HOME}/env"
    fi

    success "rustup installed"
  else
    log "Updating rustup and installing/setting toolchain ${RUST_TOOLCHAIN}..."
    rustup self update || warn "Failed to update rustup"
    rustup toolchain install "${RUST_TOOLCHAIN}" || error "Failed to install toolchain ${RUST_TOOLCHAIN}"
    rustup default "${RUST_TOOLCHAIN}" || error "Failed to set default toolchain"
    success "Rust toolchain ${RUST_TOOLCHAIN} set as default"
  fi

  # Verify installation
  if command -v rustc >/dev/null 2>&1; then
    RUST_VERSION="$(rustc --version)"
    success "${RUST_VERSION} installed"
  fi
else
  log "Using existing Rust installation"
fi

# ---- rust-analyzer (optional) ----
SKIP_RUST_ANALYZER=0

if [[ "${INSTALL_RUST_ANALYZER}" -eq 1 ]]; then
  if [[ "${RUST_ANALYZER_SPEC}" == "auto" ]]; then
    log "Installing rust-analyzer via rustup component..."

    # Check if already installed
    if rustup component list --installed | grep -q "^rust-analyzer"; then
      log "rust-analyzer component already installed"
      if [[ "${AUTO_YES}" -eq 0 ]]; then
        read -p "Update rust-analyzer? [y/N] " -r REPLY
        [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping rust-analyzer update"; SKIP_RUST_ANALYZER=1; }
      else
        log "Auto-confirming update (--yes flag)"
      fi
    fi

    if [[ "${SKIP_RUST_ANALYZER}" -eq 0 ]]; then
      # Add rust-analyzer component (will update if already installed)
      rustup component add rust-analyzer || warn "Failed to install rust-analyzer component (may not be available for this toolchain)"

      if command -v rust-analyzer >/dev/null 2>&1; then
        success "rust-analyzer installed at $(command -v rust-analyzer)"
      else
        warn "rust-analyzer component installed but not in PATH. You may need to use 'rustup run ${RUST_TOOLCHAIN} rust-analyzer'"
      fi
    fi
  fi
else
  warn "Skipping rust-analyzer installation"
fi

# ---- PATH setup ----
if [[ -f "${CARGO_HOME}/env" ]]; then
  # shellcheck source=/dev/null
  source "${CARGO_HOME}/env"
fi

if ! printf '%s' "$PATH" | grep -q -F "${CARGO_HOME}/bin"; then
  SHELLRC="${HOME}/.bashrc"
  [[ "$SHELL" == */zsh ]] && SHELLRC="${HOME}/.zshrc"

  if [[ -f "${SHELLRC}" ]] && ! grep -q -F ". \"${CARGO_HOME}/env\"" "${SHELLRC}" &>/dev/null; then
    echo "" >> "${SHELLRC}"
    echo "# Added by rust.sh" >> "${SHELLRC}"
    echo ". \"\${CARGO_HOME}/env\"" >> "${SHELLRC}"
    success "Added cargo environment to ${SHELLRC}"
  fi
fi

# ---- Summary ----
echo ""
success "Installation complete!"

if command -v rustc >/dev/null 2>&1; then
  log "Rust: $(rustc --version)"
fi

if command -v cargo >/dev/null 2>&1; then
  log "Cargo: $(cargo --version)"
fi

if [[ "${INSTALL_RUST_ANALYZER}" -eq 1 ]] && command -v rust-analyzer >/dev/null 2>&1; then
  RA_VERSION="$(rust-analyzer --version 2>/dev/null || echo 'installed')"
  log "rust-analyzer: ${RA_VERSION}"
fi

log "Tip: Use 'rustup toolchain install <version>' to install additional toolchains"
log "Tip: Use 'rustup default <toolchain>' to switch between installed toolchains"
