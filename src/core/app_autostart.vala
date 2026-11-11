namespace AppManager.Core {
    /**
     * Login entries of installed apps. The app's own setting switches them on and off.
     *
     * A sandboxed app writes its entry into its private home (SandboxBwrap binds that
     * folder over ~/.config/autostart even when the real home is granted), where the
     * session never looks. sandbox-run mirrors it to the host as an entry running the
     * app's sandboxed Exec line with the app's own arguments. Only the arguments are
     * taken: the program an app names is often its temporary mount, and running it
     * directly would skip the sandbox. An app can only change its entry while it
     * runs, and it runs only under sandbox-run, so no AppManager window is needed.
     * What it wrote in the real folder before it was sandboxed is removed.
     *
     * An unsandboxed app writes the real entry itself and is left alone: an entry
     * it gets wrong is for its upstream to fix.
     */
    public class AppAutostart {
        private const string MARKER = "X-AppManager-Autostart";
        private const string PREFIX = "appmanager-";
        // Meaningless at login; systemd's autostart generator drops them too.
        private const string[] FIELD_CODES = { "%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k", "%v", "%m" };
        private const string[] SHELLS = { "sh", "bash", "dash", "zsh" };

        /**
         * Own prefix instead of the app's desktop file name, which unsandboxed apps
         * like Bitwarden use for the entry they write themselves.
         */
        public static string? entry_path(string? desktop_file) {
            if (desktop_file == null || desktop_file.strip() == "") {
                return null;
            }
            return Path.build_filename(autostart_dir(), PREFIX + Path.get_basename(desktop_file));
        }

        private static string autostart_dir() {
            return Path.build_filename(Environment.get_user_config_dir(), "autostart");
        }

        /** The host folder the sandboxed app uses as its autostart folder. */
        public static string private_dir(string sandbox_home) {
            return Path.build_filename(sandbox_home, ".config", "autostart");
        }

        /** Mirrors a sandboxed record's entry; any other record has none. */
        public static void sync_record(InstallationRecord record) {
            if (record.sandbox_enabled()) {
                sync(record.id, SandboxConfig.sandbox_home_path(record), record.desktop_file);
                remove_leftovers({ record });
            } else {
                remove(record.desktop_file);
            }
        }

        /**
         * Runs when AppManager starts. Brings our entries in line with their records,
         * which drops those of apps that are not sandboxed, and removes leftovers.
         * Reads the one autostart folder, not every app's private one: sandbox-run
         * keeps those in step. Our entries no record names are left alone, as another
         * registry (a run with its own XDG_DATA_HOME) may own them.
         */
        public static void refresh(InstallationRecord[] records) {
            var names = new Gee.HashSet<string>();
            try {
                var listing = Dir.open(autostart_dir());
                string? name;
                while ((name = listing.read_name()) != null) {
                    names.add(name);
                }
            } catch (FileError e) {
                return;
            }
            foreach (var record in records) {
                var path = entry_path(record.desktop_file);
                if (path != null && Path.get_basename(path) in names) {
                    sync_record(record);
                }
            }
            remove_leftovers(records);
        }

        /**
         * Deletes the entries in the real folder that start a sandboxed record's
         * AppImage directly. The app wrote them before it was sandboxed, or an
         * instance started back then still runs; the next login would start it
         * unconfined.
         */
        private static void remove_leftovers(InstallationRecord[] records) {
            var appimages = new Gee.HashSet<string>();
            foreach (var record in records) {
                if (record.sandbox_enabled() && (record.installed_path ?? "") != "") {
                    appimages.add(SandboxConfig.canonicalize(record.installed_path));
                }
            }
            if (appimages.size == 0) {
                return;
            }
            var group = KeyFileDesktop.GROUP;
            var leftovers = new Gee.ArrayList<string>();
            try {
                var listing = Dir.open(autostart_dir());
                string? name;
                while ((name = listing.read_name()) != null) {
                    if (!name.has_suffix(".desktop") || name.has_prefix(PREFIX)) {
                        continue;
                    }
                    var path = Path.build_filename(autostart_dir(), name);
                    try {
                        var keyfile = new KeyFile();
                        keyfile.load_from_file(path, KeyFileFlags.NONE);
                        string[] argv;
                        Shell.parse_argv(keyfile.get_string(group, "Exec"), out argv);
                        int i = program_index(argv);
                        if (i < argv.length && Path.is_absolute(argv[i])
                            && SandboxConfig.canonicalize(argv[i]) in appimages) {
                            leftovers.add(path);
                        }
                    } catch (Error e) {
                        debug("Ignoring autostart entry %s: %s", path, e.message);
                    }
                }
            } catch (FileError e) {
                return;
            }
            foreach (var path in leftovers) {
                try {
                    File.new_for_path(path).delete();
                    debug("Removed autostart entry %s of a sandboxed app", path);
                } catch (Error e) {
                    warning("Failed to remove autostart entry %s: %s", path, e.message);
                }
            }
        }

        /**
         * Syncs on every change while the app runs. An app that stays in the tray all
         * session may switch login start on, and a session that ends hard never
         * reaches the sync after it exits. Returns the loop to quit once the app has
         * exited, or null when nothing is watched.
         */
        public static MainLoop? watch(string record_id, string sandbox_home, string? desktop_file) {
            var dir = private_dir(sandbox_home);
            if (entry_path(desktop_file) == null || DirUtils.create_with_parents(dir, 0700) != 0) {
                return null;
            }
            // A monitor reports to the context that is thread-default when it is made.
            var context = new MainContext();
            context.push_thread_default();
            FileMonitor? monitor = null;
            try {
                monitor = File.new_for_path(dir).monitor_directory(FileMonitorFlags.WATCH_MOVES);
            } catch (Error e) {
                warning("Sandbox: cannot watch %s: %s", dir, e.message);
            }
            context.pop_thread_default();
            if (monitor == null) {
                return null;
            }
            monitor.changed.connect((file, other, event) => {
                // CHANGES_DONE_HINT follows the writes, which arrive as CHANGED.
                if (event != FileMonitorEvent.CHANGED && event != FileMonitorEvent.ATTRIBUTE_CHANGED) {
                    sync(record_id, sandbox_home, desktop_file);
                }
            });
            var loop = new MainLoop(context);
            new Thread<void>("autostart", () => {
                loop.run();
                monitor.cancel();
            });
            return loop;
        }

        public static void sync(string record_id, string sandbox_home, string? desktop_file) {
            var path = entry_path(desktop_file);
            if (path == null || sandbox_home.strip() == "") {
                return;
            }
            var args = requested_args(private_dir(sandbox_home));
            var contents = (args != null) ? build_entry(record_id, desktop_file, args) : null;
            if (contents == null) {
                remove(desktop_file);
                return;
            }
            try {
                string current = "";
                // Apps that recreate their entry on every launch must not churn it.
                if (GLib.FileUtils.test(path, FileTest.EXISTS)
                    && GLib.FileUtils.get_contents(path, out current) && current == contents) {
                    return;
                }
                DirUtils.create_with_parents(Path.get_dirname(path), 0755);
                GLib.FileUtils.set_contents(path, contents);
            } catch (FileError e) {
                warning("Failed to write autostart entry %s: %s", path, e.message);
            }
        }

        public static void remove(string? desktop_file) {
            var path = entry_path(desktop_file);
            if (path == null || !GLib.FileUtils.test(path, FileTest.EXISTS)) {
                return;
            }
            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(path, KeyFileFlags.NONE);
                if (keyfile.has_key(KeyFileDesktop.GROUP, MARKER)) {
                    File.new_for_path(path).delete();
                }
            } catch (Error e) {
                warning("Failed to remove autostart entry %s: %s", path, e.message);
            }
        }

        // Arguments of the first enabled entry the app wrote, or null when it has
        // none. Hidden and X-GNOME-Autostart-enabled are how apps switch it off.
        private static string[]? requested_args(string dir) {
            var names = new Gee.ArrayList<string>();
            try {
                var listing = Dir.open(dir);
                string? name;
                while ((name = listing.read_name()) != null) {
                    if (name.has_suffix(".desktop")) {
                        names.add(name);
                    }
                }
            } catch (FileError e) {
                return null;
            }
            names.sort();
            var group = KeyFileDesktop.GROUP;
            foreach (var name in names) {
                try {
                    var keyfile = new KeyFile();
                    keyfile.load_from_file(Path.build_filename(dir, name), KeyFileFlags.NONE);
                    if (keyfile.has_key(group, "Hidden") && keyfile.get_boolean(group, "Hidden")) {
                        continue;
                    }
                    if (keyfile.has_key(group, "X-GNOME-Autostart-enabled")
                        && !keyfile.get_boolean(group, "X-GNOME-Autostart-enabled")) {
                        continue;
                    }
                    string[] argv;
                    Shell.parse_argv(keyfile.get_string(group, "Exec"), out argv);
                    return app_args(argv);
                } catch (Error e) {
                    debug("Sandbox: ignoring autostart entry %s: %s", name, e.message);
                }
            }
            return null;
        }

        // Index of the program, past an env prefix.
        private static int program_index(string[] argv) {
            int i = 0;
            if (Path.get_basename(argv[0]) == "env") {
                i++;
                while (i < argv.length && (argv[i].index_of_char('=') > 0 || argv[i].has_prefix("-"))) {
                    i++;
                }
            }
            return i;
        }

        // What follows the program. A shell command line cannot be taken apart, so it
        // starts the app without arguments. Arguments with control characters are
        // dropped: the app wrote them, and a newline could reach the session's own
        // parsing of the entry.
        private static string[] app_args(string[] argv) {
            int i = program_index(argv);
            var args = new string[0];
            if (i >= argv.length || Path.get_basename(argv[i]) in SHELLS) {
                return args;
            }
            for (int j = i + 1; j < argv.length; j++) {
                var arg = argv[j];
                if (arg in FIELD_CODES || has_control_char(arg)) {
                    continue;
                }
                args += arg.replace("%%", "%");
            }
            return args;
        }

        private static bool has_control_char(string value) {
            for (int i = 0; i < value.length; i++) {
                var byte = (uchar) value[i];
                if (byte < 0x20 || byte == 0x7f) {
                    return true;
                }
            }
            return false;
        }

        // Our menu Exec line with the app's arguments in place of the field codes.
        private static string launch_line(string exec, string[] args) {
            var line = new StringBuilder();
            foreach (var token in exec.split(" ")) {
                if (token in FIELD_CODES) {
                    continue;
                }
                if (line.len > 0) {
                    line.append_c(' ');
                }
                line.append(token);
            }
            foreach (var arg in args) {
                line.append(" \"%s\"".printf(arg.replace("\\", "\\\\").replace("\"", "\\\"")
                    .replace("$", "\\$").replace("`", "\\`").replace("%", "%%")));
            }
            return line.str;
        }

        // The host entry, or null when the app's desktop entry does not launch it
        // sandboxed: a login entry must never start it unconfined. The app's
        // arguments land after sandbox-run's "--", next to the user's own.
        private static string? build_entry(string record_id, string desktop_file, string[] args) {
            var group = KeyFileDesktop.GROUP;
            try {
                var source = new KeyFile();
                source.load_from_file(desktop_file, KeyFileFlags.NONE);
                var exec = source.get_string(group, "Exec");
                if (!(exec + " ").contains(" %s --id=%s ".printf(SANDBOX_RUN_VERB, record_id))) {
                    return null;
                }
                var entry = new KeyFile();
                entry.set_string(group, "Type", "Application");
                entry.set_string(group, "Name", source.get_string(group, "Name"));
                if (source.has_key(group, "Icon")) {
                    entry.set_string(group, "Icon", source.get_string(group, "Icon"));
                }
                entry.set_string(group, "Exec", launch_line(exec, args));
                entry.set_boolean(group, MARKER, true);
                return entry.to_data();
            } catch (Error e) {
                warning("Cannot mirror the autostart entry of %s: %s", desktop_file, e.message);
                return null;
            }
        }
    }
}
