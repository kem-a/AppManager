<!-- Core project info -->
[![Download](https://img.shields.io/badge/Download-latest-blue)](https://github.com/kem-a/AppManager/releases/latest)
[![Release](https://img.shields.io/github/v/release/kem-a/AppManager?semver)](https://github.com/kem-a/AppManager/releases/latest)
[![License](https://img.shields.io/github/license/kem-a/AppManager)](https://github.com/kem-a/AppManager/blob/main/LICENSE)
![GNOME 40+](https://img.shields.io/badge/GNOME-40%2B-blue?logo=gnome)
![GTK 4](https://img.shields.io/badge/GTK-4-blue?logo=gtk)
![Vala](https://img.shields.io/badge/Vala-compiler-blue?logo=vala)
[![Stars](https://img.shields.io/github/stars/kem-a/AppManager?style=social)](https://github.com/kem-a/AppManager/stargazers)

# <img width="48" height="48" alt="org github AppManager" src="https://github.com/user-attachments/assets/57e52017-df9e-49ac-8490-bc0db6e6a00e" /> AppManager

AppManager is a GTK/Libadwaita developed desktop utility in Vala that makes installing and uninstalling AppImages on Linux desktop painless. Double-click any `.AppImage` to open a macOS-style drag-and-drop window, just drag to install and AppManager will move the app, wire up desktop entries, and copy icons.


<img width="503" height="320" alt="Screenshot From 2025-11-22 11-30-42" src="https://github.com/user-attachments/assets/ddd36694-b38d-452d-a5eb-8bca1c329a1f" />


## Features

- **Drag-and-drop installer** - mimics the familiar macOS Applications install flow.
- **Smart install modes** - can choose between portable (move the AppImage) and extracted (unpack to `~/Applications/.installed/AppRun`) while letting you override it.
- **Desktop integration** - extracts the bundled `.desktop` file via `7z` or `dwarfs`, rewrites `Exec` and `Icon`, and stores it in `~/.local/share/applications`.
- **Simple uninstall** - right click in app drawer and choose `Move to Trash`, can uninstall in AppManager or simply delete from `~/Applications` folder.
- **Install registry + preferences** - main window lists installed apps, default mode, and cleanup behaviors, all stored with GSettings.
- **Background update checks** - optional portal-backed checks with user-granted permission, interval control, and a notification when updates are found.

## Requirements

- `valac`, `meson`, `ninja`
- Libraries: `libadwaita-1`, `gtk4`, `gio-2.0`, `glib-2.0`, `json-glib-1.0`, `gee-0.8`, `libsoup-3.0`, `libportal` (>= 0.6), `libportal-gtk4` (>= 0.6)
- Runtime tools: `7z`/`p7zip-full`, `dwarfs`, `dwarfsextract`

## Install

[Download](https://github.com/kem-a/AppManager/releases) latest app version and run self install, for example:

```sh
chmod +x app-manager-1.0.0-beta-x86_64.AppImage
./app-manager-1.0.0-beta-x86_64.AppImage --install app-manager-1.0.0-beta-x86_64.AppImage
```

## Build

<details> <summary> <H4>Install development dependencies</H4> <b>(click to open)</b> </summary>

Install the development packages required to build AppManager on each distribution:

- **Debian / Ubuntu:**

```bash
sudo apt install valac meson ninja-build pkg-config libadwaita-1-dev libgtk-4-dev libglib2.0-dev libjson-glib-dev libgee-0.8-dev libgirepository1.0-dev libsoup-3.0-dev libportal-dev libportal-gtk4-dev p7zip-full
```

- **Fedora:**

```bash
sudo dnf install vala meson ninja-build gtk4-devel libadwaita-devel glib2-devel json-glib-devel libgee-devel libsoup3-devel libportal-devel p7zip p7zip-plugins
```

- **Arch Linux / Manjaro:**

```bash
sudo pacman -S vala meson ninja gtk4 libadwaita glib2 json-glib gee libsoup libportal p7zip
```
</details>

Default setup
```bash
meson setup build
```

Or if you prefer user Home install

```bash
meson setup build --prefix=$HOME/.local
```

Build and install
```bash
meson compile -C build
meson install -C build
```

## CLI helpers

- Install an AppImage: `app-manager --install /path/to/app.AppImage`
- Uninstall by path or checksum: `app-manager --uninstall /path/or/checksum`
- Check if installed: `app-manager --is-installed /path/to/app.AppImage`
- Run a background update check: `app-manager --background-update`
- Show version or help: `app-manager --version` / `app-manager --help`

## License
GPL-3.0-or-later. See [LICENSE](./LICENSE).
