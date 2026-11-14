using Gee;

namespace AppManager.Core {
    public errordomain AppHubPolicyError {
        INVALID,
        UNSUPPORTED,
        ARTIFACT_MISMATCH,
        UNAVAILABLE
    }

    public delegate string AppHubFetch(string resource, Cancellable? cancellable) throws Error;

    /** A validated AppHub template bound to a catalog application and artifact. */
    public class AppHubPolicy : Object {
        public const string API_BASE = "https://xlc-dev.github.io/apphub/api/v1/";
        public string app_id { get; private set; }
        public string json { get; private set; }
        public string? sha256 { get; private set; }
        private Json.Object policy;

        private AppHubPolicy(string app_id, Json.Node? node) throws Error {
            if (!valid_id(app_id)) fail("invalid application ID");
            if (node == null) fail("missing sandbox policy");
            this.app_id = app_id;
            validate(node);
            this.policy = node.get_object();
            var generator = new Json.Generator();
            generator.set_root(node);
            this.json = generator.to_data(null);
        }

        private static void fail(string detail) throws AppHubPolicyError {
            throw new AppHubPolicyError.INVALID(_("Invalid AppHub sandbox policy: %s").printf(detail));
        }

        public static bool valid_id(string id) {
            if (id.length < 2 || id.length > 255) return false;
            foreach (var c in id.to_utf8()) {
                if (!(c.isalnum() || c == '.' || c == '_' || c == '-')) return false;
            }
            return id[0].isalnum();
        }

        public static string string_value(Json.Object obj, string key) throws Error {
            if (!obj.has_member(key)) fail("missing field: " + key);
            var node = obj.get_member(key);
            if (node == null || node.get_node_type() != Json.NodeType.VALUE
                || node.get_value_type() != typeof(string)) fail("expected string: " + key);
            return node.get_string();
        }

        private static bool bool_value(Json.Object obj, string key) throws Error {
            if (!obj.has_member(key)) fail("missing field: " + key);
            var node = obj.get_member(key);
            if (node == null || node.get_node_type() != Json.NodeType.VALUE
                || node.get_value_type() != typeof(bool)) fail("expected boolean: " + key);
            return node.get_boolean();
        }

        private static Json.Array array_value(Json.Object obj, string key, uint limit) throws Error {
            if (!obj.has_member(key)) fail("missing field: " + key);
            var node = obj.get_member(key);
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY) fail("expected array: " + key);
            var array = node.get_array();
            if (array.get_length() > limit) fail("too many entries: " + key);
            return array;
        }

        private static Json.Object object_value(Json.Object obj, string key) throws Error {
            if (!obj.has_member(key)) fail("missing field: " + key);
            var node = obj.get_member(key);
            if (node == null || node.get_node_type() != Json.NodeType.OBJECT) fail("expected object: " + key);
            return node.get_object();
        }

        private static void keys(Json.Object obj, string[] allowed) throws Error {
            foreach (var key in obj.get_members()) {
                if (!(key in allowed)) fail("unknown field: " + key);
            }
        }

        private static string choice(Json.Object obj, string key, string[] allowed) throws Error {
            var value = string_value(obj, key);
            if (!(value in allowed)) fail("unknown " + key + ": " + value);
            return value;
        }

