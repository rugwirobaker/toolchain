#!/usr/bin/env bash
# bun.sh
# Install Bun JavaScript runtime
# Usage:
#   ./bun.sh                  # Install latest
#   ./bun.sh --bun 1.2.23     # Install specific version
#   ./bun.sh --upgrade        # Upgrade existing installation
#   ./bun.sh --yes            # Auto-confirm prompts
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

BUN_VERSION="latest"
UPGRADE_MODE=false
AUTO_YES=0
SKIP_BUN=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --bun)
      BUN_VERSION="$2"
      shift 2
      ;;
    --upgrade)
      UPGRADE_MODE=true
      shift
      ;;
    -y|--yes)
      AUTO_YES=1
      shift
      ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [OPTIONS]

Options:
  --bun VERSION    Install specific Bun version (e.g., 1.2.23)
  --upgrade        Upgrade existing Bun installation
  -y, --yes        Auto-confirm all prompts
  -h, --help       Show this help message

Examples:
  $0                    # Install latest Bun
  $0 --bun 1.2.23       # Install Bun 1.2.23
  $0 --upgrade          # Upgrade Bun
  $0 --yes              # Non-interactive install
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Handle upgrade mode
if [[ "$UPGRADE_MODE" == true ]]; then
  if command -v bun &> /dev/null; then
    log "Upgrading Bun..."
    bun upgrade
    success "Bun upgraded successfully to version $(bun --version)"
    exit 0
  else
    error "Bun is not installed. Run without --upgrade to install."
  fi
fi

# ---- Check for existing Bun ----
if command -v bun >/dev/null 2>&1; then
  EXISTING_VER="$(bun --version 2>/dev/null || echo '')"
  EXISTING_PATH="$(command -v bun)"
  
  if [[ "$BUN_VERSION" == "latest" ]]; then
    log "Bun ${EXISTING_VER} already installed at ${EXISTING_PATH}"
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      read -p "Reinstall/update? [y/N] " -r REPLY
      [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping Bun installation"; SKIP_BUN=1; }
    else
      log "Auto-confirming update (--yes flag)"
    fi
  else
    if [[ "${EXISTING_VER}" == "${BUN_VERSION}" ]]; then
      log "Bun ${BUN_VERSION} already installed at ${EXISTING_PATH}"
      if [[ "${AUTO_YES}" -eq 0 ]]; then
        read -p "Reinstall? [y/N] " -r REPLY
        [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Skipping Bun installation"; SKIP_BUN=1; }
      else
        log "Auto-confirming reinstall (--yes flag)"
      fi
    else
      log "Found Bun ${EXISTING_VER}, will install ${BUN_VERSION}"
    fi
  fi
fi

# ---- Install Bun ----
if [[ "${SKIP_BUN}" -eq 0 ]]; then
  log "Installing Bun${BUN_VERSION:+ version $BUN_VERSION}..."

  if [[ "$BUN_VERSION" == "latest" ]]; then
    curl -fsSL https://bun.sh/install | bash
  else
    curl -fsSL https://bun.sh/install | bash -s "bun-v$BUN_VERSION"
  fi

  # Verify installation
  BUN_BIN="$HOME/.bun/bin/bun"
  if [[ -x "$BUN_BIN" ]]; then
    INSTALLED_VERSION=$("$BUN_BIN" --version)
    success "Bun $INSTALLED_VERSION installed at $BUN_BIN"
  else
    error "Bun installation failed"
  fi

  # Add to PATH in shell rc files if needed
  BUN_BIN_DIR="$HOME/.bun/bin"
  SHELL_RCS=("$HOME/.bashrc" "$HOME/.zshrc")

  for RC in "${SHELL_RCS[@]}"; do
    if [[ -f "$RC" ]]; then
      # Check if PATH already contains ~/.bun/bin
      if ! grep -q 'export PATH.*\.bun/bin' "$RC" && ! grep -q 'export BUN_INSTALL' "$RC"; then
        echo "" >> "$RC"
        echo "# Bun" >> "$RC"
        echo 'export BUN_INSTALL="$HOME/.bun"' >> "$RC"
        echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$RC"
        success "Added Bun to PATH in $RC"
      fi
    fi
  done

  echo ""
  success "Installation complete!"
  log "Run 'source ~/.bashrc' or 'source ~/.zshrc' (or restart your shell) to use Bun."
else
  log "Using existing Bun installation"
fi
