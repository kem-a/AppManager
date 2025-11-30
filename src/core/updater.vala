using Gee;
using Soup;

namespace AppManager.Core {
    public enum UpdateStatus {
        UPDATED,
        SKIPPED,
        FAILED
    }

    public enum UpdateSkipReason {
        NO_UPDATE_URL,
        UNSUPPORTED_SOURCE,
        ALREADY_CURRENT,
        MISSING_ASSET,
        API_UNAVAILABLE
    }

    public class UpdateResult : Object {
        public InstallationRecord record { get; private set; }
        public UpdateStatus status { get; private set; }
        public string message { get; private set; }
        public string? new_version { get; private set; }
        public UpdateSkipReason? skip_reason;

        public UpdateResult(InstallationRecord record, UpdateStatus status, string message, string? new_version = null, UpdateSkipReason? skip_reason = null) {
            Object();
            this.record = record;
            this.status = status;
            this.message = message;
            this.new_version = new_version;
            this.skip_reason = skip_reason;
        }
    }

    public class UpdateProbeResult : Object {
        public InstallationRecord record { get; private set; }
        public bool has_update { get; private set; }
        public string? available_version { get; private set; }
        public UpdateSkipReason? skip_reason;
        public string? message { get; private set; }

        public UpdateProbeResult(InstallationRecord record, bool has_update, string? available_version = null, UpdateSkipReason? skip_reason = null, string? message = null) {
            Object();
            this.record = record;
            this.has_update = has_update;
            this.available_version = available_version;
            this.skip_reason = skip_reason;
            this.message = message;
        }
    }

    public class Updater : Object {
        public signal void record_checking(InstallationRecord record);
        public signal void record_downloading(InstallationRecord record);
        public signal void record_succeeded(InstallationRecord record);
        public signal void record_failed(InstallationRecord record, string reason);
        public signal void record_skipped(InstallationRecord record, UpdateSkipReason reason);

        private InstallationRegistry registry;
        private Installer installer;
        private Soup.Session session;
        private string user_agent;
        private const int GITHUB_RELEASES_PER_PAGE = 20;
        private const int GITHUB_RELEASES_PAGE_LIMIT = 3;

        public Updater(InstallationRegistry registry, Installer installer) {
            this.registry = registry;
            this.installer = installer;
            session = new Soup.Session();
            user_agent = "AppManager/%s".printf(Core.APPLICATION_VERSION);
            session.user_agent = user_agent;
            session.timeout = 60;
        }

        public string? get_update_url(InstallationRecord record) {
            return read_update_url(record);
        }

        public ArrayList<UpdateProbeResult> probe_updates(GLib.Cancellable? cancellable = null) {
            var outcomes = new ArrayList<UpdateProbeResult>();
            foreach (var record in registry.list()) {
                outcomes.add(probe_record(record, cancellable));
            }
            return outcomes;
        }

        public UpdateProbeResult probe_single(InstallationRecord record, GLib.Cancellable? cancellable = null) {
            return probe_record(record, cancellable);
        }

        public ArrayList<UpdateResult> update_all(GLib.Cancellable? cancellable = null) {
            var outcomes = new ArrayList<UpdateResult>();
            foreach (var record in registry.list()) {
                outcomes.add(update_record(record, cancellable));
            }
            return outcomes;
        }

        public UpdateResult update_single(InstallationRecord record, GLib.Cancellable? cancellable = null) {
            return update_record(record, cancellable);
        }

        private UpdateProbeResult probe_record(InstallationRecord record, GLib.Cancellable? cancellable) {
            var update_url = read_update_url(record);
            if (update_url == null || update_url.strip() == "") {
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.NO_UPDATE_URL, I18n.tr("No update address configured"));
            }

            var source = resolve_update_source(update_url, record.version);
            if (source == null) {
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.UNSUPPORTED_SOURCE, I18n.tr("Update source not supported"));
            }

