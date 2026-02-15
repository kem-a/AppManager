using Gee;

namespace AppManager.Core {
    public errordomain AppImageAssetsError {
        DESKTOP_FILE_MISSING,
        ICON_FILE_MISSING,
        APPRUN_FILE_MISSING,
        SYMLINK_LOOP,
        SYMLINK_LIMIT_EXCEEDED,
        EXTRACTION_FAILED
    }

    internal class DwarfsTools : Object {
        private static bool checked_tools = false;
        private static bool available_cache = false;
        private static string? extract_path = null;
        private static bool missing_logged = false;

        private static void init_tool_paths() {
            if (checked_tools) {
                return;
            }

            string? env_dir = Environment.get_variable("APP_MANAGER_DWARFS_DIR");
            var candidates = new Gee.ArrayList<string>();
            if (env_dir != null && env_dir.strip() != "") {
                candidates.add(env_dir.strip());
            }

            // Build-time bundle dir (typically /usr/bin)
            if (DWARFS_BUNDLE_DIR != null && DWARFS_BUNDLE_DIR.strip() != "") {
                var bundle_dir = DWARFS_BUNDLE_DIR.strip();
                candidates.add(bundle_dir);

                // If running in AppImage, check relative to APPDIR
                var appdir = Environment.get_variable("APPDIR");
                if (appdir != null && appdir != "") {
                    var relative_bundle_dir = bundle_dir;
                    if (relative_bundle_dir.has_prefix("/")) {
                        relative_bundle_dir = relative_bundle_dir.substring(1);
                    }
                    candidates.add(Path.build_filename(appdir, relative_bundle_dir));
                }
            }

            // System-wide fallback locations (for compatibility with appimage-thumbnailer)
            candidates.add("/usr/lib/appimage-thumbnailer");

            // Per-user bundle locations
            var xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
            if (xdg_data_home == null || xdg_data_home.strip() == "") {
                xdg_data_home = Path.build_filename(Environment.get_home_dir(), ".local", "share");
            }
            candidates.add(Path.build_filename(xdg_data_home, "app-manager", "dwarfs"));
            candidates.add(Path.build_filename(Environment.get_home_dir(), ".local", "share", "app-manager", "dwarfs"));

            foreach (var base_dir in candidates) {
                var extract_candidate = Path.build_filename(base_dir, "dwarfsextract");
                if (FileUtils.test(extract_candidate, FileTest.IS_EXECUTABLE)) {
                    extract_path = extract_candidate;
                    break;
                }
            }

            if (extract_path == null) {
                var extract_found = Environment.find_program_in_path("dwarfsextract");
                if (extract_found != null && extract_found.strip() != "") {
                    extract_path = extract_found;
                }
            }

            available_cache = extract_path != null;
            checked_tools = true;
        }

        public static bool available() {
            init_tool_paths();
            return available_cache;
        }

        public static void log_missing_once() {
            if (available_cache || missing_logged) {
                return;
            }
            missing_logged = true;
            warning("DwarFS tools not found. Install or place dwarfsextract in PATH, APP_MANAGER_DWARFS_DIR, /usr/lib/app-manager, or ~/.local/share/app-manager/dwarfs for DwarFS AppImages.");
        }

        /**
         * Extracts files matching pattern from a DwarFS archive.
         * Returns false if tools unavailable or extraction fails.
         */
        public static bool extract_entry(string archive, string output_dir, string pattern) {
            if (!available()) {
                log_missing_once();
                return false;
            }

            try {
                string? stdout_str;
                string? stderr_str;
                var cleaned = strip_leading_slashes(pattern);
                var cmd = new string[] {
                    extract_path ?? "dwarfsextract",
                    "-i", archive,
                    "-O", "auto",
                    "--pattern", cleaned,
                    "-o", output_dir,
                    "--log-level=error"
                };
                int exit_status = execute(cmd, out stdout_str, out stderr_str);
                if (exit_status != 0) {
                    var err = stderr_str ?? "";
                    // "no filesystem found" just means this isn't a DwarFS image — not an error
                    if (!err.contains("no filesystem found")) {
                        debug("dwarfsextract failed (%d): %s", exit_status, err);
                    }
                }
                return exit_status == 0;
            } catch (Error e) {
                debug("Failed to run dwarfsextract: %s", e.message);
                return false;
            }
        }

