using Gee;

namespace AppManager.Core {
    /**
     * Translates an InstallationRecord's sandbox permissions into sas
     * (simple-appimage-sandbox) flags, and persists them to the per-app
     * <data_dir>/sandbox/<record-id>.args file that SandboxLauncher reads.
     *
     * Mostly only deviations from sas's own defaults are emitted, so the file stays
     * short enough for a user to read when an app misbehaves. sas defaults that matter
     * here: network, audio, pipewire, dbus and ALL of /dev are shared, and no user
     * directory is. dbus therefore has to be taken away explicitly — leaving it at its
     * default would make the sandbox nearly pointless. X11 is the exception to the
     * "only deviations" rule and is always stated outright, because sas's own default
     * for it depends on whether the session is Wayland.
     */
    public class SandboxConfig {
        /**
         * Applies a named preset's permissions to the record and stamps the profile.
         * "custom" and "off" carry no permissions of their own, so they only set the label.
         */
        public static void apply_preset(InstallationRecord record, string profile) {
            switch (profile) {
                case SANDBOX_PROFILE_STANDARD:
                    record.sandbox_allow_network = true;
                    record.sandbox_allow_audio = true;
                    record.sandbox_allow_x11 = true;
                    record.sandbox_allow_dbus = false;
                    record.sandbox_allow_downloads = true;
                    record.sandbox_allow_documents = false;
                    record.sandbox_allow_desktop = false;
                    record.sandbox_allow_pictures = false;
                    record.sandbox_allow_videos = false;
                    record.sandbox_allow_music = false;
                    break;
                case SANDBOX_PROFILE_STRICT:
                    record.sandbox_allow_network = false;
                    record.sandbox_allow_audio = false;
                    record.sandbox_allow_x11 = false;
                    record.sandbox_allow_dbus = false;
                    record.sandbox_allow_downloads = false;
                    record.sandbox_allow_documents = false;
                    record.sandbox_allow_desktop = false;
                    record.sandbox_allow_pictures = false;
                    record.sandbox_allow_videos = false;
                    record.sandbox_allow_music = false;
                    break;
                default:
                    break;
            }
            record.sandbox_profile = profile;
        }

        /**
         * Returns the preset whose permissions match the record's current state,
         * or "custom" when none does. Never returns "off" — callers decide that
         * from sandbox_enabled().
         */
        public static string detect_profile(InstallationRecord record) {
            if (matches(record, true, true, true, true)) {
                return SANDBOX_PROFILE_STANDARD;
            }
            if (matches(record, false, false, false, false)) {
                return SANDBOX_PROFILE_STRICT;
            }
            return SANDBOX_PROFILE_CUSTOM;
        }

        private static bool matches(InstallationRecord r, bool network, bool audio, bool x11, bool downloads) {
            return r.sandbox_allow_network == network
                && r.sandbox_allow_audio == audio
                && r.sandbox_allow_x11 == x11
                && r.sandbox_allow_downloads == downloads
                && !r.sandbox_allow_dbus
                && !r.sandbox_allow_documents
                && !r.sandbox_allow_desktop
                && !r.sandbox_allow_pictures
                && !r.sandbox_allow_videos
                && !r.sandbox_allow_music
                && (r.sandbox_extra_dirs == null || r.sandbox_extra_dirs.length == 0);
        }

        /**
         * Path of the app's persistent sandboxed home. Mirrors the existing
         * <installed_path>.home / .config convention.
         *
         * An explicit path is required rather than sas's default: sas would otherwise
         * create <installed_path>.home, which the AppImage runtime then adopts as a
         * portable home — silently flipping AppManager's own portable .home toggle.
         */
        public static string sandbox_home_path(InstallationRecord record) {
            return "%s.sandbox".printf(record.installed_path ?? "");
        }

        /**
         * Whether this record can actually be sandboxed. EXTRACTED installs are
         * excluded: sas expects a single file it can mount, and an extracted AppDir's
         * AppRun resolves its own location, so binding it alone would break the app.
         */
        public static bool supports_record(InstallationRecord record) {
            return record.mode == InstallMode.PORTABLE
                && record.installed_path != null
                && record.installed_path.strip() != ""
                && record.original_startup_wm_class != APPLICATION_ID;
        }

