namespace AppManager.Core {
    /**
     * The permission model behind the "Privacy & Security" page: presets, the rules
     * for deciding which preset a set of toggles corresponds to, and the paths the
     * sandbox occupies. Persisting the permissions is SandboxManifest's job; turning
     * them into a command line is SandboxBwrap's.
     *
     * Every toggle reads as a permission, so true always means "the app is allowed
     * this", matching the UI switches one-for-one.
     */
    public class SandboxConfig {
        /**
         * Applies a named preset's permissions to the record and stamps the profile.
         * "custom" and "off" carry no permissions of their own, so they only set the label.
         *
         * Both real presets keep hardware acceleration on: software rendering makes
         * apps unusably slow without materially improving isolation.
         */
        public static void apply_preset(InstallationRecord record, string profile) {
            switch (profile) {
                case SANDBOX_PROFILE_STANDARD:
                    apply_toggles(record, true);
                    break;
                case SANDBOX_PROFILE_STRICT:
                    apply_toggles(record, false);
                    break;
                default:
                    break;
            }
            record.sandbox_profile = profile;
        }

        /**
         * The two presets differ only in whether the "convenience" permissions are
         * granted; everything else is fixed. `open` selects Standard over Strict.
         */
        private static void apply_toggles(InstallationRecord record, bool open) {
            record.sandbox_allow_network = open;
            record.sandbox_allow_audio = open;
            record.sandbox_allow_x11 = open;
            record.sandbox_allow_notifications = open;
            record.sandbox_allow_downloads = open;
            // Desktop integration is baseline: both presets keep it, and AppHub
            // templates can state otherwise. It is not part of what Strict removes.
            record.sandbox_allow_tray = true;
            record.sandbox_allow_media_controls = true;
            record.sandbox_allow_accessibility = true;

            record.sandbox_allow_gpu = true;

            record.sandbox_allow_dbus = false;
            record.sandbox_allow_camera = false;
            record.sandbox_allow_input = false;
            record.sandbox_allow_security_keys = false;
            record.sandbox_allow_bluetooth = false;
            record.sandbox_allow_location = false;
            record.sandbox_allow_network_info = false;
            record.sandbox_allow_keyring = false;
            record.sandbox_allow_online_accounts = false;
            record.sandbox_allow_polkit = false;
            record.sandbox_allow_screenshots = false;

            record.sandbox_allow_documents = false;
            record.sandbox_allow_desktop = false;
            record.sandbox_allow_pictures = false;
            record.sandbox_allow_videos = false;
            record.sandbox_allow_music = false;
            // Explicit special-folder grants supplement every preset/template.
            record.sandbox_read_only_dirs = null;
            record.sandbox_other_dirs = null;
            record.sandbox_display = null;
            record.sandbox_share_processes = false;
            record.sandbox_share_ipc = false;
            record.sandbox_session_bus = null;
            record.sandbox_system_bus = null;
            record.sandbox_session_rules = null;
            record.sandbox_system_rules = null;
            record.sandbox_extra_devices = null;
        }

        /**
         * Returns the preset whose permissions match the record's current state,
         * or "custom" when none does. Never returns "off" - callers decide that
         * from sandbox_enabled().
         */
        public static string detect_profile(InstallationRecord record) {
            if (matches_apphub(record)) return SANDBOX_PROFILE_APPHUB;
            if (matches(record, true)) {
                return SANDBOX_PROFILE_STANDARD;
            }
            if (matches(record, false)) {
                return SANDBOX_PROFILE_STRICT;
            }
            return SANDBOX_PROFILE_CUSTOM;
        }

        public static bool has_apphub_profile(InstallationRecord record) {
            if (record.apphub_id == null || record.apphub_policy == null) return false;
            try {
                AppHubPolicy.parse(record.apphub_id, record.apphub_policy);
                return true;
            } catch (Error e) { return false; }
        }

        public static void restore_apphub_profile(InstallationRecord record) throws Error {
            if (record.apphub_id == null || record.apphub_policy == null) throw new IOError.NOT_FOUND("No downloaded AppHub profile");
            var policy = AppHubPolicy.parse(record.apphub_id, record.apphub_policy);
            policy.apply(record);
        }

        private static bool same_set(string[]? a, string[]? b) {
            var left = new Gee.HashSet<string>();
            var right = new Gee.HashSet<string>();
            foreach (var value in a ?? new string[0]) left.add(value);
            foreach (var value in b ?? new string[0]) right.add(value);
            if (left.size != right.size) return false;
            foreach (var value in left) if (!right.contains(value)) return false;
            return true;
        }

