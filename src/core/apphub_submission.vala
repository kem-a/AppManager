using Gee;

namespace AppManager.Core {
    public delegate string AppHubPublicFetch(string url, Cancellable? cancel) throws Error;
    /** Source identity, not the literal version/architecture-specific update URL. */
    public class AppHubSource : Object {
        public string kind;
        public string repository;
        public string key { owned get { return kind + ":" + (kind == "github" ? repository.down() : repository); } }

        public static AppHubSource parse(string? url) throws Error {
            if (url == null || url.strip() == "") throw new IOError.INVALID_ARGUMENT(_("A valid update URL is required."));
            var uri = Uri.parse(url.strip(), UriFlags.NONE);
            if (uri.get_scheme() != "https" || uri.get_userinfo() != null || uri.get_port() > 0)
                throw new IOError.INVALID_ARGUMENT(_("The update URL must be a public HTTPS release source."));
            var host = (uri.get_host() ?? "").down();
            var parts = new ArrayList<string>();
            foreach (var part in uri.get_path().split("/")) if (part != "") parts.add(part);
            var source = new AppHubSource();
            if (host == "github.com" || host == "codeberg.org") {
                if (parts.size < 2 || !Regex.match_simple("^[A-Za-z0-9_.-]+$", parts[0])
                    || !Regex.match_simple("^[A-Za-z0-9_.-]+$", parts[1])
                    || parts[0] == "." || parts[0] == ".." || parts[1] == "." || parts[1] == "..")
                    throw new IOError.INVALID_ARGUMENT(_("The update URL must identify a release repository."));
                source.kind = host == "github.com" ? "github" : "codeberg";
                source.repository = parts[0] + "/" + parts[1];
            } else if (host == "gitlab.com") {
                int end = parts.index_of("-");
                if (end < 0) end = parts.size;
                if (end < 2) throw new IOError.INVALID_ARGUMENT(_("The update URL must identify a release repository."));
                var path = new StringBuilder();
                for (int i = 0; i < end; i++) {
                    if (!Regex.match_simple("^[A-Za-z0-9_.-]+$", parts[i]) || parts[i] == "." || parts[i] == "..") throw new IOError.INVALID_ARGUMENT(_("Invalid GitLab repository path."));
                    if (i > 0) path.append("/");
                    path.append(parts[i]);
                }
                source.kind = "gitlab";
                source.repository = path.str;
            } else {
                // A feed must actually be fetched and validated before submission.
                if (host == "" || !uri.get_path().has_suffix(".json") || uri.get_query() != null || uri.get_fragment() != null)
                    throw new IOError.NOT_SUPPORTED(_("AppHub needs GitHub, GitLab.com, Codeberg, or a public AppHub JSON release feed. A direct AppImage or zsync URL is not sufficient."));
                source.kind = "feed";
                source.repository = url.strip();
            }
            return source;
        }

        public Json.Node to_json() {
            var obj = new Json.Object();
            obj.set_string_member("type", kind);
            obj.set_string_member(kind == "feed" ? "url" : "repository", repository);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(obj);
            return node;
        }
    }

    public class AppHubMatch : Object {
        public string url;
        public string message;
        public AppHubMatch(string url, string message) { this.url = url; this.message = message; }
    }

    public class AppHubSubmission : Object {
        public const string REPO = "/repos/xlc-dev/apphub";
        private GitHubClient github;
        private AppHubPublicFetch? public_fetch;
        // Memory only. Main-branch tree SHA determines whether cached manifests remain current.
        private string? cached_tree;
        private HashMap<string, Json.Node> manifests = new HashMap<string, Json.Node>();
        public string? source_warning { get; private set; }
        public AppHubSubmission(GitHubClient github, owned AppHubPublicFetch? public_fetch = null) {
            this.github = github;
            this.public_fetch = (owned) public_fetch;
        }

        private static void https_url(string url) throws Error {
            var uri = Uri.parse(url, UriFlags.NONE);
            if (uri.get_scheme() != "https" || uri.get_host() == null || uri.get_userinfo() != null || uri.get_fragment() != null)
                throw new IOError.INVALID_ARGUMENT(_("Source and media URLs must use public HTTPS."));
        }