        private static void validate(Json.Node node, bool installing = true) throws Error {
            if (node.get_node_type() != Json.NodeType.OBJECT) fail("expected policy object");
            var p = node.get_object();
            bool extended = p.has_member("version");
            if (extended) {
                var version = p.get_member("version");
                if (version.get_node_type() != Json.NodeType.VALUE
                    || !((version.get_value_type() == typeof(int64) && version.get_int() == 2)
                        || (version.get_value_type() == typeof(double) && version.get_double() == 2.0))) fail("unsupported sandbox version");
                keys(p, { "version", "appearance", "desktopServices", "ownership", "network", "audio", "display", "processes", "ipc", "filesystem", "devices", "sessionBus", "systemBus" });
                // Old downloaded snapshots carried this retired setting.
                if (p.has_member("appearance")) choice(p, "appearance", { "shared", "private" });
                var services = new HashSet<string>();
                string[] known = { "notifications", "media-controls", "system-tray", "accessibility", "network-information", "location", "bluetooth", "online-accounts" };
                if (!p.has_member("desktopServices")) fail("missing desktopServices");
                if (p.get_member("desktopServices").get_node_type() == Json.NodeType.OBJECT) {
                    var settings = object_value(p, "desktopServices");
                    keys(settings, known);
                    foreach (var key in settings.get_members()) if (bool_value(settings, key)) services.add(key);
                } else {
                    foreach (var entry in array_value(p, "desktopServices", 7).get_elements()) {
                        if (entry.get_node_type() != Json.NodeType.VALUE || entry.get_value_type() != typeof(string)) fail("invalid desktop service");
                        var service = entry.get_string();
                        if (!(service in known) || !services.add(service)) fail("invalid or duplicate desktop service: " + service);
                    }
                }
                var ownership = object_value(p, "ownership");
                keys(ownership, { "application", "mediaPlayers" });
                if (ownership.has_member("application")) bool_value(ownership, "application");
                var names = new HashSet<string>();
                if (ownership.has_member("mediaPlayers")) {
                    foreach (var entry in array_value(ownership, "mediaPlayers", 20).get_elements()) {
                        if (entry.get_node_type() != Json.NodeType.VALUE || entry.get_value_type() != typeof(string) || !valid_media_name(entry.get_string()) || !names.add(entry.get_string())) fail("invalid media-player ownership name");
                    }
                }
            } else {
                keys(p, { "network", "audio", "display", "processes", "ipc", "filesystem", "devices", "sessionBus", "systemBus" });
            }
            choice(p, "network", { "none", "full" });
            choice(p, "audio", { "none", "full" });
            choice(p, "display", { "none", "wayland", "x11", "wayland-or-x11" });
            choice(p, "processes", { "isolated", "full" });
            bool_value(p, "ipc");
            var fs = array_value(p, "filesystem", 11);
            var seen = new HashSet<string>();
            foreach (var entry in fs.get_elements()) {
                if (entry.get_node_type() != Json.NodeType.OBJECT) fail("invalid filesystem rule");
                var rule = entry.get_object();
                keys(rule, { "location", "access" });
                var location = choice(rule, "location", { "home", "desktop", "documents", "downloads", "music", "pictures", "public-share", "templates", "videos", "removable-media" });
                choice(rule, "access", { "read-only", "read-write" });
                if (!seen.add(location)) fail("duplicate filesystem location: " + location);
            }
            seen.clear();
            foreach (var entry in array_value(p, "devices", 8).get_elements()) {
                if (entry.get_node_type() != Json.NodeType.VALUE || entry.get_value_type() != typeof(string)) fail("invalid device category");
                var device = entry.get_string();
                if (!(device in new string[] { "gpu", "input", "camera", "usb", "serial", "optical", "fuse", "kvm" })) fail("unknown device category: " + device);
                if (!seen.add(device)) fail("duplicate device category: " + device);
                // The engine deliberately blocks mount/userns syscalls. Do not turn
                // this into a cosmetic /dev/fuse bind that cannot satisfy the grant.
                if (installing && device == "fuse") throw new AppHubPolicyError.UNSUPPORTED(_("AppHub policy requires FUSE access inside the sandbox, which is not supported."));
            }
            validate_bus(object_value(p, "sessionBus"));
            validate_bus(object_value(p, "systemBus"));
        }