        private static bool matches_apphub(InstallationRecord record) {
            if (!record.sandbox_enabled() || record.apphub_id == null || record.apphub_policy == null) return false;
            try {
                var expected = new InstallationRecord(record.id, record.name, record.mode);
                expected.is_terminal = record.is_terminal;
                expected.original_name = record.original_name;
                expected.desktop_file = record.desktop_file;
                expected.appstream_id = record.appstream_id;
                expected.original_startup_wm_class = record.original_startup_wm_class;
                expected.copy_index = record.copy_index;
                AppHubPolicy.parse(record.apphub_id, record.apphub_policy).apply(expected);
                bool[] actual_flags = { record.sandbox_allow_network, record.sandbox_allow_audio, record.sandbox_allow_x11,
                    record.sandbox_allow_gpu, record.sandbox_allow_camera, record.sandbox_allow_input, record.sandbox_allow_dbus,
                    record.sandbox_allow_notifications, record.sandbox_allow_tray, record.sandbox_allow_media_controls,
                    record.sandbox_allow_accessibility, record.sandbox_allow_network_info, record.sandbox_allow_bluetooth,
                    record.sandbox_allow_location, record.sandbox_allow_keyring, record.sandbox_allow_online_accounts,
                    record.sandbox_allow_polkit, record.sandbox_allow_screenshots, record.sandbox_share_processes,
                    record.sandbox_share_ipc, record.sandbox_allow_security_keys };
                bool[] wanted_flags = { expected.sandbox_allow_network, expected.sandbox_allow_audio, expected.sandbox_allow_x11,
                    expected.sandbox_allow_gpu, expected.sandbox_allow_camera, expected.sandbox_allow_input, expected.sandbox_allow_dbus,
                    expected.sandbox_allow_notifications, expected.sandbox_allow_tray, expected.sandbox_allow_media_controls,
                    expected.sandbox_allow_accessibility, expected.sandbox_allow_network_info, expected.sandbox_allow_bluetooth,
                    expected.sandbox_allow_location, expected.sandbox_allow_keyring, expected.sandbox_allow_online_accounts,
                    expected.sandbox_allow_polkit, expected.sandbox_allow_screenshots, expected.sandbox_share_processes,
                    expected.sandbox_share_ipc, expected.sandbox_allow_security_keys };
                for (int i = 0; i < actual_flags.length; i++) if (actual_flags[i] != wanted_flags[i]) return false;
                foreach (var location in new string[] { "downloads", "documents", "desktop", "pictures", "videos", "music" }) {
                    if (folder_access(record, location) != folder_access(expected, location)) return false;
                }
                return record.sandbox_display == expected.sandbox_display
                    && (record.sandbox_system_bus == "full") == (expected.sandbox_system_bus == "full")
                    && same_set(record.sandbox_other_dirs, expected.sandbox_other_dirs)
                    && same_set(record.sandbox_session_rules, expected.sandbox_session_rules)
                    && same_set(record.sandbox_system_rules, expected.sandbox_system_rules)
                    && same_set(record.sandbox_extra_devices, expected.sandbox_extra_devices)
                    && same_set(SandboxIdentity.media_names_for(record), SandboxIdentity.media_names_for(expected));
            } catch (Error e) { return false; }
        }

        private static bool matches(InstallationRecord r, bool open) {
            return r.sandbox_allow_network == open
                && r.sandbox_allow_audio == open
                && r.sandbox_allow_x11 == open
                && r.sandbox_allow_notifications == open
                && r.sandbox_allow_downloads == open
                && r.sandbox_allow_tray
                && r.sandbox_allow_media_controls
                && r.sandbox_allow_accessibility
                && r.sandbox_allow_gpu
                && !r.sandbox_allow_dbus
                && !r.sandbox_allow_camera
                && !r.sandbox_allow_input
                && !r.sandbox_allow_security_keys
                && !r.sandbox_allow_bluetooth
                && !r.sandbox_allow_location
                && !r.sandbox_allow_network_info
                && !r.sandbox_allow_keyring
                && !r.sandbox_allow_online_accounts
                && !r.sandbox_allow_polkit
                && !r.sandbox_allow_screenshots
                && !r.sandbox_allow_documents
                && !r.sandbox_allow_desktop
                && !r.sandbox_allow_pictures
                && !r.sandbox_allow_videos
                && !r.sandbox_allow_music
                && !r.sandbox_share_processes && !r.sandbox_share_ipc
                && r.sandbox_display == null && r.sandbox_session_bus == null && r.sandbox_system_bus == null
                && (r.sandbox_read_only_dirs == null || r.sandbox_read_only_dirs.length == 0)
                && (r.sandbox_other_dirs == null || r.sandbox_other_dirs.length == 0)
                && (r.sandbox_session_rules == null || r.sandbox_session_rules.length == 0)
                && (r.sandbox_system_rules == null || r.sandbox_system_rules.length == 0)
                && (r.sandbox_extra_devices == null || r.sandbox_extra_devices.length == 0)
                && (r.sandbox_extra_dirs == null || r.sandbox_extra_dirs.length == 0);
        }