        /** Public-source checks never carry the GitHub token, including on redirects. */
        private string fetch(string url, Cancellable? cancel) throws Error {
            if (public_fetch != null) return public_fetch(url, cancel);
            var session = new Soup.Session();
            session.timeout = 30;
            session.user_agent = "AppManager/" + APPLICATION_VERSION;
            string target = url;
            for (int hop = 0; hop < 4; hop++) {
                https_url(target);
                var uri = Uri.parse(target, UriFlags.NONE);
                var addresses = Resolver.get_default().lookup_by_name(uri.get_host(), cancel);
                foreach (var address in addresses) {
                    if (address.get_is_loopback() || address.get_is_link_local() || address.get_is_site_local()
                        || address.get_is_any() || address.get_is_multicast())
                        throw new IOError.INVALID_ARGUMENT(_("AppHub sources must be publicly accessible."));
                }
                var message = new Soup.Message("GET", target);
                message.set_flags(Soup.MessageFlags.NO_REDIRECT);
                string? redirect = null;
                string? result = null;
                TlsSession.with_session(() => {
                    var input = session.send(message, cancel);
                    if (message.status_code >= 300 && message.status_code < 400) {
                        var location = message.response_headers.get_one("Location");
                        if (location == null) throw new IOError.INVALID_DATA(_("Invalid source redirect."));
                        redirect = Uri.resolve_relative(target, location, UriFlags.NONE);
                        input.close(cancel);
                        return;
                    }
                    if (message.status_code != 200) throw new IOError.FAILED(_("Public source is unavailable (HTTP %u).").printf(message.status_code));
                    var text = new StringBuilder();
                    uint8[] buffer = new uint8[16384];
                    ssize_t count;
                    while ((count = input.read(buffer, cancel)) > 0) {
                        if (text.len + count > 2 * 1024 * 1024) throw new IOError.FAILED(_("Public source response is too large."));
                        text.append_len((string) buffer, count);
                    }
                    input.close(cancel);
                    result = text.str;
                });
                if (result != null) return result;
                target = redirect;
            }
            throw new IOError.FAILED(_("Too many source redirects."));
        }

        private static Json.Node parse_json(string text) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(text);
            return parser.get_root().copy();
        }

        public void validate_sources(Json.Node manifest, Cancellable? cancel = null) throws Error {
            var obj = manifest.get_object();
            var id = manifest_id(obj);
            var metadata = obj.get_object_member("appstream");
            var type = metadata.get_string_member("type");
            if (type == "flathub") {
                var data = parse_json(fetch("https://flathub.org/api/v2/appstream/" + Uri.escape_string(id, null, false), cancel));
                if (SubmissionJson.text(SubmissionJson.object(data), "id") != id
                    || SubmissionJson.text(SubmissionJson.object(data), "type") != "desktop-application")
                    throw new IOError.INVALID_DATA(_("Flathub did not return application metadata."));
            } else if (type == "url") {
                var xml = fetch(metadata.get_string_member("url"), cancel);
                var identity = new AppStreamIdentity(id.has_suffix(".desktop") ? id : id + ".desktop", null);
                identity.add_xml(xml);
                if (identity.matched_id() != id) throw new IOError.INVALID_DATA(_("The MetaInfo XML does not identify this application."));
            }
            var src = obj.get_object_member("releaseSource");
            var provider = src.get_string_member("type");
            Json.Node releases;
            if (provider == "github") {
                var repo = "/repos/" + src.get_string_member("repository");
                var info = github.require("GET", repo, null, cancel).get_object();
                if (SubmissionJson.boolean(info, "private", true)) throw new IOError.INVALID_ARGUMENT(_("AppHub cannot list a private release repository."));
                releases = github.require("GET", repo + "/releases?per_page=100", null, cancel);
            } else if (provider == "gitlab") {
                releases = parse_json(fetch("https://gitlab.com/api/v4/projects/" + Uri.escape_string(src.get_string_member("repository"), null, false) + "/releases?per_page=100", cancel));
            } else if (provider == "codeberg") {
                releases = parse_json(fetch("https://codeberg.org/api/v1/repos/" + src.get_string_member("repository") + "/releases?limit=100", cancel));
            } else {
                var feed = parse_json(fetch(src.get_string_member("url"), cancel));
                releases = SubmissionJson.member(SubmissionJson.object(feed), "releases");
            }
            if (releases == null || releases.get_node_type() != Json.NodeType.ARRAY)
                throw new IOError.INVALID_DATA(_("The source did not return a release list."));
            foreach (var release_node in releases.get_array().get_elements()) {
                var release = SubmissionJson.object(release_node);
                if (SubmissionJson.boolean(release, "draft") || SubmissionJson.boolean(release, "prerelease")) continue;
                Json.Array? assets = null;
                if (provider == "feed") {
                    if (release.get_string_member_with_default("version", "") == "" || release.get_string_member_with_default("publishedAt", "") == "") continue;
                    https_url(SubmissionJson.text(release, "page"));
                    assets = SubmissionJson.array(SubmissionJson.member(release, "artifacts"));
                } else if (provider == "gitlab") assets = SubmissionJson.array(SubmissionJson.member(SubmissionJson.child(release, "assets"), "links"));
                else assets = SubmissionJson.array(SubmissionJson.member(release, "assets"));
                foreach (var node in assets.get_elements()) {
                    var asset = SubmissionJson.object(node);
                    if (!SubmissionJson.text(asset, "name").has_suffix(".AppImage")) continue;
                    if (provider == "feed") {
                        if (asset.get_string_member_with_default("architecture", "") == "" || asset.get_int_member_with_default("size", 0) <= 0) continue;
                        https_url(SubmissionJson.text(asset, "url"));
                    }
                    return;
                }
                // AppHub uses the newest stable release, not an arbitrary old release with assets.
                break;
            }
            throw new IOError.INVALID_DATA(_("The latest stable release does not publish an AppImage. Check the update source."));
        }

