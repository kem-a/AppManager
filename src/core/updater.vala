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
        API_UNAVAILABLE,
        NO_TRACKING_HEADERS
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
        private string update_log_path;
        private const int MAX_PARALLEL_JOBS = 5;
        private static string? _system_arch = null;

        public Updater(InstallationRegistry registry, Installer installer) {
            this.registry = registry;
            this.installer = installer;
            session = new Soup.Session();
            user_agent = "AppManager/%s".printf(Core.APPLICATION_VERSION);
            session.user_agent = user_agent;
            session.timeout = 60;
            update_log_path = Path.build_filename(AppPaths.data_dir, "updates.log");
        }

        public ArrayList<UpdateProbeResult> probe_updates(GLib.Cancellable? cancellable = null) {
            var records = registry.list();
            if (records.length == 0) {
                return new ArrayList<UpdateProbeResult>();
            }
            return probe_updates_parallel(records, cancellable);
        }

        public UpdateProbeResult probe_single(InstallationRecord record, GLib.Cancellable? cancellable = null) {
            return probe_record(record, cancellable);
        }

        public ArrayList<UpdateResult> update_all(GLib.Cancellable? cancellable = null) {
            var records = registry.list();
            if (records.length == 0) {
                return new ArrayList<UpdateResult>();
            }
            return update_records_parallel(records, cancellable);
        }

        public UpdateResult update_single(InstallationRecord record, GLib.Cancellable? cancellable = null) {
            return update_record(record, cancellable);
        }

        // ─────────────────────────────────────────────────────────────────────
        // Architecture Detection
        // ─────────────────────────────────────────────────────────────────────

        /**
         * Get system architecture (cached).
         * Returns: x86_64, aarch64, armv7l, etc.
         */
        private static string get_system_arch() {
            if (_system_arch == null) {
                try {
                    string stdout_buf;
                    Process.spawn_command_line_sync("uname -m", out stdout_buf, null, null);
                    _system_arch = stdout_buf.strip();
                } catch (Error e) {
                    warning("Failed to get system architecture: %s", e.message);
                    _system_arch = "x86_64"; // fallback
                }
            }
            return _system_arch;
        }

        /**
         * Get architecture aliases for matching.
         * E.g., x86_64 should also match amd64, 64-bit, etc.
         */
        private static string[] get_arch_patterns(string arch) {
            switch (arch.down()) {
                case "x86_64":
                    return { "x86_64", "x86-64", "amd64", "x64" };
                case "aarch64":
                    return { "aarch64", "arm64" };
                case "armv7l":
                    return { "armv7l", "armhf", "arm32" };
                case "i686":
                case "i386":
                    return { "i686", "i386", "x86", "ia32" };
                default:
                    return { arch };
            }
        }

        /**
         * Check if an asset name matches the system architecture.
         */
        private static bool matches_system_arch(string asset_name) {
            var name_lower = asset_name.down();
            var patterns = get_arch_patterns(get_system_arch());
            
            foreach (var pattern in patterns) {
                // Check for pattern with common separators: App-x86_64.AppImage, App_amd64.AppImage
                if (name_lower.contains(pattern.down())) {
                    return true;
                }
            }
            return false;
        }

        // ─────────────────────────────────────────────────────────────────────
        // URL Normalization
        // ─────────────────────────────────────────────────────────────────────

        /**
         * Normalize update URL to project base URL.
         * Truncates full download URLs to just the project URL.
         * 
         * Examples:
         *   https://github.com/user/repo/releases/download/v1.0/App.AppImage → https://github.com/user/repo
         *   https://github.com/user/repo/releases → https://github.com/user/repo
         *   https://github.com/user/repo → https://github.com/user/repo
         *   https://gitlab.com/group/project/-/releases/v1.0/downloads/App.AppImage → https://gitlab.com/group/project
         *   https://gitlab.com/group/project/-/jobs/123/artifacts/raw/App.AppImage → https://gitlab.com/group/project
         *   gh-releases-zsync|owner|repo|latest|*.zsync → https://github.com/owner/repo
         *   zsync|https://example.com/app.zsync → https://example.com/app.zsync (with .zsync stripped)
         */
        public static string? normalize_update_url(string? url) {
            if (url == null || url.strip() == "") {
                return null;
            }

            var trimmed = url.strip();
            
            // Handle gh-releases-zsync format: gh-releases-zsync|owner|repo|tag|pattern
            // Convert to GitHub repository URL
            if (trimmed.has_prefix("gh-releases-zsync|")) {
                var parts = trimmed.split("|");
                if (parts.length >= 3) {
                    var owner = parts[1].strip();
                    var repo = parts[2].strip();
                    if (owner != "" && repo != "") {
                        return "https://github.com/%s/%s".printf(owner, repo);
                    }
                }
                return trimmed;
            }
            
            // Handle zsync direct URL format: zsync|URL
            // Strip the zsync| prefix and normalize the URL
            if (trimmed.has_prefix("zsync|")) {
                var zsync_url = trimmed.substring(6).strip();
                // Remove .zsync extension for display
                if (zsync_url.has_suffix(".zsync")) {
                    zsync_url = zsync_url.substring(0, zsync_url.length - 6);
                }
                // Recursively normalize the extracted URL
                return normalize_update_url(zsync_url);
            }
            
            try {
                var uri = GLib.Uri.parse(trimmed, GLib.UriFlags.NONE);
                var host = uri.get_host();
                var path = uri.get_path();
                var scheme = uri.get_scheme() ?? "https";
                
                if (host == null || path == null) {
                    return trimmed;
                }

                var host_lower = host.down();
                var segments = tokenize_path(path);

                // GitHub: https://github.com/owner/repo/...
                if (host_lower == "github.com" && segments.length >= 2) {
                    return "%s://%s/%s/%s".printf(scheme, host, segments[0], segments[1]);
                }

                // GitLab: find "/-/" marker or strip /releases
                if (host_lower.contains("gitlab") || path.contains("/-/")) {
                    int end = segments.length;
                    for (int i = 0; i < segments.length; i++) {
                        if (segments[i] == "-") { end = i; break; }
                    }
                    if (end == segments.length && segments.length > 0 && segments[end - 1] == "releases") {
                        end--;
                    }
                    if (end >= 1) {
                        return "%s://%s/%s".printf(scheme, host, string.joinv("/", segments[0:end]));
                    }
                }

                // Generic: strip /releases if present at end
                if (segments.length >= 2 && segments[segments.length - 1] == "releases") {
                    return "%s://%s/%s".printf(scheme, host, string.joinv("/", segments[0:segments.length - 1]));
                }

            } catch (Error e) {
                warning("Failed to parse URL %s: %s", trimmed, e.message);
            }

            return trimmed;
        }

        /**
         * Resolve zsync update info to a ZsyncDirectSource.
         * Handles both direct zsync URLs and gh-releases-zsync format.
         */
        private ZsyncDirectSource? resolve_zsync_source(string zsync_info) {
            // Direct zsync URL: zsync|https://example.com/app.zsync
            var zsync_direct = ZsyncDirectSource.parse(zsync_info);
            if (zsync_direct != null) {
                return zsync_direct;
            }

            // GitHub releases zsync: gh-releases-zsync|owner|repo|tag|pattern
            // This returns the source with version info for comparison
            return resolve_gh_releases_zsync_source(zsync_info);
        }

        // ─────────────────────────────────────────────────────────────────────
        // Update Source Resolution
        // ─────────────────────────────────────────────────────────────────────

        private UpdateSource? resolve_update_source(string update_url, string? record_version) {
            // First check for zsync-specific formats from .upd_info
            var zsync_direct = ZsyncDirectSource.parse(update_url);
            if (zsync_direct != null) {
                return zsync_direct;
            }

            // Handle gh-releases-zsync by resolving to actual zsync URL
            var resolved_zsync_url = resolve_gh_releases_zsync(update_url);;
            if (resolved_zsync_url != null) {
                return new ZsyncDirectSource(resolved_zsync_url);
            }

            var normalized = normalize_update_url(update_url);
            if (normalized == null) {
                return null;
            }

            var github = GithubSource.parse(normalized, record_version);
            if (github != null) {
                return github;
            }

            var gitlab = GitlabSource.parse(normalized, record_version);
            if (gitlab != null) {
                return gitlab;
            }

            // Fall back to direct URL for non-GitHub/GitLab URLs
            return DirectUrlSource.parse(update_url);
        }

        /**
         * Resolve gh-releases-zsync format to actual zsync download URL and version.
         * Format: gh-releases-zsync|owner|repo|tag|filename-pattern
         * Returns the resolved ZsyncDirectSource with version, or null if resolution fails.
         */
        private ZsyncDirectSource? resolve_gh_releases_zsync_source(string update_info) {
            if (!update_info.has_prefix("gh-releases-zsync|")) {
                return null;
            }
            
            var parts = update_info.split("|");
            if (parts.length < 5) {
                return null;
            }
            
            var owner = parts[1].strip();
            var repo = parts[2].strip();
            var tag = parts[3].strip();
            var pattern = parts[4].strip();
            
            if (owner == "" || repo == "" || tag == "" || pattern == "") {
                return null;
            }
            
            try {
                // Use appropriate API endpoint based on tag
                string api_url;
                if (tag == "latest") {
                    api_url = "https://api.github.com/repos/%s/%s/releases/latest".printf(owner, repo);
                } else {
                    api_url = "https://api.github.com/repos/%s/%s/releases?per_page=10".printf(owner, repo);
                }
                
                var root = fetch_json(api_url, "application/vnd.github+json", null);
                if (root == null) return null;
                
                // Find matching asset
                if (tag == "latest" && root.get_node_type() == Json.NodeType.OBJECT) {
                    return find_zsync_asset_with_version(root.get_object(), pattern);
                } else if (root.get_node_type() == Json.NodeType.ARRAY) {
                    var array = root.get_array();
                    for (uint i = 0; i < array.get_length(); i++) {
                        var node = array.get_element(i);
                        if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                        
                        var obj = node.get_object();
                        // For specific tag, match it
                        if (tag != "latest" && obj.has_member("tag_name")) {
                            var release_tag = obj.get_string_member("tag_name");
                            if (release_tag != tag && !release_tag.has_prefix(tag)) {
                                continue;
                            }
                        }
                        
                        var source = find_zsync_asset_with_version(obj, pattern);
                        if (source != null) return source;
                    }
                }
            } catch (Error e) {
                warning("Failed to resolve gh-releases-zsync: %s", e.message);
            }
            
            return null;
        }

        /**
         * Legacy: Resolve gh-releases-zsync format to actual zsync download URL.
         * Format: gh-releases-zsync|owner|repo|tag|filename-pattern
         * Returns the resolved URL or null if not a gh-releases-zsync format or resolution fails.
         */
        private string? resolve_gh_releases_zsync(string update_info) {
            var source = resolve_gh_releases_zsync_source(update_info);
            return source != null ? source.zsync_url : null;
        }

        /**
         * Find zsync asset URL and version in a GitHub release object matching the pattern.
         */
        private ZsyncDirectSource? find_zsync_asset_with_version(Json.Object release_obj, string pattern) {
            if (!release_obj.has_member("assets")) return null;
            
            // Extract version from tag_name
            string? version = null;
            if (release_obj.has_member("tag_name")) {
                var tag_name = release_obj.get_string_member("tag_name");
                // Handle tags like "3.1.1-2@2026-01-22_1769070653" → "3.1.1-2"
                if (tag_name != null) {
                    var at_pos = tag_name.index_of("@");
                    if (at_pos > 0) {
                        version = tag_name.substring(0, at_pos);
                    } else {
                        version = tag_name;
                    }
                }
            }
            
            var assets = release_obj.get_array_member("assets");
            for (uint i = 0; i < assets.get_length(); i++) {
                var node = assets.get_element(i);
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                
                var asset = node.get_object();
                if (!asset.has_member("name") || !asset.has_member("browser_download_url")) continue;
                
                var name = asset.get_string_member("name");
                if (pattern_matches_zsync(pattern, name)) {
                    var url = asset.get_string_member("browser_download_url");
                    return new ZsyncDirectSource(url, version);
                }
            }
            return null;
        }

        /**
         * Simple glob pattern matching for zsync filename patterns.
         */
        private static bool pattern_matches_zsync(string pattern, string text) {
            int pi = 0;
            int ti = 0;
            int star_pi = -1;
            int star_ti = -1;
            
            while (ti < text.length) {
                if (pi < pattern.length && (pattern[pi] == text[ti] || pattern[pi] == '?')) {
                    pi++;
                    ti++;
                } else if (pi < pattern.length && pattern[pi] == '*') {
                    star_pi = pi + 1;
                    star_ti = ti;
                    pi++;
                } else if (star_pi != -1) {
                    pi = star_pi;
                    star_ti++;
                    ti = star_ti;
                } else {
                    return false;
                }
            }
            
            while (pi < pattern.length && pattern[pi] == '*') {
                pi++;
            }
            
            return pi == pattern.length;
        }

        private string? read_update_url(InstallationRecord record) {
            var effective_url = record.get_effective_update_link();
            if (effective_url != null && effective_url.strip() != "") {
                return effective_url;
            }
            
            // Legacy: read from desktop file
            if (record.desktop_file == null || record.desktop_file.strip() == "") {
                return null;
            }

            var entry = new DesktopEntry(record.desktop_file);
            var value = entry.appimage_update_url;
            if (value != null && value.strip() != "") {
                return value.strip();
            }
            return null;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Parallel Processing
        // ─────────────────────────────────────────────────────────────────────

        private ArrayList<UpdateProbeResult> probe_updates_parallel(InstallationRecord[] records, GLib.Cancellable? cancellable) {
            var slots = new UpdateProbeResult?[records.length];
            Mutex slots_lock = Mutex();
            ThreadPool<RecordTask>? pool = null;

            try {
                pool = new ThreadPool<RecordTask>.with_owned_data((task) => {
                    slots_lock.lock();
                    slots[task.index] = probe_record(task.record, cancellable);
                    slots_lock.unlock();
                }, MAX_PARALLEL_JOBS, false);

                for (int i = 0; i < records.length; i++) {
                    var task = new RecordTask(i, records[i]);
                    pool.add((owned) task);
                }
                ThreadPool.free((owned) pool, false, true);
            } catch (Error e) {
                warning("Parallel probe failed: %s", e.message);
            }

            var results = new ArrayList<UpdateProbeResult>();
            foreach (var slot in slots) {
                if (slot != null) results.add(slot);
            }
            return results;
        }

        private ArrayList<UpdateResult> update_records_parallel(InstallationRecord[] records, GLib.Cancellable? cancellable) {
            var slots = new UpdateResult?[records.length];
            Mutex slots_lock = Mutex();
            ThreadPool<RecordTask>? pool = null;

            try {
                pool = new ThreadPool<RecordTask>.with_owned_data((task) => {
                    slots_lock.lock();
                    slots[task.index] = update_record(task.record, cancellable);
                    slots_lock.unlock();
                }, MAX_PARALLEL_JOBS, false);

                for (int i = 0; i < records.length; i++) {
                    var task = new RecordTask(i, records[i]);
                    pool.add((owned) task);
                }
                ThreadPool.free((owned) pool, false, true);
            } catch (Error e) {
                warning("Parallel update failed: %s", e.message);
            }

            var results = new ArrayList<UpdateResult>();
            foreach (var slot in slots) {
                if (slot != null) results.add(slot);
            }
            return results;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Probe & Update Logic
        // ─────────────────────────────────────────────────────────────────────

        private UpdateProbeResult probe_record(InstallationRecord record, GLib.Cancellable? cancellable) {
            // Check if app uses zsync delta updates
            if (record.zsync_update_info != null && record.zsync_update_info.strip() != "") {
                var zsync_source = resolve_zsync_source(record.zsync_update_info);
                if (zsync_source != null) {
                    return probe_zsync(record, zsync_source, cancellable);
                }
            }
            
            var update_url = read_update_url(record);
            if (update_url == null || update_url.strip() == "") {
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.NO_UPDATE_URL, _("No update address configured"));
            }

            var source = resolve_update_source(update_url, record.version);
            if (source == null) {
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.UNSUPPORTED_SOURCE, _("Update source not supported"));
            }

            // Handle zsync sources (legacy path for apps with zsync URL in update_link)
            if (source is ZsyncDirectSource) {
                return probe_zsync(record, source, cancellable);
            }

            if (source is DirectUrlSource) {
                return probe_direct(record, source as DirectUrlSource, cancellable);
            }

            try {
                var release_source = source as ReleaseSource;
                var release = fetch_latest_release(release_source, cancellable);
                if (release == null) {
                    return new UpdateProbeResult(record, false, null, UpdateSkipReason.API_UNAVAILABLE, _("Unable to read releases"));
                }

                var asset = select_appimage_asset(release.assets);
                if (asset == null) {
                    return new UpdateProbeResult(record, false, release.version, UpdateSkipReason.MISSING_ASSET, _("No matching AppImage found for %s").printf(get_system_arch()));
                }

                var latest = release.version;
                var current = record.version;
                
                // Version comparison: if both have versions, compare them
                if (latest != null && current != null && compare_versions(latest, current) <= 0) {
                    return new UpdateProbeResult(record, false, latest, UpdateSkipReason.ALREADY_CURRENT, _("Already up to date"));
                }
                
                // Fallback: if version is missing, compare release tags
                if ((latest == null || current == null) && release.tag_name != null) {
                    if (record.last_release_tag == release.tag_name) {
                        return new UpdateProbeResult(record, false, release.tag_name, UpdateSkipReason.ALREADY_CURRENT, _("Already up to date"));
                    }
                }

                return new UpdateProbeResult(record, true, latest ?? release.tag_name);
            } catch (Error e) {
                warning("Failed to check updates for %s: %s", record.name, e.message);
                return new UpdateProbeResult(record, false, null, null, e.message);
            }
        }

        private UpdateResult update_record(InstallationRecord record, GLib.Cancellable? cancellable) {
            // Check if app uses zsync delta updates
            if (record.zsync_update_info != null && record.zsync_update_info.strip() != "") {
                var zsync_source = resolve_zsync_source(record.zsync_update_info);
                if (zsync_source != null) {
                    record_checking(record);
                    return update_zsync(record, zsync_source, cancellable);
                }
            }
            
            var update_url = read_update_url(record);
            if (update_url == null || update_url.strip() == "") {
                record_skipped(record, UpdateSkipReason.NO_UPDATE_URL);
                log_update_event(record, "SKIP", "no update url configured");
                return new UpdateResult(record, UpdateStatus.SKIPPED, _("No update address configured"), null, UpdateSkipReason.NO_UPDATE_URL);
            }

            record_checking(record);

            var source = resolve_update_source(update_url, record.version);
            if (source == null) {
                record_skipped(record, UpdateSkipReason.UNSUPPORTED_SOURCE);
                log_update_event(record, "SKIP", "unsupported update source");
                return new UpdateResult(record, UpdateStatus.SKIPPED, _("Update source not supported"), null, UpdateSkipReason.UNSUPPORTED_SOURCE);
            }

            // Handle zsync sources (legacy path for apps with zsync URL in update_link)
            if (source is ZsyncDirectSource) {
                return update_zsync(record, source, cancellable);
            }

            if (source is DirectUrlSource) {
                return update_direct(record, source as DirectUrlSource, cancellable);
            }

            try {
                var release_source = source as ReleaseSource;
                var release = fetch_latest_release(release_source, cancellable);
                if (release == null) {
                    record_skipped(record, UpdateSkipReason.API_UNAVAILABLE);
                    log_update_event(record, "SKIP", "release API unavailable");
                    return new UpdateResult(record, UpdateStatus.SKIPPED, _("Unable to read releases"), null, UpdateSkipReason.API_UNAVAILABLE);
                }

                var latest = release.version;
                var current = record.version;
                
                // Version comparison: if both have versions, compare them
                if (latest != null && current != null && compare_versions(latest, current) <= 0) {
                    record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                    log_update_event(record, "SKIP", "already current");
                    return new UpdateResult(record, UpdateStatus.SKIPPED, _("Already up to date"), latest, UpdateSkipReason.ALREADY_CURRENT);
                }
                
                // Fallback: if version is missing, compare release tags
                if ((latest == null || current == null) && release.tag_name != null) {
                    if (record.last_release_tag == release.tag_name) {
                        record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                        log_update_event(record, "SKIP", "release tag unchanged");
                        return new UpdateResult(record, UpdateStatus.SKIPPED, _("Already up to date"), release.tag_name, UpdateSkipReason.ALREADY_CURRENT);
                    }
                }

                var asset = select_appimage_asset(release.assets);
                if (asset == null) {
                    record_skipped(record, UpdateSkipReason.MISSING_ASSET);
                    log_update_event(record, "SKIP", "no matching AppImage for " + get_system_arch());
                    return new UpdateResult(record, UpdateStatus.SKIPPED, _("No matching AppImage found for %s").printf(get_system_arch()), latest, UpdateSkipReason.MISSING_ASSET);
                }

                record_downloading(record);

                var download = download_file(asset.download_url, cancellable);
                InstallationRecord? new_record = null;
                try {
                    new_record = installer.upgrade(download.file_path, record);
                } finally {
                    AppManager.Utils.FileUtils.remove_dir_recursive(download.temp_dir);
                }

                // Store the release tag for version-less apps
                if (release.tag_name != null && new_record != null) {
                    new_record.last_release_tag = release.tag_name;
                    registry.persist();
                }

                var display_version = release.tag_name ?? asset.name;
                record_succeeded(record);
                log_update_event(record, "UPDATED", "updated to %s".printf(display_version));
                return new UpdateResult(record, UpdateStatus.UPDATED, _("Updated to %s").printf(display_version), release.version ?? display_version);
            } catch (Error e) {
                warning("Failed to update %s: %s", record.name, e.message);
                record_failed(record, e.message);
                log_update_event(record, "FAILED", e.message);
                return new UpdateResult(record, UpdateStatus.FAILED, e.message);
            }
        }
        // ─────────────────────────────────────────────────────────────────────
        // Direct URL Updates (Last-Modified + Content-Length based)
        // Note: ETag is unreliable for mirror-based CDNs (each mirror generates different ETags)
        // Last-Modified and Content-Length are consistent across mirrors
        // ─────────────────────────────────────────────────────────────────────

        /**
         * Build a fingerprint from Last-Modified and Content-Length headers.
         * This is more reliable than ETag for mirror-based CDNs.
         */
        private string? build_direct_fingerprint(Soup.Message message) {
            var last_modified = message.response_headers.get_one("Last-Modified");
            var content_length = message.response_headers.get_content_length();
            
            if (last_modified != null && last_modified.strip() != "") {
                if (content_length > 0) {
                    return "%s|%lld".printf(last_modified.strip(), content_length);
                }
                return last_modified.strip();
            }
            
            // Fallback: just content length
            if (content_length > 0) {
                return "size:%lld".printf(content_length);
            }
            
            return null;
        }

        /**
         * Extract the stored fingerprint from record
         */
        private string? get_stored_fingerprint(InstallationRecord record) {
            if (record.last_modified != null && record.last_modified.strip() != "") {
                if (record.content_length > 0) {
                    return "%s|%lld".printf(record.last_modified.strip(), record.content_length);
                }
                return record.last_modified.strip();
            }
            
            // Fallback: just content length
            if (record.content_length > 0) {
                return "size:%lld".printf(record.content_length);
            }
            
            return null;
        }

        /**
         * Store fingerprint components from HTTP headers into the record
         */
        private void store_fingerprint(InstallationRecord record, Soup.Message message) {
            var last_modified = message.response_headers.get_one("Last-Modified");
            record.last_modified = (last_modified != null && last_modified.strip() != "") ? last_modified.strip() : null;
            record.content_length = message.response_headers.get_content_length();
        }

        private UpdateProbeResult probe_direct(InstallationRecord record, DirectUrlSource source, GLib.Cancellable? cancellable) {
            try {
                var message = send_head(source.url, cancellable);
                var current_fingerprint = build_direct_fingerprint(message);
                
                if (current_fingerprint == null) {
                    return new UpdateProbeResult(record, false, null, UpdateSkipReason.NO_TRACKING_HEADERS, _("Server does not provide change tracking headers"));
                }

                var stored_fingerprint = get_stored_fingerprint(record);
                if (stored_fingerprint == null) {
                    // First time: record baseline
                    store_fingerprint(record, message);
                    registry.persist(false);
                    return new UpdateProbeResult(record, false, current_fingerprint, UpdateSkipReason.ALREADY_CURRENT, _("Baseline recorded"));
                }

                if (stored_fingerprint == current_fingerprint) {
                    return new UpdateProbeResult(record, false, current_fingerprint, UpdateSkipReason.ALREADY_CURRENT, _("Already up to date"));
                }

                return new UpdateProbeResult(record, true, current_fingerprint);
            } catch (Error e) {
                warning("Failed to check direct update for %s: %s", record.name, e.message);
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.API_UNAVAILABLE, e.message);
            }
        }

        private UpdateResult update_direct(InstallationRecord record, DirectUrlSource source, GLib.Cancellable? cancellable) {
            try {
                var message = send_head(source.url, cancellable);
                var current_fingerprint = build_direct_fingerprint(message);
                
                if (current_fingerprint == null) {
                    record_skipped(record, UpdateSkipReason.NO_TRACKING_HEADERS);
                    log_update_event(record, "SKIP", "direct url missing tracking headers");
                    return new UpdateResult(record, UpdateStatus.SKIPPED, _("Server does not provide change tracking headers"), null, UpdateSkipReason.NO_TRACKING_HEADERS);
                }

                var stored_fingerprint = get_stored_fingerprint(record);
                if (stored_fingerprint != null && stored_fingerprint == current_fingerprint) {
                    record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                    log_update_event(record, "SKIP", "fingerprint unchanged");
                    return new UpdateResult(record, UpdateStatus.SKIPPED, _("Already up to date"), current_fingerprint, UpdateSkipReason.ALREADY_CURRENT);
                }

                record_downloading(record);

                var download = download_file(source.url, cancellable);
                InstallationRecord? new_record = null;
                try {
                    new_record = installer.upgrade(download.file_path, record);
                } finally {
                    AppManager.Utils.FileUtils.remove_dir_recursive(download.temp_dir);
                }

                // Store the new fingerprint on the new record (upgrade returns a new record)
                if (new_record != null) {
                    store_fingerprint(new_record, message);
                }
                registry.persist();
                record_succeeded(record);
                log_update_event(record, "UPDATED", "direct url fingerprint=%s".printf(current_fingerprint));
                return new UpdateResult(record, UpdateStatus.UPDATED, _("Updated"), current_fingerprint);
            } catch (Error e) {
                warning("Failed to update %s via direct URL: %s", record.name, e.message);
                record_failed(record, e.message);
                log_update_event(record, "FAILED", e.message);
                return new UpdateResult(record, UpdateStatus.FAILED, e.message);
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Asset Selection
        // ─────────────────────────────────────────────────────────────────────

        /**
         * Select the best AppImage asset for the current system.
         * Priority:
         *   1. AppImage with explicit system architecture match
         *   2. AppImage with no architecture (assumes x86_64 default)
         *   3. Single AppImage (if only one exists)
         */
        private ReleaseAsset? select_appimage_asset(ArrayList<ReleaseAsset> assets) {
            var appimages = new ArrayList<ReleaseAsset>();
            ReleaseAsset? arch_match = null;
            ReleaseAsset? no_arch_asset = null;

            foreach (var asset in assets) {
                var name_lower = asset.name.down();
                
                // Check both asset name and URL for .appimage extension
                if (!name_lower.has_suffix(".appimage") && !asset.download_url.down().has_suffix(".appimage")) {
                    continue;
                }
                
                appimages.add(asset);
                
                // Check explicit architecture match (against both name and URL)
                if (arch_match == null && (matches_system_arch(asset.name) || matches_system_arch(asset.download_url))) {
                    arch_match = asset;
                }
                
                // Track assets with no architecture in filename (common for x86_64 default)
                if (no_arch_asset == null && !has_any_arch_in_name(asset.name)) {
                    no_arch_asset = asset;
                }
            }

            // Return explicit architecture match if found
            if (arch_match != null) {
                return arch_match;
            }

            // On x86_64, fall back to no-arch asset (many projects assume x86_64 is default)
            if (no_arch_asset != null && get_system_arch() == "x86_64") {
                return no_arch_asset;
            }

            // If only one AppImage exists, use it
            if (appimages.size == 1) {
                return appimages[0];
            }

            return null;
        }
        
        /**
         * Check if an asset name contains any known architecture string.
         */
        private static bool has_any_arch_in_name(string asset_name) {
            var name_lower = asset_name.down();
            // All known arch patterns
            string[] all_archs = {
                "x86_64", "x86-64", "amd64", "x64",
                "aarch64", "arm64",
                "armv7l", "armhf", "arm32",
                "i686", "i386", "ia32"
            };
            foreach (var arch in all_archs) {
                if (name_lower.contains(arch)) {
                    return true;
                }
            }
            return false;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Release Fetching
        // ─────────────────────────────────────────────────────────────────────

        private ReleaseInfo? fetch_latest_release(ReleaseSource source, GLib.Cancellable? cancellable) throws Error {
            if (source is GithubSource) {
                return fetch_github_release(source as GithubSource, cancellable);
            }
            if (source is GitlabSource) {
                return fetch_gitlab_release(source as GitlabSource, cancellable);
            }
            return null;
        }

        private Json.Node? fetch_json(string url, string accept_header, GLib.Cancellable? cancellable) throws Error {
            var message = new Soup.Message("GET", url);
            message.request_headers.replace("Accept", accept_header);
            message.request_headers.replace("User-Agent", user_agent);
            
            var bytes = session.send_and_read(message, cancellable);
            var status = message.get_status();
            if (status < 200 || status >= 300) {
                throw new GLib.IOError.FAILED("API error (%u)".printf(status));
            }

            var parser = new Json.Parser();
            parser.load_from_stream(new MemoryInputStream.from_bytes(bytes), cancellable);
            return parser.steal_root();
        }

        private ReleaseInfo? find_release_with_appimage(Json.Array array, ParseReleaseFunc parser) {
            ReleaseInfo? fallback = null;
            for (uint i = 0; i < array.get_length(); i++) {
                var node = array.get_element(i);
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                
                var release = parser(node.get_object());
                if (release == null) continue;
                
                if (fallback == null) fallback = release;
                if (select_appimage_asset(release.assets) != null) return release;
            }
            return fallback;
        }

        private delegate ReleaseInfo? ParseReleaseFunc(Json.Object obj);

        private ReleaseInfo? fetch_github_release(GithubSource source, GLib.Cancellable? cancellable) throws Error {
            var root = fetch_json(source.releases_api_url(), "application/vnd.github+json", cancellable);
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return null;
            return find_release_with_appimage(root.get_array(), parse_github_release);
        }

        private ReleaseInfo? parse_github_release(Json.Object obj) {
            string? tag = obj.has_member("tag_name") ? obj.get_string_member("tag_name") : null;
            var assets = new ArrayList<ReleaseAsset>();
            
            if (obj.has_member("assets")) {
                var arr = obj.get_array_member("assets");
                for (uint i = 0; i < arr.get_length(); i++) {
                    var node = arr.get_element(i);
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    
                    var asset_obj = node.get_object();
                    if (!asset_obj.has_member("name") || !asset_obj.has_member("browser_download_url")) continue;
                    
                    assets.add(new ReleaseAsset(
                        asset_obj.get_string_member("name"),
                        asset_obj.get_string_member("browser_download_url")
                    ));
                }
            }

            return new ReleaseInfo(tag, VersionUtils.sanitize(tag), assets);
        }

        private ReleaseInfo? fetch_gitlab_release(GitlabSource source, GLib.Cancellable? cancellable) throws Error {
            var root = fetch_json(source.releases_api_url(), "application/json", cancellable);
            if (root == null) return null;
            
            if (root.get_node_type() == Json.NodeType.ARRAY) {
                return find_release_with_appimage(root.get_array(), parse_gitlab_release);
            } else if (root.get_node_type() == Json.NodeType.OBJECT) {
                return parse_gitlab_release(root.get_object());
            }
            return null;
        }

        private ReleaseInfo? parse_gitlab_release(Json.Object obj) {
            string? tag = obj.has_member("tag_name") ? obj.get_string_member("tag_name") : null;
            string? name = obj.has_member("name") ? obj.get_string_member("name") : null;
            var assets = new ArrayList<ReleaseAsset>();

            if (obj.has_member("assets")) {
                var assets_obj = obj.get_object_member("assets");
                if (assets_obj.has_member("links")) {
                    var links = assets_obj.get_array_member("links");
                    for (uint i = 0; i < links.get_length(); i++) {
                        var node = links.get_element(i);
                        if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                        
                        var link = node.get_object();
                        string? download_url = null;
                        string? asset_name = null;
                        
                        if (link.has_member("direct_asset_url")) {
                            download_url = link.get_string_member("direct_asset_url");
                        } else if (link.has_member("url")) {
                            download_url = link.get_string_member("url");
                        }
                        
                        if (link.has_member("name")) {
                            asset_name = link.get_string_member("name");
                        }
                        
                        if (download_url != null && download_url.strip() != "") {
                            // Use link name or derive from URL
                            var final_name = asset_name ?? derive_filename(download_url);
                            assets.add(new ReleaseAsset(final_name, download_url));
                        }
                    }
                }
            }

            return new ReleaseInfo(tag ?? name, VersionUtils.sanitize(tag ?? name), assets);
        }

        // ─────────────────────────────────────────────────────────────────────
        // Utilities
        // ─────────────────────────────────────────────────────────────────────

        private static string[] tokenize_path(string path) {
            var parts = new ArrayList<string>();
            foreach (var segment in path.split("/")) {
                if (segment != null && segment.strip() != "") {
                    parts.add(segment);
                }
            }
            return parts.to_array();
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
                // ignore
            }
            return "update.AppImage";
        }

        private static int compare_versions(string? left, string? right) {
            return VersionUtils.compare(left, right);
        }

        private DownloadArtifact download_file(string url, GLib.Cancellable? cancellable) throws Error {
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
                ssize_t read;
                while ((read = input.read(buffer, cancellable)) > 0) {
                    output.write(buffer[0:read], cancellable);
                }
                output.close(cancellable);
                input.close(cancellable);
                
                return new DownloadArtifact(temp_dir, dest_path);
            } catch (Error e) {
                AppManager.Utils.FileUtils.remove_dir_recursive(temp_dir);
                throw e;
            }
        }

        private Soup.Message send_head(string url, GLib.Cancellable? cancellable) throws Error {
            var message = new Soup.Message("HEAD", url);
            message.request_headers.replace("User-Agent", user_agent);
            session.send_and_read(message, cancellable);
            var status = message.get_status();
            if (status < 200 || status >= 300) {
                throw new GLib.IOError.FAILED("HEAD request failed (%u)".printf(status));
            }
            return message;
        }

        private void log_update_event(InstallationRecord record, string status, string detail) {
            try {
                var file = File.new_for_path(update_log_path);
                var stream = file.append_to(FileCreateFlags.NONE);
                var timestamp = new GLib.DateTime.now_local();
                var line = "%s [%s] %s: %s\n".printf(timestamp.format("%Y-%m-%dT%H:%M:%S%z"), status, record.name, detail);
                stream.write(line.data);
                stream.close(null);
            } catch (Error e) {
                warning("Failed to write update log: %s", e.message);
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Zsync Updates
        // ─────────────────────────────────────────────────────────────────────

        /**
         * Information extracted from a zsync file header.
         */
        private class ZsyncFileInfo : Object {
            public string? filename { get; set; }
            public string? url { get; set; }
            public string? version { get; set; }
            
            public ZsyncFileInfo() {
                Object();
            }
        }

        /**
         * Fetch and parse zsync file header to extract metadata.
         * Zsync files have a text header followed by binary data.
         * Header format:
         *   zsync: 0.6.2
         *   Filename: app-1.2.3-x86_64.AppImage
         *   MTime: ...
         *   URL: https://example.com/app-1.2.3-x86_64.AppImage
         *   ...
         *   <blank line>
         *   <binary data>
         */
        private ZsyncFileInfo? fetch_zsync_file_info(string zsync_url, GLib.Cancellable? cancellable) {
            try {
                // Fetch just the first 2KB - zsync headers are typically < 1KB
                var message = new Soup.Message("GET", zsync_url);
                message.request_headers.replace("Range", "bytes=0-2047");
                message.request_headers.replace("User-Agent", user_agent);
                
                var bytes = session.send_and_read(message, cancellable);
                var status = message.get_status();
                
                // Accept both 200 (full content) and 206 (partial content)
                if (status != 200 && status != 206) {
                    return null;
                }
                
                var content = (string) bytes.get_data();
                if (content == null || content.length == 0) {
                    return null;
                }
                
                var info = new ZsyncFileInfo();
                
                // Parse line by line until we hit a blank line or binary data
                var lines = content.split("\n");
                foreach (var line in lines) {
                    var trimmed = line.strip();
                    
                    // Empty line marks end of header
                    if (trimmed == "") {
                        break;
                    }
                    
                    // Check for binary data (zsync header lines are ASCII)
                    bool has_binary = false;
                    for (int i = 0; i < trimmed.length && i < 20; i++) {
                        char c = trimmed[i];
                        if (c < 32 && c != '\t') {
                            has_binary = true;
                            break;
                        }
                    }
                    if (has_binary) {
                        break;
                    }
                    
                    // Parse header fields
                    var colon_pos = trimmed.index_of(":");
                    if (colon_pos > 0) {
                        var key = trimmed.substring(0, colon_pos).strip().down();
                        var value = trimmed.substring(colon_pos + 1).strip();
                        
                        if (key == "filename" && value != "") {
                            info.filename = value;
                            // Extract version from filename (e.g., "krita-5.2.15-x86_64.AppImage" -> "5.2.15")
                            info.version = VersionUtils.sanitize(value);
                        } else if (key == "url" && value != "") {
                            info.url = value;
                        }
                    }
                }
                
                return info;
            } catch (Error e) {
                warning("Failed to fetch zsync file info from %s: %s", zsync_url, e.message);
                return null;
            }
        }

        /**
         * Check if zsync update is available for a record.
         * Compares the remote version from the release with the installed version.
         */
        private UpdateProbeResult probe_zsync(InstallationRecord record, UpdateSource source, GLib.Cancellable? cancellable) {
            if (!(source is ZsyncDirectSource)) {
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.UNSUPPORTED_SOURCE, _("Unknown zsync source type"));
            }
            
            var zsync_source = source as ZsyncDirectSource;
            var remote_version = zsync_source.remote_version;
            var current_version = record.version;
            
            // If we don't have version info from gh-releases-zsync, try to fetch it from the zsync file header
            if (remote_version == null || remote_version.strip() == "") {
                var zsync_info = fetch_zsync_file_info(zsync_source.zsync_url, cancellable);
                if (zsync_info != null && zsync_info.version != null && zsync_info.version.strip() != "") {
                    remote_version = zsync_info.version;
                }
            }
            
            // If we have version info, use version comparison
            if (remote_version != null && remote_version.strip() != "") {
                // Compare versions
                if (current_version != null && current_version.strip() != "") {
                    var cmp = compare_versions(remote_version, current_version);
                    if (cmp <= 0) {
                        // Remote version is same or older than current
                        return new UpdateProbeResult(record, false, remote_version, UpdateSkipReason.ALREADY_CURRENT, _("Already up to date"));
                    }
                    // Remote version is newer
                    return new UpdateProbeResult(record, true, remote_version);
                }
                // No current version to compare, assume update available
                return new UpdateProbeResult(record, true, remote_version);
            }
            
            // Fallback to fingerprint comparison for zsync URLs without version info
            try {
                var message = send_head(zsync_source.zsync_url, cancellable);
                var fingerprint = build_direct_fingerprint(message);
                
                if (fingerprint == null) {
                    return new UpdateProbeResult(record, false, null, UpdateSkipReason.NO_TRACKING_HEADERS, _("Server does not provide change tracking headers"));
                }
                
                var stored = get_stored_fingerprint(record);
                
                if (stored == null) {
                    // First time: record baseline fingerprint
                    store_fingerprint(record, message);
                    registry.persist(false);
                    return new UpdateProbeResult(record, false, fingerprint, UpdateSkipReason.ALREADY_CURRENT, _("Baseline recorded"));
                }
                
                if (stored == fingerprint) {
                    return new UpdateProbeResult(record, false, fingerprint, UpdateSkipReason.ALREADY_CURRENT, _("Already up to date"));
                }
                
                return new UpdateProbeResult(record, true, fingerprint);
            } catch (Error e) {
                warning("Failed to probe zsync for %s: %s", record.name, e.message);
                return new UpdateProbeResult(record, false, null, null, e.message);
            }
        }

        /**
         * Perform a zsync delta update.
         * Uses zsync2 to efficiently download only changed blocks.
         */
        private UpdateResult update_zsync(InstallationRecord record, UpdateSource source, GLib.Cancellable? cancellable) {
            if (!(source is ZsyncDirectSource)) {
                record_skipped(record, UpdateSkipReason.UNSUPPORTED_SOURCE);
                return new UpdateResult(record, UpdateStatus.SKIPPED, _("Unknown zsync source"), null, UpdateSkipReason.UNSUPPORTED_SOURCE);
            }
            
            var zsync_source = source as ZsyncDirectSource;
            var zsync_url = zsync_source.zsync_url;
            
            // Get version info for checking and display
            string? new_version = zsync_source.remote_version;
            if (new_version == null || new_version.strip() == "") {
                var zsync_info = fetch_zsync_file_info(zsync_url, null);
                if (zsync_info != null && zsync_info.version != null) {
                    new_version = zsync_info.version;
                }
            }
            
            // Check if update is actually needed before downloading
            var current_version = record.version;
            if (new_version != null && new_version.strip() != "") {
                // Compare versions if both are available
                if (current_version != null && current_version.strip() != "") {
                    var cmp = compare_versions(new_version, current_version);
                    if (cmp <= 0) {
                        // Remote version is same or older than current - skip
                        record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                        log_update_event(record, "SKIP", "already current");
                        return new UpdateResult(record, UpdateStatus.SKIPPED, _("Already up to date"), new_version, UpdateSkipReason.ALREADY_CURRENT);
                    }
                }
            } else {
                // Fallback to fingerprint comparison for zsync URLs without version info
                try {
                    var message = send_head(zsync_url, cancellable);
                    var fingerprint = build_direct_fingerprint(message);
                    
                    if (fingerprint != null) {
                        var stored = get_stored_fingerprint(record);
                        
                        if (stored == null) {
                            // First time: record baseline fingerprint and skip
                            store_fingerprint(record, message);
                            registry.persist(false);
                            record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                            log_update_event(record, "SKIP", "baseline recorded");
                            return new UpdateResult(record, UpdateStatus.SKIPPED, _("Baseline recorded"), fingerprint, UpdateSkipReason.ALREADY_CURRENT);
                        }
                        
                        if (stored == fingerprint) {
                            record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                            log_update_event(record, "SKIP", "already current");
                            return new UpdateResult(record, UpdateStatus.SKIPPED, _("Already up to date"), fingerprint, UpdateSkipReason.ALREADY_CURRENT);
                        }
                    }
                } catch (Error e) {
                    // Non-fatal: continue with update attempt if fingerprint check fails
                    warning("Failed to check zsync fingerprint for %s: %s", record.name, e.message);
                }
            }
            
            var zsync_bin = AppPaths.zsync_path;
            if (zsync_bin == null) {
                // Fall back to full download if zsync is not available
                warning("zsync2 not available, falling back to full download for %s", record.name);
                return update_zsync_fallback(record, zsync_url, new_version, cancellable);
            }

            try {
                record_downloading(record);

                // Create temp directory for zsync output
                var temp_dir = AppManager.Utils.FileUtils.create_temp_dir("appmgr-zsync-");
                
                try {
                    // Run zsync2 with the existing AppImage as seed
                    var output_path = run_zsync(zsync_bin, zsync_url, record.installed_path, temp_dir, cancellable);
                    
                    // Upgrade using the downloaded file
                    var new_record = installer.upgrade(output_path, record);
                    
                    // Update fingerprint for future checks
                    try {
                        var message = send_head(zsync_url, null);
                        if (new_record != null) {
                            store_fingerprint(new_record, message);
                            registry.persist();
                        }
                    } catch (Error e) {
                        // Non-fatal: fingerprint update failed
                    }
                    
                    record_succeeded(record);
                    var version_msg = (new_version != null && new_version.strip() != "") 
                        ? _("Updated to %s").printf(new_version) 
                        : _("Updated");
                    log_update_event(record, "UPDATED", "zsync delta update to %s".printf(new_version ?? "unknown"));
                    // Return new_record so the UI can refresh with updated data
                    return new UpdateResult(new_record ?? record, UpdateStatus.UPDATED, version_msg, new_version);
                } finally {
                    AppManager.Utils.FileUtils.remove_dir_recursive(temp_dir);
                }
            } catch (Error e) {
                warning("Zsync update failed for %s: %s", record.name, e.message);
                record_failed(record, e.message);
                log_update_event(record, "FAILED", "zsync: %s".printf(e.message));
                return new UpdateResult(record, UpdateStatus.FAILED, e.message);
            }
        }

        /**
         * Fallback to full download when zsync is not available.
         */
        private UpdateResult update_zsync_fallback(InstallationRecord record, string zsync_url, string? new_version, GLib.Cancellable? cancellable) {
            try {
                // Try to get actual download URL from zsync file header first
                string? download_url = null;
                var zsync_info = fetch_zsync_file_info(zsync_url, cancellable);
                if (zsync_info != null && zsync_info.url != null && zsync_info.url.strip() != "") {
                    download_url = zsync_info.url;
                    // Also update version if we got it from zsync header
                    if (new_version == null && zsync_info.version != null) {
                        new_version = zsync_info.version;
                    }
                }
                
                // Fallback: derive AppImage URL from zsync URL (remove .zsync suffix)
                if (download_url == null) {
                    if (zsync_url.has_suffix(".zsync")) {
                        download_url = zsync_url.substring(0, zsync_url.length - 6);
                    } else {
                        record_skipped(record, UpdateSkipReason.UNSUPPORTED_SOURCE);
                        return new UpdateResult(record, UpdateStatus.SKIPPED, _("Cannot determine download URL from zsync URL"), null, UpdateSkipReason.UNSUPPORTED_SOURCE);
                    }
                }

                record_downloading(record);

                var download = download_file(download_url, cancellable);
                InstallationRecord? new_record = null;
                try {
                    new_record = installer.upgrade(download.file_path, record);
                } finally {
                    AppManager.Utils.FileUtils.remove_dir_recursive(download.temp_dir);
                }

                // Update fingerprint for future checks
                try {
                    var message = send_head(zsync_url, null);
                    if (new_record != null) {
                        store_fingerprint(new_record, message);
                        registry.persist();
                    }
                } catch (Error e) {
                    // Non-fatal
                }

                record_succeeded(record);
                var version_msg = (new_version != null && new_version.strip() != "") 
                    ? _("Updated to %s").printf(new_version) 
                    : _("Updated");
                log_update_event(record, "UPDATED", "full download (zsync unavailable) to %s".printf(new_version ?? "unknown"));
                // Return new_record so the UI can refresh with updated data
                return new UpdateResult(new_record ?? record, UpdateStatus.UPDATED, version_msg, new_version);
            } catch (Error e) {
                warning("Fallback update failed for %s: %s", record.name, e.message);
                record_failed(record, e.message);
                log_update_event(record, "FAILED", e.message);
                return new UpdateResult(record, UpdateStatus.FAILED, e.message);
            }
        }

        /**
         * Execute zsync2 to perform delta download.
         * @param zsync_path Path to zsync2 binary
         * @param zsync_url URL to the .zsync file
         * @param seed_path Path to existing AppImage to use as seed
         * @param output_dir Directory to write the output file
         * @param cancellable Optional cancellable
         * @return Path to the downloaded AppImage
         */
        private string run_zsync(string zsync_path, string zsync_url, string seed_path, string output_dir, GLib.Cancellable? cancellable) throws Error {
            // Determine output filename from zsync URL
            var zsync_basename = Path.get_basename(zsync_url);
            string output_name;
            if (zsync_basename.has_suffix(".zsync")) {
                output_name = zsync_basename.substring(0, zsync_basename.length - 6);
            } else {
                output_name = zsync_basename + ".AppImage";
            }
            var output_path = Path.build_filename(output_dir, output_name);

            // Build zsync2 command
            // zsync2 -i <seed> -o <output> <zsync_url>
            string[] argv = {
                zsync_path,
                "-i", seed_path,
                "-o", output_path,
                zsync_url
            };

            debug("Running zsync2: %s", string.joinv(" ", argv));

            string stdout_buf;
            string stderr_buf;
            int exit_status;

            Process.spawn_sync(
                output_dir,
                argv,
                Environ.get(),
                SpawnFlags.SEARCH_PATH,
                null,
                out stdout_buf,
                out stderr_buf,
                out exit_status
            );

            if (exit_status != 0) {
                var error_msg = stderr_buf.strip();
                if (error_msg == "") {
                    error_msg = stdout_buf.strip();
                }
                if (error_msg == "") {
                    error_msg = "zsync2 exited with code %d".printf(exit_status);
                }
                throw new GLib.IOError.FAILED("zsync failed: %s", error_msg);
            }

            // Verify output file exists
            if (!FileUtils.test(output_path, FileTest.EXISTS)) {
                throw new GLib.IOError.FAILED("zsync did not produce output file");
            }

            // Make executable
            FileUtils.chmod(output_path, 0755);

            return output_path;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Data Classes
        // ─────────────────────────────────────────────────────────────────────

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
            public string? version { get; private set; }
            public ArrayList<ReleaseAsset> assets { get; private set; }

            public ReleaseInfo(string? tag_name, string? version, ArrayList<ReleaseAsset> assets) {
                Object();
                this.tag_name = tag_name;
                this.version = version;
                this.assets = assets;
            }
        }

        private class RecordTask : Object {
            public int index { get; private set; }
            public InstallationRecord record { get; private set; }

            public RecordTask(int index, InstallationRecord record) {
                Object();
                this.index = index;
                this.record = record;
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