        /**
         * Path of the app's persistent sandboxed home. Mirrors the existing
         * <installed_path>.home / .config convention.
         *
         * An explicit path outside the AppImage's own portable-home names is required:
         * <installed_path>.home would be adopted by the AppImage runtime as a portable
         * home, silently flipping AppManager's own portable .home toggle.
         */
        public static string sandbox_home_path(InstallationRecord record) {
            return "%s.sandbox".printf(record.installed_path ?? "");
        }

        /**
         * Whether this record can actually be sandboxed. EXTRACTED installs are
         * excluded for now: the engine mounts a single AppImage file, and an extracted
         * AppDir would need a different (read-only bind) path that is not implemented.
         */
        public static int folder_access(InstallationRecord record, string location) {
            bool allowed = false;
            switch (location) {
                case "downloads": allowed = record.sandbox_allow_downloads; break;
                case "documents": allowed = record.sandbox_allow_documents; break;
                case "desktop": allowed = record.sandbox_allow_desktop; break;
                case "pictures": allowed = record.sandbox_allow_pictures; break;
                case "videos": allowed = record.sandbox_allow_videos; break;
                case "music": allowed = record.sandbox_allow_music; break;
            }
            if (!allowed) return 0;
            return location in (record.sandbox_read_only_dirs ?? new string[0]) ? 1 : 2;
        }

        public static void set_folder_access(InstallationRecord record, string location, int access) {
            bool allowed = access != 0;
            switch (location) {
                case "downloads": record.sandbox_allow_downloads = allowed; break;
                case "documents": record.sandbox_allow_documents = allowed; break;
                case "desktop": record.sandbox_allow_desktop = allowed; break;
                case "pictures": record.sandbox_allow_pictures = allowed; break;
                case "videos": record.sandbox_allow_videos = allowed; break;
                case "music": record.sandbox_allow_music = allowed; break;
            }
            var read_only = new Gee.ArrayList<string>();
            foreach (var name in record.sandbox_read_only_dirs ?? new string[0]) {
                if (name != location) read_only.add(name);
            }
            if (access == 1) read_only.add(location);
            record.sandbox_read_only_dirs = read_only.size == 0 ? null : read_only.to_array();
        }

        public static bool service_has_full_bus(InstallationRecord r, string service) {
            if (service in new string[] { "bluetooth", "location", "network-information" }) return r.sandbox_system_bus == "full";
            return r.sandbox_allow_dbus && service in new string[] { "notifications", "system-tray", "media-controls", "keyring", "online-accounts", "screenshots" };
        }

        public static bool service_enabled(InstallationRecord r, string service) {
            if (service_has_full_bus(r, service)) return true;
            bool enabled = false;
            switch (service) {
                case "notifications": enabled = r.sandbox_allow_notifications; break;
                case "system-tray": enabled = r.sandbox_allow_tray; break;
                case "media-controls": enabled = r.sandbox_allow_media_controls; break;
                case "accessibility": return r.sandbox_allow_accessibility;
                // The switch alone: a full system bus or an imported rule reaches
                // polkit, but only the switch shares the host pids it checks.
                case "system-authentication": return r.sandbox_allow_polkit;
                // A rule for the whole portal grants far more than screenshots, so
                // it does not count as this switch.
                case "screenshots": return r.sandbox_allow_screenshots;
                case "bluetooth": enabled = r.sandbox_allow_bluetooth; break;
                case "location": enabled = r.sandbox_allow_location; break;
                case "network-information": enabled = r.sandbox_allow_network_info; break;
                case "keyring": enabled = r.sandbox_allow_keyring; break;
                case "online-accounts": enabled = r.sandbox_allow_online_accounts; break;
            }
            if (enabled) return true;
            bool system_service = service in new string[] { "bluetooth", "location", "network-information" };
            var rules = system_service ? r.sandbox_system_rules : r.sandbox_session_rules;
            foreach (var rule in rules ?? new string[0]) {
                if (!rule.has_prefix("see:") && service_rule_matches(r, service, rule)) return true;
            }
            return false;
        }