        public static void complete_manifest(Json.Node manifest, string? manual, string? evidence, string assets_json) throws Error {
            var obj = manifest.get_object();
            var id = manifest_id(obj);
            if (manual != null) {
                var node = parse_json(manual);
                var source = SubmissionJson.object(node);
                if (SubmissionJson.text(source, "type") != "manual" || manifest_id_from_source(source) != id)
                    throw new IOError.INVALID_ARGUMENT(_("Manual metadata must use the same AppStream ID."));
                foreach (var key in source.get_members()) if (!(key in new string[] { "type", "metadata", "media" }))
                    throw new IOError.INVALID_ARGUMENT(_("Unknown manual source field: %s").printf(key));
                var metadata = SubmissionJson.child(source, "metadata");
                foreach (var key in new string[] { "name", "summary", "projectLicense" })
                    if (SubmissionJson.text(metadata, key).strip() == "") throw new IOError.INVALID_ARGUMENT(_("Manual metadata is missing: %s").printf(key));
                if (SubmissionJson.text(SubmissionJson.child(metadata, "developer"), "name") == ""
                    || SubmissionJson.array(SubmissionJson.member(metadata, "description")).get_length() == 0 || SubmissionJson.array(SubmissionJson.member(metadata, "categories")).get_length() == 0)
                    throw new IOError.INVALID_ARGUMENT(_("Manual metadata needs a developer, description, and categories."));
                https_url(SubmissionJson.text(metadata, "homepage"));
                var media = SubmissionJson.child(source, "media");
                https_url(SubmissionJson.text(media, "icon"));
                var screenshots = SubmissionJson.array(SubmissionJson.member(media, "screenshots"));
                if (screenshots.get_length() < 1 || screenshots.get_length() > 5) throw new IOError.INVALID_ARGUMENT(_("Provide one to five public screenshots."));
                foreach (var item in screenshots.get_elements()) {
                    https_url(SubmissionJson.text(SubmissionJson.object(item), "source"));
                    if (SubmissionJson.text(SubmissionJson.object(item), "caption") == "") throw new IOError.INVALID_ARGUMENT(_("Screenshot captions are required."));
                }
                obj.set_member("appstream", node);
            }
            if (evidence != null) {
                https_url(evidence);
                var origin = new Json.Object();
                origin.set_string_member("type", "upstream");
                var proof = new Json.Object();
                proof.set_string_member("method", "upstream-link");
                proof.set_string_member("url", evidence);
                origin.set_object_member("evidence", proof);
                obj.set_object_member("origin", origin);
            }
            var assets = parse_json(assets_json);
            if (assets.get_node_type() != Json.NodeType.OBJECT) throw new IOError.INVALID_ARGUMENT(_("Architecture patterns must be a JSON object."));
            foreach (var key in assets.get_object().get_members()) {
                var value = assets.get_object().get_member(key);
                if (!Regex.match_simple("^[a-z0-9][a-z0-9_+-]*$", key) || value.get_value_type() != typeof(string)
                    || !value.get_string().has_suffix(".AppImage") || value.get_string().contains("/"))
                    throw new IOError.INVALID_ARGUMENT(_("Invalid architecture filename pattern."));
            }
            if (assets.get_object().get_size() > 0) obj.set_member("assets", assets);
        }

        private static string manifest_id_from_source(Json.Object source) throws Error {
            return SubmissionJson.text(SubmissionJson.child(source, "metadata"), "id");
        }

        public static string manifest_id(Json.Object manifest) throws Error {
            var appstream = SubmissionJson.child(manifest, "appstream");
            if (SubmissionJson.text(appstream, "type") == "manual") return SubmissionJson.text(SubmissionJson.child(appstream, "metadata"), "id");
            return SubmissionJson.text(appstream, "id");
        }

