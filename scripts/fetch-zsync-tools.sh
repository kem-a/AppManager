#!/bin/sh
# Download zsync2 binary for bundling with AppManager
# Usage: fetch-zsync-tools.sh <arch> <output_dir>
# zsync2 is used for efficient delta updates of AppImages

set -e

ARCH="${1:-x86_64}"
OUTPUT_DIR="${2:-.}"

# zsync2 releases from AppImageCommunity
ZSYNC2_REPO="AppImageCommunity/zsync2"

# Map architecture names
case "$ARCH" in
    x86_64|amd64)
        ZSYNC2_ARCH="x86_64"
        ;;
    aarch64|arm64)
        ZSYNC2_ARCH="aarch64"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# Get the latest release asset URL using GitHub API
echo "Finding latest zsync2 release for ${ZSYNC2_ARCH}..."
ZSYNC2_URL=$(curl -s "https://api.github.com/repos/${ZSYNC2_REPO}/releases/latest" | \
    grep -o "https://github.com/${ZSYNC2_REPO}/releases/download/[^\"]*-${ZSYNC2_ARCH}.AppImage\"" | \
    head -1 | tr -d '"')

if [ -z "$ZSYNC2_URL" ]; then
    # Fallback: search in all releases
    ZSYNC2_URL=$(curl -s "https://api.github.com/repos/${ZSYNC2_REPO}/releases" | \
        grep -o "https://github.com/${ZSYNC2_REPO}/releases/download/[^\"]*-${ZSYNC2_ARCH}.AppImage\"" | \
        head -1 | tr -d '"')
fi

if [ -z "$ZSYNC2_URL" ]; then
    echo "Error: Could not find zsync2 AppImage for ${ZSYNC2_ARCH}"
    exit 1
fi

# Download zsync2 AppImage directly as the zsync2 binary
# We use the AppImage directly since the extracted binary has library dependencies
echo "Downloading zsync2 from: $ZSYNC2_URL"
curl -L -o "zsync2" "$ZSYNC2_URL"
chmod +x "zsync2"

echo "zsync2 downloaded to $OUTPUT_DIR"
ls -la zsync2
