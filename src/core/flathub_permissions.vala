using Gee;

namespace AppManager.Core {
    /**
     * Flathub's published permissions for an app, translated into the sandbox model.
     * The match rests on the id the AppImage declares about itself, which anyone can
     * copy, so this is only ever offered as a suggestion the user confirms.
     */
    public class FlathubPermissions : Object {
        public const string API_BASE = "https://flathub.org/api/v2/summary/";
        public string app_id { get; private set; }
        private Json.Object permissions;

        private FlathubPermissions(string app_id, Json.Object permissions) {
            this.app_id = app_id;
            this.permissions = permissions;
        }

        /** Null when the summary carries no build metadata (an unknown or removed app). */
        public static FlathubPermissions? parse(string app_id, string json) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(json);
            return from_root(app_id, parser.get_root());
        }

        private static FlathubPermissions? from_root(string app_id, Json.Node? root) {
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
            var metadata = root.get_object().get_member("metadata");
            if (metadata == null || metadata.get_node_type() != Json.NodeType.OBJECT) return null;
            var node = metadata.get_object().get_member("permissions");
            var permissions = node != null && node.get_node_type() == Json.NodeType.OBJECT
                ? node.get_object() : new Json.Object();
            return new FlathubPermissions(app_id, permissions);
        }

        /** The first of `ids` Flathub knows, or null when it knows none. */
        public static FlathubPermissions? lookup(string[] ids, Cancellable? cancellable = null) throws Error {
            var session = new Soup.Session();
            session.timeout = 30;
            session.user_agent = "AppManager/" + APPLICATION_VERSION;
            foreach (var id in ids) {
                if (!AppHubPolicy.valid_id(id)) continue;
                FlathubPermissions? found = null;
                TlsSession.with_session(() => {
                    var message = new Soup.Message("GET", API_BASE + id);
                    var bytes = session.send_and_read(message, cancellable);
                    if (message.status_code == 404) return;
                    if (message.status_code != 200 || message.uri.get_host() != "flathub.org") {
                        throw new IOError.FAILED(_("Unable to retrieve Flathub permissions (HTTP %u)").printf(message.status_code));
                    }
                    var parser = new Json.Parser();
                    parser.load_from_stream(new MemoryInputStream.from_bytes(bytes), cancellable);
                    found = from_root(id, parser.get_root());
                });
                if (found != null) return found;
            }
            return null;
        }

        /**
         * After a fresh install, flags the record when Flathub has the app, so the
         * details page can point at the Flathub profile once. Runs in the background
         * and stays silent offline: the profile is still there to pick later.
         */
        public static void check_new_install(InstallationRegistry registry, InstallationRecord record) {
            if (!should_check(record)) return;
            var ids = candidate_ids(record);
            var id = record.id;
            var checksum = record.source_checksum;
            new Thread<void>("flathub-check", () => {
                try {
                    var found = lookup(ids);
                    var flathub_id = found != null ? found.app_id : null;
                    Idle.add(() => {
                        registry.set_flathub_result(id, checksum, flathub_id);
                        return Source.REMOVE;
                    });
                } catch (Error e) {
                    // Left unchecked, so the details page can try again later.
                    debug("Flathub check for %s failed: %s", id, e.message);
                }
            });
        }

        /** Whether a lookup could offer anything: AppHub's verified template wins. */
        public static bool should_check(InstallationRecord record) {
            return !record.flathub_checked && record.apphub_id == null && AppPaths.sandbox_available
                && SandboxConfig.supports_record(record) && candidate_ids(record).length > 0;
        }

        // Release channels upstreams append to their id while Flathub lists the plain
        // one: GIMP's AppImage is org.gimp.GIMP.Stable, Flathub's org.gimp.GIMP.
        private const string[] CHANNEL_SUFFIXES = { ".Stable", ".Devel", ".Nightly", ".Beta" };

        /**
         * The ids to try on Flathub, in order: those the app declares (desktop file,
         * matched AppStream id, window class), then the same without a channel
         * suffix, as long as a three-part id remains.
         */
        public static string[] candidate_ids(InstallationRecord record) {
            var ids = new ArrayList<string>();
            foreach (var id in SandboxIdentity.own_names_for(record)) ids.add(id);
            foreach (var id in SandboxIdentity.own_names_for(record)) {
                foreach (var suffix in CHANNEL_SUFFIXES) {
                    if (!id.has_suffix(suffix)) continue;
                    var plain = id.substring(0, id.length - suffix.length);
                    if (plain.split(".").length >= 3 && !ids.contains(plain)) ids.add(plain);
                }
            }
            return ids.to_array();
        }