        /**
         * Extracts entire DwarFS archive contents.
         * Returns false if tools unavailable or extraction fails.
         */
        public static bool extract_all(string archive, string output_dir) {
            return extract_entry(archive, output_dir, "*");
        }

        /**
         * Checks whether a DwarFS archive contains at least one entry matching pattern.
         * Uses streaming tar output (no disk writes) to probe for file existence.
         * An empty tar archive is 1024 bytes; any match produces > 1024 bytes.
         */
        public static bool has_entry(string archive, string pattern) {
            if (!available()) {
                log_missing_once();
                return false;
            }

            try {
                var cleaned = strip_leading_slashes(pattern);
                var proc = new GLib.Subprocess.newv(new string[] {
                    extract_path ?? "dwarfsextract",
                    "-i", archive,
                    "-O", "auto",
                    "-f", "ustar",
                    "--pattern", cleaned,
                    "--log-level=error"
                }, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);

                GLib.Bytes stdout_bytes;
                proc.communicate(null, null, out stdout_bytes, null);
                // An empty ustar archive is exactly 1024 bytes (two 512-byte zero blocks).
                // Any matched file produces > 1024 bytes of tar output.
                return stdout_bytes != null && stdout_bytes.get_size() > 1024;
            } catch (Error e) {
                debug("Failed to probe DwarFS archive: %s", e.message);
                return false;
            }
        }

        private static int execute(string[] arguments, out string? stdout_str, out string? stderr_str) throws Error {
            int exit_status;
            Process.spawn_sync(null, arguments, null, SpawnFlags.SEARCH_PATH, null, out stdout_str, out stderr_str, out exit_status);
            return exit_status;
        }

        private static string strip_leading_slashes(string value) {
            var result = value ?? "";
            while (result.has_prefix("/")) {
                result = result.substring(1);
            }
            return result;
        }

    }

    public class AppImageAssets : Object {
        private const string DIRICON_NAME = ".DirIcon";
        private const int MAX_SYMLINK_ITERATIONS = 5;

        public static DesktopEntry parse_desktop_file(string desktop_path) throws Error {
            return new DesktopEntry(desktop_path);
        }

        public static string extract_desktop_entry(string appimage_path, string temp_root) throws Error {
            var desktop_root = Path.build_filename(temp_root, "desktop");
            DirUtils.create_with_parents(desktop_root, 0755);
            
            // Extract only root-level .desktop files
            if (!try_extract_entry(appimage_path, desktop_root, "*.desktop")) {
                throw new AppImageAssetsError.DESKTOP_FILE_MISSING("No .desktop file found in AppImage root");
            }
            
            // Find .desktop file in root
            string? desktop_path = find_file_in_root(desktop_root, "*.desktop");
            if (desktop_path == null) {
                throw new AppImageAssetsError.DESKTOP_FILE_MISSING("No .desktop file found in AppImage root");
            }
            
            // Resolve symlink if needed
            return resolve_symlink(desktop_path, appimage_path, desktop_root);
        }

        public static string extract_icon(string appimage_path, string temp_root) throws Error {
            var icon_root = Path.build_filename(temp_root, "icon");
            DirUtils.create_with_parents(icon_root, 0755);
            
            // Try common icon patterns in root first
            var png_icon = try_extract_icon_pattern(appimage_path, icon_root, "*.png");
            if (png_icon != null) {
                return resolve_symlink(png_icon, appimage_path, icon_root);
            }
            var svg_icon = try_extract_icon_pattern(appimage_path, icon_root, "*.svg");
            if (svg_icon != null) {
                return resolve_symlink(svg_icon, appimage_path, icon_root);
            }
            
            // Fall back to .DirIcon
            if (try_extract_entry(appimage_path, icon_root, DIRICON_NAME)) {
                var diricon_path = Path.build_filename(icon_root, DIRICON_NAME);
                if (File.new_for_path(diricon_path).query_exists()) {
                    return resolve_symlink(diricon_path, appimage_path, icon_root);
                }
            }
            
            throw new AppImageAssetsError.ICON_FILE_MISSING("No icon file (.png, .svg, or .DirIcon) found in AppImage root");
        }

