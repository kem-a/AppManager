#!/bin/sh
#
# Build AnyLinux AppImage for AppManager using quick-sharun + sharun
#
# Produces a truly portable AppImage that works on any Linux distro,
# including old glibc, musl-based, and non-FHS systems.
#
# The script auto-detects whether it's running inside Arch Linux.
# If not, it will use podman to run itself inside a container.
#
# Usage:  ./scripts/make-anyimage.sh
# Output: ./build-anyimage/dist/AppManager-<version>-anylinux-<arch>.AppImage
#

set -eu

CONTAINER_IMAGE="ghcr.io/pkgforge-dev/archlinux:latest"
CONTAINER_NAME="appmanager-anylinux-build"

# ── Container bootstrap ─────────────────────────────────────────────
# If not running inside the Arch container, re-exec inside one.
_inside_arch() {
    [ -f /etc/arch-release ] 2>/dev/null
}

if ! _inside_arch; then
    if ! command -v podman >/dev/null 2>&1; then
        echo "Error: podman is required to build outside of Arch Linux."
        echo "Install it with your package manager, e.g.:"
        echo "  sudo dnf install podman   # Fedora"
        echo "  sudo apt install podman   # Debian/Ubuntu"
        exit 1
    fi

    # Check if image is available locally
    if ! podman image exists "$CONTAINER_IMAGE" 2>/dev/null; then
        printf "Arch container image not found locally.\n"
        printf "Pull %s? [Y/n] " "$CONTAINER_IMAGE"
        read -r answer </dev/tty || answer=""
        case "$answer" in
            [nN]*) echo "Aborted."; exit 1 ;;
        esac
        podman pull "$CONTAINER_IMAGE"
    fi

    # Reuse an existing container if available, otherwise create one.
    # This avoids re-downloading packages on every build.
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        echo "=== Reusing existing Arch container ($CONTAINER_NAME) ==="
        exec podman start -ai "$CONTAINER_NAME"
    else
        echo "=== Creating Arch Linux container ($CONTAINER_NAME) ==="
        exec podman run \
            -v "$PWD":/src:Z \
            -w /src \
            --name "$CONTAINER_NAME" \
            "$CONTAINER_IMAGE" \
            sh scripts/make-anyimage.sh
    fi
fi

# ── From here on we are inside Arch Linux ────────────────────────────

ARCH=$(uname -m)
SHARUN_URL="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/quick-sharun.sh"
DEBLOATED_URL="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/get-debloated-pkgs.sh"

# ── Install build dependencies ──────────────────────────────────────
echo "Installing build dependencies..."
echo "---------------------------------------------------------------"
pacman -Syu --noconfirm \
    base-devel \
    meson \
    vala \
    glib2 \
    gtk4 \
    libadwaita \
    json-glib \
    libgee \
    libsoup3 \
    gvfs \
    desktop-file-utils \
    squashfs-tools \
    wget \
    xorg-server-xvfb \
    zsync

# ── Install debloated packages ──────────────────────────────────────
echo "Installing debloated packages..."
echo "---------------------------------------------------------------"
if command -v get-debloated-pkgs >/dev/null 2>&1; then
    get-debloated-pkgs --add-common --prefer-nano
else
    wget --retry-connrefused --tries=30 "$DEBLOATED_URL" -O /tmp/get-debloated-pkgs.sh
    chmod +x /tmp/get-debloated-pkgs.sh
    /tmp/get-debloated-pkgs.sh --add-common --prefer-nano
fi

# ── Build and install app-manager ────────────────────────────────────
echo "Building app-manager..."
echo "---------------------------------------------------------------"
# Use a separate build dir to avoid conflicts with the host build/
rm -rf build-anyimage
meson setup build-anyimage --prefix=/usr \
    -Dbundle_dwarfs=true \
    -Dbundle_zsync=true \
    -Dbundle_unsquashfs=false
meson compile -C build-anyimage
meson install -C build-anyimage

