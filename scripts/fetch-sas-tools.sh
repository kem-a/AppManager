#!/bin/sh
# Download sas (simple-appimage-sandbox) and squashfuse for bundling with AppManager.
# Usage: fetch-sas-tools.sh <sas_version> <arch> <output_dir>
#
# sas is the sandbox launcher AppManager writes its .desktop Exec lines against.
# It hard-fails on any missing dependency, and needs the squashfuse and dwarfs FUSE
# *drivers* — not the unsquashfs / dwarfsextract extractors AppManager uses elsewhere.
# The dwarfs driver comes from fetch-dwarfs-tools.sh, which downloads it anyway.
#
# squashfuse comes from pkgforge's bincache, the same source sas's own AppImage uses,
# and the same org AppManager's AppImage is already built in and fetches tooling from.

set -e

VERSION="${1:-2.4}"
ARCH="${2:-x86_64}"
OUTPUT_DIR="${3:-.}"

SAS_URL="https://raw.githubusercontent.com/Samueru-sama/simple-appimage-sandbox/${VERSION}/sas.sh"
SQUASHFUSE_URL="https://pkgs.pkgforge.dev/dl/bincache/${ARCH}-linux/squashfuse/nixpkgs/squashfuse/raw.dl"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

if [ -x "sas" ] && [ -x "squashfuse" ]; then
    echo "Sandbox tools already exist in $OUTPUT_DIR, skipping download"
    ls -la sas squashfuse
    exit 0
fi

if [ ! -x "sas" ]; then
    echo "Downloading sas $VERSION..."
    curl -L --retry 3 -o sas "$SAS_URL"
    chmod +x sas
    # Fail loudly rather than shipping an HTML error page as the launcher.
    if ! head -n 1 sas | grep -q '^#!'; then
        echo "Downloaded sas does not look like a script" >&2
        rm -f sas
        exit 1
    fi
fi

if [ ! -x "squashfuse" ]; then
    echo "Downloading squashfuse for $ARCH..."
    curl -L --retry 3 -o squashfuse "$SQUASHFUSE_URL"
    chmod +x squashfuse
fi

echo "Sandbox tools placed in $OUTPUT_DIR"
ls -la sas squashfuse