        public static string? extract_apprun(string appimage_path, string temp_root) {
            var apprun_root = Path.build_filename(temp_root, "apprun");
            try {
                DirUtils.create_with_parents(apprun_root, 0755);
                if (try_extract_entry(appimage_path, apprun_root, "AppRun")) {
                    var apprun_path = Path.build_filename(apprun_root, "AppRun");
                    if (File.new_for_path(apprun_path).query_exists()) {
                        return resolve_symlink(apprun_path, appimage_path, apprun_root);
                    }
                }
            } catch (Error e) {
                warning("Failed to extract AppRun: %s", e.message);
            }
            return null;
        }

        /**
         * Extracts and parses metainfo/appdata XML to get app version.
         * Looks in usr/share/metainfo/*.metainfo.xml and usr/share/metainfo/*.appdata.xml
         * Returns the latest release version or null if not found.
         */
        public static string? extract_version_from_metainfo(string appimage_path, string temp_root) {
            var metainfo_root = Path.build_filename(temp_root, "metainfo");
            DirUtils.create_with_parents(metainfo_root, 0755);
            
            // Try to extract metainfo files from standard locations
            // 7z preserves directory structure, so files will be at metainfo_root/usr/share/metainfo/
            string[] patterns = {
                "usr/share/metainfo/*.metainfo.xml",
                "usr/share/metainfo/*.appdata.xml",
                "usr/share/appdata/*.appdata.xml"
            };
            
            foreach (var pattern in patterns) {
                try_extract_entry(appimage_path, metainfo_root, pattern);
            }
            
            // Search recursively since 7z preserves directory structure
            var version = find_version_in_dir_recursive(metainfo_root);
            if (version != null) {
                return version;
            }
            return null;
        }

        /**
         * Recursively searches for metainfo XML files and parses them for version.
         */
        private static string? find_version_in_dir_recursive(string dir_path) {
            try {
                var dir = GLib.Dir.open(dir_path);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var path = Path.build_filename(dir_path, name);
                    
                    if (GLib.FileUtils.test(path, GLib.FileTest.IS_DIR)) {
                        var version = find_version_in_dir_recursive(path);
                        if (version != null) {
                            return version;
                        }
                    } else if (name.has_suffix(".metainfo.xml") || name.has_suffix(".appdata.xml")) {
                        var version = parse_metainfo_version(path);
                        if (version != null) {
                            return version;
                        }
                    }
                }
            } catch (Error e) {
                debug("Failed to search metainfo dir %s: %s", dir_path, e.message);
            }
            return null;
        }

        /**
         * Parses a metainfo XML file and extracts the latest release version.
         * Looks for <releases><release version="..."/></releases>
         */
        private static string? parse_metainfo_version(string xml_path) {
            try {
                string contents;
                FileUtils.get_contents(xml_path, out contents);
                
                // Simple XML parsing for <release version="...">
                // The first <release version= tag is typically the latest version
                // Use "release version" to avoid matching <releases> tag
                var release_start = contents.index_of("<release version");
                if (release_start < 0) {
                    // Also try with space before version: <release  version
                    release_start = contents.index_of("<release ");
                    if (release_start < 0) {
                        return null;
                    }
                }
                
                var release_end = contents.index_of(">", release_start);
                if (release_end < 0) {
                    return null;
                }
                
                var release_tag = contents.substring(release_start, release_end - release_start + 1);
                
                // Extract version attribute
                var version_attr = "version=\"";
                var version_start = release_tag.index_of(version_attr);
                if (version_start < 0) {
                    // Try single quotes
                    version_attr = "version='";
                    version_start = release_tag.index_of(version_attr);
                }
                
                if (version_start < 0) {
                    return null;
                }
                
                version_start += version_attr.length;
                var quote_char = version_attr[version_attr.length - 1];
                var version_end = release_tag.index_of_char(quote_char, version_start);
                if (version_end < 0) {
                    return null;
                }
                
                var version = release_tag.substring(version_start, version_end - version_start).strip();
                if (version.length > 0) {
                    debug("Found version %s in metainfo: %s", version, xml_path);
                    return version;
                }
            } catch (Error e) {
                debug("Failed to parse metainfo %s: %s", xml_path, e.message);
            }
            return null;
        }

