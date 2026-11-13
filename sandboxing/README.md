# Sandboxing in AppManager

Sandboxing runs an AppImage with its own home folder and limited access to your
files, devices and desktop services. You choose the access each app needs. It
reduces what an app can reach, but does not guarantee that an app is trustworthy.

## Getting started

Open an app's details, then **Privacy & Security**, and choose a profile:

- **Standard** allows network, sound, legacy X11, notifications and the Downloads
  folder. Other personal folders stay hidden until you grant them.
- **Strict** disables those permissions. It still keeps hardware acceleration,
  media controls, tray integration and accessibility, as Standard does.
- **Custom** appears when your changes no longer match a preset or saved AppHub
  template.
- **AppHub**, when available, restores the app's downloaded store template without
  an internet connection. Folders you added stay granted.
- **Off** runs the app without AppManager's sandbox.

Accessibility is on by default and has its own switch; an AppHub template can
turn it off. Media controls and tray integration are automatic unless the template
disables them. Host themes, icons, fonts and desktop settings are shared read-only
so sandboxed apps keep your desktop appearance.

Every sandboxed app is also told when the system goes to sleep or shuts down and
when the screen locks, so password managers such as Bitwarden can lock themselves.
An app may delay sleep for a few seconds to finish locking or saving. Apps can also
register a global menu on desktops that show one. These have no switch. An AppHub
template that turns the system bus off also turns off the sleep notices.

Folder selectors offer **Off**, **Read-only**, or **Read and write**. Use **Add
folder** at the bottom of **Folders** to add other folders, then choose their
access.
The Display selector lets you choose Wayland, X11, prefer Wayland with an X11
fallback, or neither. A small shield beside an app's icon indicates sandboxing is
enabled.

To enable sandboxing for new non-store apps or grant a folder to all sandboxed
apps, open **Preferences → Security & Privacy**. Global folder grants and folders
you added supplement every profile, including Strict.

## Always-shared appearance files

To keep apps looking like your desktop, these 15 hidden paths in your real home
folder (`~/`) are **always shared read-only when present**, in every sandbox
profile, including Strict. This access has no switch; it does not share all hidden
files or your whole home folder.

```text
~/.config/gtk-3.0
~/.config/gtk-4.0
~/.config/dconf
~/.config/fontconfig
~/.config/Kvantum
~/.config/qt5ct
~/.config/qt6ct
~/.local/share/icons
~/.local/share/themes
~/.local/share/fonts
~/.gtkrc-2.0
~/.themes
~/.icons
~/.fonts
~/.local/share/gnome-shell/extensions
```

## Apps installed from AppHub

Downloads matching [AppHub](https://xlc-dev.github.io/apphub/)'s catalog receive
the store's per-app sandbox template. The downloaded URL and SHA-256 must match
the catalog before that template is applied. For example, a music player can
receive read-only Music access, while an image editor can have network and sound
disabled. The Standard-default preference applies to apps outside AppHub.

Your changes, including turning sandboxing off, survive restarts and updates.
Existing installed-app settings take precedence when an app is first recognized
as an AppHub download. Selecting **AppHub** restores the saved template. After
uninstalling and reinstalling, only folders you added are restored;
the app otherwise receives its current template or normal installation defaults.

Failed catalog checks stop a web installation rather than silently choosing
broader permissions. Templates requiring unsupported features, such as mounting
filesystems inside the sandbox, are refused. Catalog hashes check downloaded
bytes; they are not a guarantee that the app is safe.

## Requirements

Sandboxing needs **bubblewrap** (`bwrap`), **xdg-dbus-proxy** and **fusermount3**
installed on your Linux system, plus working user namespaces and FUSE. The
AppManager AppImage bundles the squashfuse and dwarfs mount drivers. Bubblewrap
and the D-Bus proxy are supplied by your distribution.

If required tools are missing or sandbox setup fails, a sandboxed app refuses to
start rather than launching without confinement. Only **portable AppImage
installs** are supported; extracted apps cannot currently be sandboxed.

## Known issues and limitations

- **Private settings and accounts.** The app starts with a separate home folder
  beside the AppImage (`<app>.sandbox`), so it may ask you to configure accounts
  and settings again. Your old real-home configuration stays intact, and turning
  sandboxing off uses it again. Existing portable `.home`/`.config` data is moved
  into the sandbox when enabled and is not moved back when disabled.
- **Online accounts and mail.** Mail and calendar apps that use GNOME Online
  Accounts need the **Online accounts** service. It also reaches Evolution Data
  Server, Contacts, Settings and passphrase prompts, so the app can access every
  configured account and its mail, calendar and contact data.
- **File access and links.** File dialogs show only visible folders. Dragging a
  file from outside may give the app a path it cannot open; grant its folder
  first. Browser links and "open containing folder" are not supported through
  desktop handoff. Symlink targets need their own access if outside granted paths.
- **Remote folders.** Network permission alone does not enable desktop remote
  filesystem browsing, such as SMB or WebDAV through GVFS.
- **Sound includes microphone access.** Playback and recording cannot currently
  be granted separately.
- **Network is all-or-nothing.** With it enabled, an app can also reach services
  on localhost. There is no per-app firewall.
- **Display isolation varies.** X11 permits clients to observe other clients'
  input and windows. Prefer Wayland when the app supports it; additional Wayland
  isolation depends on your compositor.
- **Security keys must be plugged in first.** The **Security keys** switch shares
  FIDO2 and U2F keys only, not other USB or input devices. Keys are shared when
  the app starts, so plug the key in before starting the app.
- **Broad grants weaken isolation.** Full session bus, your whole home, or device
  access gives an app more reach. Game-controller access also exposes other input
  devices. Only grant what the app needs.
- **Location uses AppManager's switch.** Your desktop may not prompt or list the
  app separately because requests pass through AppManager's proxy. Use its
  Location switch to control that app; the desktop's global switch still applies.
- **Browser extension pairing.** Apps that pair with a browser extension, such as
  Bitwarden's browser unlock, register in the browser's native-messaging folder,
  which the separate home folder hides. Grant `~/.mozilla/native-messaging-hosts`
  (Firefox) or `~/.config/<browser>/NativeMessagingHosts` (Chromium-based) with
  **Read and write** under **Folders**, then restart the app and the browser.
  Press Ctrl+H in the folder picker to show hidden folders. This lets the app
  install a helper that your browser runs outside the sandbox. Apps that keep
  their connection socket elsewhere may still fail.
- **Suspend protection covers sandboxed apps only.** A running AppImage can stop
  the computer from suspending when the suspend catches it reading from its
  mounted image. AppManager prevents this for sandboxed apps: it pauses the app
  just before the suspend and resumes it afterwards. This needs systemd and
  logind; without them the app still runs, unprotected. Apps that are not
  sandboxed start through their own AppImage runtime and are not protected.
- **Some apps need compatibility adjustments.** Detected Chromium/Electron and
  WebKitGTK apps run with their internal sandbox disabled because it conflicts
  with this one; AppManager's outer sandbox remains active. Custom themes
  importing files from other folders may need an extra folder grant. Some apps
  can still fail with restricted permissions.

[Back to AppManager](../README.md)