        private static bool service_rule_matches(InstallationRecord r, string service, string rule) {
            int colon = rule.index_of_char(':');
            if (colon < 0) return false;
            var name = rule.substring(colon + 1);
            switch (service) {
                case "notifications": return name == "org.freedesktop.Notifications" || name == "org.gtk.Notifications";
                case "system-tray": return name == "org.kde.StatusNotifierWatcher" || name.has_prefix("org.kde.StatusNotifierItem-");
                case "media-controls": return name.has_prefix("org.mpris.MediaPlayer2.");
                case "bluetooth": return name == "org.bluez";
                case "location": return name == "org.freedesktop.GeoClue2";
                case "network-information": return name == "org.freedesktop.NetworkManager";
                case "keyring": return name in SandboxDbusProxy.KEYRING_NAMES;
                case "online-accounts":
                    return name in SandboxDbusProxy.ONLINE_ACCOUNTS_NAMES
                        || name.has_prefix(SandboxDbusProxy.EVOLUTION_DATASERVER_NAMESPACE + ".");
            }
            return false;
        }

        public static void set_service_access(InstallationRecord r, string service, bool allowed) {
            if (service == "media-controls" && (r.sandbox_media_names == null || r.sandbox_media_names.length == 0)) {
                var names = new Gee.ArrayList<string>();
                foreach (var rule in r.sandbox_session_rules ?? new string[0]) {
                    if (rule.has_prefix("own:org.mpris.MediaPlayer2.")) names.add(rule.substring(4));
                }
                if (names.size > 0) r.sandbox_media_names = names.to_array();
            }
            switch (service) {
                case "notifications": r.sandbox_allow_notifications = allowed; break;
                case "system-tray": r.sandbox_allow_tray = allowed; break;
                case "media-controls": r.sandbox_allow_media_controls = allowed; break;
                case "accessibility": r.sandbox_allow_accessibility = allowed; break;
                case "bluetooth": r.sandbox_allow_bluetooth = allowed; break;
                case "location": r.sandbox_allow_location = allowed; break;
                case "network-information": r.sandbox_allow_network_info = allowed; break;
                case "keyring": r.sandbox_allow_keyring = allowed; break;
                case "online-accounts": r.sandbox_allow_online_accounts = allowed; break;
                case "system-authentication": r.sandbox_allow_polkit = allowed; break;
                case "screenshots": r.sandbox_allow_screenshots = allowed; break;
            }
            // A user override replaces equivalent imported rules, rather than leaving
            // an invisible grant behind an Off switch. Unrelated rules stay intact.
            var session = new Gee.ArrayList<string>();
            bool system_service = service in new string[] { "bluetooth", "location", "network-information" };
            foreach (var rule in r.sandbox_session_rules ?? new string[0]) {
                if (system_service || !service_rule_matches(r, service, rule)) session.add(rule);
            }
            var system = new Gee.ArrayList<string>();
            foreach (var rule in r.sandbox_system_rules ?? new string[0]) {
                if (!system_service || !service_rule_matches(r, service, rule)) system.add(rule);
            }
            r.sandbox_session_rules = session.size > 0 ? session.to_array() : null;
            r.sandbox_system_rules = system.size > 0 ? system.to_array() : null;
        }