        public static string ensure_apprun_present(string extracted_root) throws Error {
            var apprun_path = Path.build_filename(extracted_root, "AppRun");
            var apprun_file = File.new_for_path(apprun_path);
            if (!apprun_file.query_exists()) {
                throw new AppImageAssetsError.APPRUN_FILE_MISSING("No AppRun entry point found in extracted AppImage; the file may be corrupted or incompatible");
            }
            var type = apprun_file.query_file_type(FileQueryInfoFlags.NONE);
            if (type == FileType.DIRECTORY) {
                throw new AppImageAssetsError.APPRUN_FILE_MISSING("AppRun entry point is a directory, expected executable");
            }
            return apprun_path;
        }

        public static bool check_compatibility(string appimage_path) {
            // Try SquashFS path via 7z listing first
            var paths = list_archive_paths_7z(appimage_path);
            if (paths != null) {
                if (!archive_has_pattern(paths, "*.desktop")) {
                    return false;
                }
                bool has_icon = archive_has_pattern(paths, "*.png") ||
                               archive_has_pattern(paths, "*.svg") ||
                               archive_has_pattern(paths, DIRICON_NAME);
                if (!has_icon) {
                    return false;
                }
                if (!archive_has_pattern(paths, "AppRun")) {
                    return false;
                }
                return true;
            }

            // DwarFS path — probe via streaming tar (no disk writes)
            if (!DwarfsTools.available()) {
                DwarfsTools.log_missing_once();
                return false;
            }
            if (!DwarfsTools.has_entry(appimage_path, "*.desktop")) {
                return false;
            }
            bool has_icon = DwarfsTools.has_entry(appimage_path, "*.png") ||
                           DwarfsTools.has_entry(appimage_path, "*.svg") ||
                           DwarfsTools.has_entry(appimage_path, DIRICON_NAME);
            if (!has_icon) {
                return false;
            }
            if (!DwarfsTools.has_entry(appimage_path, "AppRun")) {
                return false;
            }
            return true;
        }

        private static string? find_file_in_root(string directory, string pattern) {
            GLib.Dir dir;
            try {
                dir = GLib.Dir.open(directory);
            } catch (Error e) {
                warning("Failed to open directory %s: %s", directory, e.message);
                return null;
            }

            string? name;
            while ((name = dir.read_name()) != null) {
                var path = Path.build_filename(directory, name);
                
                // Skip directories
                if (GLib.FileUtils.test(path, GLib.FileTest.IS_DIR)) {
                    continue;
                }
                
                // Match pattern
                if (pattern == "*.desktop" && name.has_suffix(".desktop")) {
                    return path;
                } else if (pattern == "*.png" && name.has_suffix(".png")) {
                    return path;
                } else if (pattern == "*.svg" && name.has_suffix(".svg")) {
                    return path;
                }
            }

            return null;
        }

