#!/bin/sh
# Download and extract 7-Zip tools for bundling with AppManager
# Usage: fetch-7z-tools.sh <version> <arch> <output_dir>
# 7-Zip 23.01+ is required for zstd compression support

set -e

VERSION="${1:-2501}"
ARCH="${2:-x86_64}"
OUTPUT_DIR="${3:-.}"

# 7-Zip uses a different version format in filenames (2501 = 25.01)
# and different architecture naming
case "$ARCH" in
    x86_64|amd64)
        SEVENZIP_ARCH="linux-x64"
        ;;
    aarch64|arm64)
        SEVENZIP_ARCH="linux-arm64"
        ;;
    armhf|armv7l)
        SEVENZIP_ARCH="linux-arm"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

TARBALL="7z${VERSION}-${SEVENZIP_ARCH}.tar.xz"
URL="https://www.7-zip.org/a/${TARBALL}"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# Download if not already present
if [ ! -f "$TARBALL" ]; then
    echo "Downloading 7-Zip ${VERSION} for ${SEVENZIP_ARCH}..."
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$TARBALL" "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$TARBALL" "$URL"
    else
        echo "Error: Neither curl nor wget found"
        exit 1
    fi
fi

# Extract the 7zz binary (standalone console version)
echo "Extracting 7zz..."
tar -xf "$TARBALL" 7zz

# Rename to 7z for convenience
mv 7zz 7z
chmod +x 7z

# Cleanup
rm -f "$TARBALL"

echo "7-Zip extracted to $OUTPUT_DIR"
ls -la 7z

# Verify it works
echo ""
echo "Version check:"
./7z | head -3