        public static string source_key(Json.Object manifest) throws Error {
            var source = SubmissionJson.child(manifest, "releaseSource");
            var kind = SubmissionJson.text(source, "type");
            var repository = SubmissionJson.text(source, kind == "feed" ? "url" : "repository");
            return kind + ":" + (kind == "github" ? repository.down() : repository);
        }

        private Json.Node blob(string repo, string sha, Cancellable? cancel) throws Error {
            if (!Regex.match_simple("^[0-9a-f]{40,64}$", sha)) throw new IOError.INVALID_DATA(_("Invalid GitHub blob identity."));
            var obj = SubmissionJson.object(github.require("GET", repo + "/git/blobs/" + sha, null, cancel));
            if (SubmissionJson.text(obj, "encoding") != "base64") throw new IOError.INVALID_DATA(_("Unexpected GitHub manifest encoding."));
            var data = Base64.decode(SubmissionJson.text(obj, "content"));
            if (data.length > 65536) throw new IOError.INVALID_DATA(_("AppHub manifest is too large."));
            var parser = new Json.Parser();
            parser.load_from_data((string) data, data.length);
            return parser.get_root().copy();
        }

        private static Json.Node object_node(Json.Object obj) {
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(obj);
            return node;
        }

        public static AppHubMatch? match_manifest(Json.Node node, string id, AppHubSource source, string url) throws Error {
            var manifest = SubmissionJson.object(node);
            if (manifest_id(manifest) != id) return null;
            if (source_key(manifest) != source.key)
                return new AppHubMatch(url, _("This app is already listed or proposed from another release source. Changing the source requires AppHub maintainer review."));
            return new AppHubMatch(url, _("This app already has an AppHub listing or submission."));
        }

        /** Complete, paginated remote checks; any incomplete response fails closed. */
        public AppHubMatch? check(string id, AppHubSource source, Cancellable? cancel = null) throws Error {
            source_warning = null;
            var branch = SubmissionJson.object(github.require("GET", REPO + "/branches/main", null, cancel));
            var tree_sha = SubmissionJson.text(SubmissionJson.child(SubmissionJson.child(SubmissionJson.child(branch, "commit"), "commit"), "tree"), "sha");
            if (cached_tree != tree_sha) {
                var tree = SubmissionJson.object(github.require("GET", REPO + "/git/trees/" + tree_sha + "?recursive=1", null, cancel));
                if (!tree.has_member("truncated")) throw new IOError.INVALID_DATA(_("Incomplete GitHub tree response."));
                if (SubmissionJson.boolean(tree, "truncated")) throw new IOError.FAILED(_("AppHub duplicate check is incomplete. Please retry later."));
                var fresh = new HashMap<string, Json.Node>();
                foreach (var entry in SubmissionJson.array(SubmissionJson.member(tree, "tree")).get_elements()) {
                    var file = SubmissionJson.object(entry);
                    var path = SubmissionJson.text(file, "path");
                    if (path.has_prefix("apps/") && path.has_suffix(".json") && SubmissionJson.text(file, "type") == "blob")
                        fresh[path] = blob(REPO, SubmissionJson.text(file, "sha"), cancel);
                }
                manifests = fresh;
                cached_tree = tree_sha;
            }
            foreach (var entry in manifests.entries) {
                var found = match_manifest(entry.value, id, source, "https://github.com/xlc-dev/apphub/blob/main/" + entry.key);
                if (found != null) return found;
                if (source_key(SubmissionJson.object(entry.value)) == source.key)
                    source_warning = _("This release repository is already used by another AppStream ID. Submit only if it genuinely publishes a separate application.");
            }
            for (int page = 1; page <= 20; page++) {
                var pulls = SubmissionJson.array(github.require("GET", REPO + "/pulls?state=open&per_page=100&page=%d".printf(page), null, cancel));
                foreach (var node in pulls.get_elements()) {
                    var pr = SubmissionJson.object(node);
                    var number = SubmissionJson.integer(pr, "number");
                    if (number <= 0) throw new IOError.INVALID_DATA(_("Invalid pull request number."));
                    var head = SubmissionJson.child(pr, "head");
                    var head_repo_node = SubmissionJson.member(head, "repo");
                    if (head_repo_node == null || head_repo_node.is_null()) throw new IOError.FAILED(_("An AppHub submission could not be checked. Please retry later."));
                    var head_repo_name = SubmissionJson.text(SubmissionJson.object(head_repo_node), "full_name");
                    if (!Regex.match_simple("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", head_repo_name)) throw new IOError.INVALID_DATA(_("Invalid pull request repository."));
                    var head_repo = "/repos/" + head_repo_name;
                    for (int files_page = 1; files_page <= 30; files_page++) {
                        var files = SubmissionJson.array(github.require("GET", REPO + "/pulls/%lld/files?per_page=100&page=%d".printf(number, files_page), null, cancel));
                        foreach (var file_node in files.get_elements()) {
                            var file = SubmissionJson.object(file_node);
                            var path = SubmissionJson.text(file, "filename");
                            if (path.has_prefix("apps/") && path.has_suffix(".json") && SubmissionJson.text(file, "status") != "removed") {
                                var proposed = blob(head_repo, SubmissionJson.text(file, "sha"), cancel);
                                var found = match_manifest(proposed, id, source, SubmissionJson.text(pr, "html_url"));
                                if (found != null) return found;
                                if (source_key(SubmissionJson.object(proposed)) == source.key)
                                    source_warning = _("Another submission uses this repository for a different AppStream ID. Confirm that your listing is a separate application.");
                            }
                        }
                        if (files.get_length() < 100) break;
                        if (files_page == 30) throw new IOError.FAILED(_("AppHub duplicate check is incomplete. Please retry later."));
                    }
                }
                if (pulls.get_length() < 100) return null;
            }
            throw new IOError.FAILED(_("AppHub duplicate check is incomplete. Please retry later."));
        }