        private static string resolve_symlink(string file_path, string appimage_path, string extract_root) throws Error {
            var file = File.new_for_path(file_path);
            if (!file.query_exists()) {
                throw new AppImageAssetsError.EXTRACTION_FAILED("File does not exist: %s".printf(file_path));
            }

            var type = file.query_file_type(FileQueryInfoFlags.NONE);
            if (type != FileType.SYMBOLIC_LINK) {
                // Not a symlink, return as-is
                return file_path;
            }

            var visited = new Gee.HashSet<string>();
            var current_path = file_path;
            visited.add(Path.get_basename(file_path));

            for (int iteration = 0; iteration < MAX_SYMLINK_ITERATIONS; iteration++) {
                string target;
                try {
                    target = GLib.FileUtils.read_link(current_path);
                } catch (Error e) {
                    throw new AppImageAssetsError.EXTRACTION_FAILED("Unable to read symlink: %s".printf(e.message));
                }

                var normalized = normalize_archive_path(target);
                if (normalized == null) {
                    throw new AppImageAssetsError.EXTRACTION_FAILED("Symlink target is invalid: %s".printf(target));
                }

                if (visited.contains(normalized)) {
                    throw new AppImageAssetsError.SYMLINK_LOOP("Symlink loop detected at: %s".printf(normalized));
                }
                visited.add(normalized);

                // Extract the symlink target from AppImage
                extract_entry_or_fail(appimage_path, extract_root, normalized);

                current_path = Path.build_filename(extract_root, normalized);
                var current_file = File.new_for_path(current_path);
                
                if (!current_file.query_exists()) {
                    throw new AppImageAssetsError.EXTRACTION_FAILED("Symlink target not found in AppImage: %s".printf(normalized));
                }

                var current_type = current_file.query_file_type(FileQueryInfoFlags.NONE);
                if (current_type != FileType.SYMBOLIC_LINK) {
                    // Resolved to actual file
                    return current_path;
                }
            }

            throw new AppImageAssetsError.SYMLINK_LIMIT_EXCEEDED("Symlink chain exceeded limit of %d iterations".printf(MAX_SYMLINK_ITERATIONS));
        }

        private static void extract_entry_or_fail(string appimage_path, string output_dir, string pattern) throws Error {
            if (try_extract_entry(appimage_path, output_dir, pattern)) {
                return;
            }
            throw new AppImageAssetsError.EXTRACTION_FAILED("Failed to extract %s from AppImage".printf(pattern));
        }

        private static bool try_extract_entry(string appimage_path, string output_dir, string pattern) {
            if (try_run_7z({"x", "-tSquashFS", appimage_path, "-o" + output_dir, pattern, "-y"}) &&
                extraction_successful(output_dir, pattern)) {
                return true;
            }
            if (DwarfsTools.extract_entry(appimage_path, output_dir, pattern) &&
                extraction_successful(output_dir, pattern)) {
                return true;
            }
            return false;
        }

        private static bool extraction_successful(string output_dir, string pattern) {
            var has_wildcard = pattern.index_of_char('*') >= 0 || pattern.index_of_char('?') >= 0;
            if (has_wildcard && !pattern.contains("/")) {
                try {
                    var spec = new GLib.PatternSpec(pattern);
                    var dir = GLib.Dir.open(output_dir);
                    string? name;
                    while ((name = dir.read_name()) != null) {
                        if (spec.match_string(name)) {
                            return true;
                        }
                    }
                } catch (Error e) {
                    debug("Failed to inspect extraction output: %s", e.message);
                }
                return false;
            }

            var target_path = Path.build_filename(output_dir, pattern);
            return File.new_for_path(target_path).query_exists();
        }

        private static Gee.ArrayList<string>? list_archive_paths_7z(string appimage_path) {
            try {
                string? stdout_str;
                string? stderr_str;
                int exit_status = execute_7z({"l", "-slt", "-tSquashFS", appimage_path}, out stdout_str, out stderr_str);
                if (exit_status != 0) {
                    debug("7z list failed (%d): %s", exit_status, stderr_str ?? "");
                    return null;
                }

                var paths = new Gee.ArrayList<string>();
                if (stdout_str == null) {
                    return null;
                }

                foreach (var raw_line in stdout_str.split("\n")) {
                    var line = raw_line.strip();
                    if (line.has_prefix("Path = ")) {
                        var path = line.substring("Path = ".length).strip();
                        var normalized = normalize_archive_path(path);
                        if (normalized != null) {
                            paths.add(normalized);
                        }
                    }
                }

                return paths.size > 0 ? paths : null;
            } catch (Error e) {
                debug("Failed to list archive paths with 7z: %s", e.message);
                return null;
            }
        }

