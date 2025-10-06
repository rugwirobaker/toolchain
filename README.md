# Toolchain

One-shot seeding of new workstations with development tools. The first thing to run on a new machine.

**Note:** This is a personal toolchain and hence opinionated about tool selection and installation methods.

## Requirements

- **Bash 4.0+** - Required for individual tool scripts
- **curl** or **wget** - For downloading
- **tar**, **jq** - Basic utilities (jq bootstrapped automatically if missing)
- Supported platforms: Linux (x86_64, aarch64), macOS (Intel, Apple Silicon)

## Installation

```bash
# Install everything
curl -fsSL https://toolchain.acodechef.dev/install.sh | sh

# Non-interactive
curl -fsSL https://toolchain.acodechef.dev/install.sh | sh -s -- --yes

# Install specific tools only
curl -fsSL https://toolchain.acodechef.dev/install.sh | sh -s -- --only-rust --only-go

# Individual tool scripts
curl -fsSL https://toolchain.acodechef.dev/zig.sh | bash
curl -fsSL https://toolchain.acodechef.dev/gadgets.sh | bash
```

## What's Included

### Languages
- **Zig** - Latest or pinned version + ZLS language server
- **Rust** - Via rustup (rustc, cargo, clippy, rustfmt, rust-analyzer)
- **Go** - Latest or pinned version
- **Bun** - JavaScript runtime

### CLI Utilities (gadgets.sh)
ast-grep, curlie, doggo, duf, flyctl, fzf, hexyl, jq, yq, ripgrep, uv+uvx+ruff, zoxide

## Important Nuances

### jq Bootstrap Requirement
Most scripts require `jq` to parse GitHub API responses. `gadgets.sh` breaks character and installs jq first before everything else. If you don't have `jq`:

```bash
# Bootstrap jq only
curl -fsSL https://toolchain.acodechef.dev/install.sh | sh -s -- --only-jq
```

### Zig Script
```bash
./zig.sh                              # Latest Zig + auto-matched ZLS
./zig.sh --zig 0.14.1 --zls 0.14.0    # Pin specific versions
./zig.sh --skip-zls                   # Skip language server
./zig.sh --yes                        # Non-interactive
```

- Supports both `arm64` (macOS) and `aarch64` (Linux) architectures
- SHA256 verification when available
- Auto-adds `~/.local/bin` to PATH

### Rust Script
```bash
./rust.sh                              # Latest stable Rust + rust-analyzer
./rust.sh --rust nightly               # Install nightly toolchain
./rust.sh --rust 1.83.0                # Pin specific version
./rust.sh --skip-rust-analyzer         # Skip language server
./rust.sh --yes                        # Non-interactive
```

Uses official rustup installer - just a wrapper for convenience.

### Go Script
```bash
./golang.sh                            # Latest Go + gopls
./golang.sh --go 1.25.1                # Pin specific version
./golang.sh --gopls v0.20.0            # Pin gopls version
./golang.sh --skip-gopls               # Skip language server
./golang.sh --yes                      # Non-interactive
```

### Bun Script
```bash
./bun.sh                               # Latest Bun
./bun.sh --bun 1.2.23                  # Pin specific version
./bun.sh --upgrade                     # Upgrade existing installation
./bun.sh --yes                         # Non-interactive
```

### Gadgets Script
```bash
./gadgets.sh                          # Install all to /usr/local/bin (needs sudo)
./gadgets.sh --bindir ~/.local/bin    # User install (no sudo)
./gadgets.sh --skip-ruff              # Skip specific tools
./gadgets.sh --only-jq                # Bootstrap mode - installs ONLY jq
```

- Always installs jq first (needed for parsing GitHub API)
- Generates shell completions automatically
- System-wide by default, user install with `--bindir`

## Location

- **Local cache:** `$HOME/.toolchain`
- **Binaries:** `~/.local/bin` (languages) or `/usr/local/bin` (utilities)
- **Online:** https://toolchain.acodechef.dev

## Environment Variables

`GITHUB_TOKEN` - Optional, increases API rate limits
