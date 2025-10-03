#!/usr/bin/env bash
set -euo pipefail

# Bun installer - wraps official Bun installation script
# Usage:
#   ./bun.sh                  # Install latest
#   ./bun.sh --bun 1.2.23     # Install specific version
#   ./bun.sh --upgrade        # Upgrade existing installation

BUN_VERSION="latest"
UPGRADE_MODE=false

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
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --bun VERSION    Install specific Bun version (e.g., 1.2.23)"
      echo "  --upgrade        Upgrade existing Bun installation"
      echo "  -h, --help       Show this help message"
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
    echo "Upgrading Bun..."
    bun upgrade
    echo "Bun upgraded successfully to version $(bun --version)"
    exit 0
  else
    echo "Bun is not installed. Run without --upgrade to install."
    exit 1
  fi
fi

# Install Bun
echo "Installing Bun${BUN_VERSION:+ version $BUN_VERSION}..."

if [[ "$BUN_VERSION" == "latest" ]]; then
  curl -fsSL https://bun.com/install | bash
else
  curl -fsSL https://bun.com/install | bash -s "bun-v$BUN_VERSION"
fi

# Verify installation
BUN_BIN="$HOME/.bun/bin/bun"
if [[ -x "$BUN_BIN" ]]; then
  INSTALLED_VERSION=$("$BUN_BIN" --version)
  echo "Bun $INSTALLED_VERSION installed successfully at $BUN_BIN"
else
  echo "Error: Bun installation failed"
  exit 1
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
      echo "Added Bun to PATH in $RC"
    fi
  fi
done

echo ""
echo "Installation complete!"
echo "Run 'source ~/.bashrc' or 'source ~/.zshrc' (or restart your shell) to use Bun."