        public static bool supports_record(InstallationRecord record) {
            return record.mode == InstallMode.PORTABLE
                && record.installed_path != null
                && record.installed_path.strip() != ""
                && !record.is_self_app();
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

        // What the sandbox provides itself at the top of $XDG_RUNTIME_DIR, plus the raw
        // sockets behind its filtered ones: the session bus, the a11y bus and systemd's
        // private socket each give the app the whole desktop.
        private const string[] RESERVED_RUNTIME_ENTRIES = { "bus", "pulse", "Xauthority", "pulse-client.conf", "at-spi", "systemd" };

        /**
         * The path below $XDG_RUNTIME_DIR a Flatpak "xdg-run/<path>[:ro|:rw|:create]"
         * grant names, with its mode (rw when unstated), or null when it is not one or
         * would reach a reserved entry, AppManager's runtime files or another sandbox's.
         */
        public static string? runtime_grant(string token, out string mode) {
            mode = "rw";
            var spec = token.strip();
            if (!spec.has_prefix("xdg-run/")) return null;
            spec = spec.substring("xdg-run/".length);
            foreach (var suffix in new string[] { "ro", "rw", "create" }) {
                if (spec.has_suffix(":" + suffix)) {
                    mode = suffix;
                    spec = spec.substring(0, spec.length - suffix.length - 1);
                    break;
                }
            }
            if (spec == "") return null;
            var parts = spec.split("/");
            foreach (var part in parts) {
                if (part == "" || part == "." || part == ".." || ":" in part) return null;
            }
            var first = parts[0];
            if (first in RESERVED_RUNTIME_ENTRIES || first.has_prefix("wayland-") || first.has_prefix("pipewire-")
                || first == DATA_DIRNAME || first.has_prefix(DATA_DIRNAME + "-")) {
                return null;
            }
            return spec;
        }

        /**
         * A granted-folder entry without its ":rw" access suffix.
         */
        public static string strip_access_suffix(string entry) {
            var trimmed = entry.strip();
            return trimmed.has_suffix(":rw") ? trimmed.substring(0, trimmed.length - 3) : trimmed;
        }

        /**
         * Folders the user granted to every sandboxed app, in the same "path[:rw]"
         * form as a record's own extra dirs. Empty entries are dropped so a stale
         * GSettings value cannot turn into a bind of "".
         */
        public static string[] global_extra_dirs() {
            var settings = new Settings(APPLICATION_ID);
            var kept = new Gee.ArrayList<string>();
            foreach (var entry in settings.get_strv("sandbox-global-dirs")) {
                if (entry != null && entry.strip() != "") {
                    kept.add(entry.strip());
                }
            }
            return kept.to_array();
        }

        /**
         * Writes a record's manifest, or removes it when the record is not sandboxed.
         * Single entry point so callers never have to think about which of the two
         * they want.
         *
         * `existing` is only needed to keep two records from being handed the same
         * sandbox app id; pass the registry contents where they are at hand.
         */
        public static bool sync_manifest(InstallationRecord record, InstallationRecord[]? existing = null) {
            if (record.sandbox_enabled()) {
                SandboxIdentity.ensure_app_id(record, existing);
                return SandboxManifest.write_for_record(record);
            } else {
                SandboxManifest.remove(record.id);
                return !SandboxManifest.exists(record.id);
            }
        }

        /**
         * Rewrites the manifest of every sandboxed record and drops the file of any
         * record that is no longer sandboxed.
         *
         * Called at startup so a change to the manifest format or to what a permission
         * implies reaches apps that were sandboxed by an older build. Writing them is
         * cheap - a few hundred bytes each - and the launcher reads the file fresh on
         * every launch, so the next start picks it up.
         *
         * Returns true when a record was modified - an app id was assigned to one that
         * had none - and the registry therefore needs persisting. Without that the id
         * would be generated afresh on every start, and the Wayland security context
         * keyed by it would stop identifying the app.
         */
        public static bool refresh_all(InstallationRecord[] records) {
            // Sorted so that, if two apps of the same name both need an id, which one
            // gets the "_2" suffix does not depend on hash-table order.
            var ordered = new Gee.ArrayList<InstallationRecord>();
            foreach (var record in records) {
                ordered.add(record);
            }
            ordered.sort((a, b) => strcmp(a.id, b.id));

            bool changed = false;
            var live = new Gee.HashSet<string>();
            foreach (var record in ordered) {
                if (record.sandbox_enabled()) {
                    if (record.sandbox_app_id == null || record.sandbox_app_id.strip() == "") {
                        SandboxIdentity.ensure_app_id(record, records);
                        changed = true;
                    }
                    SandboxManifest.write_for_record(record);
                    live.add("%s%s".printf(record.id, SANDBOX_MANIFEST_SUFFIX));
                } else {
                    SandboxManifest.remove(record.id);
                }
            }

            // Drop files left behind by records that vanished without an uninstall
            // (a hand-edited registry, a restored backup), so the directory cannot
            // grow without bound. ".args" files come from unreleased test builds of
            // the first sandbox implementation and are never read again.
            try {
                var dir = Dir.open(AppPaths.sandbox_dir);
                var orphans = new Gee.ArrayList<string>();
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_suffix(".args")
                        || (name.has_suffix(SANDBOX_MANIFEST_SUFFIX) && !live.contains(name))) {
                        orphans.add(name);
                    }
                }
                foreach (var orphan in orphans) {
                    var file = File.new_for_path(Path.build_filename(AppPaths.sandbox_dir, orphan));
                    file.delete(null);
                    debug("Removed orphaned sandbox file %s", orphan);
                }
            } catch (Error e) {
                debug("Could not scan sandbox dir for orphans: %s", e.message);
            }
            return changed;
        }
    }
}
