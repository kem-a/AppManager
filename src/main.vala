using AppManager.Core;

/**
 * The AppImage runtime redirects $HOME / $XDG_CONFIG_HOME when a .home /
 * .config folder exists next to the AppImage ("portable mode"). AppManager
 * cannot function that way: all of its state (GSettings, the installation
 * registry, desktop entries) lives under the real $HOME, so a redirected
 * HOME makes it lose track of itself and re-prompt for self-install in an
 * endless loop (issue #140). Undo the redirection before GLib caches any
 * user directory.
 */
static void neutralize_portable_dirs() {
    var appimage = GLib.Environment.get_variable("APPIMAGE");
    if (appimage == null || appimage.strip() == "") {
        return; // not running as an AppImage
    }

    var home = GLib.Environment.get_variable("HOME");
    if (home != null && home == appimage + ".home") {
        // Prefer HOST_HOME (exported by the uruntime/sharun hooks with the exact
        // pre-redirection value); fall back to the passwd database for builds
        // using the standard type-2 runtime, which exports no HOST_* variables.
        var host_home = GLib.Environment.get_variable("HOST_HOME");
        if (host_home != null && host_home.strip() != "" && host_home != home) {
            GLib.Environment.set_variable("HOME", host_home, true);
            warning("Portable .home redirection detected and neutralized; HOME restored to %s", host_home);
        } else {
            unowned Posix.Passwd? pw = Posix.getpwuid(Posix.getuid());
            if (pw != null && pw.pw_dir != null && pw.pw_dir != "") {
                GLib.Environment.set_variable("HOME", pw.pw_dir, true);
                warning("Portable .home redirection detected and neutralized; HOME reset to %s", pw.pw_dir);
            }
        }
    }

    var config = GLib.Environment.get_variable("XDG_CONFIG_HOME");
    if (config != null && config == appimage + ".config") {
        // Same preference: exact pre-redirection value when the hooks provide it.
        var host_config = GLib.Environment.get_variable("HOST_XDG_CONFIG_HOME");
        if (host_config != null && host_config.strip() != "" && host_config != config) {
            GLib.Environment.set_variable("XDG_CONFIG_HOME", host_config, true);
        } else {
            GLib.Environment.unset_variable("XDG_CONFIG_HOME");
        }
        warning("Portable .config redirection detected and neutralized");
    }
}

int main(string[] args) {
    neutralize_portable_dirs();

    // Initialize translations before anything else
    i18n_init();

    // If DBUS_SESSION_BUS_ADDRESS names a unix socket that doesn't exist,
    // unset it so GLib.Application skips DBus registration gracefully instead
    // of failing. Happens on minimal desktops where the env var is set by a
    // display manager but no session bus is actually running.
    var dbus_addr = GLib.Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
    if (dbus_addr != null && dbus_addr.has_prefix("unix:path=")) {
        var socket_path = dbus_addr.substring("unix:path=".length);
        if (!GLib.FileUtils.test(socket_path, GLib.FileTest.EXISTS)) {
            GLib.Environment.unset_variable("DBUS_SESSION_BUS_ADDRESS");
        }
    }

    var app = new AppManager.Application();
    return app.run(args);
}
