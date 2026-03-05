#!/bin/bash
set -euo pipefail

# grove installer
# Usage: curl -fsSL https://grove-code.github.io/scripts/install.sh | bash
#
# Installs to ~/.grove/bin by default (no sudo required)
#
# Environment variables:
#   channel           - Release channel: stable (default) or canary
#   grove_install_dir - Override install directory (default: ~/.grove/bin)
#
# Examples:
#   curl -fsSL .../install.sh | bash                    # Latest stable
#   curl -fsSL .../install.sh | channel=canary bash    # Latest canary
#   curl -fsSL .../install.sh | bash -s v0.1.0         # Specific version

repo="grove-code/downloads"
grove_home="${GROVE_HOME:-$HOME/.grove}"
install_dir="${grove_install_dir:-$grove_home/bin}"
channel="${channel:-stable}"
version="${1:-}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
nc='\033[0m'

info() { echo -e "${green}info${nc}: $1"; }
warn() { echo -e "${yellow}warn${nc}: $1"; }
error() { echo -e "${red}error${nc}: $1"; exit 1; }

download() {
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -qO "$dest" "$url"
    else
        error "Neither curl nor wget found. Install one and retry."
    fi
}

sha256_verify() {
    local file="$1" expected="$2" actual
    if command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "$file" | cut -d' ' -f1)
    elif command -v shasum &>/dev/null; then
        actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    else
        warn "No sha256sum or shasum found, skipping verification"
        return 0
    fi
    if [[ "$actual" != "$expected" ]]; then
        error "Checksum mismatch!\n  Expected: ${expected}\n  Actual:   ${actual}"
    fi
}

# Detect platform
case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *)      error "Unsupported OS: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64)         arch="x86_64" ;;
    arm64|aarch64)  arch="aarch64" ;;
    *)              error "Unsupported architecture: $(uname -m)" ;;
esac

platform="${os}-${arch}"
info "Detected platform: ${platform}"

# Resolve version
if [[ -z "$version" ]]; then
    if [[ "$channel" == "canary" ]]; then
        info "Fetching latest canary version..."
        if command -v curl &>/dev/null; then
            releases_json=$(curl -fsSL "https://api.github.com/repos/${repo}/releases")
        elif command -v wget &>/dev/null; then
            releases_json=$(wget -qO- "https://api.github.com/repos/${repo}/releases")
        else
            error "Neither curl nor wget found. Install one and retry."
        fi
        version=$(echo "$releases_json" | \
            grep -E '"tag_name":|"prerelease":' | \
            paste - - | \
            grep 'true' | \
            sed -E 's/.*"tag_name": "([^"]+)".*/\1/' | \
            sort -t. -k1,1V -k2,2V -k3,3V -k4,4n | \
            tail -1)
        if [[ -z "$version" ]]; then
            error "No canary releases found"
        fi
    else
        info "Fetching latest stable version..."
        if command -v curl &>/dev/null; then
            version=$(curl -fsSI "https://github.com/${repo}/releases/latest" | grep -i '^location:' | sed -E 's|.*/tag/([^[:space:]]+).*|\1|')
        else
            version=$(wget --spider -S "https://github.com/${repo}/releases/latest" 2>&1 | grep -i 'location:' | tail -1 | sed -E 's|.*/tag/([^[:space:]]+).*|\1|')
        fi
        if [[ -z "$version" ]]; then
            error "Failed to fetch latest stable version"
        fi
    fi
fi

info "Installing grove ${version} (${channel})..."

# Check for existing installation
if [[ -x "${install_dir}/grove" ]]; then
    existing=$("${install_dir}/grove" --version 2>/dev/null | head -1 || echo "unknown")
    info "Upgrading from ${existing}"
fi

# Download and verify
tmp_dir=$(mktemp -d)
trap "rm -rf $tmp_dir" EXIT

info "Fetching checksums..."
if ! download "https://github.com/${repo}/releases/download/${version}/checksums.txt" "${tmp_dir}/checksums.txt"; then
    error "Failed to download checksums. Check that version ${version} exists."
fi

info "Downloading ${platform}.tar.gz..."
if ! download "https://github.com/${repo}/releases/download/${version}/${platform}.tar.gz" "${tmp_dir}/grove.tar.gz"; then
    error "Download failed. Check that version ${version} has binaries for ${platform}."
fi

expected_sha=$(grep "${platform}.tar.gz" "${tmp_dir}/checksums.txt" | cut -d' ' -f1)
if [[ -z "$expected_sha" ]]; then
    error "No checksum found for ${platform}.tar.gz in checksums.txt"
fi
info "Verifying checksum..."
sha256_verify "${tmp_dir}/grove.tar.gz" "$expected_sha"

# Extract and install
tar -xzf "${tmp_dir}/grove.tar.gz" -C "$tmp_dir"

mkdir -p "$install_dir"
mv "${tmp_dir}/grove" "${install_dir}/grove"
chmod +x "${install_dir}/grove"

info "Installed grove to ${install_dir}/grove"

if ! "${install_dir}/grove" --version &>/dev/null; then
    error "Installation verification failed. Binary may be incompatible with this system."
fi

# Install man page
man_dir="${grove_home}/share/man/man1"
if [[ -f "${tmp_dir}/grove.1" ]]; then
    mkdir -p "$man_dir"
    mv "${tmp_dir}/grove.1" "${man_dir}/grove.1"
    info "Installed man page to ${man_dir}/grove.1"
fi

# Symlink to ~/.local/bin if it exists
if [[ -d "$HOME/.local/bin" ]]; then
    ln -sf "${install_dir}/grove" "$HOME/.local/bin/grove"
    info "Symlinked to ~/.local/bin/grove"
fi

echo ""

if [[ ":$PATH:" != *":$install_dir:"* ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    warn "grove is not in your PATH"
    echo ""
    echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
    echo ""
    echo "  export PATH=\"\$HOME/.grove/bin:\$PATH\""
    echo "  export MANPATH=\"\$HOME/.grove/share/man:\$MANPATH\""
    echo ""
fi

echo "Run 'grove --help' to get started"