        /** Same name grammar as AppHub sandbox v1: exact names only, no wildcards. */
        private static bool v1_bus_name(string name) {
            return name.length >= 3 && name.length <= 255
                && Regex.match_simple("^[A-Za-z_][A-Za-z0-9_-]*(\\.[A-Za-z_][A-Za-z0-9_-]*)+$", name);
        }

        private static void add_rule(HashMap<string, string> rules, string name, string access) {
            if (!v1_bus_name(name)) return;
            if (access == "own" && !SandboxIdentity.is_ownable_bus_name(name)) return;
            int rank = access == "own" ? 3 : access == "talk" ? 2 : access == "see" ? 1 : 0;
            if (rank == 0) return;
            var existing = rules.get(name);
            int existing_rank = existing == null ? 0 : existing == "own" ? 3 : existing == "talk" ? 2 : 1;
            if (rank > existing_rank) rules.set(name, access);
        }

        private static void add_exact_rules(HashMap<string, string> rules, string[]? entries) {
            foreach (var entry in entries ?? new string[0]) {
                var separator = entry.index_of_char(':');
                if (separator <= 0) continue;
                add_rule(rules, entry.substring(separator + 1), entry.substring(0, separator));
            }
        }

        private static Json.Object bus_object(string access, HashMap<string, string> rules) {
            var bus = new Json.Object();
            bus.set_string_member("access", access);
            var array = new Json.Array();
            // Sorted so the prefilled JSON is stable between openings.
            var names = new Gee.TreeSet<string>();
            foreach (var name in rules.keys) names.add(name);
            foreach (var name in names) {
                var rule = new Json.Object();
                rule.set_string_member("name", name);
                rule.set_string_member("access", rules.get(name));
                array.add_object_element(rule);
            }
            bus.set_array_member("rules", array);
            return bus;
        }