        /**
         * Builds the sas flag list for this record, excluding the target path
         * (SandboxLauncher appends that).
         */
        public static string[] build_args(InstallationRecord record) {
            var args = new ArrayList<string>();

            // Persistent per-app home, so settings and logins survive a restart.
            args.add("--data-dir");
            args.add(sandbox_home_path(record));

            // Leave the AppImage mounted on exit.
            //
            // sas otherwise unmounts and then unconditionally "rm -rf"s the mount point on
            // every exit, and its mount point is shared by all launches of the same file.
            // A second launch that quits immediately — an Electron app handing off to the
            // running instance, say — therefore tries to unmount the mount the first one is
            // still using: it fails with EBUSY, and the rm then walks the still-mounted
            // read-only tree printing a screenful of errors. Worse, were the unmount ever to
            // succeed it would pull the files out from under the running app.
            //
            // Keeping the mount avoids both, and later launches skip re-mounting. The cost is
            // one FUSE mount per AppImage left behind until reboot (sas reuses it, so it does
            // not grow per launch; a new one appears after an app is updated).
            args.add("--keep-mount");

            // Theming paths sas does not cover. Its own defaults already bind
            // ~/.config/gtk-3.0, gtk-4.0, dconf, fontconfig, the Qt theme configs and
            // ~/.local/share/{icons,themes,fonts}; these are the legacy dotfile locations
            // plus the GNOME extensions tree, which a user gtk.css commonly @imports from.
            // All read-only, and "-try" means a missing one costs nothing.
            var home = Environment.get_home_dir();
            string[] theme_extras = {
                ".gtkrc-2.0",
                ".themes",
                ".icons",
                ".fonts",
                ".local/share/gnome-shell/extensions"
            };
            foreach (var rel in theme_extras) {
                // sas treats --add-file and --add-dir identically, so one flag covers both.
                add_pair(args, "--add-dir", Path.build_filename(home, rel));
            }

            // /dev is deliberately left at sas's default, which shares all of it.
            //
            // Restricting it with "--rm-device all" does work, but sas's GPU handling binds
            // only the NVIDIA nodes and never /dev/dri, and its "--add-dir" emits a plain
            // --bind. A plain bind of a device node into bwrap's nodev /dev tmpfs leaves a
            // node that is visible and mode 0666 yet cannot be opened, so every Intel and
            // AMD machine loses hardware rendering. Expressing this correctly needs
            // --dev-bind, which sas has no flag for. Until it does, working GPUs beat
            // blocking cameras — and device access is the portal work's job anyway.

            // X11. sas turns this off by itself when the session is Wayland, which breaks
            // any app pinned to X11 (Electron with --ozone-platform=x11 is the common case):
            // XAUTHORITY keeps pointing at a host path that was never bound, so the app
            // fails with "Authorization required" and no display. Be explicit in both
            // directions rather than inheriting a session-dependent default.
            add_pair(args, record.sandbox_allow_x11 ? "--add-socket" : "--rm-socket", "x11");

            // sas proxies xdg-open through a background daemon that inherits stdout, so a
            // caller reading the app's output through a pipe never sees EOF and hangs. That
            // is fatal for a command-line app ("app | grep x") and harmless for a GUI one,
            // which would otherwise lose the ability to open links in host apps.
            if (record.is_terminal) {
                args.add("--no-xdgopen");
            }

            // The session bus is shared by default and is the widest escape route
            // there is (systemd StartTransientUnit, terminal services), so it is
            // removed unless the user knowingly grants it.
            if (!record.sandbox_allow_dbus) {
                add_pair(args, "--rm-socket", "dbus");
            }
            if (!record.sandbox_allow_network) {
                add_pair(args, "--rm-socket", "network");
            }
            if (!record.sandbox_allow_audio) {
                add_pair(args, "--rm-socket", "audio");
                add_pair(args, "--rm-socket", "pipewire");
            }

            // User directories. sas grants none by default; ":rw" makes a grant writable.
            if (record.sandbox_allow_downloads) add_dir(args, "xdg-download");
            if (record.sandbox_allow_documents) add_dir(args, "xdg-documents");
            if (record.sandbox_allow_desktop)   add_dir(args, "xdg-desktop");
            if (record.sandbox_allow_pictures)  add_dir(args, "xdg-pictures");
            if (record.sandbox_allow_videos)    add_dir(args, "xdg-videos");
            if (record.sandbox_allow_music)     add_dir(args, "xdg-music");

            foreach (var dir in record.sandbox_extra_dirs ?? new string[0]) {
                if (dir == null || dir.strip() == "") {
                    continue;
                }
                var entry = dir.strip();
                var writable = entry.has_suffix(":rw");
                var path = writable ? entry.substring(0, entry.length - 3) : entry;
                path = canonicalize(path);
                add_pair(args, "--add-dir", writable ? "%s:rw".printf(path) : path);
            }

            return args.to_array();
        }