        private static void validate_bus(Json.Object bus) throws Error {
            keys(bus, { "access", "rules" });
            var access = choice(bus, "access", { "none", "filtered", "full" });
            var rules = array_value(bus, "rules", 50);
            if ((access == "filtered") != (rules.get_length() > 0)) fail("bus access/rules mismatch");
            var seen = new HashSet<string>();
            foreach (var node in rules.get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) fail("invalid bus rule");
                var rule = node.get_object();
                keys(rule, { "name", "access" });
                var name = string_value(rule, "name");
                var permission = choice(rule, "access", { "see", "talk", "own" });
                if (!DBus.is_name(name) || name.has_prefix(":")) fail("invalid exact bus name: " + name);
                if (!seen.add(name)) fail("duplicate bus name: " + name);
                if (permission == "own" && !SandboxIdentity.is_ownable_bus_name(name)) fail("reserved ownership name: " + name);
            }
        }

        public static AppHubPolicy parse(string app_id, string json) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(json);
            return new AppHubPolicy(app_id, parser.get_root());
        }

        public static void validate_listing(Json.Node node) throws Error {
            if (node.get_node_type() != Json.NodeType.OBJECT || node.get_object().has_member("version"))
                fail("catalog submissions require sandbox v1");
            validate(node, false);
        }

        public static bool valid_media_name(string name) {
            return name.length <= 255 && Regex.match_simple("^org[.]mpris[.]MediaPlayer2[.][A-Za-z_][A-Za-z0-9_-]*([.][A-Za-z_][A-Za-z0-9_-]*)*([.][*])?$", name);
        }

        public void apply(InstallationRecord record) {
            record.apphub_id = app_id;
            record.apphub_policy = json;
            SandboxConfig.apply_preset(record, SANDBOX_PROFILE_STRICT);
            record.sandbox_media_names = null;
            record.sandbox_profile = SANDBOX_PROFILE_APPHUB;
            // Legacy bus rules grant only what they explicitly list. V2 gives
            // desktop services and runtime-resolved ownership their own fields.
            record.sandbox_allow_network = policy.get_string_member("network") == "full";
            record.sandbox_allow_audio = policy.get_string_member("audio") == "full";
            record.sandbox_display = policy.get_string_member("display");
            bool desktop = !record.is_terminal && record.sandbox_display != "none";
            record.sandbox_allow_notifications = desktop;
            record.sandbox_allow_tray = desktop;
            record.sandbox_allow_media_controls = desktop;
            record.sandbox_allow_accessibility = desktop;
            record.sandbox_allow_x11 = record.sandbox_display == "x11" || record.sandbox_display == "wayland-or-x11";
            record.sandbox_share_processes = policy.get_string_member("processes") == "full";
            record.sandbox_share_ipc = policy.get_boolean_member("ipc");
            record.sandbox_allow_gpu = false;
            var extra_devices = new ArrayList<string>();
            foreach (var entry in policy.get_array_member("devices").get_elements()) {
                switch (entry.get_string()) {
                    case "gpu": record.sandbox_allow_gpu = true; break;
                    case "input": record.sandbox_allow_input = true; break;
                    case "camera": record.sandbox_allow_camera = true; break;
                    default: extra_devices.add(entry.get_string()); break;
                }
            }
            record.sandbox_extra_devices = extra_devices.to_array();
            var others = new ArrayList<string>();
            foreach (var entry in policy.get_array_member("filesystem").get_elements()) {
                var rule = entry.get_object();
                var location = rule.get_string_member("location");
                bool writable = rule.get_string_member("access") == "read-write";
                if (location in new string[] { "downloads", "documents", "desktop", "pictures", "videos", "music" }) {
                    SandboxConfig.set_folder_access(record, location, writable ? 2 : 1);
                } else {
                    others.add(location + (writable ? ":rw" : ":ro"));
                }
            }
            record.sandbox_other_dirs = others.to_array();
            var session = policy.get_object_member("sessionBus");
            record.sandbox_session_bus = session.get_string_member("access");
            record.sandbox_allow_dbus = record.sandbox_session_bus == "full";
            record.sandbox_session_rules = bus_rules(session);
            var system = policy.get_object_member("systemBus");
            record.sandbox_system_bus = system.get_string_member("access");
            record.sandbox_system_rules = bus_rules(system);
            if (policy.has_member("version")) {
                record.sandbox_allow_notifications = desktop_service("notifications", desktop);
                record.sandbox_allow_media_controls = desktop_service("media-controls", desktop);
                record.sandbox_allow_tray = desktop_service("system-tray", desktop);
                record.sandbox_allow_accessibility = desktop_service("accessibility", desktop);
                record.sandbox_allow_network_info = desktop_service("network-information", false);
                record.sandbox_allow_location = desktop_service("location", false);
                record.sandbox_allow_bluetooth = desktop_service("bluetooth", false);
                record.sandbox_allow_online_accounts = desktop_service("online-accounts", false);
                var ownership = policy.get_object_member("ownership");
                var names = new ArrayList<string>();
                if (ownership.has_member("mediaPlayers")) {
                    foreach (var node in ownership.get_array_member("mediaPlayers").get_elements()) names.add(node.get_string());
                }
                record.sandbox_media_names = names.to_array();
            }
            record.apphub_policy_customized = false;
        }

        private bool desktop_service(string service, bool fallback) {
            var node = policy.get_member("desktopServices");
            if (node.get_node_type() == Json.NodeType.OBJECT) {
                var settings = node.get_object();
                return settings.has_member(service) ? settings.get_boolean_member(service) : fallback;
            }
            // Legacy array form names what the template wants on; anything unstated
            // keeps the desktop baseline.
            foreach (var item in node.get_array().get_elements()) if (item.get_string() == service) return true;
            return fallback;
        }

        private static string[] bus_rules(Json.Object bus) {
            var list = new ArrayList<string>();
            foreach (var entry in bus.get_array_member("rules").get_elements()) {
                var rule = entry.get_object();
                list.add(rule.get_string_member("access") + ":" + rule.get_string_member("name"));
            }
            return list.to_array();
        }

        public static AppHubPolicy? from_detail(string data, string? url, string sha256) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(data);
            if (parser.get_root().get_node_type() != Json.NodeType.OBJECT) fail("invalid AppHub detail response");
            var app = object_value(parser.get_root().get_object(), "app");
            var status = string_value(app, "status");
            if (!(status in new string[] { "current", "stale" })) {
                throw new AppHubPolicyError.UNAVAILABLE(_("This AppHub artifact is not available for installation."));
            }
            if (!app.has_member("latestRelease")) fail("missing latestRelease");
            var release_node = app.get_member("latestRelease");
            if (release_node == null || release_node.get_node_type() != Json.NodeType.OBJECT) return null;
            foreach (var node in array_value(release_node.get_object(), "artifacts", 10).get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) fail("invalid artifact");
                var artifact = node.get_object();
                if (string_value(artifact, "sha256") != sha256 || (url != null && string_value(artifact, "url") != url)) continue;
                if (!bool_value(artifact, "installable")) {
                    throw new AppHubPolicyError.UNAVAILABLE(_("This AppHub artifact is not available for installation."));
                }
                object_value(app, "sandbox");
                var result = new AppHubPolicy(string_value(app, "id"), app.get_member("sandbox"));
                result.sha256 = sha256;
                return result;
            }
            return null;
        }

        private static string fetch_https(Soup.Session session, string resource, Cancellable? cancellable) throws Error {
            string result = "";
            TlsSession.with_session(() => {
                var message = new Soup.Message("GET", API_BASE + resource);
                var input = session.send(message, cancellable);
                if (message.status_code != 200 || message.uri.get_scheme() != "https" || message.uri.get_host() != "xlc-dev.github.io"
                    || !message.uri.get_path().has_prefix("/apphub/api/v1/")) {
                    throw new AppHubPolicyError.UNAVAILABLE(_("Unable to retrieve the AppHub sandbox policy."));
                }
                var output = new MemoryOutputStream.resizable();
                uint8[] buffer = new uint8[8192];
                ssize_t read;
                while ((read = input.read(buffer, cancellable)) > 0) {
                    if (output.get_data_size() + read > 4 * 1024 * 1024) fail("AppHub response too large");
                    output.write_all(buffer[0:read], null, cancellable);
                }
                input.close(cancellable);
                output.write_all(new uint8[] { 0 }, null, cancellable);
                output.close(cancellable);
                result = (string) output.steal_data();
            });
            return result;
        }

        /** Current AppHub links lack a referrer/app ID: match catalog URL + digest.
         * Cache only the discovery index; always fetch a matched template fresh. */
        public static AppHubPolicy? resolve(string? url, string sha256, string? known_id = null,
                                            Cancellable? cancellable = null, AppHubFetch? fetch = null) throws Error {
            var session = new Soup.Session();
            session.timeout = 30;
            session.user_agent = "AppManager/" + APPLICATION_VERSION;
            AppHubFetch network_loader = (resource, cancel) => fetch_https(session, resource, cancel);
            unowned AppHubFetch loader = network_loader;
            if (fetch != null) loader = fetch;
            if (known_id != null) {
                if (!valid_id(known_id)) fail("invalid AppHub ID");
                var data = loader("apps/" + known_id + ".json", cancellable);
                var detail = new Json.Parser();
                detail.load_from_data(data);
                if (detail.get_root().get_node_type() != Json.NodeType.OBJECT
                    || string_value(object_value(detail.get_root().get_object(), "app"), "id") != known_id) fail("AppHub identity mismatch");
                var result = from_detail(data, url, sha256);
                if (result != null && result.app_id != known_id) fail("AppHub identity mismatch");
                return result;
            }
            var cache_path = Path.build_filename(Environment.get_user_cache_dir(), DATA_DIRNAME, "apphub-index.json");
            Json.Array? index = null;
            bool cached_index = false;
            if (fetch == null) {
                try {
                    var parser = new Json.Parser();
                    parser.load_from_file(cache_path);
                    if (parser.get_root().get_node_type() == Json.NodeType.OBJECT) {
                        var root = parser.get_root().get_object();
                        if (root.has_member("expires") && root.has_member("entries")
                            && root.get_member("expires").get_node_type() == Json.NodeType.VALUE
                            && root.get_member("expires").get_value_type() == typeof(int64)
                            && root.get_member("entries").get_node_type() == Json.NodeType.ARRAY
                            && root.get_int_member("expires") > get_real_time()) {
                            index = root.get_array_member("entries");
                            cached_index = true;
                        }
                    }
                } catch (Error e) {
                    debug("AppHub index cache unavailable: %s", e.message);
                }
            }
            if (index == null) {
                index = new Json.Array();
                string page = "apps.json";
                int pages = 0;
                do {
                    if (++pages > 100) fail("too many catalog pages");
                    var parser = new Json.Parser();
                    parser.load_from_data(loader(page, cancellable));
                    if (parser.get_root().get_node_type() != Json.NodeType.OBJECT) fail("invalid catalog response");
                    var root = parser.get_root().get_object();
                    foreach (var item in array_value(root, "items", 1000).get_elements()) {
                        if (item.get_node_type() != Json.NodeType.OBJECT) fail("invalid catalog entry");
                        var id = string_value(item.get_object(), "id");
                        if (!valid_id(id)) fail("invalid catalog ID");
                        var detail = new Json.Parser();
                        detail.load_from_data(loader("apps/" + id + ".json", cancellable));
                        if (detail.get_root().get_node_type() != Json.NodeType.OBJECT) fail("invalid detail response");
                        var app = object_value(detail.get_root().get_object(), "app");
                        if (string_value(app, "id") != id) fail("catalog identity mismatch");
                        var release = app.get_member("latestRelease");
                        if (release == null || release.get_node_type() == Json.NodeType.NULL) continue;
                        if (release.get_node_type() != Json.NodeType.OBJECT) fail("invalid release");
                        foreach (var asset in array_value(release.get_object(), "artifacts", 10).get_elements()) {
                            if (asset.get_node_type() != Json.NodeType.OBJECT) fail("invalid artifact");
                            var entry = new Json.Object();
                            entry.set_string_member("id", id);
                            entry.set_string_member("url", string_value(asset.get_object(), "url"));
                            entry.set_string_member("sha256", string_value(asset.get_object(), "sha256"));
                            index.add_object_element(entry);
                        }
                    }
                    var pagination = object_value(root, "pagination");
                    var next = pagination.get_member("next");
                    page = (next != null && next.get_node_type() == Json.NodeType.NULL) ? "" : string_value(pagination, "next");
                    if (page.has_prefix("/apphub/api/v1/")) page = page.substring("/apphub/api/v1/".length);
                    if (page != "" && (!page.has_prefix("apps/page/") || page.contains("..") || page.contains(":"))) fail("invalid catalog pagination");
                } while (page != "");
                if (fetch == null) {
                    try {
                        DirUtils.create_with_parents(Path.get_dirname(cache_path), 0700);
                        var object = new Json.Object();
                        object.set_int_member("expires", get_real_time() + 3600 * 1000000LL);
                        object.set_array_member("entries", index);
                        var node = new Json.Node(Json.NodeType.OBJECT);
                        node.set_object(object);
                        var generator = new Json.Generator();
                        generator.set_root(node);
                        GLib.FileUtils.set_contents(cache_path, generator.to_data(null));
                    } catch (Error e) {
                        debug("Could not cache AppHub discovery: %s", e.message);
                    }
                }
            }
            string? matched_id = null;
            foreach (var node in index.get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) fail("invalid cached AppHub entry");
                var entry = node.get_object();
                if (string_value(entry, "sha256") != sha256 || (url != null && string_value(entry, "url") != url)) continue;
                var id = string_value(entry, "id");
                if (!valid_id(id)) fail("invalid cached AppHub ID");
                if (matched_id != null && matched_id != id) fail("ambiguous AppHub artifact");
                matched_id = id;
            }
            if (matched_id == null) {
                // A new catalog release must not receive Standard because an older
                // discovery index lacks its URL/digest. Rebuild once on cache misses.
                if (cached_index) {
                    GLib.FileUtils.unlink(cache_path);
                    return resolve(url, sha256, null, cancellable, loader);
                }
                return null;
            }
            var policy = resolve(url, sha256, matched_id, cancellable, loader);
            if (policy == null) throw new AppHubPolicyError.ARTIFACT_MISMATCH(_("The AppHub sandbox policy could not be matched to this download."));
            return policy;
        }
    }
}
