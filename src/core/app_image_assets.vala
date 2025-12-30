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
        private static string? check_path = null;
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

            // Build-time bundle dir (e.g., /usr/lib/app-manager/dwarfs)
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
                    candidates.add(Path.build_filename(appdir, "usr", "bin"));
                }
            }

            // System-wide bundle locations
            candidates.add("/usr/lib/app-manager");
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
                var check_candidate = Path.build_filename(base_dir, "dwarfsck");
                if (FileUtils.test(extract_candidate, FileTest.IS_EXECUTABLE) &&
                    FileUtils.test(check_candidate, FileTest.IS_EXECUTABLE)) {
                    extract_path = extract_candidate;
                    check_path = check_candidate;
                    break;
                }
            }

            if (extract_path == null || check_path == null) {
                var extract_found = Environment.find_program_in_path("dwarfsextract");
                var check_found = Environment.find_program_in_path("dwarfsck");
                if (extract_found != null && extract_found.strip() != "") {
                    extract_path = extract_found;
                }
                if (check_found != null && check_found.strip() != "") {
                    check_path = check_found;
                }
            }

            available_cache = extract_path != null && check_path != null;
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
            warning("DwarFS tools not found. Install or place dwarfsextract/dwarfsck in PATH, APP_MANAGER_DWARFS_DIR, /usr/lib/app-manager, or ~/.local/share/app-manager/dwarfs for DwarFS AppImages.");
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
                    debug("dwarfsextract failed (%d): %s", exit_status, stderr_str ?? "");
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
         * Lists all paths in a DwarFS archive.
         * Returns null if tools unavailable or listing fails.
         */
        public static Gee.ArrayList<string>? list_paths(string archive) {
            if (!available()) {
                log_missing_once();
                return null;
            }

            try {
                string? stdout_str;
                string? stderr_str;
                var cmd = new string[] {check_path ?? "dwarfsck", "-l", "--no-check", "-O", "auto", archive};
                int exit_status = execute(cmd, out stdout_str, out stderr_str);
                if (exit_status != 0) {
                    debug("dwarfsck list failed (%d): %s", exit_status, stderr_str ?? "");
                    return null;
                }

                var paths = new Gee.ArrayList<string>();
                if (stdout_str == null) {
                    return null;
                }

                foreach (var raw_line in stdout_str.split("\n")) {
                    var line = raw_line.strip();
                    if (line == "") {
                        continue;
                    }

                    // DwarFS uses ls-like output; extract the first token that looks like a path and keep the rest (supports spaces).
                    var tokens = new Gee.ArrayList<string>();
                    foreach (var part in raw_line.replace("\t", " ").split(" ")) {
                        var trimmed = part.strip();
                        if (trimmed != "") {
                            tokens.add(trimmed);
                        }
                    }

                    if (tokens.size == 0) {
                        continue;
                    }

                    int path_index = -1;
                    for (int i = 0; i < tokens.size; i++) {
                        if (looks_like_path_token(tokens.get(i))) {
                            path_index = i;
                            break;
                        }
                    }

                    if (path_index < 0) {
                        path_index = tokens.size - 1;
                    }

                    var builder = new StringBuilder();
                    for (int i = path_index; i < tokens.size; i++) {
                        if (tokens.get(i) == "->") {
                            break; // stop before symlink target
                        }
                        if (builder.len > 0) {
                            builder.append(" ");
                        }
                        builder.append(tokens.get(i));
                    }

                    var path = strip_leading_slashes(builder.str.strip());
                    if (path != "") {
                        paths.add(path);
                    }
                }

                return paths.size > 0 ? paths : null;
            } catch (Error e) {
                debug("Failed to list DwarFS paths: %s", e.message);
                return null;
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

        private static bool looks_like_path_token(string token) {
            return token.contains("/") ||
                token == "AppRun" ||
                token.has_suffix(".desktop") ||
                token.has_suffix(".png") ||
                token.has_suffix(".svg") ||
                token.has_suffix(".DirIcon") ||
                token == ".DirIcon";
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
            var paths = list_archive_paths(appimage_path);
            if (paths == null) {
                return false;
            }

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

        private static Gee.ArrayList<string>? list_archive_paths(string appimage_path) {
            var paths = list_archive_paths_7z(appimage_path);
            if (paths != null) {
                return paths;
            }
            var dwarfs_paths = DwarfsTools.list_paths(appimage_path);
            return dwarfs_paths;
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
            cmd[0] = "7z";
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
