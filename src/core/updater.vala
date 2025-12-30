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
        ETAG_MISSING
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

    public class UpdateCheckInfo : Object {
        public bool has_update { get; private set; }
        public string latest_version { get; private set; }
        public string current_version { get; private set; }
        public string? display_version { get; private set; }

        public UpdateCheckInfo(bool has_update, string latest, string current, string? display) {
            Object();
            this.has_update = has_update;
            this.latest_version = latest;
            this.current_version = current;
            this.display_version = display;
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

        public string? get_update_url(InstallationRecord record) {
            return read_update_url(record);
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

        public async UpdateCheckInfo? check_for_update_async(InstallationRecord record, GLib.Cancellable? cancellable = null) throws Error {
            return check_for_update(record, cancellable);
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
         */
        public static string? normalize_update_url(string? url) {
            if (url == null || url.strip() == "") {
                return null;
            }

            var trimmed = url.strip();
            
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

                // GitLab (gitlab.com or self-hosted): https://gitlab.com/group/project/...
                // GitLab URLs may have nested groups: group/subgroup/project
                // The "/-/" marker separates project path from GitLab-specific routes
                if (host_lower.contains("gitlab") || path.contains("/-/")) {
                    int split_index = -1;
                    for (int i = 0; i < segments.length; i++) {
                        if (segments[i] == "-") {
                            split_index = i;
                            break;
                        }
                    }
                    
                    if (split_index > 0) {
                        // Build project path from segments before "/-/"
                        var project_parts = new StringBuilder();
                        for (int i = 0; i < split_index; i++) {
                            if (i > 0) project_parts.append("/");
                            project_parts.append(segments[i]);
                        }
                        return "%s://%s/%s".printf(scheme, host, project_parts.str);
                    }
                    
                    // No "/-/" marker, check for /releases at end
                    if (segments.length >= 2) {
                        int end = segments.length;
                        if (segments[end - 1] == "releases") {
                            end--;
                        }
                        var project_parts = new StringBuilder();
                        for (int i = 0; i < end; i++) {
                            if (i > 0) project_parts.append("/");
                            project_parts.append(segments[i]);
                        }
                        return "%s://%s/%s".printf(scheme, host, project_parts.str);
                    }
                }

                // Generic: strip /releases if present at end
                if (segments.length >= 2 && segments[segments.length - 1] == "releases") {
                    var project_parts = new StringBuilder();
                    for (int i = 0; i < segments.length - 1; i++) {
                        if (i > 0) project_parts.append("/");
                        project_parts.append(segments[i]);
                    }
                    return "%s://%s/%s".printf(scheme, host, project_parts.str);
                }

            } catch (Error e) {
                warning("Failed to parse URL %s: %s", trimmed, e.message);
            }

            return trimmed;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Update Source Resolution
        // ─────────────────────────────────────────────────────────────────────

        private UpdateSource? resolve_update_source(string update_url, string? record_version) {
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
                    var outcome = probe_record(task.record, cancellable);
                    slots_lock.lock();
                    slots[task.index] = outcome;
                    slots_lock.unlock();
                }, MAX_PARALLEL_JOBS, false);

                for (int i = 0; i < records.length; i++) {
                    var task = new RecordTask(i, records[i]);
                    pool.add((owned) task);
                }

                ThreadPool.free((owned) pool, false, true);
                pool = null;
            } catch (Error e) {
                if (pool != null) {
                    ThreadPool.free((owned) pool, false, true);
                }
                warning("Parallel probe failed: %s", e.message);
            }

            var results = new ArrayList<UpdateProbeResult>();
            for (int i = 0; i < slots.length; i++) {
                results.add(slots[i] ?? probe_record(records[i], cancellable));
            }
            return results;
        }

        private ArrayList<UpdateResult> update_records_parallel(InstallationRecord[] records, GLib.Cancellable? cancellable) {
            var slots = new UpdateResult?[records.length];
            Mutex slots_lock = Mutex();
            ThreadPool<RecordTask>? pool = null;

            try {
                pool = new ThreadPool<RecordTask>.with_owned_data((task) => {
                    var outcome = update_record(task.record, cancellable);
                    slots_lock.lock();
                    slots[task.index] = outcome;
                    slots_lock.unlock();
                }, MAX_PARALLEL_JOBS, false);

                for (int i = 0; i < records.length; i++) {
                    var task = new RecordTask(i, records[i]);
                    pool.add((owned) task);
                }

                ThreadPool.free((owned) pool, false, true);
                pool = null;
            } catch (Error e) {
                if (pool != null) {
                    ThreadPool.free((owned) pool, false, true);
                }
                warning("Parallel update failed: %s", e.message);
            }

            var results = new ArrayList<UpdateResult>();
            for (int i = 0; i < slots.length; i++) {
                results.add(slots[i] ?? update_record(records[i], cancellable));
            }
            return results;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Probe & Update Logic
        // ─────────────────────────────────────────────────────────────────────

        private UpdateProbeResult probe_record(InstallationRecord record, GLib.Cancellable? cancellable) {
            var update_url = read_update_url(record);
            if (update_url == null || update_url.strip() == "") {
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.NO_UPDATE_URL, I18n.tr("No update address configured"));
            }

            var source = resolve_update_source(update_url, record.version);
            if (source == null) {
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.UNSUPPORTED_SOURCE, I18n.tr("Update source not supported"));
            }

            if (source is DirectUrlSource) {
                return probe_direct(record, source as DirectUrlSource, cancellable);
            }

            try {
                var release_source = source as ReleaseSource;
                var release = fetch_latest_release(release_source, cancellable);
                if (release == null) {
                    return new UpdateProbeResult(record, false, null, UpdateSkipReason.API_UNAVAILABLE, I18n.tr("Unable to read releases"));
                }

                var asset = select_appimage_asset(release.assets);
                if (asset == null) {
                    return new UpdateProbeResult(record, false, release.version, UpdateSkipReason.MISSING_ASSET, I18n.tr("No matching AppImage found for %s").printf(get_system_arch()));
                }

                var latest = release.version;
                var current = record.version;
                
                // Version comparison: if both have versions, compare them
                if (latest != null && current != null && compare_versions(latest, current) <= 0) {
                    return new UpdateProbeResult(record, false, latest, UpdateSkipReason.ALREADY_CURRENT, I18n.tr("Already up to date"));
                }
                
                // Fallback: if version is missing, compare release tags
                if ((latest == null || current == null) && release.tag_name != null) {
                    if (record.last_release_tag == release.tag_name) {
                        return new UpdateProbeResult(record, false, release.tag_name, UpdateSkipReason.ALREADY_CURRENT, I18n.tr("Already up to date"));
                    }
                }

                return new UpdateProbeResult(record, true, latest ?? release.tag_name);
            } catch (Error e) {
                warning("Failed to check updates for %s: %s", record.name, e.message);
                return new UpdateProbeResult(record, false, null, null, e.message);
            }
        }

        private UpdateResult update_record(InstallationRecord record, GLib.Cancellable? cancellable) {
            var update_url = read_update_url(record);
            if (update_url == null || update_url.strip() == "") {
                record_skipped(record, UpdateSkipReason.NO_UPDATE_URL);
                log_update_event(record, "SKIP", "no update url configured");
                return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("No update address configured"), null, UpdateSkipReason.NO_UPDATE_URL);
            }

            record_checking(record);

            var source = resolve_update_source(update_url, record.version);
            if (source == null) {
                record_skipped(record, UpdateSkipReason.UNSUPPORTED_SOURCE);
                log_update_event(record, "SKIP", "unsupported update source");
                return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Update source not supported"), null, UpdateSkipReason.UNSUPPORTED_SOURCE);
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
                    return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Unable to read releases"), null, UpdateSkipReason.API_UNAVAILABLE);
                }

                var latest = release.version;
                var current = record.version;
                
                // Version comparison: if both have versions, compare them
                if (latest != null && current != null && compare_versions(latest, current) <= 0) {
                    record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                    log_update_event(record, "SKIP", "already current");
                    return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Already up to date"), latest, UpdateSkipReason.ALREADY_CURRENT);
                }
                
                // Fallback: if version is missing, compare release tags
                if ((latest == null || current == null) && release.tag_name != null) {
                    if (record.last_release_tag == release.tag_name) {
                        record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                        log_update_event(record, "SKIP", "release tag unchanged");
                        return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Already up to date"), release.tag_name, UpdateSkipReason.ALREADY_CURRENT);
                    }
                }

                var asset = select_appimage_asset(release.assets);
                if (asset == null) {
                    record_skipped(record, UpdateSkipReason.MISSING_ASSET);
                    log_update_event(record, "SKIP", "no matching AppImage for " + get_system_arch());
                    return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("No matching AppImage found for %s").printf(get_system_arch()), latest, UpdateSkipReason.MISSING_ASSET);
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
                return new UpdateResult(record, UpdateStatus.UPDATED, I18n.tr("Updated to %s").printf(display_version), release.version ?? display_version);
            } catch (Error e) {
                warning("Failed to update %s: %s", record.name, e.message);
                record_failed(record, e.message);
                log_update_event(record, "FAILED", e.message);
                return new UpdateResult(record, UpdateStatus.FAILED, e.message);
            }
        }

        private UpdateCheckInfo? check_for_update(InstallationRecord record, GLib.Cancellable? cancellable) throws Error {
            var update_url = read_update_url(record);
            if (update_url == null || update_url.strip() == "") {
                return null;
            }

            var source = resolve_update_source(update_url, record.version);
            if (source == null) {
                return null;
            }

            if (source is DirectUrlSource) {
                return check_direct_update(record, source as DirectUrlSource, cancellable);
            }

            var release_source = source as ReleaseSource;
            var release = fetch_latest_release(release_source, cancellable);
            if (release == null) {
                return null;
            }

            var latest = release.version ?? release.tag_name ?? "";
            var current = record.version ?? "";
            var asset = select_appimage_asset(release.assets);

            if (asset == null) {
                return new UpdateCheckInfo(false, latest, current, release.tag_name);
            }

            // Version comparison if both have versions
            bool has_update = false;
            if (latest != "" && current != "" && record.version != null && release.version != null) {
                has_update = compare_versions(latest, current) > 0;
            } else if (release.tag_name != null) {
                // Fallback: compare release tags for version-less apps
                has_update = record.last_release_tag != release.tag_name;
            }
            
            return new UpdateCheckInfo(has_update, latest, current, release.tag_name);
        }

        // ─────────────────────────────────────────────────────────────────────
        // Direct URL Updates (ETag-based)
        // ─────────────────────────────────────────────────────────────────────

        private UpdateProbeResult probe_direct(InstallationRecord record, DirectUrlSource source, GLib.Cancellable? cancellable) {
            try {
                var message = send_head(source.url, cancellable);
                var etag = message.response_headers.get_one("ETag");
                if (etag == null || etag.strip() == "") {
                    return new UpdateProbeResult(record, false, null, UpdateSkipReason.ETAG_MISSING, I18n.tr("No ETag returned by server"));
                }

                var current = etag.strip();
                if (record.etag == null || record.etag.strip() == "") {
                    record.etag = current;
                    registry.persist(false);
                    return new UpdateProbeResult(record, false, current, UpdateSkipReason.ALREADY_CURRENT, I18n.tr("Baseline ETag recorded"));
                }

                if (record.etag == current) {
                    return new UpdateProbeResult(record, false, current, UpdateSkipReason.ALREADY_CURRENT, I18n.tr("Already up to date"));
                }

                return new UpdateProbeResult(record, true, current);
            } catch (Error e) {
                warning("Failed to check direct update for %s: %s", record.name, e.message);
                return new UpdateProbeResult(record, false, null, UpdateSkipReason.API_UNAVAILABLE, e.message);
            }
        }

        private UpdateResult update_direct(InstallationRecord record, DirectUrlSource source, GLib.Cancellable? cancellable) {
            try {
                var message = send_head(source.url, cancellable);
                var etag = message.response_headers.get_one("ETag");
                if (etag == null || etag.strip() == "") {
                    record_skipped(record, UpdateSkipReason.ETAG_MISSING);
                    log_update_event(record, "SKIP", "direct url missing etag");
                    return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("No ETag returned by server"), null, UpdateSkipReason.ETAG_MISSING);
                }

                var current = etag.strip();
                if (record.etag != null && record.etag == current) {
                    record_skipped(record, UpdateSkipReason.ALREADY_CURRENT);
                    log_update_event(record, "SKIP", "etag unchanged");
                    return new UpdateResult(record, UpdateStatus.SKIPPED, I18n.tr("Already up to date"), current, UpdateSkipReason.ALREADY_CURRENT);
                }

                record_downloading(record);

                var download = download_file(source.url, cancellable);
                try {
                    installer.upgrade(download.file_path, record);
                } finally {
                    AppManager.Utils.FileUtils.remove_dir_recursive(download.temp_dir);
                }

                record.etag = current;
                registry.persist();
                record_succeeded(record);
                log_update_event(record, "UPDATED", "direct url etag=%s".printf(current));
                return new UpdateResult(record, UpdateStatus.UPDATED, I18n.tr("Updated"), current);
            } catch (Error e) {
                warning("Failed to update %s via direct URL: %s", record.name, e.message);
                record_failed(record, e.message);
                log_update_event(record, "FAILED", e.message);
                return new UpdateResult(record, UpdateStatus.FAILED, e.message);
            }
        }

        private UpdateCheckInfo? check_direct_update(InstallationRecord record, DirectUrlSource source, GLib.Cancellable? cancellable) throws Error {
            var message = send_head(source.url, cancellable);
            var etag = message.response_headers.get_one("ETag");
            if (etag == null || etag.strip() == "") {
                var baseline = record.etag ?? "";
                return new UpdateCheckInfo(false, baseline, baseline, null);
            }

            var current = etag.strip();
            var previous = record.etag ?? current;
            return new UpdateCheckInfo(previous != current, current, previous, current);
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

        private ReleaseInfo? fetch_github_release(GithubSource source, GLib.Cancellable? cancellable) throws Error {
            var url = source.releases_api_url();
            var message = new Soup.Message("GET", url);
            message.request_headers.replace("Accept", "application/vnd.github+json");
            message.request_headers.replace("User-Agent", user_agent);
            
            var bytes = session.send_and_read(message, cancellable);
            var status = message.get_status();
            if (status < 200 || status >= 300) {
                throw new GLib.IOError.FAILED("GitHub API error (%u)".printf(status));
            }

            var parser = new Json.Parser();
            parser.load_from_stream(new MemoryInputStream.from_bytes(bytes), cancellable);
            var root = parser.steal_root();
            
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) {
                return null;
            }

            var array = root.get_array();
            
            // Find first release with an AppImage asset
            for (uint i = 0; i < array.get_length(); i++) {
                var node = array.get_element(i);
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                
                var release = parse_github_release(node.get_object());
                if (release != null && select_appimage_asset(release.assets) != null) {
                    return release;
                }
            }

            // Fallback to first release even without matching asset
            if (array.get_length() > 0) {
                var first = array.get_element(0);
                if (first.get_node_type() == Json.NodeType.OBJECT) {
                    return parse_github_release(first.get_object());
                }
            }

            return null;
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
            var url = source.releases_api_url();
            var message = new Soup.Message("GET", url);
            message.request_headers.replace("Accept", "application/json");
            message.request_headers.replace("User-Agent", user_agent);
            
            var bytes = session.send_and_read(message, cancellable);
            var status = message.get_status();
            if (status < 200 || status >= 300) {
                throw new GLib.IOError.FAILED("GitLab API error (%u)".printf(status));
            }

            var parser = new Json.Parser();
            parser.load_from_stream(new MemoryInputStream.from_bytes(bytes), cancellable);
            var root = parser.steal_root();
            
            if (root == null) return null;

            Json.Object? release_obj = null;
            if (root.get_node_type() == Json.NodeType.ARRAY) {
                var array = root.get_array();
                
                // Find first release with an AppImage asset
                for (uint i = 0; i < array.get_length(); i++) {
                    var node = array.get_element(i);
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    
                    var release = parse_gitlab_release(node.get_object());
                    if (release != null && select_appimage_asset(release.assets) != null) {
                        return release;
                    }
                    if (release_obj == null) {
                        release_obj = node.get_object();
                    }
                }
                
                // Fallback to first release
                if (release_obj != null) {
                    return parse_gitlab_release(release_obj);
                }
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
