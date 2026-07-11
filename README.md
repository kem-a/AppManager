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

It also doesn't require FUSE to run, thanks to the [uruntime](https://github.com/VHSgunzo/uruntime)

## Preview

<img width="1600" height="1237" alt="Screenshot From 2026-01-11 00-24-35" src="https://github.com/user-attachments/assets/acc7d1b8-6e07-4540-af6c-cf3167345252" />

## Features

- **Drag-and-drop installer**: Mimics the familiar macOS Applications install flow.
- **Smart install modes**: Can choose between portable (move the AppImage) and extracted (unpack to `~/Applications/.installed/AppRun`) while letting you override it.
- **True isolated portable mode**: Optionally creates `.home` and `.config` folders next to the AppImage so the app stores all its data alongside itself — fully self-contained and portable.
- **Side-by-side installs**: Install multiple copies or versions of the same app; extra copies get a numbered suffix (e.g. `Bitwarden` and `Bitwarden 2`) with their own desktop entries and icons.
- **Desktop integration**: Extracts the bundled `.desktop` file via `unsquashfs` or `dwarfsextract`, rewrites `Exec` and `Icon`, and stores it in `~/.local/share/applications`.
- **Simple uninstall**: Right click in app drawer and choose `Move to Trash`, can uninstall in AppManager or simply delete from `~/Applications` folder.
- **Install registry + preferences**: Main window lists installed apps, default mode, and cleanup behaviors, all stored with GSettings.
- **Background app updates**: Optional automatic update checks with configurable interval (daily, weekly, monthly) and notifications when updates are found.
- **GitHub authentication**: Optionally store a GitHub personal access token to raise the API rate limit from 60 to 5,000 requests per hour. The token is kept in the system keyring (GNOME Keyring, KWallet, KeePassXC) when a Secret Service is available, and otherwise in an AES-256-GCM blob bound to the machine and user account, so a synced or copied config file is useless elsewhere.

## Requirements

- `valac`, `meson`, `ninja`
- Libraries: `libadwaita-1` (>= 1.6), `gtk4`, `gio-2.0`, `glib-2.0`, `gmodule-2.0`, `json-glib-1.0`, `gee-0.8`, `libsoup-3.0`, `libsecret-1`, `gnutls` (>= 3.6.13)
- Runtime tools: `unsquashfs`, `dwarfsextract`

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

Install the development packages required to build AppManager on each distribution:

- **Debian / Ubuntu:**

```bash
sudo apt install valac meson ninja-build pkg-config libadwaita-1-dev libgtk-4-dev libglib2.0-dev libjson-glib-dev libgee-0.8-dev libgirepository1.0-dev libsoup-3.0-dev cmake desktop-file-utils jq libzstd-dev
```

- **Fedora:**

```bash
sudo dnf install vala meson ninja-build gtk4-devel libadwaita-devel glib2-devel json-glib-devel libgee-devel libsoup3-devel cmake desktop-file-utils jq libzstd-devel
```

- **Arch Linux / Manjaro:**

```bash
sudo pacman -S vala meson ninja gtk4 libadwaita glib2 json-glib libgee libsoup cmake desktop-file-utils jq libzstd-devel
```

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

## CLI helpers

- Install an AppImage: `app-manager install /path/to/app.AppImage`
- Install side by side, keeping the existing app: `app-manager install --keep-both /path/to/app.AppImage`
- Uninstall by path or checksum: `app-manager uninstall /path/or/checksum`
- Update a single installed AppImage: `app-manager update /path/or/checksum`
- Update all installed AppImages: `app-manager --update-all`
- List available updates (no install): `app-manager --update-check`
- Check if installed: `app-manager --is-installed /path/to/app.AppImage`
- Run a background update check: `app-manager --background-update`
- Show version or help: `app-manager --version` / `app-manager --help`

## Translations

AppManager supports multiple languages. Want to help translate to your language? See the [translation guide](po/README.md) for instructions.

Currently supported: German, Spanish, Estonian, Finnish, French, Italian, Japanese, Lithuanian, Latvian, Norwegian, Portuguese (Brazil), Swedish, Chinese (Simplified).

## Reviews

<a href="https://itsfoss.com/appmanager/">
<img width="150" height="54" alt="itsfoss" src="https://itsfoss.com/content/images/size/w300/format/webp/2026/01/itsfoss-logo.png" />
</a>

*App of the Week*