            try {
                var release = fetch_release_for_source(source, cancellable);
                if (release == null) {
                    return new UpdateProbeResult(record, false, null, UpdateSkipReason.API_UNAVAILABLE, I18n.tr("Unable to read releases"));
                }

                var asset = source.select_asset(release.assets);
                if (asset == null) {
                    return new UpdateProbeResult(record, false, release.normalized_version, UpdateSkipReason.MISSING_ASSET, I18n.tr("Matching AppImage not found in latest release"));
                }

                var latest_version = release.normalized_version;
                var current_version = source.current_version;
                if (latest_version != null && current_version != null) {
                    if (compare_versions(latest_version, current_version) <= 0) {
                        return new UpdateProbeResult(record, false, latest_version, UpdateSkipReason.ALREADY_CURRENT, I18n.tr("Already up to date"));
                    }
                }

                var display_version = release.tag_name ?? asset.name;
                return new UpdateProbeResult(record, true, latest_version ?? display_version);
            } catch (Error e) {
                warning("Failed to check updates for %s: %s", record.name, e.message);
                return new UpdateProbeResult(record, false, null, null, e.message);
            }
        }

        private UpdateResult update_record(InstallationRecord record, GLib.Cancellable? cancellable) {
            var update_url = read_update_url(record);
            if (update_url == null || update_url.strip() == "") {
                record_skipped(record, UpdateSkipReason.NO_UPDATE_URL);
                return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("No update address configured"), null, UpdateSkipReason.NO_UPDATE_URL);
            }

            record_checking(record);

            var source = resolve_update_source(update_url, record.version);
            if (source == null) {
                record_skipped(record, UpdateSkipReason.UNSUPPORTED_SOURCE);
                return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Update source not supported"), null, UpdateSkipReason.UNSUPPORTED_SOURCE);
            }

            try {
                var release = fetch_release_for_source(source, cancellable);
                if (release == null) {
                    record_skipped(record, UpdateSkipReason.API_UNAVAILABLE);
                    return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Unable to read releases"), null, UpdateSkipReason.API_UNAVAILABLE);
                }

                var latest_version = release.normalized_version;
                var current_version = source.current_version;
                if (latest_version != null && current_version != null) {
                    if (compare_versions(latest_version, current_version) <= 0) {
                        record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                        return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Already up to date"), latest_version, UpdateSkipReason.ALREADY_CURRENT);
                    }
                }

                var asset = source.select_asset(release.assets);
                if (asset == null) {
                    record_skipped(record, UpdateSkipReason.MISSING_ASSET);
                    return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Matching AppImage not found in latest release"), latest_version, UpdateSkipReason.MISSING_ASSET);
                }

                record_downloading(record);

                var download = download_asset(asset.download_url, cancellable);
                try {
                    installer.upgrade(download.file_path, record);
                } finally {
                    AppManager.Utils.FileUtils.remove_dir_recursive(download.temp_dir);
                }

                var display_version = release.tag_name ?? asset.name;
                record_succeeded(record);
                return new UpdateResult(record, UpdateStatus.UPDATED, I18n.tr("Updated to %s").printf(display_version), release.normalized_version ?? display_version);
            } catch (Error e) {
                warning("Failed to update %s: %s", record.name, e.message);
                record_failed(record, e.message);
                return new UpdateResult(record, UpdateStatus.FAILED, e.message);
            }
        }

        private ReleaseSource? resolve_update_source(string update_url, string? record_version) {
            var github_source = GithubSource.parse(update_url, record_version);
            if (github_source != null) {
                return github_source;
            }

            var gitlab_source = GitlabSource.parse(update_url, record_version);
            if (gitlab_source != null) {
                return gitlab_source;
            }

            return null;
        }

        private string? read_update_url(InstallationRecord record) {
            if (record.desktop_file == null || record.desktop_file.strip() == "") {
                return null;
            }

            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(record.desktop_file, KeyFileFlags.NONE);
                if (keyfile.has_key("Desktop Entry", "X-AppImage-UpdateURL")) {
                    var value = keyfile.get_string("Desktop Entry", "X-AppImage-UpdateURL").strip();
                    return value.length > 0 ? value : null;
                }
            } catch (Error e) {
                warning("Failed to read update URL for %s: %s", record.name, e.message);
            }
            return null;
        }

        private ReleaseInfo? fetch_release_for_source(ReleaseSource source, GLib.Cancellable? cancellable) throws Error {
            if (source is GithubSource) {
                var github_source = source as GithubSource;
                if (github_source != null) {
                    return fetch_latest_github_release(github_source, cancellable);
                }
            }
            if (source is GitlabSource) {
                var gitlab_source = source as GitlabSource;
                if (gitlab_source != null) {
                    return fetch_latest_gitlab_release(gitlab_source, cancellable);
                }
            }
            return null;
        }

        private ReleaseInfo? fetch_latest_github_release(GithubSource source, GLib.Cancellable? cancellable) throws Error {
            ReleaseInfo? fallback = null;

            for (int page = 1; page <= GITHUB_RELEASES_PAGE_LIMIT; page++) {
                var releases_url = source.releases_api_url(page, GITHUB_RELEASES_PER_PAGE);
                var root = fetch_github_json(releases_url, cancellable);
                if (root == null) {
                    break;
                }

                if (root.get_node_type() == Json.NodeType.ARRAY) {
                    var array = root.get_array();
                    if (array.get_length() == 0) {
                        break;
                    }
                    for (uint i = 0; i < array.get_length(); i++) {
                        var info = parse_github_release_node(array.get_element(i));
                        if (info == null) {
                            continue;
                        }
                        if (fallback == null) {
                            fallback = info;
                        }
                        if (source.select_asset(info.assets) != null) {
                            return info;
                        }
                    }
                    if (array.get_length() < GITHUB_RELEASES_PER_PAGE) {
                        break;
                    }
                    continue;
                }

                if (root.get_node_type() == Json.NodeType.OBJECT) {
                    var single = parse_github_release_node(root);
                    if (single != null) {
                        return single;
                    }
                    break;
                }

                break;
            }

            if (fallback != null) {
                return fallback;
            }

            var latest_root = fetch_github_json(source.latest_api_url(), cancellable);
            if (latest_root == null || latest_root.get_node_type() != Json.NodeType.OBJECT) {
                return null;
            }
            return build_github_release(latest_root.get_object());
        }

        private Json.Node? fetch_github_json(string url, GLib.Cancellable? cancellable) throws Error {
            var message = new Soup.Message("GET", url);
            message.request_headers.replace("Accept", "application/vnd.github+json");
            message.request_headers.replace("User-Agent", user_agent);
            var bytes = session.send_and_read(message, cancellable);
            var status = message.get_status();
            if (status < 200 || status >= 300) {
                throw new GLib.IOError.FAILED("GitHub API error (%u)".printf(status));
            }

            var parser = new Json.Parser();
            var stream = new MemoryInputStream.from_bytes(bytes);
            parser.load_from_stream(stream, cancellable);
            return parser.steal_root();
        }

        private ReleaseInfo? parse_github_release_node(Json.Node node) {
            if (node.get_node_type() != Json.NodeType.OBJECT) {
                return null;
            }
            return build_github_release(node.get_object());
        }

        private ReleaseInfo build_github_release(Json.Object release_obj) {
            string? tag_name = null;
            if (release_obj.has_member("tag_name")) {
                tag_name = release_obj.get_string_member("tag_name");
            }
            var assets = extract_github_assets(release_obj);
            var normalized = sanitize_version(tag_name);
            return new ReleaseInfo(tag_name, normalized, assets);
        }

        private ReleaseInfo? fetch_latest_gitlab_release(GitlabSource source, GLib.Cancellable? cancellable) throws Error {
            var message = new Soup.Message("GET", source.releases_api_url());
            message.request_headers.replace("Accept", "application/json");
            message.request_headers.replace("User-Agent", user_agent);
            var bytes = session.send_and_read(message, cancellable);
            var status = message.get_status();
            if (status < 200 || status >= 300) {
                throw new GLib.IOError.FAILED("GitLab API error (%u)".printf(status));
            }

            var parser = new Json.Parser();
            var stream = new MemoryInputStream.from_bytes(bytes);
            parser.load_from_stream(stream, cancellable);
            var root = parser.get_root();
            if (root == null) {
                return null;
            }

            Json.Object? release_obj = null;
            if (root.get_node_type() == Json.NodeType.OBJECT) {
                release_obj = root.get_object();
            } else if (root.get_node_type() == Json.NodeType.ARRAY) {
                var array = root.get_array();
                if (array.get_length() == 0) {
                    return null;
                }
                var first = array.get_element(0);
                if (first.get_node_type() == Json.NodeType.OBJECT) {
                    release_obj = first.get_object();
                }
            }

            if (release_obj == null) {
                return null;
            }

            string? tag_name = null;
            if (release_obj.has_member("tag_name")) {
                tag_name = release_obj.get_string_member("tag_name");
            }

            string? fallback_name = null;
            if (release_obj.has_member("name")) {
                fallback_name = release_obj.get_string_member("name");
            }

            var assets = extract_gitlab_assets(release_obj);
            var normalized = sanitize_version(tag_name ?? fallback_name);
            return new ReleaseInfo(tag_name ?? fallback_name, normalized, assets);
        }

        private ArrayList<ReleaseAsset> extract_gitlab_assets(Json.Object release_obj) {
            var assets = new ArrayList<ReleaseAsset>();
            if (!release_obj.has_member("assets")) {
                return assets;
            }

            var assets_obj = release_obj.get_object_member("assets");
            if (assets_obj.has_member("links")) {
                var links = assets_obj.get_array_member("links");
                for (uint i = 0; i < links.get_length(); i++) {
                    var node = links.get_element(i);
                    if (node.get_node_type() != Json.NodeType.OBJECT) {
                        continue;
                    }
                    var link_obj = node.get_object();
                    string? download_url = null;
                    if (link_obj.has_member("direct_asset_url")) {
                        download_url = link_obj.get_string_member("direct_asset_url");
                    }
                    if ((download_url == null || download_url == "") && link_obj.has_member("url")) {
                        download_url = link_obj.get_string_member("url");
                    }
                    if (download_url == null || download_url.strip() == "") {
                        continue;
                    }
                    var filename = derive_filename(download_url);
                    assets.add(new ReleaseAsset(filename, download_url));
                }
            }

            return assets;
        }

        private ArrayList<ReleaseAsset> extract_github_assets(Json.Object release_obj) {
            var assets = new ArrayList<ReleaseAsset>();
            if (!release_obj.has_member("assets")) {
                return assets;
            }

            var assets_array = release_obj.get_array_member("assets");
            for (uint i = 0; i < assets_array.get_length(); i++) {
                var node = assets_array.get_element(i);
                if (node.get_node_type() != Json.NodeType.OBJECT) {
                    continue;
                }
                var asset_obj = node.get_object();
                if (!asset_obj.has_member("name") || !asset_obj.has_member("browser_download_url")) {
                    continue;
                }
                assets.add(new ReleaseAsset(asset_obj.get_string_member("name"), asset_obj.get_string_member("browser_download_url")));
            }

            return assets;
        }

        private DownloadArtifact download_asset(string url, GLib.Cancellable? cancellable) throws Error {
            var temp_dir = AppManager.Utils.FileUtils.create_temp_dir("appmgr-update-");
            var target_name = derive_filename(url);
            var dest_path = Path.build_filename(temp_dir, target_name);

            try {
                var message = new Soup.Message("GET", url);
                message.request_headers.replace("Accept", "application/octet-stream");
                message.request_headers.replace("User-Agent", user_agent);
                var input = session.send(message, cancellable);
                var status = message.get_status();
                if (status < 200 || status >= 300) {
                    throw new GLib.IOError.FAILED("Download failed (%u)".printf(status));
                }

                var output = File.new_for_path(dest_path).replace(null, false, FileCreateFlags.REPLACE_DESTINATION, cancellable);
                uint8[] buffer = new uint8[64 * 1024];
                ssize_t read = 0;
                while ((read = input.read(buffer, cancellable)) > 0) {
                    var chunk = buffer[0:read];
                    output.write(chunk, cancellable);
                }
                output.close(cancellable);
                input.close(cancellable);
                return new DownloadArtifact(temp_dir, dest_path);
            } catch (Error e) {
                AppManager.Utils.FileUtils.remove_dir_recursive(temp_dir);
                throw e;
            }
        }

        private static string derive_filename(string url) {
            try {
                var uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
                var path = uri.get_path();
                if (path != null && path.length > 0) {
                    var basename = Path.get_basename(path);
                    var decoded = GLib.Uri.unescape_string(basename);
                    if (decoded != null && decoded.strip() != "") {
                        return decoded;
                    }
                    if (basename != null && basename.strip() != "") {
                        return basename;
                    }
                }
            } catch (Error e) {
                warning("Failed to derive file name from %s: %s", url, e.message);
            }
            return "update.AppImage";
        }

        private static string? sanitize_version(string? value) {
            if (value == null) {
                return null;
            }
            var trimmed = value.strip();
            if (trimmed.length == 0) {
                return null;
            }

            // Skip any leading channel prefix (e.g. "desktop-", "linux-") but keep an optional preceding "v".
            int start = 0;
            bool found_digit = false;
            for (int i = 0; i < trimmed.length; i++) {
                char ch = trimmed[i];
                if (ch >= '0' && ch <= '9') {
                    start = i;
                    if (i > 0 && (trimmed[i - 1] == 'v' || trimmed[i - 1] == 'V')) {
                        start = i - 1;
                    }
                    found_digit = true;
                    break;
                }
            }
            if (found_digit && start > 0) {
                trimmed = trimmed.substring(start);
            }

            if (trimmed.has_prefix("v") || trimmed.has_prefix("V")) {
                trimmed = trimmed.substring(1);
            }

            var builder = new StringBuilder();
            for (int i = 0; i < trimmed.length; i++) {
                char ch = trimmed[i];
                if ((ch >= '0' && ch <= '9') || ch == '.') {
                    builder.append_c(ch);
                    continue;
                }
                break;
            }
            var sanitized = builder.len > 0 ? builder.str : trimmed;
            sanitized = sanitized.strip();
            return sanitized.length > 0 ? sanitized : null;
        }

        private static int compare_versions(string? left, string? right) {
            var a = sanitize_version(left);
            var b = sanitize_version(right);
            if (a == null && b == null) {
                return 0;
            }
            if (a == null) {
                return -1;
            }
            if (b == null) {
                return 1;
            }
            var left_parts = a.split(".");
            var right_parts = b.split(".");
            var max_parts = left_parts.length > right_parts.length ? left_parts.length : right_parts.length;
            for (int i = 0; i < max_parts; i++) {
                var left_value = i < left_parts.length ? parse_version_part(left_parts[i]) : 0;
                var right_value = i < right_parts.length ? parse_version_part(right_parts[i]) : 0;
                if (left_value == right_value) {
                    continue;
                }
                return left_value > right_value ? 1 : -1;
            }
            return 0;
        }

        private static int parse_version_part(string token) {
            if (token == null || token.strip() == "") {
                return 0;
            }
            int parsed_value;
            if (int.try_parse(token, out parsed_value)) {
                return parsed_value;
            }

            int value = 0;
            for (int i = 0; i < token.length; i++) {
                char ch = token[i];
                if (ch >= '0' && ch <= '9') {
                    value = (value * 10) + (ch - '0');
                } else {
                    break;
                }
            }
            return value;
        }

        private static string[] tokenize_path(string path) {
            var parts = new ArrayList<string>();
            foreach (var segment in path.split("/")) {
                if (segment == null || segment.strip() == "") {
                    continue;
                }
                parts.add(segment);
            }
            return parts.to_array();
        }

        private static string? find_version_token(string text, string? preferred_version) {
            if (text == null || text.strip() == "") {
                return null;
            }
            var preferred = sanitize_version(preferred_version);
            if (preferred != null) {
                var idx = text.index_of(preferred);
                if (idx >= 0) {
                    return text.substring(idx, preferred.length);
                }
                var alt = "v" + preferred;
                idx = text.index_of(alt);
                if (idx >= 0) {
                    return text.substring(idx, alt.length);
                }
            }
            try {
                var regex = new Regex("v?[0-9]+(\\.[0-9]+)+([\\-_][0-9A-Za-z]+)?", RegexCompileFlags.CASELESS);
                MatchInfo info;
                if (regex.match(text, 0, out info)) {
                    return info.fetch(0);
                }
            } catch (RegexError e) {
                warning("Failed to detect version token in %s: %s", text, e.message);
            }
            return null;
        }

        private abstract class ReleaseSource : Object {
            public string? current_version { get; protected set; }
            protected string asset_prefix;
            protected string asset_suffix;

            protected ReleaseSource(string asset_prefix, string asset_suffix, string? current_version) {
                Object();
                this.asset_prefix = asset_prefix ?? "";
                this.asset_suffix = asset_suffix ?? "";
                this.current_version = current_version;
            }

            public ReleaseAsset? select_asset(ArrayList<ReleaseAsset> assets) {
                ReleaseAsset? fallback = null;
                int appimage_candidates = 0;
                foreach (var asset in assets) {
                    if (!asset.name.down().has_suffix(".appimage")) {
                        continue;
                    }
                    appimage_candidates++;
                    if (matches_asset(asset.name)) {
                        return asset;
                    }
                    if (fallback == null) {
                        fallback = asset;
                    }
                }
                if (appimage_candidates == 1 && fallback != null) {
                    return fallback;
                }
                return null;
            }

            private bool matches_asset(string candidate) {
                bool prefix_ok = asset_prefix == "" || candidate.has_prefix(asset_prefix);
                bool suffix_ok = asset_suffix == "" || candidate.has_suffix(asset_suffix);
                return prefix_ok && suffix_ok;
            }
        }

        private class GithubSource : ReleaseSource {
            public string owner { get; private set; }
            public string repo { get; private set; }

            private GithubSource(string owner, string repo, string asset_prefix, string asset_suffix, string? current_version) {
                base(asset_prefix, asset_suffix, current_version);
                this.owner = owner;
                this.repo = repo;
            }

            public static GithubSource? parse(string url, string? record_version) {
                try {
                    var uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
                    var path = uri.get_path();
                    if (path == null) {
                        return null;
                    }
                    var segments = tokenize_path(path);
                    if (segments.length < 6) {
                        return null;
                    }
                    if (segments[2] != "releases" || segments[3] != "download") {
                        return null;
                    }
                    var owner = segments[0];
                    var repo = segments[1];
                    var tag_segment = segments[4];
                    var asset_segment = segments[segments.length - 1];
                    var decoded = GLib.Uri.unescape_string(asset_segment);
                    if (decoded != null && decoded.strip() != "") {
                        asset_segment = decoded;
                    }

                    var token = find_version_token(asset_segment, record_version);
                    var prefix = derive_prefix(asset_segment, token);
                    var suffix = derive_suffix(asset_segment, token);
                    var inferred = sanitize_version(record_version) ?? sanitize_version(tag_segment) ?? sanitize_version(token);
                    return new GithubSource(owner, repo, prefix, suffix, inferred);
                } catch (Error e) {
                    warning("Failed to parse GitHub update URL %s: %s", url, e.message);
                    return null;
                }
            }

            public string latest_api_url() {
                return "https://api.github.com/repos/%s/%s/releases/latest".printf(owner, repo);
            }

            public string releases_api_url(int page = 1, int per_page = 20) {
                return "https://api.github.com/repos/%s/%s/releases?per_page=%d&page=%d".printf(owner, repo, per_page, page);
            }
        }

        private class GitlabSource : ReleaseSource {
            private string scheme;
            private string host;
            private int port;
            private string project_path;

            private GitlabSource(string scheme, string host, int port, string project_path, string asset_prefix, string asset_suffix, string? current_version) {
                base(asset_prefix, asset_suffix, current_version);
                this.scheme = scheme;
                this.host = host;
                this.port = port;
                this.project_path = project_path;
            }

            public static GitlabSource? parse(string url, string? record_version) {
                try {
                    var uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
                    var host = uri.get_host();
                    var path = uri.get_path();
                    if (host == null || path == null) {
                        return null;
                    }
                    var segments = tokenize_path(path);
                    if (segments.length < 4) {
                        return null;
                    }

                    int split_index = -1;
                    for (int i = 0; i < segments.length; i++) {
                        if (segments[i] == "-") {
                            split_index = i;
                            break;
                        }
                    }
                    if (split_index <= 0) {
                        return null;
                    }
                    var action = segments[split_index + 1];
                    if (action != "jobs" && action != "releases") {
                        return null;
                    }

                    if (action == "jobs") {
                        if (segments.length < split_index + 5) {
                            return null;
                        }
                        bool saw_artifacts = false;
                        int raw_index = -1;
                        for (int i = split_index + 2; i < segments.length; i++) {
                            if (segments[i] == "artifacts") {
                                saw_artifacts = true;
                            }
                            if (segments[i] == "raw" || segments[i] == "download") {
                                raw_index = i;
                                break;
                            }
                        }
                        if (!saw_artifacts || raw_index < 0 || raw_index + 1 >= segments.length) {
                            return null;
                        }
                    } else if (action == "releases") {
                        if (segments.length < split_index + 4) {
                            return null;
                        }
                        int downloads_index = -1;
                        for (int i = split_index + 1; i < segments.length; i++) {
                            if (segments[i] == "downloads") {
                                downloads_index = i;
                                break;
                            }
                        }
                        if (downloads_index < 0 || downloads_index + 1 >= segments.length) {
                            return null;
                        }
                        // ensure we actually have "downloads/<filename>"
                        if (downloads_index == segments.length - 1) {
                            return null;
                        }
                    }

                    var asset_segment = segments[segments.length - 1];
                    var decoded = GLib.Uri.unescape_string(asset_segment);
                    if (decoded != null && decoded.strip() != "") {
                        asset_segment = decoded;
                    }

                    var project_builder = new StringBuilder();
                    for (int i = 0; i < split_index; i++) {
                        if (i > 0) {
                            project_builder.append_c('/');
                        }
                        project_builder.append(segments[i]);
                    }
                    var project_path = project_builder.str;
                    if (project_path == null || project_path.strip() == "") {
                        return null;
                    }

                    string? tag_segment = null;
                    if (action == "releases") {
                        for (int i = split_index + 2; i < segments.length; i++) {
                            var value = segments[i];
                            if (value == "downloads") {
                                break;
                            }
                            if (value == "permalink" || value == "latest") {
                                continue;
                            }
                            tag_segment = value;
                            break;
                        }
                    }

                    var token = find_version_token(asset_segment, record_version) ?? find_version_token(tag_segment ?? "", record_version);
                    var prefix = derive_prefix(asset_segment, token);
                    var suffix = derive_suffix(asset_segment, token);
                    var inferred = sanitize_version(record_version) ?? sanitize_version(tag_segment) ?? sanitize_version(token);
                    var scheme = uri.get_scheme() ?? "https";
                    var port = uri.get_port();
                    return new GitlabSource(scheme, host, port, project_path, prefix, suffix, inferred);
                } catch (Error e) {
                    warning("Failed to parse GitLab update URL %s: %s", url, e.message);
                    return null;
                }
            }

            public string releases_api_url() {
                var builder = new StringBuilder();
                builder.append(scheme);
                builder.append("://");
                builder.append(host);
                if (port > 0 && !((scheme == "https" && port == 443) || (scheme == "http" && port == 80))) {
                    builder.append(":");
                    builder.append("%d".printf(port));
                }
                var encoded_project = GLib.Uri.escape_string(project_path, null, true);
                builder.append("/api/v4/projects/");
                builder.append(encoded_project);
                builder.append("/releases?per_page=20&order_by=released_at&sort=desc");
                return builder.str;
            }
        }

        private static string derive_prefix(string text, string? token) {
            if (token == null || token == "") {
                return text;
            }
            var idx = text.index_of(token);
            if (idx < 0) {
                return text;
            }
            return text.substring(0, idx);
        }

        private static string derive_suffix(string text, string? token) {
            if (token == null || token == "") {
                return "";
            }
            var idx = text.index_of(token);
            if (idx < 0) {
                return "";
            }
            return text.substring(idx + token.length);
        }

        private class ReleaseAsset : Object {
            public string name { get; private set; }
            public string download_url { get; private set; }

            public ReleaseAsset(string name, string download_url) {
                Object();
                this.name = name;
                this.download_url = download_url;
            }
        }

        private class ReleaseInfo : Object {
            public string? tag_name { get; private set; }
            public string? normalized_version { get; private set; }
            public ArrayList<ReleaseAsset> assets { get; private set; }

            public ReleaseInfo(string? tag_name, string? normalized_version, ArrayList<ReleaseAsset> assets) {
                Object();
                this.tag_name = tag_name;
                this.normalized_version = normalized_version;
                this.assets = assets;
            }
        }

        private class DownloadArtifact : Object {
            public string temp_dir { get; private set; }
            public string file_path { get; private set; }

            public DownloadArtifact(string temp_dir, string file_path) {
                Object();
                this.temp_dir = temp_dir;
                this.file_path = file_path;
            }
        }
    }
}
