<!-- Core project info -->
[![Download](https://img.shields.io/badge/Download-latest-blue)](https://github.com/kem-a/AppManager/releases/latest)
[![Release](https://img.shields.io/github/v/release/kem-a/AppManager?semver)](https://github.com/kem-a/AppManager/releases/latest)
[![License](https://img.shields.io/github/license/kem-a/AppManager)](https://github.com/kem-a/AppManager/blob/main/LICENSE)
![GNOME 40+](https://img.shields.io/badge/GNOME-40%2B-blue?logo=gnome)
![GTK 4](https://img.shields.io/badge/GTK-4-blue?logo=gtk)
![Vala](https://img.shields.io/badge/Vala-compiler-blue?logo=vala)
[![Stars](https://img.shields.io/github/stars/kem-a/AppManager?style=social)](https://github.com/kem-a/AppManager/stargazers)

# <img width="48" height="48" alt="com github AppManager" src="https://github.com/user-attachments/assets/879952cc-d0b3-48c8-aa35-1132c7423fe0" /> AppManager

**AppManager** is a GTK/Libadwaita developed desktop utility in **Vala** that makes installing and uninstalling AppImages on Linux desktop painless. It supports both SquashFS and DwarFS AppImage formats, features a seamless background **auto-update** process, and leverages **zsync** delta updates for efficient bandwidth usage. Double-click any `.AppImage` to open a macOS-style drag-and-drop window, just drag to install and AppManager will move the app, wire up desktop entries, and copy icons.

<img width="1600" height="1237" alt="Screenshot From 2026-01-11 00-24-35" src="https://github.com/user-attachments/assets/acc7d1b8-6e07-4540-af6c-cf3167345252" />

## Features

- **Drag-and-drop installer**: Mimics the familiar macOS Applications install flow.
- **Smart install modes**: Can choose between portable (move the AppImage) and extracted (unpack to `~/Applications/.installed/AppRun`) while letting you override it.
- **Desktop integration**: Extracts the bundled `.desktop` file via `7z` or `dwarfs`, rewrites `Exec` and `Icon`, and stores it in `~/.local/share/applications`.
- **Simple uninstall**: Right click in app drawer and choose `Move to Trash`, can uninstall in AppManager or simply delete from `~/Applications` folder.
- **Install registry + preferences**: Main window lists installed apps, default mode, and cleanup behaviors, all stored with GSettings.
- **Background app updates**: Optional automatic update checks with configurable interval (daily, weekly, monthly) and notifications when updates are found.

## Requirements

- `valac`, `meson`, `ninja`
- Libraries: `libadwaita-1` (>= 1.6), `gtk4`, `gio-2.0`, `glib-2.0`, `json-glib-1.0`, `gee-0.8`, `libsoup-3.0`
- Runtime tools: `7z`/`p7zip-full`, `dwarfs`, `dwarfsextract`

## Install

Simply [download](https://github.com/kem-a/AppManager/releases) latest app version, enable execute and double click to install it.

## Build

<details> <summary> <H4>Install development dependencies</H4> <b>(click to open)</b> </summary>

Install the development packages required to build AppManager on each distribution:

- **Debian / Ubuntu:**

```bash
sudo apt install valac meson ninja-build pkg-config libadwaita-1-dev libgtk-4-dev libglib2.0-dev libjson-glib-dev libgee-0.8-dev libgirepository1.0-dev libsoup-3.0-dev p7zip-full cmake desktop-file-utils jq
```

- **Fedora:**

```bash
sudo dnf install vala meson ninja-build gtk4-devel libadwaita-devel glib2-devel json-glib-devel libgee-devel libsoup3-devel p7zip p7zip-plugins cmake desktop-file-utils jq
```

- **Arch Linux / Manjaro:**

```bash
sudo pacman -S vala meson ninja gtk4 libadwaita glib2 json-glib libgee libsoup p7zip cmake desktop-file-utils jq
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
- Uninstall by path or checksum: `app-manager uninstall /path/or/checksum`
- Check if installed: `app-manager --is-installed /path/to/app.AppImage`
- Run a background update check: `app-manager --background-update`
- Show version or help: `app-manager --version` / `app-manager --help`

## Translations

AppManager supports multiple languages. Want to help translate to your language? See the [translation guide](po/README.md) for instructions.

Currently supported: German, Spanish, Estonian, Finnish, French, Italian, Japanese, Lithuanian, Latvian, Norwegian, Portuguese (Brazil), Swedish, Chinese (Simplified).

## License

GPL-3.0-or-later. See [LICENSE](./LICENSE).
