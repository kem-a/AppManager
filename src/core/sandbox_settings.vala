namespace AppManager.Core {
    /**
     * GSettings for a sandbox behind the filtered bus. dconf writes go over D-Bus to
     * ca.desrt.dconf, which the proxy refuses, and GLib then reverts the value:
     * preferences never stick and a window size bound to a key snaps back. So the
     * sandbox uses GLib's keyfile backend in its private home, seeded from the host's
     * dconf on every launch. GLib's own read-only defaults layer would fit better, but
     * its path is fixed at /etc/glib-2.0/settings and /etc is the host's, read-only.
     */
    public class SandboxSettings : Object {
        private const string KEYFILE = "keyfile";
        // The host values the last seed wrote, to tell them from the app's own writes.
        private const string SEED = "host-seed";

        public static void seed(string home) {
            string dump;
            int status;
            try {
                // `dconf dump` prints the format the keyfile backend reads.
                Process.spawn_sync(null, { "dconf", "dump", "/" }, null,
                    SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL, null, out dump, null, out status);
            } catch (SpawnError e) {
                debug("Sandbox: no host dconf to seed settings from: %s", e.message);
                return;
            }
            if (status != 0) {
                debug("Sandbox: dconf dump failed (%d), settings not seeded", status);
                return;
            }
            try {
                if (!apply(home, dump)) {
                    warning("Sandbox: cannot seed settings under %s: %s", home, Posix.strerror(Posix.errno));
                }
            } catch (KeyFileError e) {
                warning("Sandbox: unreadable dconf dump: %s", e.message);
            }
        }

        // Settings portal keys GTK 4 reads on Wayland, with their settings.ini names.
        // Only settings every GTK 4 knows, since an unknown key warns on each start.
        // The input method is left out: the host's may be unreachable from inside.
        private const string[] GTK_KEYS = {
            "org.gnome.desktop.wm.preferences", "button-layout", "gtk-decoration-layout",
            "org.gnome.desktop.wm.preferences", "action-double-click-titlebar", "gtk-titlebar-double-click",
            "org.gnome.desktop.wm.preferences", "action-middle-click-titlebar", "gtk-titlebar-middle-click",
            "org.gnome.desktop.wm.preferences", "action-right-click-titlebar", "gtk-titlebar-right-click",
            "org.gnome.desktop.interface", "gtk-theme", "gtk-theme-name",
            "org.gnome.desktop.interface", "icon-theme", "gtk-icon-theme-name",
            "org.gnome.desktop.interface", "cursor-theme", "gtk-cursor-theme-name",
            "org.gnome.desktop.interface", "cursor-size", "gtk-cursor-theme-size",
            "org.gnome.desktop.interface", "font-name", "gtk-font-name",
            "org.gnome.desktop.interface", "text-scaling-factor", "gtk-xft-dpi",
            "org.gnome.desktop.interface", "cursor-blink", "gtk-cursor-blink",
            "org.gnome.desktop.interface", "cursor-blink-time", "gtk-cursor-blink-time",
            "org.gnome.desktop.interface", "cursor-blink-timeout", "gtk-cursor-blink-timeout",
            "org.gnome.desktop.interface", "enable-animations", "gtk-enable-animations",
            "org.gnome.desktop.interface", "gtk-enable-primary-paste", "gtk-enable-primary-paste",
            "org.gnome.desktop.interface", "overlay-scrolling", "gtk-overlay-scrolling",
            "org.gnome.desktop.peripherals.mouse", "double-click", "gtk-double-click-time",
            "org.gnome.desktop.peripherals.mouse", "drag-threshold", "gtk-dnd-drag-threshold",
            "org.gnome.desktop.sound", "theme-name", "gtk-sound-theme-name",
            "org.gnome.desktop.sound", "event-sounds", "gtk-enable-event-sounds",
            "org.gnome.desktop.sound", "input-feedback-sounds", "gtk-enable-input-feedback-sounds",
            "org.gnome.desktop.privacy", "recent-files-max-age", "gtk-recent-files-max-age",
            "org.gnome.desktop.privacy", "remember-recent-files", "gtk-recent-files-enabled",
            "org.gnome.desktop.a11y", "always-show-text-caret", "gtk-keynav-use-caret"
        };

        /**
         * GTK 4 on Wayland takes these settings only from the Settings portal, and
         * uses the portal only after reading its version property, which the filtered
         * bus refuses (properties would also enable portals the proxy blocks). It then
         * falls back to built-in defaults: window buttons on the right, the default
         * icon theme, "Sans 10". So the host portal's values go in as a settings.ini,
         * read at startup: later changes reach the app on its next launch.
         */
        public static string? host_gtk_settings() {
            try {
                var reply = Bus.get_sync(BusType.SESSION).call_sync(
                    "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                    "org.freedesktop.portal.Settings", "ReadAll",
                    new Variant.tuple({ new Variant.strv({ "org.gnome.desktop.*" }) }),
                    new VariantType("(a{sa{sv}})"), DBusCallFlags.NONE, 2000);
                return gtk_settings_ini(reply.get_child_value(0));
            } catch (Error e) {
                debug("Sandbox: no host Settings portal for GTK settings: %s", e.message);
                return null;
            }
        }

        /** A portal ReadAll result as GTK 4 settings.ini contents, null if empty. */
        public static string? gtk_settings_ini(Variant namespaces) {
            var ini = new KeyFile();
            for (int i = 0; i + 2 < GTK_KEYS.length; i += 3) {
                var group = namespaces.lookup_value(GTK_KEYS[i], VariantType.VARDICT);
                var value = group != null ? group.lookup_value(GTK_KEYS[i + 1], null) : null;
                if (value == null) {
                    continue;
                }
                var name = GTK_KEYS[i + 2];
                if (value.is_of_type(VariantType.STRING)) {
                    ini.set_string("Settings", name, value.get_string());
                } else if (value.is_of_type(VariantType.INT32)) {
                    ini.set_integer("Settings", name, value.get_int32());
                } else if (value.is_of_type(VariantType.BOOLEAN)) {
                    ini.set_boolean("Settings", name, value.get_boolean());
                } else if (value.is_of_type(VariantType.DOUBLE)) {
                    // text-scaling-factor: Xft counts 1/1024ths of a 96 dpi inch.
                    ini.set_integer("Settings", name, (int) (value.get_double() * 96 * 1024));
                }
            }
            return ini.has_group("Settings") ? ini.to_data() : null;
        }

        public static bool apply(string home, string host) throws KeyFileError {
            int dir = open_settings_dir(home);
            if (dir < 0) {
                return false;
            }
            try {
                return write_at(dir, KEYFILE, merge(read_at(dir, KEYFILE), read_at(dir, SEED), host))
                    && write_at(dir, SEED, host);
            } finally {
                Posix.close(dir);
            }
        }

        /**
         * The host's values, except for keys the app wrote since the last seed (absent
         * from it, or different), which are kept.
         */
        public static string merge(string current, string previous, string host) throws KeyFileError {
            var result = new KeyFile();
            result.load_from_data(host, -1, KeyFileFlags.NONE);
            var app = load(current);
            var seeded = load(previous);
            foreach (var group in app.get_groups()) {
                foreach (var key in app.get_keys(group)) {
                    var value = app.get_value(group, key);
                    if (value != lookup(seeded, group, key)) {
                        result.set_value(group, key, value);
                    }
                }
            }
            return result.to_data();
        }

        private static KeyFile load(string data) {
            var file = new KeyFile();
            try {
                file.load_from_data(data, -1, KeyFileFlags.NONE);
            } catch (KeyFileError e) {
                return new KeyFile();
            }
            return file;
        }

        private static string? lookup(KeyFile file, string group, string key) {
            try {
                return file.has_group(group) && file.has_key(group, key) ? file.get_value(group, key) : null;
            } catch (KeyFileError e) {
                return null;
            }
        }

        // The home is app-writable: anchor every step to a directory fd and refuse
        // symlinks, so a planted link cannot redirect this host-side write.
        private static int open_settings_dir(string home) {
            int dir = Posix.open(home, Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
            foreach (var part in new string[] { ".config", "glib-2.0", "settings" }) {
                if (dir < 0) break;
                if (Posix.mkdirat(dir, part, 0700) != 0 && Posix.errno != Posix.EEXIST) {
                    Posix.close(dir);
                    return -1;
                }
                int next = Posix.openat(dir, part, Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
                Posix.close(dir);
                dir = next;
            }
            return dir;
        }

        private static string read_at(int dir, string name) {
            int fd = Posix.openat(dir, name, Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_NONBLOCK | Posix.O_CLOEXEC);
            if (fd < 0) {
                return "";
            }
            var data = new StringBuilder();
            Posix.Stat st = Posix.Stat();
            if (Posix.fstat(fd, out st) == 0 && Posix.S_ISREG(st.st_mode)) {
                var buf = new uint8[65536];
                ssize_t n;
                while ((n = Posix.read(fd, buf, buf.length)) > 0) {
                    data.append_len((string) buf, n);
                }
            }
            Posix.close(fd);
            return data.str;
        }

        // A fresh file renamed into place: a running instance never reads half of it.
        private static bool write_at(int dir, string name, string data) {
            var tmp = "." + name + ".new";
            Posix.unlinkat(dir, tmp, 0);
            int fd = Posix.openat(dir, tmp, Posix.O_CREAT | Posix.O_EXCL | Posix.O_WRONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC, 0600);
            if (fd < 0) {
                return false;
            }
            size_t done = 0;
            while (done < data.length) {
                var n = Posix.write(fd, (uint8*) data + done, data.length - done);
                if (n <= 0) break;
                done += n;
            }
            Posix.close(fd);
            return done == data.length && Posix.renameat(dir, tmp, dir, name) == 0;
        }
    }
}
