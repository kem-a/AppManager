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
        // The installed desktop entry, whose Exec line a mirrored login entry reuses.
        public string desktop_file = "";
        // Terminal apps skip --new-session, which would break job control for them.
        public bool terminal = false;

        public bool network = false;
        public bool audio = false;
        public bool x11 = false;
        public bool gpu = true;
        public bool camera = false;
        public bool input = false;
        public bool security_keys = false;
        public bool bluetooth = false;
        public bool notifications = false;
        public bool tray = false;
        public bool media_controls = false;
        public bool accessibility = false;
        public string[] media_names = new string[0];
        public bool location = false;
        public bool network_info = false;
        public bool keyring = false;
        public bool online_accounts = false;
        public bool polkit = false;
        public bool screenshots = false;
        public bool full_session_bus = false;
        public bool imported_policy = false;
        public string display = "legacy";
        public bool share_processes = false;
        public bool share_ipc = false;
        public string session_bus_access = "legacy";
        public string system_bus_access = "legacy";
        public string[] session_rules = new string[0];
        public string[] system_rules = new string[0];
        public string[] extra_devices = new string[0];

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
            m.desktop_file = record.desktop_file ?? "";
            m.terminal = record.is_terminal;

            m.network = record.sandbox_allow_network;
            m.audio = record.sandbox_allow_audio;
            m.x11 = record.sandbox_allow_x11;
            m.gpu = record.sandbox_allow_gpu;
            m.camera = record.sandbox_allow_camera;
            m.input = record.sandbox_allow_input;
            m.security_keys = record.sandbox_allow_security_keys;
            m.bluetooth = record.sandbox_allow_bluetooth;
            m.notifications = record.sandbox_allow_notifications;
            m.tray = record.sandbox_allow_tray;
            m.media_controls = record.sandbox_allow_media_controls;
            m.accessibility = record.sandbox_allow_accessibility;
            m.media_names = SandboxIdentity.media_names_for(record);
            m.location = record.sandbox_allow_location;
            m.network_info = record.sandbox_allow_network_info;
            m.keyring = record.sandbox_allow_keyring;
            m.online_accounts = record.sandbox_allow_online_accounts;
            m.polkit = record.sandbox_allow_polkit;
            m.screenshots = record.sandbox_allow_screenshots;
            m.full_session_bus = record.sandbox_allow_dbus;
            m.imported_policy = record.sandbox_session_bus != null || record.sandbox_system_bus != null;
            m.display = record.sandbox_display ?? "legacy";
            // Polkit looks the caller's pid up on the host. A namespaced pid names
            // another process there, and the check fails.
            m.share_processes = record.sandbox_share_processes || record.sandbox_allow_polkit;
            m.share_ipc = record.sandbox_share_ipc;
            m.session_bus_access = record.sandbox_session_bus ?? "legacy";
            m.system_bus_access = record.sandbox_system_bus ?? "legacy";
            m.session_rules = record.sandbox_session_rules ?? new string[0];
            m.system_rules = record.sandbox_system_rules ?? new string[0];
            m.extra_devices = record.sandbox_extra_devices ?? new string[0];

            var dirs = new Gee.ArrayList<string>();
            foreach (var location in new string[] { "downloads", "documents", "desktop", "pictures", "videos", "music" }) {
                int access = SandboxConfig.folder_access(record, location);
                if (access > 0) dirs.add(location + (access == 1 ? ":ro" : ""));
            }
            foreach (var entry in record.sandbox_other_dirs ?? new string[0]) dirs.add(entry);
            m.xdg_dirs = dirs.to_array();

            // The app's own folders first, then the ones granted to every sandboxed
            // app, so a folder listed in both keeps the app's own access mode.
            var requested = new Gee.ArrayList<string>();
            foreach (var entry in record.sandbox_extra_dirs ?? new string[0]) {
                requested.add(entry);
            }
            foreach (var entry in SandboxConfig.global_extra_dirs()) {
                requested.add(entry);
            }

            var extras = new Gee.ArrayList<string>();
            var seen = new Gee.HashSet<string>();
            foreach (var entry in requested) {
                if (entry == null || entry.strip() == "") {
                    continue;
                }
                var trimmed = entry.strip();
                var writable = trimmed.has_suffix(":rw");
                var path = writable ? trimmed.substring(0, trimmed.length - 3) : trimmed;
                // Resolve here as well as when the UI stores it, so entries written by
                // an older build are corrected too. See SandboxConfig.canonicalize.
                path = SandboxConfig.canonicalize(path);
                if (!seen.add(path)) {
                    continue;
                }
                extras.add(writable ? "%s:rw".printf(path) : path);
            }
            m.extra_dirs = extras.to_array();

            var env_list = new Gee.ArrayList<string>();
            foreach (var entry in record.get_effective_env_vars()) {
                if (entry != null && entry.strip() != "" && entry.contains("=")) {
                    env_list.add(entry);
                }
            }
            m.env = env_list.to_array();
            // Application identity is automatic whenever a session proxy is in play:
            // GApplication registration and single-instance handoff need it even when
            // no service is declared. Its absence is what made some apps crash once a
            // desktop service opened the filtered bus.
            bool session_bus_reason = m.notifications || m.tray || m.media_controls
                || m.accessibility || m.keyring || m.online_accounts || m.screenshots
                || m.session_rules.length > 0;
            var ownership = new Gee.ArrayList<string>();
            if (session_bus_reason) {
                foreach (var name in SandboxIdentity.own_names_for(record)) ownership.add(name);
                if (record.apphub_id != null && SandboxIdentity.is_ownable_bus_name(record.apphub_id)
                    && !ownership.contains(record.apphub_id)) ownership.add(record.apphub_id);
            }
            m.own_names = ownership.to_array();
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
                kf.set_string(GROUP_SANDBOX, "desktop-file", desktop_file);
                kf.set_boolean(GROUP_SANDBOX, "terminal", terminal);
                kf.set_boolean(GROUP_SANDBOX, "imported-policy", imported_policy);
                kf.set_string(GROUP_PERMISSIONS, "display", display);
                kf.set_boolean(GROUP_PERMISSIONS, "share-processes", share_processes);
                kf.set_boolean(GROUP_PERMISSIONS, "share-ipc", share_ipc);
                kf.set_string(GROUP_PERMISSIONS, "session-bus-access", session_bus_access);
                kf.set_string(GROUP_PERMISSIONS, "system-bus-access", system_bus_access);
                kf.set_string_list(GROUP_PERMISSIONS, "session-rules", session_rules);
                kf.set_string_list(GROUP_PERMISSIONS, "system-rules", system_rules);
                kf.set_string_list(GROUP_PERMISSIONS, "extra-devices", extra_devices);

                kf.set_boolean(GROUP_PERMISSIONS, "network", network);
                kf.set_boolean(GROUP_PERMISSIONS, "audio", audio);
                kf.set_boolean(GROUP_PERMISSIONS, "x11", x11);
                kf.set_boolean(GROUP_PERMISSIONS, "gpu", gpu);
                kf.set_boolean(GROUP_PERMISSIONS, "camera", camera);
                kf.set_boolean(GROUP_PERMISSIONS, "input", input);
                kf.set_boolean(GROUP_PERMISSIONS, "security-keys", security_keys);
                kf.set_boolean(GROUP_PERMISSIONS, "bluetooth", bluetooth);
                kf.set_boolean(GROUP_PERMISSIONS, "notifications", notifications);
                kf.set_boolean(GROUP_PERMISSIONS, "tray", tray);
                kf.set_boolean(GROUP_PERMISSIONS, "media-controls", media_controls);
                kf.set_boolean(GROUP_PERMISSIONS, "accessibility", accessibility);
                kf.set_string_list(GROUP_PERMISSIONS, "media-names", media_names);
                kf.set_boolean(GROUP_PERMISSIONS, "location", location);
                kf.set_boolean(GROUP_PERMISSIONS, "network-info", network_info);
                kf.set_boolean(GROUP_PERMISSIONS, "keyring", keyring);
                kf.set_boolean(GROUP_PERMISSIONS, "online-accounts", online_accounts);
                kf.set_boolean(GROUP_PERMISSIONS, "polkit", polkit);
                kf.set_boolean(GROUP_PERMISSIONS, "screenshots", screenshots);
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
            if (m.version < 1 || m.version > SANDBOX_MANIFEST_VERSION) {
                warning("Sandbox manifest %s is version %d, this build understands %d",
                    path, m.version, SANDBOX_MANIFEST_VERSION);
                return null;
            }

            m.app_id = read_string(kf, GROUP_SANDBOX, "app-id", "");
            m.profile = read_string(kf, GROUP_SANDBOX, "profile", SANDBOX_PROFILE_CUSTOM);
            m.appimage = read_string(kf, GROUP_SANDBOX, "appimage", "");
            m.home = read_string(kf, GROUP_SANDBOX, "home", "");
            m.desktop_file = read_string(kf, GROUP_SANDBOX, "desktop-file", "");
            m.terminal = read_bool(kf, GROUP_SANDBOX, "terminal", false);
            m.imported_policy = read_bool(kf, GROUP_SANDBOX, "imported-policy", false);
            m.display = read_string(kf, GROUP_PERMISSIONS, "display", "legacy");
            m.share_processes = read_bool(kf, GROUP_PERMISSIONS, "share-processes", false);
            m.share_ipc = read_bool(kf, GROUP_PERMISSIONS, "share-ipc", false);
            m.session_bus_access = read_string(kf, GROUP_PERMISSIONS, "session-bus-access", "legacy");
            m.system_bus_access = read_string(kf, GROUP_PERMISSIONS, "system-bus-access", "legacy");
            m.session_rules = read_list(kf, GROUP_PERMISSIONS, "session-rules");
            m.system_rules = read_list(kf, GROUP_PERMISSIONS, "system-rules");
            m.extra_devices = read_list(kf, GROUP_PERMISSIONS, "extra-devices");

            m.network = read_bool(kf, GROUP_PERMISSIONS, "network", false);
            m.audio = read_bool(kf, GROUP_PERMISSIONS, "audio", false);
            m.x11 = read_bool(kf, GROUP_PERMISSIONS, "x11", false);
            m.gpu = read_bool(kf, GROUP_PERMISSIONS, "gpu", true);
            m.camera = read_bool(kf, GROUP_PERMISSIONS, "camera", false);
            m.input = read_bool(kf, GROUP_PERMISSIONS, "input", false);
            m.security_keys = read_bool(kf, GROUP_PERMISSIONS, "security-keys", false);
            m.bluetooth = read_bool(kf, GROUP_PERMISSIONS, "bluetooth", false);
            m.notifications = read_bool(kf, GROUP_PERMISSIONS, "notifications", false);
            m.tray = read_bool(kf, GROUP_PERMISSIONS, "tray", false);
            m.media_controls = read_bool(kf, GROUP_PERMISSIONS, "media-controls", m.version < 3 && m.tray);
            m.media_names = read_list(kf, GROUP_PERMISSIONS, "media-names");
            m.location = read_bool(kf, GROUP_PERMISSIONS, "location", false);
            m.network_info = read_bool(kf, GROUP_PERMISSIONS, "network-info", false);
            m.keyring = read_bool(kf, GROUP_PERMISSIONS, "keyring", false);
            m.online_accounts = read_bool(kf, GROUP_PERMISSIONS, "online-accounts", false);
            m.polkit = read_bool(kf, GROUP_PERMISSIONS, "polkit", false);
            m.screenshots = read_bool(kf, GROUP_PERMISSIONS, "screenshots", false);
            m.full_session_bus = read_bool(kf, GROUP_PERMISSIONS, "full-session-bus", false);
            m.accessibility = read_bool(kf, GROUP_PERMISSIONS, "accessibility", m.version < 3 && (m.session_bus_access == "legacy" || m.full_session_bus));

            m.xdg_dirs = read_list(kf, GROUP_FILESYSTEM, "xdg-dirs");
            m.extra_dirs = read_list(kf, GROUP_FILESYSTEM, "extra");
            m.env = read_list(kf, GROUP_SANDBOX, "env");
            m.own_names = read_list(kf, GROUP_SANDBOX, "own-names");
            if (!(m.display in new string[] { "legacy", "none", "wayland", "x11", "wayland-or-x11" })
                || !(m.session_bus_access in new string[] { "legacy", "none", "filtered", "full" })
                || !(m.system_bus_access in new string[] { "legacy", "none", "filtered", "full" })
                || (m.imported_policy && m.version < 2)
                || !valid_rules(m.session_rules) || !valid_rules(m.system_rules)) {
                warning("Sandbox manifest %s contains an unsupported policy value", path);
                return null;
            }
            foreach (var device in m.extra_devices) {
                if (!(device in new string[] { "usb", "serial", "optical", "kvm" })) {
                    warning("Sandbox manifest %s contains an unsupported device category", path);
                    return null;
                }
            }
            foreach (var name in m.media_names) {
                if (!AppHubPolicy.valid_media_name(name)) {
                    warning("Sandbox manifest %s contains an invalid media ownership name", path);
                    return null;
                }
            }
            if (m.media_controls && m.media_names.length == 0) {
                var legacy = new InstallationRecord(record_id, Path.get_basename(m.appimage), InstallMode.PORTABLE);
                if (m.own_names.length > 0) legacy.desktop_file = m.own_names[0] + ".desktop";
                m.media_names = SandboxIdentity.media_names_for(legacy);
            }
            return m;
        }

        private static bool valid_rules(string[] rules) {
            foreach (var rule in rules) {
                int colon = rule.index_of_char(':');
                if (colon <= 0) return false;
                var access = rule.substring(0, colon);
                var name = rule.substring(colon + 1);
                if (!(access in new string[] { "see", "talk", "own" }) || !DBus.is_name(name) || name.has_prefix(":")) return false;
                if (access == "own" && !SandboxIdentity.is_ownable_bus_name(name)) return false;
            }
            return true;
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
         * full_session_bus on, the real session socket is bound instead; the system
         * bus can still need its own filtered proxy.
         *
         * own_names is what keeps an ordinary app on a session bus. Without it a Strict
         * profile - every service toggle off - would get no bus at all, and no bus means
         * no DBUS_SESSION_BUS_ADDRESS under --clearenv.
         */
        public bool needs_bus_proxy() {
            return needs_session_bus() || needs_system_bus();
        }

        public bool needs_session_bus() {
            return !full_session_bus && (notifications || tray || media_controls || (version >= 3 && accessibility) || keyring || online_accounts || screenshots || own_names.length > 0 || session_rules.length > 0);
        }

        /**
         * Whether a system proxy is needed: always for logind's sleep notices, unless
         * a store template asked for no system bus. Then only BlueZ, GeoClue2, network
         * information or polkit still need one.
         */
        public bool needs_system_bus() {
            return system_bus_access != "full" && (system_bus_access != "none"
                || bluetooth || location || network_info || polkit || system_rules.length > 0);
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
