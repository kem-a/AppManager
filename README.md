<!-- Core project info -->
[![Download](https://img.shields.io/badge/Download-latest-blue)](https://github.com/kem-a/AppManager/releases/latest)
[![Release](https://img.shields.io/github/v/release/kem-a/AppManager?semver)](https://github.com/kem-a/AppManager/releases/latest)
[![License](https://img.shields.io/github/license/kem-a/AppManager)](https://github.com/kem-a/AppManager/blob/main/LICENSE)
[![AnyLinux](https://img.shields.io/badge/AnyLinux-compatible-green?logo=linux&logoColor=white)](https://pkgforge-dev.github.io/Anylinux-AppImages/)
![GTK 4](https://img.shields.io/badge/GTK-4-blue?logo=gtk)
![Vala](https://img.shields.io/badge/Vala-compiler-blue?logo=vala)
[![Stars](https://img.shields.io/github/stars/kem-a/AppManager?style=social)](https://github.com/kem-a/AppManager/stargazers)

# <img width="48" height="48" alt="com github AppManager" src="https://github.com/user-attachments/assets/879952cc-d0b3-48c8-aa35-1132c7423fe0" /> AppManager

**AppManager** is a GTK/Libadwaita developed desktop utility in **Vala** that makes installing and uninstalling AppImages on Linux desktop painless. It supports both SquashFS and DwarFS AppImage formats, features a seamless background **auto-update** process, and leverages **zsync** delta updates for efficient bandwidth usage. Double-click any `.AppImage` to open a macOS-style drag-and-drop window, just drag to install and AppManager will move the app, wire up desktop entries, and copy icons.

> **This AppImage bundles everything and it should work on any Linux distro, including old and musl-based ones.**

AppManager doesn't require FUSE to run, thanks to the [uruntime](https://github.com/VHSgunzo/uruntime)

## Preview

<img width="1600" height="1237" alt="Screenshot From 2026-01-11 00-24-35" src="https://github.com/user-attachments/assets/acc7d1b8-6e07-4540-af6c-cf3167345252" />

## Features

- **Drag-and-drop installer**: Mimics the familiar macOS Applications install flow.
- **Portable or extracted**: Apps are installed portable (the AppImage is moved to `~/Applications`). From the app's details you can extract it to `~/Applications/.installed/<app>/` instead.
- **True isolated portable mode**: Optionally creates `.home` and `.config` folders next to the AppImage so the app stores all its data alongside itself - fully self-contained and portable.
- **Side-by-side installs**: Install multiple copies or versions of the same app; extra copies get a numbered suffix (e.g. `Bitwarden` and `Bitwarden 2`) with their own desktop entries and icons.
- **Desktop integration**: Extracts the bundled `.desktop` file via `unsquashfs` or `dwarfsextract`, rewrites `Exec` and `Icon`, and stores it in `~/.local/share/applications`.
- **Simple uninstall**: Right click in app drawer and choose `Move to Trash`, can uninstall in AppManager or simply delete from `~/Applications` folder.
- **One-click installs from the web**: Registers the `x-scheme-handler/appimg` handler, so an `appimg://install?url=…&sha256=…` link downloads the AppImage over HTTPS and verifies the supplied SHA-256 and size. Downloads matching [AppHub](https://xlc-dev.github.io/apphub/)'s catalog receive the app's sandbox template; other downloads use your normal installation defaults.
- **App library**: The main window lists installed apps with search, sorting and list or grid views. Changing the install folder in Preferences moves the installed apps along.
- **Update sources**: zsync delta updates from the AppImage's embedded update info, GitHub and GitLab releases (optionally including pre-releases), or a plain download link checked for changes.
- **Update progress**: Apps update in parallel, each with its own progress ring that follows the download, delta downloads included. A running check or update can be cancelled.
- **Background app updates**: Optional automatic update checks with configurable interval (daily, weekly, monthly), notifications when updates are found, and optional automatic installs. Each run is written to an update log.
- **Per-app customization**: Rename an app, change its icon, keywords or `StartupWMClass`, add launch arguments and environment variables, hide it from the app drawer, or add it to `$PATH`. These settings survive updates.
- **GitHub authentication**: Optionally store a GitHub personal access token to raise the API rate limit from 60 to 5,000 requests per hour and update apps from private repositories. For private repositories, use a fine-grained token with repository access and Contents (read) permission, or a classic token with the `repo` scope; organization SSO authorization may also be required. Private updates use full release-asset downloads, including when the AppImage embeds zsync update information; public delta updates are unchanged. The token is kept in the system keyring (GNOME Keyring, KWallet, KeePassXC) when a Secret Service is available, and otherwise in an AES-256-GCM blob bound to the machine and user account, so a synced or copied config file is useless elsewhere.
- **Per-app sandboxing**: Give each app a private home and control its access to personal files, network, sound, devices and desktop services. Choose a preset, customize permissions, or use an AppHub template. See the [sandboxing guide](sandboxing/README.md).

## Sandboxing

Run portable AppImages with a private home and configurable access to your files,
network, devices and desktop services. Choose **Standard** or **Strict** in an
app's **Privacy & Security** settings, or use its AppHub template.

See the [sandboxing guide](sandboxing/README.md) for setup, profiles, requirements
and known limitations.

## Requirements

- Build tools: a C compiler, `valac`, `meson` (>= 0.64), `ninja`, `pkg-config`, `gettext`, `glib-compile-resources`, `glib-compile-schemas`
- Installation tools: `gtk4-update-icon-cache` (or `gtk-update-icon-cache`, depending on the distribution) and `update-desktop-database` (from `desktop-file-utils`)
- Libraries (with development headers): `libadwaita-1` (>= 1.6), `gtk4` (>= 4.22), `glib-2.0` (>= 2.84, required by GTK 4.22), `gio-2.0`, `gio-unix-2.0`, `gmodule-2.0`, `json-glib-1.0`, `gee-0.8`, `libsoup-3.0`, `libsecret-1`, `gnutls` (>= 3.6.13)
- Default bundled helpers: `curl`, `tar`, `gzip`, `xz`, `make`, Rust (`rustc` and `cargo`, >= 1.85; current stable recommended), and development headers for zlib, liblzma and zstd. See the build options below to use host tools instead.
- AppImage packaging with `scripts/make-appimage.sh`: `bash`, `jq` and `appimagetool` (downloaded automatically if missing)
- Optional, for sandbox hardening: `libseccomp` (syscall filtering), `wayland-client` plus `wayland-scanner` (compositor-side isolation). Both are found automatically and can be turned off with `-Dseccomp=disabled` and `-Dwayland_security_context=disabled`.
- Runtime tools: `unsquashfs`, `dwarfsextract`; optionally `zsync-rs` (0.2.2 or newer, for its `--json` progress) for delta updates
- Runtime tools for sandboxing: `bwrap`, `xdg-dbus-proxy`, `fusermount3`, `squashfuse`, `dwarfs`

## Install

Simply [download](https://github.com/kem-a/AppManager/releases) latest app version, enable execute and double click to install it.

## Nix / NixOS

### Run without installation

```bash
nix run "github:kem-a/AppManager"
```

### Install permanently

```bash
nix profile install "github:kem-a/AppManager"
```

### NixOS / Home Manager

```nix
inputs.app-manager.url = "github:kem-a/AppManager";
# then add to packages:
inputs.app-manager.packages.x86_64-linux.default
```

## Build

<details> <summary> <H4>Install development dependencies</H4> <b>(click to open)</b> </summary>

Install the packages below for the default build, including bundled helpers and `jq` for AppImage packaging. Your distribution must provide the minimum library versions listed above, especially GTK >= 4.22 and libadwaita >= 1.6. The lists also include the optional sandbox-hardening libraries.

- **Debian / Ubuntu:**

```bash
sudo apt install build-essential valac meson ninja-build pkg-config gettext \
  desktop-file-utils libgtk-4-bin libadwaita-1-dev libgtk-4-dev libglib2.0-dev \
  libjson-glib-dev libgee-0.8-dev libsoup-3.0-dev libsecret-1-dev libgnutls28-dev \
  libseccomp-dev libwayland-dev curl tar gzip xz-utils rustc cargo jq \
  zlib1g-dev liblzma-dev libzstd-dev
```

- **Fedora:**

```bash
sudo dnf install gcc make vala meson ninja-build pkgconf-pkg-config gettext \
  desktop-file-utils gtk-update-icon-cache gtk4-devel libadwaita-devel glib2-devel \
  json-glib-devel libgee-devel libsoup3-devel libsecret-devel gnutls-devel \
  libseccomp-devel wayland-devel curl tar gzip xz rust cargo jq \
  zlib-devel xz-devel libzstd-devel
```

- **Arch Linux / Manjaro:**

```bash
sudo pacman -S --needed base-devel vala meson ninja gettext desktop-file-utils \
  gtk4 libadwaita glib2 json-glib libgee libsoup3 libsecret gnutls libseccomp \
  wayland curl tar gzip xz rust jq zlib zstd
```

On Arch Linux / Manjaro, `base-devel` supplies the C compiler, `make` and `pkgconf`, and `rust` supplies both `rustc` and `cargo`.

The helper-specific dependencies are:

- `curl` for downloading DwarFS, squashfuse and the unsquashfs source.
- `tar` and `xz` (`xz-utils` on Debian / Ubuntu) for extracting the DwarFS `.tar.xz` archive.
- `make`, `tar`, `gzip`, and the zlib/liblzma/zstd development headers for building `unsquashfs`. XZ support is enabled in `scripts/build-unsquashfs.sh`, so `liblzma-dev` / `xz-devel` / `xz` is still needed. LZ4 and LZO support are disabled and need no development packages.
- Rust and Cargo for building `zsync-rs`. The bundled 0.3.0 release uses Rust edition 2024, which requires Rust >= 1.85; use a current stable toolchain for its locked dependencies.

`desktop-file-utils` is needed for the desktop database update during installation. `jq` is needed by `scripts/make-appimage.sh`, but not by the Meson build itself.

</details>

Default setup

```bash
meson setup build --prefix=$HOME/.local
```

Build and install

```bash
meson compile -C build
meson install -C build
```

By default the build bundles its helper tools: it downloads `dwarfsextract` and the `dwarfs` FUSE driver and `squashfuse`, compiles `unsquashfs` from source, and builds `zsync-rs` from crates.io with `cargo`. This needs network access. To use the host's tools instead, pass any of `-Dbundle_dwarfs=false`, `-Dbundle_zsync=false`, `-Dbundle_squashfuse=false`, `-Dbundle_unsquashfs=false`.

## CLI helpers

- Open the installer window for a file: `app-manager /path/to/app.AppImage`
- Install an AppImage: `app-manager install /path/to/app.AppImage`
- Install side by side, keeping the existing app: `app-manager install --keep-both /path/to/app.AppImage`
- Uninstall by path: `app-manager uninstall /path/to/app.AppImage`
- Update a single installed AppImage: `app-manager update /path/to/app.AppImage`
- Update all installed AppImages: `app-manager --update-all`
- List available updates (no install): `app-manager --update-check`
- Check if installed: `app-manager --is-installed /path/to/app.AppImage`
- Run the background update service (started by its autostart entry): `app-manager --background-update`
- Show version or help: `app-manager --version` / `app-manager --help`
- Open a web install link: `app-manager 'appimg://install?url=https://host/App.AppImage&sha256=<hex>'`

## Translations

AppManager supports multiple languages. Want to help translate to your language? See the [translation guide](po/README.md) for instructions.

Currently supported: Arabic, Chinese (Simplified), Dutch, Estonian, Finnish, French, German, Greek, Irish, Italian, Japanese, Kazakh, Korean, Latvian, Lithuanian, Norwegian Bokmål, Polish, Portuguese (Brazil), Spanish, Swedish, Ukrainian, Vietnamese.

## Reviews

<a href="https://itsfoss.com/appmanager/">
<img width="150" height="54" alt="itsfoss" src="https://itsfoss.com/content/images/size/w300/format/webp/2026/01/itsfoss-logo.png" />
</a>

*App of the Week*
