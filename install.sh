#!/usr/bin/env bash

set -e

# Detect architecture
ARCH="$(uname -m)"

# Check if architecture is x86_64 / amd64
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
    echo "Your arch isn't supported by Wolframite yet"
    exit 1
fi

URL="https://github.com/fkm-X3/Wolframite/releases/download/dev/ore-linux-x86_64"

# Determine install target directory
if [ "$EUID" -eq 0 ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

TARGET="$INSTALL_DIR/ore"

echo "Downloading latest dev build of 'ore'..."
curl -sSL "$URL" -o "$TARGET"

echo "Setting executable permissions..."
chmod +x "$TARGET"

echo "Successfully installed 'ore' to $TARGET"

# Check if INSTALL_DIR is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo -e "\n\033[33mWarning: $INSTALL_DIR is not in your PATH.\033[0m"
    echo "Add the following line to your ~/.bashrc or ~/.zshrc:"
    echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
fi