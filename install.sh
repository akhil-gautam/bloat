#!/bin/bash
set -euo pipefail

REPO="akhil-gautam/bloat"
INSTALL_DIR="/usr/local/bin"

# Get latest release tag
VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)

if [ -z "$VERSION" ]; then
  echo "Error: Could not determine latest version"
  exit 1
fi

echo "Installing bloat ${VERSION}..."

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  arm64)  SUFFIX="macos-arm64" ;;
  x86_64) SUFFIX="macos-x86_64" ;;
  *)      SUFFIX="macos-universal" ;;
esac

URL="https://github.com/${REPO}/releases/download/${VERSION}/bloat-${VERSION}-${SUFFIX}.tar.gz"

echo "Downloading ${URL}..."
TMPDIR=$(mktemp -d)
curl -fsSL "$URL" | tar -xz -C "$TMPDIR"

echo "Installing to ${INSTALL_DIR}/bloat..."
sudo mv "${TMPDIR}/bloat" "${INSTALL_DIR}/bloat"
sudo chmod +x "${INSTALL_DIR}/bloat"
rm -rf "$TMPDIR"

echo ""
echo "bloat ${VERSION} installed successfully!"
echo "Run 'bloat' to get started."
