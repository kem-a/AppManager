#!/bin/bash
#
# Build AppImage for AppManager using appimagetool
#
# Usage: ./scripts/make-appimage.sh [build_dir]
#
# Requirements:
#   - Compiled build in the build directory
#   - appimagetool (will be downloaded if not found)
#   - desktop-file-utils (for validation)
#   - chrpath (optional, for removing rpath)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${1:-$PROJECT_DIR/build}"

# App info
APP_NAME="AppManager"
APP_ID="com.github.AppManager"
BINARY_NAME="app-manager"

# Get version from meson introspect or fallback to meson.build
if command -v jq &>/dev/null && [ -f "$BUILD_DIR/meson-info/intro-projectinfo.json" ]; then
    VERSION=$(jq -r '.version' "$BUILD_DIR/meson-info/intro-projectinfo.json")
else
    VERSION=$(grep -oP "version:\s*'\K[^']+" "$PROJECT_DIR/meson.build" | head -1)
fi
ARCH=$(uname -m)

# Output
PACKAGE_DIR="$PROJECT_DIR"
APPIMAGE_NAME="$APP_NAME-${VERSION}-${ARCH}.AppImage"

echo "=== Building AppImage for $APP_NAME v$VERSION ==="
echo "Build directory: $BUILD_DIR"
echo "Output: $PACKAGE_DIR/$APPIMAGE_NAME"

# Verify build exists
if [ ! -f "$BUILD_DIR/src/$BINARY_NAME" ]; then
    echo "Error: Binary not found at $BUILD_DIR/src/$BINARY_NAME"
    echo "Please run 'meson compile -C build' first."
    exit 1
fi

# Check/download appimagetool
APPIMAGETOOL=""
if command -v appimagetool &>/dev/null; then
    APPIMAGETOOL="appimagetool"
elif [ -f "$PROJECT_DIR/appimagetool" ]; then
    APPIMAGETOOL="$PROJECT_DIR/appimagetool"
else
    echo "Downloading appimagetool..."
    curl -Lo "$PROJECT_DIR/appimagetool" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$PROJECT_DIR/appimagetool"
    APPIMAGETOOL="$PROJECT_DIR/appimagetool"
fi

# Create temporary install tree using meson install
DESTDIR=$(mktemp -d)
APPDIR=$(mktemp -d)
trap "rm -rf '$DESTDIR' '$APPDIR'" EXIT
# mktemp creates 0700 dirs; appimagetool requires the AppDir to be world-readable
chmod 755 "$APPDIR"

# Get the prefix from the build configuration
PREFIX=$(meson introspect "$BUILD_DIR" --buildoptions | jq -r '.[] | select(.name == "prefix") | .value')
echo "Build prefix: $PREFIX"

echo "Installing to staging directory..."
meson install -C "$BUILD_DIR" --destdir "$DESTDIR" --quiet 2>/dev/null || \
    meson install -C "$BUILD_DIR" --destdir "$DESTDIR"

# Installed files are at DESTDIR + PREFIX, we need them under APPDIR/usr
INSTALL_ROOT="$DESTDIR$PREFIX"

if [ ! -d "$INSTALL_ROOT" ]; then
    echo "Error: Install root not found at $INSTALL_ROOT"
    echo "Contents of DESTDIR:"
    find "$DESTDIR" -type d | head -20
    exit 1
fi

echo "Creating AppDir structure..."

