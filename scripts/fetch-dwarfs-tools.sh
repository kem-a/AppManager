#!/bin/sh
# Download and extract DwarFS tools for bundling with AppManager
# Usage: fetch-dwarfs-tools.sh <version> <arch> <output_dir>

set -e

VERSION="${1:-0.15.0}"
ARCH="${2:-x86_64}"
OUTPUT_DIR="${3:-.}"

TARBALL="dwarfs-${VERSION}-Linux-${ARCH}.tar.xz"
URL="https://github.com/mhx/dwarfs/releases/download/v${VERSION}/${TARBALL}"
EXTRACT_DIR="dwarfs-${VERSION}-Linux-${ARCH}"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# Check if tools already exist and are executable
if [ -x "dwarfsextract" ]; then
    echo "DwarFS tools already exist in $OUTPUT_DIR, skipping download"
    ls -la dwarfsextract
    exit 0
fi

# Download if not already present
if [ ! -f "$TARBALL" ]; then
    echo "Downloading $TARBALL..."
    curl -L -o "$TARBALL" "$URL"
fi

# Extract the specific binaries we need
echo "Extracting dwarfsextract..."
tar -xf "$TARBALL" "${EXTRACT_DIR}/bin/dwarfsextract"
mv "${EXTRACT_DIR}/bin/dwarfsextract" .
rm -rf "$EXTRACT_DIR"

echo "DwarFS tools extracted to $OUTPUT_DIR"
ls -la dwarfsextract
