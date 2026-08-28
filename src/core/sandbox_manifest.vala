namespace AppManager.Core {
    /**
     * The on-disk sandbox description of one app, and the only thing the launcher
     * knows about it: <data_dir>/sandbox/<record-id>.sandbox, a GKeyFile.
     *
     * Why a manifest of permissions rather than a ready-made argument list: the
     * bwrap command line cannot be composed ahead of time. It depends on things only
     * known at launch - which session sockets exist, which camera nodes are plugged
     * in, the per-launch instance id, the numbers of the file descriptors carrying
     * generated files. So the GUI writes intent here, and SandboxBwrap turns intent
     * into argv each time the app starts.
     *
     * The launcher's contract, unchanged from the first sandbox implementation:
     *   - manifest absent  -> the sandbox was turned off and only the .desktop Exec
     *                         line is stale; launch the app plainly.
     *   - manifest present but the tooling it needs is missing -> refuse (exit 3).
     *     The user believes this app is contained; starting it unconfined is worse
     *     than not starting it.
     */
    public class SandboxManifest {
        private const string GROUP_SANDBOX = "Sandbox";
        private const string GROUP_PERMISSIONS = "Permissions";
        private const string GROUP_FILESYSTEM = "Filesystem";

        public int version = SANDBOX_MANIFEST_VERSION;
        public string app_id = "";
        public string profile = SANDBOX_PROFILE_CUSTOM;
        // The AppImage to mount. Held explicitly rather than derived from the
        // launcher's --target, which for a sub-entry of a multi-component AppImage is
        // a ~/.local/bin symlink and must stay unresolved to keep ARGV0 dispatch working.
        public string appimage = "";
        // Persistent per-app home, bound over the real $HOME path inside the sandbox.
        public string home = "";
        // Terminal apps skip --new-session, which would break job control for them.
        public bool terminal = false;

        public bool network = false;
        public bool audio = false;
        public bool x11 = false;
        public bool gpu = true;
        public bool camera = false;
        public bool input = false;
        public bool bluetooth = false;
        public bool notifications = false;
        public bool tray = false;
        public bool location = false;
        public bool full_session_bus = false;

        public string[] xdg_dirs = new string[0];
        public string[] extra_dirs = new string[0];
        // The record's own NAME=VALUE environment variables. They have to travel in
        // here: the .desktop Exec line sets them for the launcher process, and the
        // sandbox starts from --clearenv, so anything not re-stated is lost.
        public string[] env = new string[0];
        // Bus names the app may claim through the proxy. See SandboxIdentity.
        public string[] own_names = new string[0];

        /**
         * Builds the manifest that describes a record's current permissions.
         */
        public static SandboxManifest from_record(InstallationRecord record) {
            var m = new SandboxManifest();
            m.app_id = record.sandbox_app_id ?? "";
            m.profile = record.sandbox_profile ?? SANDBOX_PROFILE_CUSTOM;
            m.appimage = record.installed_path ?? "";
            m.home = SandboxConfig.sandbox_home_path(record);
            m.terminal = record.is_terminal;

            m.network = record.sandbox_allow_network;
            m.audio = record.sandbox_allow_audio;
            m.x11 = record.sandbox_allow_x11;
            m.gpu = record.sandbox_allow_gpu;
            m.camera = record.sandbox_allow_camera;
            m.input = record.sandbox_allow_input;
            m.bluetooth = record.sandbox_allow_bluetooth;
            m.notifications = record.sandbox_allow_notifications;
            m.tray = record.sandbox_allow_tray;
            m.location = record.sandbox_allow_location;
            m.full_session_bus = record.sandbox_allow_dbus;

            var dirs = new Gee.ArrayList<string>();
            if (record.sandbox_allow_downloads) dirs.add("downloads");
            if (record.sandbox_allow_documents) dirs.add("documents");
            if (record.sandbox_allow_desktop)   dirs.add("desktop");
            if (record.sandbox_allow_pictures)  dirs.add("pictures");
            if (record.sandbox_allow_videos)    dirs.add("videos");
            if (record.sandbox_allow_music)     dirs.add("music");
            m.xdg_dirs = dirs.to_array();

            var extras = new Gee.ArrayList<string>();
            foreach (var entry in record.sandbox_extra_dirs ?? new string[0]) {
                if (entry == null || entry.strip() == "") {
                    continue;
                }
                var trimmed = entry.strip();
                var writable = trimmed.has_suffix(":rw");
                var path = writable ? trimmed.substring(0, trimmed.length - 3) : trimmed;
                // Resolve here as well as when the UI stores it, so entries written by
                // an older build are corrected too. See SandboxConfig.canonicalize.
                path = SandboxConfig.canonicalize(path);
                extras.add(writable ? "%s:rw".printf(path) : path);
            }
            m.extra_dirs = extras.to_array();

            var env_list = new Gee.ArrayList<string>();
            foreach (var entry in record.custom_env_vars ?? new string[0]) {
                if (entry != null && entry.strip() != "" && entry.contains("=")) {
                    env_list.add(entry.strip());
                }
            }
            m.env = env_list.to_array();
            m.own_names = SandboxIdentity.own_names_for(record);
            return m;
        }

        /**
         * Writes a record's manifest. Returns false (and leaves any previous file in
         * place) when the record has no installed path to sandbox.
         */
        public static bool write_for_record(InstallationRecord record) {
            if (record.installed_path == null || record.installed_path.strip() == "") {
                warning("Refusing to write a sandbox manifest for %s: no installed path", record.name);
                return false;
            }
            var path = AppPaths.sandbox_manifest_file(record.id);
            var content = from_record(record).to_data(record.name);
            if (content == null) {
                return false;
            }
            try {
                if (!GLib.FileUtils.set_contents(path, content)) {
                    warning("Failed to write sandbox manifest %s", path);
                    return false;
                }
                // 0600: the manifest names every folder the app may reach.
                GLib.FileUtils.chmod(path, 0600);
                debug("Wrote sandbox manifest for %s to %s", record.name, path);
                return true;
            } catch (Error e) {
                warning("Failed to write sandbox manifest %s: %s", path, e.message);
                return false;
            }
        }

        /**
         * Serializes to GKeyFile text. Returns null if the key file layer refuses the
         * content, which in practice cannot happen for the values used here.
         */
        public string? to_data(string app_name) {
            var kf = new KeyFile();
            try {
                kf.set_integer(GROUP_SANDBOX, "version", version);
                kf.set_string(GROUP_SANDBOX, "app-id", app_id);
                kf.set_string(GROUP_SANDBOX, "profile", profile);
                kf.set_string(GROUP_SANDBOX, "appimage", appimage);
                kf.set_string(GROUP_SANDBOX, "home", home);
                kf.set_boolean(GROUP_SANDBOX, "terminal", terminal);

                kf.set_boolean(GROUP_PERMISSIONS, "network", network);
                kf.set_boolean(GROUP_PERMISSIONS, "audio", audio);
                kf.set_boolean(GROUP_PERMISSIONS, "x11", x11);
                kf.set_boolean(GROUP_PERMISSIONS, "gpu", gpu);
                kf.set_boolean(GROUP_PERMISSIONS, "camera", camera);
                kf.set_boolean(GROUP_PERMISSIONS, "input", input);
                kf.set_boolean(GROUP_PERMISSIONS, "bluetooth", bluetooth);
                kf.set_boolean(GROUP_PERMISSIONS, "notifications", notifications);
                kf.set_boolean(GROUP_PERMISSIONS, "tray", tray);
                kf.set_boolean(GROUP_PERMISSIONS, "location", location);
                kf.set_boolean(GROUP_PERMISSIONS, "full-session-bus", full_session_bus);

                kf.set_string_list(GROUP_FILESYSTEM, "xdg-dirs", xdg_dirs);
                kf.set_string_list(GROUP_FILESYSTEM, "extra", extra_dirs);
                kf.set_string_list(GROUP_SANDBOX, "env", env);
                kf.set_string_list(GROUP_SANDBOX, "own-names", own_names);

                kf.set_comment(null, null,
                    " Generated by AppManager for %s - regenerated on every permission\n change. Edits are overwritten.".printf(app_name));
                return kf.to_data();
            } catch (Error e) {
                warning("Failed to serialize sandbox manifest: %s", e.message);
                return null;
            }
        }

        /**
         * Reads a record's manifest, or null when it is absent, unreadable, or written
         * by a newer AppManager than this one. A null return means "not sandboxed" to
         * the launcher, so an unreadable manifest is deliberately never guessed at:
         * refusing to launch is handled one level up, where the file's mere existence
         * is checked separately.
         */
        public static SandboxManifest? read(string record_id) {
            var path = AppPaths.sandbox_manifest_file(record_id);
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.KEEP_COMMENTS);
            } catch (Error e) {
                debug("No sandbox manifest at %s: %s", path, e.message);
                return null;
            }

            var m = new SandboxManifest();
            try {
                m.version = kf.get_integer(GROUP_SANDBOX, "version");
            } catch (Error e) {
                warning("Sandbox manifest %s has no version", path);
                return null;
            }
            if (m.version > SANDBOX_MANIFEST_VERSION) {
                warning("Sandbox manifest %s is version %d, this build understands %d",
                    path, m.version, SANDBOX_MANIFEST_VERSION);
                return null;
            }

            m.app_id = read_string(kf, GROUP_SANDBOX, "app-id", "");
            m.profile = read_string(kf, GROUP_SANDBOX, "profile", SANDBOX_PROFILE_CUSTOM);
            m.appimage = read_string(kf, GROUP_SANDBOX, "appimage", "");
            m.home = read_string(kf, GROUP_SANDBOX, "home", "");
            m.terminal = read_bool(kf, GROUP_SANDBOX, "terminal", false);

            m.network = read_bool(kf, GROUP_PERMISSIONS, "network", false);
            m.audio = read_bool(kf, GROUP_PERMISSIONS, "audio", false);
            m.x11 = read_bool(kf, GROUP_PERMISSIONS, "x11", false);
            m.gpu = read_bool(kf, GROUP_PERMISSIONS, "gpu", true);
            m.camera = read_bool(kf, GROUP_PERMISSIONS, "camera", false);
            m.input = read_bool(kf, GROUP_PERMISSIONS, "input", false);
            m.bluetooth = read_bool(kf, GROUP_PERMISSIONS, "bluetooth", false);
            m.notifications = read_bool(kf, GROUP_PERMISSIONS, "notifications", false);
            m.tray = read_bool(kf, GROUP_PERMISSIONS, "tray", false);
            m.location = read_bool(kf, GROUP_PERMISSIONS, "location", false);
            m.full_session_bus = read_bool(kf, GROUP_PERMISSIONS, "full-session-bus", false);

            m.xdg_dirs = read_list(kf, GROUP_FILESYSTEM, "xdg-dirs");
            m.extra_dirs = read_list(kf, GROUP_FILESYSTEM, "extra");
            m.env = read_list(kf, GROUP_SANDBOX, "env");
            m.own_names = read_list(kf, GROUP_SANDBOX, "own-names");
            return m;
        }

        /**
         * Whether a record has a manifest on disk. The launcher checks this before
         * deciding between "not sandboxed" and "sandboxed but unreadable".
         */
        public static bool exists(string record_id) {
            return GLib.FileUtils.test(AppPaths.sandbox_manifest_file(record_id), FileTest.EXISTS);
        }

        /**
         * Removes a record's manifest. Safe to call when it never existed.
         */
        public static void remove(string record_id) {
            var file = File.new_for_path(AppPaths.sandbox_manifest_file(record_id));
            try {
                if (file.query_exists()) {
                    file.delete(null);
                }
            } catch (Error e) {
                debug("Failed to remove sandbox manifest for %s: %s", record_id, e.message);
            }
        }

        /**
         * Whether the manifest asks for anything that needs a filtered bus: one of the
         * proxied services, or a bus name the app has to be able to claim. With
         * full_session_bus on, the real socket is bound instead and no proxy is involved.
         *
         * own_names is what keeps an ordinary app on a session bus. Without it a Strict
         * profile - every service toggle off - would get no bus at all, and no bus means
         * no DBUS_SESSION_BUS_ADDRESS under --clearenv.
         */
        public bool needs_bus_proxy() {
            if (full_session_bus) {
                return false;
            }
            return notifications || tray || bluetooth || location || own_names.length > 0;
        }

        /**
         * Whether the system bus half of the proxy is needed: BlueZ, and GeoClue2 now
         * that location is no longer portal-backed.
         */
        public bool needs_system_bus() {
            return !full_session_bus && (bluetooth || location);
        }

        private static string read_string(KeyFile kf, string group, string key, string fallback) {
            try {
                var value = kf.get_string(group, key);
                return value ?? fallback;
            } catch (Error e) {
                return fallback;
            }
        }

        private static bool read_bool(KeyFile kf, string group, string key, bool fallback) {
            try {
                return kf.get_boolean(group, key);
            } catch (Error e) {
                return fallback;
            }
        }

        private static string[] read_list(KeyFile kf, string group, string key) {
            try {
                return kf.get_string_list(group, key);
            } catch (Error e) {
                return new string[0];
            }
        }
    }
}
