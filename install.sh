#!/usr/bin/env bash
# ZiGrep Universal One-Line Installer
# Usage: curl -sSfL https://raw.githubusercontent.com/DannyBaanks/ZiGrep/main/install.sh | bash
set -e

REPO="DannyBaanks/ZiGrep"
VERSION="latest"

echo "⚡ Installing ZiGrep..."

# 1. Detect OS & Architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        TARGET_ARCH="x86_64"
        ;;
    aarch64|arm64)
        TARGET_ARCH="aarch64"
        ;;
    *)
        echo "❌ Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

if [ "$OS" != "linux" ]; then
    echo "⚠️ Notice: ZiGrep is ultra-optimized for Linux direct kernel syscalls (getdents64)."
fi

# 2. Determine installation target
if [ "$(id -u)" -eq 0 ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
fi
mkdir -p "$INSTALL_DIR"

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# 3. Download Release Asset or Build from Source
TAR_NAME="zigrep-linux-${TARGET_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${TAR_NAME}"

INSTALLED=0

if command -v curl >/dev/null 2>&1; then
    FETCH_CMD="curl -sSfL"
elif command -v wget >/dev/null 2>&1; then
    FETCH_CMD="wget -qO-"
else
    FETCH_CMD=""
fi

if [ -n "$FETCH_CMD" ]; then
    echo "⬇️  Downloading precompiled static binary ($TARGET_ARCH)..."
    if curl -sSfL "$DOWNLOAD_URL" -o "$TMP_DIR/$TAR_NAME" 2>/dev/null; then
        tar -xzf "$TMP_DIR/$TAR_NAME" -C "$TMP_DIR"
        cp "$TMP_DIR/zigrep" "$INSTALL_DIR/zigrep"
        chmod +x "$INSTALL_DIR/zigrep"
        INSTALLED=1
    fi
fi

# Fallback: Build from source if binary download is unavailable and zig is installed
if [ "$INSTALLED" -eq 0 ]; then
    if command -v zig >/dev/null 2>&1; then
        echo "⚙️  Precompiled asset not found or offline. Building from source with Zig..."
        git clone --depth 1 "https://github.com/${REPO}.git" "$TMP_DIR/repo" >/dev/null 2>&1
        (cd "$TMP_DIR/repo" && zig build -Doptimize=ReleaseFast >/dev/null 2>&1)
        cp "$TMP_DIR/repo/zig-out/bin/zigrep" "$INSTALL_DIR/zigrep"
        chmod +x "$INSTALL_DIR/zigrep"
        strip "$INSTALL_DIR/zigrep" 2>/dev/null || true
        INSTALLED=1
    else
        echo "❌ Failed to download $TAR_NAME and Zig compiler is not installed."
        echo "Please install Zig 0.16+ or download the binary manually from:"
        echo "https://github.com/${REPO}/releases"
        exit 1
    fi
fi

# 4. Create symlink for zgrep
ln -sf "$INSTALL_DIR/zigrep" "$INSTALL_DIR/zgrep"

# 5. Check PATH environment
PATH_OK=0
case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        PATH_OK=1
        ;;
esac

if [ "$PATH_OK" -eq 0 ]; then
    echo "⚠️  $INSTALL_DIR is not in your \$PATH."
    SHELL_NAME="$(basename "${SHELL:-bash}")"
    RC_FILE=""
    if [ "$SHELL_NAME" = "zsh" ]; then
        RC_FILE="$HOME/.zshrc"
    else
        RC_FILE="$HOME/.bashrc"
    fi
    if [ -f "$RC_FILE" ]; then
        if ! grep -q "$INSTALL_DIR" "$RC_FILE"; then
            echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$RC_FILE"
            echo "✅ Added $INSTALL_DIR to $RC_FILE. Restart your shell or run: source $RC_FILE"
        fi
    fi
fi

echo ""
echo "✨ ZiGrep installed successfully into $INSTALL_DIR/zigrep!"
"$INSTALL_DIR/zigrep" --version
echo "Ready for use by human developers and AI coding agents."