        /**
         * Builds the AppHub sandbox v1 policy from the app's effective AppManager
         * permissions. AppHub v1 has no category for some grants (accessibility,
         * dynamic tray names, security keys, custom folders); those are skipped and
         * returned in `notes` so the reviewer sees what still needs attention.
         */
        public static string sandbox_policy_json(InstallationRecord record, out string[] notes) {
            var warnings = new Gee.ArrayList<string>();
            var policy = new Json.Object();
            policy.set_string_member("network", record.sandbox_allow_network ? "full" : "none");
            policy.set_string_member("audio", record.sandbox_allow_audio ? "full" : "none");
            var display = record.sandbox_display;
            if (!(display in new string[] { "none", "wayland", "x11", "wayland-or-x11" }))
                display = record.sandbox_allow_x11 ? "wayland-or-x11" : "wayland";
            policy.set_string_member("display", display);
            policy.set_string_member("processes", record.sandbox_share_processes || record.sandbox_allow_polkit ? "full" : "isolated");
            policy.set_boolean_member("ipc", record.sandbox_share_ipc);

            var filesystem = new Json.Array();
            var locations = new Gee.HashSet<string>();
            foreach (var location in new string[] { "downloads", "documents", "desktop", "pictures", "videos", "music" }) {
                int access = SandboxConfig.folder_access(record, location);
                if (access == 0 || !locations.add(location)) continue;
                var rule = new Json.Object();
                rule.set_string_member("location", location);
                rule.set_string_member("access", access == 1 ? "read-only" : "read-write");
                filesystem.add_object_element(rule);
            }
            foreach (var entry in record.sandbox_other_dirs ?? new string[0]) {
                var text = entry.strip();
                var writable = text.has_suffix(":rw");
                if (!writable && text.has_suffix(":ro")) text = text.substring(0, text.length - 3);
                else if (writable) text = text.substring(0, text.length - 3);
                if (!(text in new string[] { "home", "public-share", "templates", "removable-media" }) || !locations.add(text)) {
                    if (text.has_prefix("/")) warnings.add(_("Custom folder: %s").printf(text));
                    continue;
                }
                var rule = new Json.Object();
                rule.set_string_member("location", text);
                rule.set_string_member("access", writable ? "read-write" : "read-only");
                filesystem.add_object_element(rule);
            }
            policy.set_array_member("filesystem", filesystem);

            var devices = new Json.Array();
            var seen_devices = new Gee.HashSet<string>();
            if (record.sandbox_allow_gpu && seen_devices.add("gpu")) devices.add_string_element("gpu");
            if (record.sandbox_allow_input && seen_devices.add("input")) devices.add_string_element("input");
            if (record.sandbox_allow_camera && seen_devices.add("camera")) devices.add_string_element("camera");
            foreach (var device in record.sandbox_extra_devices ?? new string[0]) {
                if ((device in new string[] { "usb", "serial", "optical", "kvm" }) && seen_devices.add(device))
                    devices.add_string_element(device);
            }
            policy.set_array_member("devices", devices);

            var session_rules = new HashMap<string, string>();
            bool full_session = record.sandbox_allow_dbus || record.sandbox_session_bus == "full";
            if (!full_session) {
                add_exact_rules(session_rules, record.sandbox_session_rules);
                if (record.sandbox_allow_notifications) add_rule(session_rules, "org.freedesktop.Notifications", "talk");
                if (record.sandbox_allow_keyring) {
                    foreach (var name in SandboxDbusProxy.KEYRING_NAMES) add_rule(session_rules, name, "talk");
                }
                if (record.sandbox_allow_online_accounts) {
                    foreach (var name in SandboxDbusProxy.ONLINE_ACCOUNTS_NAMES) add_rule(session_rules, name, "talk");
                }
                if (record.sandbox_allow_screenshots) add_rule(session_rules, "org.freedesktop.portal.Desktop", "talk");
                if (record.sandbox_allow_tray) {
                    add_rule(session_rules, "org.kde.StatusNotifierWatcher", "talk");
                    warnings.add(_("Tray items register dynamic bus names that AppHub sandbox v1 cannot express."));
                }
                if (record.sandbox_allow_media_controls) {
                    foreach (var name in SandboxIdentity.media_names_for(record)) add_rule(session_rules, name, "own");
                }
                foreach (var name in SandboxIdentity.own_names_for(record)) add_rule(session_rules, name, "own");
                if (record.sandbox_allow_accessibility)
                    warnings.add(_("Accessibility (AT-SPI) uses a separate bus that AppHub sandbox v1 cannot express."));
            }
            policy.set_object_member("sessionBus",
                full_session ? bus_object("full", session_rules) :
                session_rules.size > 0 ? bus_object("filtered", session_rules) : bus_object("none", session_rules));

            var system_rules = new HashMap<string, string>();
            bool full_system = record.sandbox_system_bus == "full";
            if (!full_system) {
                add_exact_rules(system_rules, record.sandbox_system_rules);
                if (record.sandbox_system_bus != "none") add_rule(system_rules, "org.freedesktop.login1", "talk");
                if (record.sandbox_allow_bluetooth) add_rule(system_rules, "org.bluez", "talk");
                if (record.sandbox_allow_location) add_rule(system_rules, "org.freedesktop.GeoClue2", "talk");
                if (record.sandbox_allow_network_info) add_rule(system_rules, "org.freedesktop.NetworkManager", "talk");
                if (record.sandbox_allow_polkit) add_rule(system_rules, "org.freedesktop.PolicyKit1", "talk");
            }
            policy.set_object_member("systemBus",
                full_system ? bus_object("full", system_rules) :
                system_rules.size > 0 ? bus_object("filtered", system_rules) : bus_object("none", system_rules));

            if (!record.sandbox_enabled())
                warnings.add(_("Sandboxing is currently off for this app; these values come from its saved permissions."));
            if (record.sandbox_allow_security_keys)
                warnings.add(_("Security keys (FIDO2) have no AppHub sandbox v1 category."));
            if ((record.sandbox_extra_dirs ?? new string[0]).length > 0)
                warnings.add(_("Custom folder grants are not part of AppHub sandbox v1."));

            notes = warnings.to_array();
            // Use the same Prettier-compatible layout as the committed manifest.
            return GitHubClient.pretty_json(object_node(policy));
        }