# ── Install bundled libraries needed by fetched tools ────────────────
# The fetch-zsync-tools.sh script extracts zsync2 from an AppImage that
# was built against OpenSSL 1.1.  It also extracts the missing .so files
# into build-anyimage/lib/, but meson only installs the binary.
# Copy those libs to the system so quick-sharun's ldd check passes.
if [ -d build-anyimage/lib ]; then
    echo "Installing bundled libraries for zsync2..."
    cp -v build-anyimage/lib/*.so* /usr/lib/ 2>/dev/null || true
    ldconfig 2>/dev/null || true
fi

# ── Get version ──────────────────────────────────────────────────────
VERSION=$(meson introspect build-anyimage --projectinfo 2>/dev/null \
    | awk -F'"' '/"version"/{print $4}')

# ── Configure AppImage ───────────────────────────────────────────────
export ARCH VERSION
export APPDIR=./build-anyimage/AppDir
export OUTPATH=./build-anyimage/dist
export OUTNAME="AppManager-${VERSION}-anylinux-${ARCH}.AppImage"
export UPINFO="gh-releases-zsync|kem-a|AppManager|latest|*anylinux*${ARCH}.AppImage.zsync"
export ICON=/usr/share/icons/hicolor/scalable/apps/com.github.AppManager.svg
export DESKTOP=/usr/share/applications/com.github.AppManager.desktop
export ANYLINUX_LIB=1

# ── Download quick-sharun if not already available ───────────────────
if command -v quick-sharun >/dev/null 2>&1; then
    QS=quick-sharun
else
    wget --retry-connrefused --tries=30 "$SHARUN_URL" -O /tmp/quick-sharun
    chmod +x /tmp/quick-sharun
    QS=/tmp/quick-sharun
fi

# ── Bundle with quick-sharun ────────────────────────────────────────
echo "Bundling AppImage..."
echo "---------------------------------------------------------------"

# Bundle main binary + helper tools invoked as subprocesses.
# quick-sharun will auto-detect GTK4, libadwaita, and all their deps.
# The helper tools (dwarfs, zsync2, unsquashfs) are installed
# by meson to /usr/bin — they need to be passed explicitly since the
# app invokes them as child processes, not via dynamic linking.
#
# Additional notes:
#   - unsquashfs is provided by the squashfs-tools Arch package (installed via pacman)

"$QS" \
    /usr/bin/app-manager \
    /usr/bin/dwarfsextract \
    /usr/bin/zsync2 \
    /usr/bin/unsquashfs
    
#   - GIO modules for TLS and proxy are needed since the app uses libsoup3 for networking
#   - this has been fixed upstream, but let's keep an eye on it https://github.com/pkgforge-dev/Anylinux-AppImages/pull/340   
#   /usr/lib/gio/modules/libgiognomeproxy.so \
#   /usr/lib/gio/modules/libgiognutls.so \
#   /usr/lib/gio/modules/libgiolibproxy.so

# ── Fix locale directory after quick-sharun debloating ────────────────
# quick-sharun's DEBLOAT_LOCALE:
#   1. Deletes .mo files not matching a bundled binary name (removes libadwaita.mo)
#   2. Only deletes regular files — broken symlinks (iso_*.mo) are left behind
#   3. Leaves empty/junk language dirs (e.g. ru/) that the app doesn't ship
#
# Fix: remove broken symlinks, purge unwanted language dirs, restore libadwaita.mo.
echo "Cleaning up locale directory..."

# Remove broken symlinks left by debloating
find "$APPDIR"/share/locale -xtype l -delete 2>/dev/null || true

# Remove language directories not in our LINGUAS
for lang_dir in "$APPDIR"/share/locale/*/; do
    [ -d "$lang_dir" ] || continue
    lang="${lang_dir%/}"
    lang="${lang##*/}"
    if ! grep -qx "$lang" po/LINGUAS; then
        rm -rf "$lang_dir"
    fi
done

# Restore libadwaita translations for our languages
echo "Restoring libadwaita locale files..."
while IFS= read -r lang; do
    case "$lang" in \#*|"") continue ;; esac
    src="/usr/share/locale/$lang/LC_MESSAGES/libadwaita.mo"
    dst="$APPDIR/share/locale/$lang/LC_MESSAGES"
    [ -f "$src" ] && [ -d "$dst" ] && cp "$src" "$dst/"
done < po/LINGUAS

# ── Create AppImage ─────────────────────────────────────────────────
"$QS" --make-appimage

# ── Clean up intermediate artifacts ─────────────────────────────────
rm -rf "$APPDIR"
rm -f "$OUTPATH"/appinfo

echo ""
echo "=== AnyLinux AppImage created ==="
echo "Output: $OUTPATH/$OUTNAME"