        private string[] strings(Json.Object obj, string key) {
            var list = new ArrayList<string>();
            var node = obj.get_member(key);
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY) return list.to_array();
            foreach (var item in node.get_array().get_elements()) {
                if (item.get_node_type() == Json.NodeType.VALUE && item.get_value_type() == typeof(string)) {
                    list.add(item.get_string());
                }
            }
            return list.to_array();
        }

        /**
         * Replaces the record's permissions with Flathub's and returns the Flatpak
         * options that have no equivalent here, spelled as on the flatpak command line.
         * Special folders the user added survive, as they do with every preset.
         */
        public string[] apply(InstallationRecord record) {
            var skipped = new ArrayList<string>();
            // Every Flatpak reaches these through portals, so a manifest that lists
            // nothing says nothing: keep the current choice, and add what it lists.
            bool screenshots = record.sandbox_allow_screenshots;
            bool geolocation = record.sandbox_allow_location;
            bool network_info = record.sandbox_allow_network_info;
            bool keyring = record.sandbox_allow_keyring;
            bool camera = record.sandbox_allow_camera;
            SandboxConfig.apply_preset(record, SANDBOX_PROFILE_STRICT);
            record.sandbox_media_names = null;
            record.sandbox_allow_screenshots = screenshots;
            record.sandbox_allow_location = geolocation;
            record.sandbox_allow_network_info = network_info;
            record.sandbox_allow_keyring = keyring;
            record.sandbox_allow_camera = camera;

            // --share=ipc is X11 shared-memory boilerplate in nearly every manifest;
            // apps run without it here, so it is dropped rather than reported.
            record.sandbox_allow_network = "network" in strings(permissions, "shared");

            var sockets = strings(permissions, "sockets");
            bool wayland = "wayland" in sockets;
            bool x11 = "x11" in sockets;
            bool fallback = "fallback-x11" in sockets;
            string display = wayland ? (x11 ? "legacy" : fallback ? "wayland-or-x11" : "wayland")
                                     : (x11 || fallback ? "x11" : "none");
            record.sandbox_display = display == "legacy" ? null : display;
            record.sandbox_allow_x11 = display != "wayland" && display != "none";
            record.sandbox_allow_audio = "pulseaudio" in sockets;
            foreach (var socket in sockets) {
                switch (socket) {
                    case "wayland": case "x11": case "fallback-x11": case "pulseaudio": break;
                    case "session-bus": record.sandbox_allow_dbus = true; break;
                    case "system-bus": record.sandbox_system_bus = "full"; break;
                    default: skipped.add("--socket=" + socket); break;
                }
            }

            // Every Flatpak reaches these through portals or the a11y bus, so Flathub
            // never lists them; keep the desktop baseline AppHub templates start from.
            bool desktop = !record.is_terminal && display != "none";
            record.sandbox_allow_notifications = desktop;
            record.sandbox_allow_tray = desktop;
            record.sandbox_allow_media_controls = desktop;
            record.sandbox_allow_accessibility = desktop;

            record.sandbox_allow_gpu = false;
            var extra_devices = new ArrayList<string>();
            foreach (var device in strings(permissions, "devices")) {
                switch (device) {
                    case "dri": record.sandbox_allow_gpu = true; break;
                    case "input": record.sandbox_allow_input = true; break;
                    case "kvm": case "usb":
                        if (!extra_devices.contains(device)) extra_devices.add(device);
                        break;
                    // All means all: every device switch the page has, plus every raw
                    // device class the sandbox can bind.
                    case "all":
                        record.sandbox_allow_gpu = true;
                        record.sandbox_allow_camera = true;
                        record.sandbox_allow_input = true;
                        record.sandbox_allow_security_keys = true;
                        foreach (var category in new string[] { "usb", "serial", "optical", "kvm" }) {
                            if (!extra_devices.contains(category)) extra_devices.add(category);
                        }
                        break;
                    default: skipped.add("--device=" + device); break;
                }
            }
            record.sandbox_extra_devices = extra_devices.size > 0 ? extra_devices.to_array() : null;

            var others = new HashMap<string, bool>();
            // Paths with no switch of their own, judged once every grant is known.
            var unmapped = new ArrayList<string>();
            foreach (var entry in strings(permissions, "filesystems")) {
                var spec = entry;
                var mode = "rw";
                int colon = entry.last_index_of_char(':');
                if (colon > 0) {
                    spec = entry.substring(0, colon);
                    mode = entry.substring(colon + 1);
                }
                bool writable = mode != "ro";
                string? folder = null;
                string[] locations = new string[0];
                switch (spec) {
                    case "xdg-download": folder = "downloads"; break;
                    case "xdg-documents": folder = "documents"; break;
                    case "xdg-desktop": folder = "desktop"; break;
                    case "xdg-pictures": folder = "pictures"; break;
                    case "xdg-videos": folder = "videos"; break;
                    case "xdg-music": folder = "music"; break;
                    case "xdg-public-share": locations = new string[] { "public-share" }; break;
                    case "xdg-templates": locations = new string[] { "templates" }; break;
                    case "home": case "~": locations = new string[] { "home" }; break;
                    case "/media": case "/mnt": case "/run/media": locations = new string[] { "removable-media" }; break;
                    // The closest grant there is: the user's own files and mounted drives.
                    case "host": locations = new string[] { "home", "removable-media" }; break;
                }
                if (!(mode in new string[] { "ro", "rw", "create" })) {
                    skipped.add("--filesystem=" + entry);
                } else if (folder == null && locations.length == 0) {
                    unmapped.add(entry);
                } else if (folder != null) {
                    SandboxConfig.set_folder_access(record, folder, int.max(SandboxConfig.folder_access(record, folder), writable ? 2 : 1));
                } else {
                    foreach (var location in locations) {
                        others.set(location, writable || (others.has_key(location) && others.get(location)));
                    }
                }
            }
            var other_dirs = new ArrayList<string>();
            foreach (var location in others.keys) other_dirs.add(location + (others.get(location) ? ":rw" : ":ro"));
            other_dirs.sort();
            record.sandbox_other_dirs = other_dirs.size > 0 ? other_dirs.to_array() : null;
            var reachable = reachable_paths(record);
            foreach (var entry in unmapped) {
                int colon = entry.last_index_of_char(':');
                var path = host_path(colon > 0 ? entry.substring(0, colon) : entry);
                if (path == null || !covered(reachable, path)) skipped.add("--filesystem=" + entry);
            }

            apply_bus(record, "session-bus");
            apply_bus(record, "system-bus");
            // Judge each name against the rules the proxy will actually build, so a
            // name a switch brings along (Online accounts grants Contacts) is not
            // reported as missing.
            var manifest = SandboxManifest.from_record(record);
            if (!record.sandbox_allow_dbus) report_bus("session-bus", SandboxDbusProxy.session_rules(manifest), skipped);
            if (record.sandbox_system_bus != "full") report_bus("system-bus", SandboxDbusProxy.system_rules(manifest), skipped);

            foreach (var key in permissions.get_members()) {
                if (!(key in new string[] { "shared", "sockets", "devices", "filesystems", "session-bus", "system-bus" })) {
                    foreach (var value in strings(permissions, key)) skipped.add("%s=%s".printf(key, value));
                }
            }
            record.sandbox_profile = SANDBOX_PROFILE_FLATHUB;
            return skipped.to_array();
        }

        // The host path a Flatpak filesystem entry names; null for xdg-run and the
        // like, which point at per-session places no grant here reaches.
        private static string? host_path(string spec) {
            if (spec.has_prefix("~/")) return Path.build_filename(Environment.get_home_dir(), spec.substring(2));
            if (spec.has_prefix("xdg-config/")) return Path.build_filename(Environment.get_user_config_dir(), spec.substring("xdg-config/".length));
            if (spec.has_prefix("xdg-data/")) return Path.build_filename(Environment.get_user_data_dir(), spec.substring("xdg-data/".length));
            if (spec.has_prefix("xdg-cache/")) return Path.build_filename(Environment.get_user_cache_dir(), spec.substring("xdg-cache/".length));
            if (spec.has_prefix("/")) return spec;
            return null;
        }

        // What every sandbox of this record reaches regardless of the template:
        // shared theming, folders granted to every app, the app's special folders,
        // and the whole home when the template grants it.
        private static string[] reachable_paths(InstallationRecord record) {
            var paths = new ArrayList<string>();
            foreach (var path in SandboxBwrap.host_appearance_paths()) paths.add(path);
            foreach (var entry in SandboxConfig.global_extra_dirs()) paths.add(SandboxConfig.strip_access_suffix(entry));
            foreach (var entry in record.sandbox_extra_dirs ?? new string[0]) paths.add(SandboxConfig.strip_access_suffix(entry));
            foreach (var entry in record.sandbox_other_dirs ?? new string[0]) {
                if (entry.has_prefix("home:")) paths.add(Environment.get_home_dir());
            }
            return paths.to_array();
        }

        private static bool covered(string[] reachable, string path) {
            foreach (var root in reachable) {
                if (path == root || path.has_prefix(root + "/")) return true;
            }
            return false;
        }

        // Names that turn on one of the page's switches. Whether every requested
        // name is then reachable is report_bus's question.
        private void apply_bus(InstallationRecord record, string key) {
            var node = permissions.get_member(key);
            if (node == null || node.get_node_type() != Json.NodeType.OBJECT) return;
            foreach (var name in strings(node.get_object(), "talk")) {
                if (key == "system-bus") {
                    switch (name) {
                        case "org.freedesktop.NetworkManager": record.sandbox_allow_network_info = true; break;
                        case "org.freedesktop.GeoClue2": record.sandbox_allow_location = true; break;
                        case "org.bluez": record.sandbox_allow_bluetooth = true; break;
                    }
                } else if (name in SandboxDbusProxy.KEYRING_NAMES) {
                    record.sandbox_allow_keyring = true;
                } else if (name == "org.gnome.OnlineAccounts"
                    || name.has_prefix(SandboxDbusProxy.EVOLUTION_DATASERVER_NAMESPACE + ".")) {
                    record.sandbox_allow_online_accounts = true;
                } else if (name == "org.freedesktop.Notifications") {
                    record.sandbox_allow_notifications = true;
                } else if (name in SCREENSHOT_NAMES) {
                    record.sandbox_allow_screenshots = true;
                }
            }
            if (key != "session-bus") return;
            var media = new ArrayList<string>();
            foreach (var name in strings(node.get_object(), "own")) {
                if (AppHubPolicy.valid_media_name(name)) media.add(name);
            }
            if (media.size > 0) {
                record.sandbox_allow_media_controls = true;
                record.sandbox_media_names = media.to_array();
            }
        }

        // Reached by every app through narrower --call rules that cover what apps use.
        // org.freedesktop.ScreenSaver is not here: apps want it for Inhibit, which
        // stays refused.
        private const string[] CALL_ONLY_NAMES = {
            "com.canonical.AppMenu.Registrar", "com.canonical.AppMenu.Registrar.*", "org.freedesktop.login1",
            "org.gnome.ScreenSaver", "org.freedesktop.FileManager1"
        };

        // Desktop screenshot APIs that refuse third-party callers since 2021. Apps
        // still listing them (GIMP) take screenshots through the portal instead,
        // which the Screenshots switch grants; apply_bus turns it on for them.
        private const string[] SCREENSHOT_NAMES = { "org.gnome.Shell.Screenshot", "org.kde.kwin.Screenshot" };

        private void report_bus(string key, Gee.List<string> rules, ArrayList<string> skipped) {
            var node = permissions.get_member(key);
            if (node == null || node.get_node_type() != Json.NodeType.OBJECT) return;
            var prefix = key == "system-bus" ? "--system-" : "--";
            foreach (var access in new string[] { "talk", "own" }) {
                foreach (var name in strings(node.get_object(), access)) {
                    bool portal_screenshot = access == "talk" && name in SCREENSHOT_NAMES;
                    if (!(name in CALL_ONLY_NAMES) && !portal_screenshot && !granted(rules, access, name)) {
                        skipped.add("%s%s-name=%s".printf(prefix, access, name));
                    }
                }
            }
        }

        // As in xdg-dbus-proxy: owning implies talking, and "name.*" covers every
        // name below it but not the name itself.
        private static bool granted(Gee.List<string> rules, string access, string name) {
            foreach (var rule in rules) {
                string target;
                if (rule.has_prefix("--own=")) {
                    target = rule.substring("--own=".length);
                } else if (access == "talk" && rule.has_prefix("--talk=")) {
                    target = rule.substring("--talk=".length);
                } else {
                    continue;
                }
                if (target == name || (target.has_suffix(".*") && name.has_prefix(target.substring(0, target.length - 1)))) {
                    return true;
                }
            }
            return false;
        }
    }
}
