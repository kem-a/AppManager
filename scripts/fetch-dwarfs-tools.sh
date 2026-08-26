#!/bin/sh
# Download and extract DwarFS tools for bundling with AppManager
# Usage: fetch-dwarfs-tools.sh <version> <arch> <output_dir>

set -e

VERSION="${1:-0.15.5}"
ARCH="${2:-x86_64}"
OUTPUT_DIR="${3:-.}"

TARBALL="dwarfs-${VERSION}-Linux-${ARCH}.tar.xz"
URL="https://github.com/mhx/dwarfs/releases/download/v${VERSION}/${TARBALL}"
EXTRACT_DIR="dwarfs-${VERSION}-Linux-${ARCH}"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# dwarfsextract unpacks DwarFS-based AppImages; dwarfs is the FUSE driver that sas
# mounts them with. Both come from the same tarball, so fetch once for both.
TOOLS="dwarfsextract dwarfs"

# Check if tools already exist and are executable
if [ -x "dwarfsextract" ] && [ -x "dwarfs" ]; then
    echo "DwarFS tools already exist in $OUTPUT_DIR, skipping download"
    ls -la $TOOLS
    exit 0
fi

# Download if not already present
if [ ! -f "$TARBALL" ]; then
    echo "Downloading $TARBALL..."
    curl -L -o "$TARBALL" "$URL"
fi

# Extract the specific binaries we need
for tool in $TOOLS; do
    [ -x "$tool" ] && continue
    echo "Extracting $tool..."
    tar -xf "$TARBALL" "${EXTRACT_DIR}/bin/${tool}"
    mv "${EXTRACT_DIR}/bin/${tool}" .
done
rm -rf "$EXTRACT_DIR"

echo "DwarFS tools extracted to $OUTPUT_DIR"
ls -la $TOOLS