        /**
         * Resolves a path to its real location, following symlinks.
         *
         * Granting a symlink itself is useless and actively harmful: bwrap resolves the
         * bind source to its target but creates the destination at the literal path, so
         * mounting onto a symlink that sits inside an already-bound read-only parent
         * fails outright and the app never starts. Binding the target directly both
         * works and makes the symlink inside that parent resolve.
         *
         * Returns the input unchanged when it cannot be resolved (e.g. it does not
         * exist yet), since the "-try" bind will simply skip it.
         */
        public static string canonicalize(string path) {
            var resolved = Posix.realpath(path);
            return (resolved != null && resolved != "") ? resolved : path;
        }

        private static void add_pair(ArrayList<string> args, string flag, string value) {
            args.add(flag);
            args.add(value);
        }

        private static void add_dir(ArrayList<string> args, string xdg_name) {
            add_pair(args, "--add-dir", "%s:rw".printf(xdg_name));
        }

        /**
         * Writes the record's .args file, one argument per line. Line-per-argument
         * means no quoting rules to get wrong, at the cost of refusing the (illegal
         * in POSIX filenames anyway) embedded newline.
         *
         * Returns false and writes nothing when an argument contains a newline.
         */
        public static bool write_args_file(InstallationRecord record) {
            var path = AppPaths.sandbox_args_file(record.id);
            var args = build_args(record);
            var content = new StringBuilder();
            content.append("# Generated by AppManager for %s — regenerated on every\n".printf(record.name));
            content.append("# permission change. Edits are overwritten; one argument per line.\n");
            foreach (var arg in args) {
                if (arg.contains("\n")) {
                    warning("Refusing to write sandbox args for %s: argument contains a newline", record.name);
                    return false;
                }
                content.append(arg);
                content.append("\n");
            }
            try {
                if (!GLib.FileUtils.set_contents(path, content.str)) {
                    warning("Failed to write sandbox args file %s", path);
                    return false;
                }
                debug("Wrote sandbox args for %s to %s", record.name, path);
                return true;
            } catch (Error e) {
                warning("Failed to write sandbox args file %s: %s", path, e.message);
                return false;
            }
        }

        /**
         * Reads a record's .args file back into an argument list.
         * Returns null when the file is missing or unreadable, which the launcher
         * treats as "run unsandboxed" rather than a fatal error.
         */
        public static string[]? read_args_file(string record_id) {
            var path = AppPaths.sandbox_args_file(record_id);
            string contents;
            try {
                if (!GLib.FileUtils.get_contents(path, out contents)) {
                    return null;
                }
            } catch (Error e) {
                debug("No sandbox args at %s: %s", path, e.message);
                return null;
            }
            var args = new ArrayList<string>();
            foreach (var line in contents.split("\n")) {
                if (line.has_prefix("#") || line.strip() == "") {
                    continue;
                }
                args.add(line);
            }
            return args.to_array();
        }

        /**
         * Rewrites the .args file of every sandboxed record, and clears the file of any
         * record that is no longer sandboxed.
         *
         * Called at startup so a change to the flag set reaches apps that were sandboxed
         * by an older build. Writing them is cheap — a few hundred bytes each — and the
         * launcher reads the file fresh on every launch, so the next start picks it up.
         */
        public static void refresh_all(InstallationRecord[] records) {
            var live = new Gee.HashSet<string>();
            foreach (var record in records) {
                if (record.sandbox_enabled()) {
                    write_args_file(record);
                    live.add("%s.args".printf(record.id));
                } else {
                    remove_args_file(record.id);
                }
            }

            // Drop files left behind by records that vanished without an uninstall
            // (a hand-edited registry, a restored backup), so the directory cannot
            // grow without bound.
            try {
                var dir = Dir.open(AppPaths.sandbox_dir);
                var orphans = new Gee.ArrayList<string>();
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_suffix(".args") && !live.contains(name)) {
                        orphans.add(name);
                    }
                }
                foreach (var orphan in orphans) {
                    var file = File.new_for_path(Path.build_filename(AppPaths.sandbox_dir, orphan));
                    file.delete(null);
                    debug("Removed orphaned sandbox args %s", orphan);
                }
            } catch (Error e) {
                debug("Could not scan sandbox dir for orphans: %s", e.message);
            }
        }

        /**
         * Removes a record's .args file. Safe to call when it never existed.
         */
        public static void remove_args_file(string record_id) {
            var file = File.new_for_path(AppPaths.sandbox_args_file(record_id));
            try {
                if (file.query_exists()) {
                    file.delete(null);
                }
            } catch (Error e) {
                debug("Failed to remove sandbox args for %s: %s", record_id, e.message);
            }
        }
    }
}