        public static Json.Node build_manifest(string id, string metadata_url, AppHubSource source, string sandbox_json) throws Error {
            if (!AppHubPolicy.valid_id(id)) throw new IOError.INVALID_ARGUMENT(_("Enter a valid AppStream ID."));
            var obj = new Json.Object();
            var appstream = new Json.Object();
            appstream.set_string_member("type", metadata_url == "" ? "flathub" : "url");
            appstream.set_string_member("id", id);
            if (metadata_url != "") {
                var uri = Uri.parse(metadata_url, UriFlags.NONE);
                if (uri.get_scheme() != "https" || uri.get_host() == null || uri.get_userinfo() != null)
                    throw new IOError.INVALID_ARGUMENT(_("The MetaInfo URL must use public HTTPS."));
                appstream.set_string_member("url", metadata_url);
            }
            obj.set_object_member("appstream", appstream);
            obj.set_string_member("addedAt", new DateTime.now_utc().format("%Y-%m-%d"));
            var origin = new Json.Object();
            origin.set_string_member("type", "third-party");
            obj.set_object_member("origin", origin);
            obj.set_member("releaseSource", source.to_json());
            // Catalog submissions currently use sandbox v1, not AppManager's extended policy.
            var parser = new Json.Parser();
            parser.load_from_data(sandbox_json);
            var policy = parser.get_root();
            if (policy == null || policy.get_node_type() != Json.NodeType.OBJECT || policy.get_object().has_member("version"))
                throw new IOError.INVALID_ARGUMENT(_("Use an AppHub sandbox v1 policy."));
            AppHubPolicy.validate_listing(policy);
            obj.set_member("sandbox", policy.copy());
            return object_node(obj);
        }

        /** Stable branch name recovers interrupted submissions without local history. */
        public static string branch_for(string id) {
            return "appmanager/submit-" + Checksum.compute_for_string(ChecksumType.SHA256, id).substring(0, 24);
        }

