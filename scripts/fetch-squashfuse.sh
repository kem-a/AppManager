#!/bin/sh
# Download the squashfuse FUSE driver for bundling with AppManager.
# Usage: fetch-squashfuse.sh <arch> <output_dir>
#
# The sandbox mounts an AppImage's payload itself, which needs the squashfuse and
# dwarfs FUSE *drivers* — not the unsquashfs / dwarfsextract extractors AppManager
# uses elsewhere. The dwarfs driver comes from fetch-dwarfs-tools.sh, which
# downloads it anyway; squashfuse has no such tarball, hence this script.
#
# The binary comes from pkgforge's bincache, the same org AppManager's own AppImage
# is built in and already fetches tooling from, so it adds no new trust dependency.

set -e

ARCH="${1:-x86_64}"
OUTPUT_DIR="${2:-.}"

SQUASHFUSE_URL="https://pkgs.pkgforge.dev/dl/bincache/${ARCH}-linux/squashfuse/nixpkgs/squashfuse/raw.dl"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

if [ -x "squashfuse" ]; then
    echo "squashfuse already exists in $OUTPUT_DIR, skipping download"
    ls -la squashfuse
    exit 0
fi

echo "Downloading squashfuse for $ARCH..."
curl -L --retry 3 -o squashfuse "$SQUASHFUSE_URL"
chmod +x squashfuse

# Fail loudly rather than shipping an HTML error page as the mount driver.
if ! head -c 4 squashfuse | grep -q 'ELF'; then
    echo "Downloaded squashfuse is not an ELF binary" >&2
    rm -f squashfuse
    exit 1
fi

echo "squashfuse placed in $OUTPUT_DIR"
ls -la squashfuse