# Copy installed files to AppDir/usr
mkdir -p "$APPDIR/usr"
cp -a "$INSTALL_ROOT"/* "$APPDIR/usr/"

# DwarFS tools are now installed directly to bin via meson

# Bundle shared libraries that may not be present on non-GNOME systems
# (e.g. KDE-based distros like CachyOS KDE)
mkdir -p "$APPDIR/usr/lib"

bundle_lib() {
    local lib_name="$1"
    local lib_path
    # Resolve the versioned .so path using the linker (most reliable)
    lib_path=$(ldd "$BUILD_DIR/src/$BINARY_NAME" 2>/dev/null | grep "$lib_name" | awk '{print $3}' | head -1)
    if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
        cp -L "$lib_path" "$APPDIR/usr/lib/"
        echo "Bundled: $lib_name → $(basename "$lib_path") ($lib_path)"
    else
        echo "Warning: $lib_name not found via ldd, skipping"
    fi
    if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
        cp -L "$lib_path" "$APPDIR/usr/lib/"
        echo "Bundled: $lib_name ($lib_path)"
    else
        echo "Warning: $lib_name not found on system, skipping"
    fi
}

bundle_lib "libgee-0.8.so"
bundle_lib "libsoup-3.0.so"

# Create AppRun script that sets up environment for GSettings schemas
# and bundled libraries
cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export APPDIR="$HERE"
export LD_LIBRARY_PATH="$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas:${GSETTINGS_SCHEMA_DIR:-}"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export PATH="$HERE/usr/bin:$PATH"
exec "$HERE/usr/bin/app-manager" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# Desktop and icon at AppDir root
install -Dm644 "$APPDIR/usr/share/applications/$APP_ID.desktop" "$APPDIR/$APP_ID.desktop"
install -Dm644 "$APPDIR/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg" "$APPDIR/$APP_ID.svg"

# .DirIcon must be a PNG; render one from the SVG if a converter is available
if command -v rsvg-convert &>/dev/null; then
    rsvg-convert -w 256 -h 256 "$APPDIR/$APP_ID.svg" -o "$APPDIR/$APP_ID.png"
elif command -v magick &>/dev/null; then
    magick -background none -density 384 "$APPDIR/$APP_ID.svg" -resize 256x256 "$APPDIR/$APP_ID.png"
else
    echo "Warning: rsvg-convert/magick not found, .DirIcon will not be a PNG"
fi
if [ -f "$APPDIR/$APP_ID.png" ]; then
    chmod 644 "$APPDIR/$APP_ID.png"
    ln -sf "$APP_ID.png" "$APPDIR/.DirIcon"
fi

# Add X-AppImage-Version to desktop file (used by AppManager to detect version during install)
if ! grep -q "^X-AppImage-Version=" "$APPDIR/$APP_ID.desktop"; then
    # Ensure file ends with newline before appending
    sed -i -e '$a\' "$APPDIR/$APP_ID.desktop"
    echo "X-AppImage-Version=$VERSION" >> "$APPDIR/$APP_ID.desktop"
fi

# Validate desktop file
if command -v desktop-file-validate &>/dev/null; then
    desktop-file-validate "$APPDIR/$APP_ID.desktop" || true
fi

# Remove rpath if present
if command -v chrpath &>/dev/null; then
    chrpath -d "$APPDIR/usr/bin/$BINARY_NAME" 2>/dev/null || true
fi

echo "AppDir contents:"
find "$APPDIR" -type f | head -20

# Build AppImage
echo "Creating AppImage..."

# Build update information for zsync delta updates
# Format: gh-releases-zsync|owner|repo|latest|pattern.zsync
# The pattern must match the zsync file uploaded to GitHub releases
UPDATE_INFO="gh-releases-zsync|kem-a|AppManager|latest|AppManager-*-${ARCH}.AppImage.zsync"

echo "Update information: $UPDATE_INFO"

# Create AppImage with embedded update information
ARCH=$ARCH "$APPIMAGETOOL" --updateinformation "$UPDATE_INFO" "$APPDIR" "$PACKAGE_DIR/$APPIMAGE_NAME"

# Generate .zsync file for delta updates
# This file should be uploaded alongside the AppImage to GitHub releases
if command -v zsyncmake &>/dev/null; then
    echo "Generating zsync file..."
    zsyncmake -u "$APPIMAGE_NAME" -o "$PACKAGE_DIR/$APPIMAGE_NAME.zsync" "$PACKAGE_DIR/$APPIMAGE_NAME"
    echo "Zsync file: $PACKAGE_DIR/$APPIMAGE_NAME.zsync"
else
    echo "Note: zsyncmake not found. Install zsync to generate .zsync file for delta updates."
fi

# Get file size
SIZE=$(du -h "$PACKAGE_DIR/$APPIMAGE_NAME" | cut -f1)

echo ""
echo "=== AppImage created successfully ==="
echo "Output: $PACKAGE_DIR/$APPIMAGE_NAME"
echo "Size: $SIZE"
echo "Update info: $UPDATE_INFO"
echo ""
echo "To enable zsync delta updates, upload both files to GitHub releases:"
echo "  - $APPIMAGE_NAME"
echo "  - $APPIMAGE_NAME.zsync (if generated)"
echo ""
echo "To run: ./$APPIMAGE_NAME"