        private static bool archive_has_pattern(Gee.ArrayList<string> paths, string pattern) {
            var spec = new GLib.PatternSpec(pattern);
            foreach (var path in paths) {
                if (spec.match_string(path)) {
                    return true;
                }
                // Allow basename match for plain patterns (e.g., "AppRun")
                if (!pattern.contains("*") && !pattern.contains("?")) {
                    if (Path.get_basename(path) == pattern) {
                        return true;
                    }
                }
            }
            return false;
        }

        private static bool try_run_7z(string[] arguments) {
            try {
                string? stdout_str;
                string? stderr_str;
                int exit_status = execute_7z(arguments, out stdout_str, out stderr_str);
                return exit_status == 0;
            } catch (Error e) {
                return false;
            }
        }

        private static int execute_7z(string[] arguments, out string? stdout_str, out string? stderr_str) throws Error {
            var cmd = new string[1 + arguments.length];
            // Try bundled 7z first, then fall back to system 7z
            string? resolved_7z = null;

            // 1. Check next to the running executable (works in AppImages
            //    where quick-sharun may restructure /usr/bin → /bin)
            try {
                var exe_path = FileUtils.read_link("/proc/self/exe");
                var exe_dir = Path.get_dirname(exe_path);
                var sibling_7z = Path.build_filename(exe_dir, "7z");
                if (FileUtils.test(sibling_7z, FileTest.IS_EXECUTABLE)) {
                    resolved_7z = sibling_7z;
                }
            } catch (Error e) {
                // /proc/self/exe not available, skip
            }

            // 2. When running inside an AppImage, resolve relative to APPDIR
            if (resolved_7z == null) {
                var appdir = Environment.get_variable("APPDIR");
                if (appdir != null && appdir != "" && SEVENZIP_BUNDLE_DIR != null && SEVENZIP_BUNDLE_DIR.strip() != "") {
                    var relative_dir = SEVENZIP_BUNDLE_DIR.strip();
                    if (relative_dir.has_prefix("/")) {
                        relative_dir = relative_dir.substring(1);
                    }
                    var appimage_7z = Path.build_filename(appdir, relative_dir, "7z");
                    if (FileUtils.test(appimage_7z, FileTest.IS_EXECUTABLE)) {
                        resolved_7z = appimage_7z;
                    }
                }
            }

            // 3. Try the build-time bundle dir directly
            if (resolved_7z == null) {
                string bundled_7z = Path.build_filename(SEVENZIP_BUNDLE_DIR, "7z");
                if (FileUtils.test(bundled_7z, FileTest.IS_EXECUTABLE)) {
                    resolved_7z = bundled_7z;
                }
            }

            cmd[0] = resolved_7z ?? "7z";
            for (int i = 0; i < arguments.length; i++) {
                cmd[i + 1] = arguments[i];
            }
            int exit_status;
            Process.spawn_sync(null, cmd, null, SpawnFlags.SEARCH_PATH, null, out stdout_str, out stderr_str, out exit_status);
            return exit_status;
        }

        private static string? normalize_archive_path(string? raw_path) {
            if (raw_path == null) {
                return null;
            }
            var trimmed = raw_path.strip();
            if (trimmed == "") {
                return null;
            }
            while (trimmed.has_prefix("/")) {
                trimmed = trimmed.substring(1);
            }

            var parts = new Gee.ArrayList<string>();
            foreach (var part in trimmed.split("/")) {
                if (part == "" || part == ".") {
                    continue;
                }
                if (part == "..") {
                    if (parts.size > 0) {
                        parts.remove_at(parts.size - 1);
                    }
                    continue;
                }
                parts.add(part);
            }

            if (parts.size == 0) {
                return null;
            }

            var builder = new StringBuilder();
            for (int i = 0; i < parts.size; i++) {
                if (i > 0) {
                    builder.append("/");
                }
                builder.append(parts.get(i));
            }
            return builder.str;
        }

        private static string? try_extract_icon_pattern(string appimage_path, string icon_root, string pattern) {
            if (!try_extract_entry(appimage_path, icon_root, pattern)) {
                return null;
            }
            return find_file_in_root(icon_root, pattern);
        }
    }
}