        public AppHubMatch submit(string slug, Json.Node manifest, Cancellable? cancel = null) throws Error {
            if (!Regex.match_simple("^[a-z0-9]+(-[a-z0-9]+)*$", slug) || slug.length > 100)
                throw new IOError.INVALID_ARGUMENT(_("Use a lowercase listing slug with hyphens."));
            var login = GitHubClient.authenticate(github.request("GET", "/user", null, cancel), true);
            var id = manifest_id(manifest.get_object());
            var src = manifest.get_object().get_object_member("releaseSource");
            var kind = src.get_string_member("type");
            var source = AppHubSource.parse(kind == "feed" ? src.get_string_member("url") :
                "https://" + (kind == "github" ? "github.com/" : kind == "gitlab" ? "gitlab.com/" : "codeberg.org/") + src.get_string_member("repository"));
            var found = check(id, source, cancel);
            if (found != null) return found;
            // The committed file is the pretty form; enforce the catalog limit on
            // exactly the bytes that will be written.
            var manifest_json = GitHubClient.pretty_json(manifest) + "\n";
            if (manifest_json.length > 65536) throw new IOError.INVALID_ARGUMENT(_("The application manifest exceeds AppHub's 64 KiB limit."));
            validate_sources(manifest, cancel);
            var path = "apps/" + slug + ".json";
            if (manifests.has_key(path)) throw new IOError.EXISTS(_("That listing slug is already in use. Choose another."));
            var fork_path = "/repos/" + login + "/apphub";
            if (fork_path == REPO) throw new IOError.NOT_SUPPORTED(_("Use a contributor account with its own AppHub fork."));
            var fork = github.request("GET", fork_path, null, cancel);
            if (fork.status == 404) {
                var args = new Json.Object();
                args.set_boolean_member("default_branch_only", true);
                github.require("POST", REPO + "/forks", object_node(args), cancel);
            } else if (fork.status != 200) GitHubClient.fail_status(fork.status);
            bool available = false;
            for (int attempt = 0; attempt < 10; attempt++) {
                var ready = github.request("GET", fork_path, null, cancel);
                if (ready.status == 200) {
                    var obj = SubmissionJson.object(ready.body);
                    if (!SubmissionJson.boolean(obj, "fork") || !obj.has_member("parent")
                        || SubmissionJson.text(SubmissionJson.child(obj, "parent"), "full_name") != "xlc-dev/apphub")
                        throw new IOError.EXISTS(_("Your apphub repository is not a fork of xlc-dev/apphub."));
                    var probe = github.request("GET", fork_path + "/git/ref/heads/main", null, cancel);
                    if (probe.status == 200) { available = true; break; }
                    if (probe.status != 404 && probe.status != 409) GitHubClient.fail_status(probe.status);
                } else if (ready.status != 404) GitHubClient.fail_status(ready.status);
                GitHubClient.cancel_check(cancel);
                Thread.usleep(1000000);
            }
            if (!available) throw new IOError.TIMED_OUT(_("GitHub is still preparing your fork. Please retry shortly."));
            var branch = branch_for(id);
            var branch_ref = fork_path + "/git/ref/heads/" + branch;
            var existing = github.request("GET", branch_ref, null, cancel);
            if (existing.status == 404) {
                var base_sha = github.require("GET", REPO + "/git/ref/heads/main", null, cancel).get_object().get_object_member("object").get_string_member("sha");
                var args = new Json.Object();
                args.set_string_member("ref", "refs/heads/" + branch);
                args.set_string_member("sha", base_sha);
                github.require("POST", fork_path + "/git/refs", object_node(args), cancel);
            } else {
                if (existing.status != 200) GitHubClient.fail_status(existing.status);
                // Never overwrite a user's branch or generate a PR containing unrelated changes.
                var diff = SubmissionJson.object(github.require("GET", REPO + "/compare/main..." + Uri.escape_string(login + ":" + branch, null, false), null, cancel));
                if (SubmissionJson.integer(diff, "ahead_by") > 1)
                    throw new IOError.EXISTS(_("The submission branch has additional commits. Review it on GitHub before retrying."));
                foreach (var node in SubmissionJson.array(SubmissionJson.member(diff, "files")).get_elements()) {
                    var file = SubmissionJson.object(node);
                    if (SubmissionJson.text(file, "filename") != path || SubmissionJson.text(file, "status") != "added")
                        throw new IOError.EXISTS(_("The submission branch contains other changes. Review it on GitHub before retrying."));
                }
            }
            // A closed PR on our deterministic branch must be reviewed, not silently duplicated.
            var previous = SubmissionJson.array(github.require("GET", REPO + "/pulls?state=all&head=" + Uri.escape_string(login + ":" + branch, null, false) + "&per_page=100", null, cancel));
            if (previous.get_length() > 0) return new AppHubMatch(SubmissionJson.text(SubmissionJson.object(previous.get_element(0)), "html_url"), _("A previous submission exists. Review its outcome on GitHub."));
            var file_path = fork_path + "/contents/" + path;
            var current = github.request("GET", file_path + "?ref=" + Uri.escape_string(branch, null, false), null, cancel);
            var args = new Json.Object();
            if (current.status == 200) {
                var current_obj = SubmissionJson.object(current.body);
                var parser = new Json.Parser();
                var bytes = Base64.decode(SubmissionJson.text(current_obj, "content"));
                parser.load_from_data((string) bytes, bytes.length);
                if (manifest_id(SubmissionJson.object(parser.get_root())) != id)
                    throw new IOError.EXISTS(_("The submission branch belongs to another app."));
                // Reuse the reviewed remote manifest after a lost PUT response. Do not
                // create another commit or overwrite edits made in the browser.
                var previous_manifest = parser.get_root().copy();
                previous_manifest.get_object().set_string_member("addedAt", manifest.get_object().get_string_member("addedAt"));
                if (GitHubClient.json(previous_manifest) != GitHubClient.json(manifest))
                    throw new IOError.EXISTS(_("A different manifest already exists on the submission branch. Review it on GitHub before retrying."));
            } else if (current.status != 404) GitHubClient.fail_status(current.status);
            args.set_string_member("message", "Add " + id);
            args.set_string_member("branch", branch);
            args.set_string_member("content", Base64.encode(manifest_json.data));
            if (current.status == 404) github.require("PUT", file_path, object_node(args), cancel);
            found = check(id, source, cancel);
            if (found != null) return found;
            args = new Json.Object();
            args.set_string_member("title", "Add " + id);
            args.set_string_member("head", login + ":" + branch);
            args.set_string_member("base", "main");
            args.set_string_member("body", "Application listing submitted with AppManager.\n\nAppStream ID: `" + id + "`\nRelease source: `" + source.key + "`\n\nPlease review the metadata source, declared origin, and requested sandbox permissions.\n");
            var pr = SubmissionJson.object(github.require("POST", REPO + "/pulls", object_node(args), cancel));
            return new AppHubMatch(SubmissionJson.text(pr, "html_url"), _("AppHub submission created."));
        }
    }
}
