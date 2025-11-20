<!-- Core project info -->
![Release](https://img.shields.io/badge/Release-Alpha-red)
[![License](https://img.shields.io/github/license/kem-a/AppManager)](https://github.com/kem-a/AppManager/blob/main/LICENSE)
![GNOME 40+](https://img.shields.io/badge/GNOME-40%2B-blue?logo=gnome)
![GTK 4](https://img.shields.io/badge/GTK-4-blue?logo=gtk)
![Vala](https://img.shields.io/badge/Vala-compiler-blue?logo=vala)
[![Stars](https://img.shields.io/github/stars/kem-a/AppManager?style=social)](https://github.com/kem-a/AppManager/stargazers)

# <img width="48" height="48" alt="org github AppManager" src="https://github.com/user-attachments/assets/57e52017-df9e-49ac-8490-bc0db6e6a00e" /> AppManager

AppManager is a Libadwaita-powered desktop utility that makes installing and uninstalling AppImages on GNOME 45–49 painless. Double-click any `.AppImage` to open a macOS-style drag-and-drop sheet, pick between portable or extracted modes, and AppManager will move/extract the payload, wire up desktop entries, copy icons, and keep Nautilus context menus in sync.

<img width="493" height="320" alt="Screenshot From 2025-11-20 10-44-56" src="https://github.com/user-attachments/assets/69d2ff59-b816-46fb-a581-851f0c3c7921" />


## Features

- 📦 **Drag-and-drop installer** — mimics the familiar App→Applications flow, showing the AppImage icon on the left and your `~/Applications` folder on the right.
- 🧠 **Smart install modes** — automatically chooses between portable (move the AppImage) and extracted (unpack to `~/Applications/.installed/AppRun`) while letting you override it.
- 🗂️ **Desktop integration** — extracts the bundled `.desktop` file via `7z`, rewrites `Exec` and `Icon`, and stores it in `~/.local/share/applications`.
- 📋 **Install registry + preferences** — main window lists installed apps, default mode, and cleanup behaviors, all stored with GSettings.
- 📁 **Nautilus context menus** — right-click `Install AppImage` or `Move AppImage to Trash`, with menu visibility based on the shared installation registry.

## Requirements

- GNOME 45–49 desktop
- `valac`, `meson`, `ninja`
- Libraries: `libadwaita-1`, `gtk4`, `gio-2.0`, `glib-2.0`, `json-glib-1.0`, `gee-0.8`
- Optional (but recommended): `libnautilus-extension-4` for context menus
- Runtime tools: `7z`/`p7zip-full`

## Build & Install

```bash
meson setup build
meson compile -C build
meson install -C build --destdir "$HOME/.local"
```

If you prefer a true per-user install (no post-install relocation), configure Meson to use your local prefix directly:

```bash
meson setup build -Dprefix=$HOME/.local
meson compile -C build
meson install -C build
```

> **Note:** Adjust the `--destdir` or run `meson install -C build` with elevated privileges if you want a system-wide installation. After installing, refresh desktop databases with `update-desktop-database ~/.local/share/applications`.

## Usage

- **Double-click** a `.AppImage`: AppManager claims the `application/x-iso9660-appimage` MIME type, shows the drag window, and installs after you drag the icon onto `~/Applications` (or click Install).
- **Preferences**: Launch AppManager from the application menu to tweak defaults and review installed items.
- **Nautilus actions**: Right-click a `.AppImage` to install or, if already installed, remove it. Removal trashes/mops up files, desktop entries, and icons.
- **CLI helpers**: `app-manager --install /path/to/AppImage`, `app-manager --uninstall /path/or/checksum`, and `app-manager --is-installed /path/to/AppImage` for scripting.

## Development Notes

- Shared logic (installer, registry, metadata) lives under `src/core/` and is reused by both the UI and Nautilus extension.
- Temporary extraction directories live under `/tmp/appmgr-*` and are auto-cleaned based on the `auto-clean-temp` preference.
- Install metadata persists in `~/.local/share/app-manager/installations.json`.

See `docs/ARCHITECTURE.md` for deeper internals and extension flows.
