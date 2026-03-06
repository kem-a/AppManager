using Gee;

namespace AppManager.Core {
    public errordomain AppImageAssetsError {
        DESKTOP_FILE_MISSING,
        ICON_FILE_MISSING,
        APPRUN_FILE_MISSING,
        SYMLINK_LOOP,
        SYMLINK_LIMIT_EXCEEDED,
        EXTRACTION_FAILED,
        NOT_AN_APPIMAGE
    }

    public enum AppImageFormat {
        UNKNOWN,
        SQUASHFS,
        DWARFS
    }

    public class AppImageAssets : Object {
        private const string DIRICON_NAME = ".DirIcon";
        private const int MAX_SYMLINK_ITERATIONS = 5;

        // ELF magic: 0x7f E L F
        private const uint8[] ELF_MAGIC = { 0x7f, 'E', 'L', 'F' };
        // AppImage magic: "AI" at ELF e_ident[8..9]
        private const uint8[] AI_MAGIC = { 0x41, 0x49 };
        // SquashFS little-endian magic: "hsqs"
        private const uint8[] SQFS_MAGIC = { 'h', 's', 'q', 's' };
        // DwarFS magic: "DWARFS"
        private const uint8[] DWARFS_MAGIC = { 'D', 'W', 'A', 'R', 'F', 'S' };

        private static bool unsquashfs_checked = false;
        private static string? unsquashfs_path = null;
        private static bool dwarfs_checked = false;
        private static string? dwarfsextract_path = null;

        /**
         * Detects AppImage format by reading ELF header and payload magic bytes.
         * Returns UNKNOWN if not a valid AppImage.
         */
        public static AppImageFormat detect_format(string appimage_path) {
            int64 offset = get_payload_offset(appimage_path);
            if (offset <= 0) {
                return AppImageFormat.UNKNOWN;
            }

            try {
                var file = File.new_for_path(appimage_path);
                var stream = file.read();
                stream.seek(offset, SeekType.SET);

                uint8[] magic = new uint8[8];
                size_t bytes_read;
                stream.read_all(magic, out bytes_read);
                stream.close();

                if (bytes_read < 4) {
                    return AppImageFormat.UNKNOWN;
                }

                if (magic[0] == SQFS_MAGIC[0] && magic[1] == SQFS_MAGIC[1] &&
                    magic[2] == SQFS_MAGIC[2] && magic[3] == SQFS_MAGIC[3]) {
                    return AppImageFormat.SQUASHFS;
                }

                if (bytes_read >= 6 &&
                    magic[0] == DWARFS_MAGIC[0] && magic[1] == DWARFS_MAGIC[1] &&
                    magic[2] == DWARFS_MAGIC[2] && magic[3] == DWARFS_MAGIC[3] &&
                    magic[4] == DWARFS_MAGIC[4] && magic[5] == DWARFS_MAGIC[5]) {
                    return AppImageFormat.DWARFS;
                }

            } catch (Error e) {
                debug("Failed to detect AppImage format: %s", e.message);
            }

            return AppImageFormat.UNKNOWN;
        }

        /**
         * Gets the payload offset (where SquashFS/DwarFS data starts) by parsing ELF header.
         * Returns -1 on failure.
         */
        public static int64 get_payload_offset(string appimage_path) {
            try {
                var file = File.new_for_path(appimage_path);
                var stream = file.read();

                uint8[] ident = new uint8[16];
                size_t bytes_read;
                stream.read_all(ident, out bytes_read);

                if (bytes_read < 16) {
                    return -1;
                }

                // Verify ELF magic
                if (ident[0] != ELF_MAGIC[0] || ident[1] != ELF_MAGIC[1] ||
                    ident[2] != ELF_MAGIC[2] || ident[3] != ELF_MAGIC[3]) {
                    return -1;
                }

                // Verify AppImage magic
                if (ident[8] != AI_MAGIC[0] || ident[9] != AI_MAGIC[1]) {
                    return -1;
                }

                int elf_class = ident[4];  // 1 = 32-bit, 2 = 64-bit
                int elf_data = ident[5];   // 1 = little-endian, 2 = big-endian

                int64 shoff;
                uint16 shentsize;
                uint16 shnum;

                if (elf_class == 2) {
                    // ELF64: e_shoff at offset 40 (8 bytes)
                    stream.seek(40, SeekType.SET);
                    uint8[] shoff_bytes = new uint8[8];
                    stream.read_all(shoff_bytes, out bytes_read);
                    if (bytes_read < 8) return -1;

                    // e_shentsize at offset 58, e_shnum at offset 60
                    stream.seek(58, SeekType.SET);
                    uint8[] size_bytes = new uint8[4];
                    stream.read_all(size_bytes, out bytes_read);
                    if (bytes_read < 4) return -1;

                    if (elf_data == 2) {  // big-endian
                        shoff = ((int64)shoff_bytes[0] << 56) | ((int64)shoff_bytes[1] << 48) |
                                ((int64)shoff_bytes[2] << 40) | ((int64)shoff_bytes[3] << 32) |
                                ((int64)shoff_bytes[4] << 24) | ((int64)shoff_bytes[5] << 16) |
                                ((int64)shoff_bytes[6] << 8) | (int64)shoff_bytes[7];
                        shentsize = (uint16)((size_bytes[0] << 8) | size_bytes[1]);
                        shnum = (uint16)((size_bytes[2] << 8) | size_bytes[3]);
                    } else {  // little-endian
                        shoff = ((int64)shoff_bytes[7] << 56) | ((int64)shoff_bytes[6] << 48) |
                                ((int64)shoff_bytes[5] << 40) | ((int64)shoff_bytes[4] << 32) |
                                ((int64)shoff_bytes[3] << 24) | ((int64)shoff_bytes[2] << 16) |
                                ((int64)shoff_bytes[1] << 8) | (int64)shoff_bytes[0];
                        shentsize = (uint16)((size_bytes[1] << 8) | size_bytes[0]);
                        shnum = (uint16)((size_bytes[3] << 8) | size_bytes[2]);
                    }
                } else if (elf_class == 1) {
                    // ELF32: e_shoff at offset 32 (4 bytes)
                    stream.seek(32, SeekType.SET);
                    uint8[] shoff_bytes = new uint8[4];
                    stream.read_all(shoff_bytes, out bytes_read);
                    if (bytes_read < 4) return -1;

                    // e_shentsize at offset 46, e_shnum at offset 48
                    stream.seek(46, SeekType.SET);
                    uint8[] size_bytes = new uint8[4];
                    stream.read_all(size_bytes, out bytes_read);
                    if (bytes_read < 4) return -1;

                    if (elf_data == 2) {  // big-endian
                        shoff = ((int64)shoff_bytes[0] << 24) | ((int64)shoff_bytes[1] << 16) |
                                ((int64)shoff_bytes[2] << 8) | (int64)shoff_bytes[3];
                        shentsize = (uint16)((size_bytes[0] << 8) | size_bytes[1]);
                        shnum = (uint16)((size_bytes[2] << 8) | size_bytes[3]);
                    } else {  // little-endian
                        shoff = ((int64)shoff_bytes[3] << 24) | ((int64)shoff_bytes[2] << 16) |
                                ((int64)shoff_bytes[1] << 8) | (int64)shoff_bytes[0];
                        shentsize = (uint16)((size_bytes[1] << 8) | size_bytes[0]);
                        shnum = (uint16)((size_bytes[3] << 8) | size_bytes[2]);
                    }
                } else {
                    return -1;
                }

                stream.close();
                return shoff + (int64)(shnum * shentsize);

            } catch (Error e) {
                debug("Failed to get AppImage payload offset: %s", e.message);
                return -1;
            }
        }

        public static DesktopEntry parse_desktop_file(string desktop_path) throws Error {
            return new DesktopEntry(desktop_path);
        }

        public static string extract_desktop_entry(string appimage_path, string temp_root) throws Error {
            var desktop_root = Path.build_filename(temp_root, "desktop");
            DirUtils.create_with_parents(desktop_root, 0755);

            // Extract all root-level .desktop files
            if (!extract_entry(appimage_path, desktop_root, "*.desktop")) {
                throw new AppImageAssetsError.DESKTOP_FILE_MISSING("No .desktop file found in AppImage root");
            }

            // Find .desktop file in root
            string? desktop_path = find_file_in_root(desktop_root, "*.desktop");
            if (desktop_path == null) {
                throw new AppImageAssetsError.DESKTOP_FILE_MISSING("No .desktop file found in AppImage root");
            }

            return resolve_symlink(desktop_path, appimage_path, desktop_root);
        }

        public static string extract_icon(string appimage_path, string temp_root) throws Error {
            var icon_root = Path.build_filename(temp_root, "icon");
            DirUtils.create_with_parents(icon_root, 0755);

            // Try .DirIcon first (AppImage spec standard)
            if (extract_entry(appimage_path, icon_root, DIRICON_NAME)) {
                var diricon_path = Path.build_filename(icon_root, DIRICON_NAME);
                if (File.new_for_path(diricon_path).query_exists()) {
                    return resolve_symlink(diricon_path, appimage_path, icon_root);
                }
            }

            // Try PNG icons in root
            if (extract_entry(appimage_path, icon_root, "*.png")) {
                var png_path = find_file_in_root(icon_root, "*.png");
                if (png_path != null) {
                    return resolve_symlink(png_path, appimage_path, icon_root);
                }
            }

            // Try SVG icons in root
            if (extract_entry(appimage_path, icon_root, "*.svg")) {
                var svg_path = find_file_in_root(icon_root, "*.svg");
                if (svg_path != null) {
                    return resolve_symlink(svg_path, appimage_path, icon_root);
                }
            }

            throw new AppImageAssetsError.ICON_FILE_MISSING("No icon file (.DirIcon, .png, or .svg) found in AppImage root");
        }

        public static string? extract_apprun(string appimage_path, string temp_root) {
            var apprun_root = Path.build_filename(temp_root, "apprun");
            try {
                DirUtils.create_with_parents(apprun_root, 0755);
                if (extract_entry(appimage_path, apprun_root, "AppRun")) {
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

        public static string? extract_version_from_metainfo(string appimage_path, string temp_root, string? desktop_id_hint = null, string? app_name_hint = null) {
            var metainfo_root = ensure_metainfo_extracted(appimage_path, temp_root);
            var best_match = find_best_metainfo_file(metainfo_root, desktop_id_hint, app_name_hint);
            if (best_match != null) {
                return parse_metainfo_version(best_match);
            }
            return find_version_in_dir_recursive(metainfo_root);
        }

        public static string? extract_summary_from_metainfo(string appimage_path, string temp_root, string? desktop_id_hint = null, string? app_name_hint = null) {
            var metainfo_root = ensure_metainfo_extracted(appimage_path, temp_root);
            var best_match = find_best_metainfo_file(metainfo_root, desktop_id_hint, app_name_hint);
            if (best_match != null) {
                return parse_metainfo_summary(best_match);
            }
            return find_summary_in_dir_recursive(metainfo_root);
        }

        private static string ensure_metainfo_extracted(string appimage_path, string temp_root) {
            var metainfo_root = Path.build_filename(temp_root, "metainfo");
            DirUtils.create_with_parents(metainfo_root, 0755);

            string[] patterns = {
                "usr/share/metainfo/*.metainfo.xml",
                "usr/share/metainfo/*.appdata.xml",
                "usr/share/appdata/*.appdata.xml",
                "share/metainfo/*.metainfo.xml",
                "share/metainfo/*.appdata.xml"
            };

            foreach (var pattern in patterns) {
                extract_entry(appimage_path, metainfo_root, pattern);
            }

            return metainfo_root;
        }

        public static string ensure_apprun_present(string extracted_root) throws Error {
            var apprun_path = Path.build_filename(extracted_root, "AppRun");
            var apprun_file = File.new_for_path(apprun_path);
            if (!apprun_file.query_exists()) {
                throw new AppImageAssetsError.APPRUN_FILE_MISSING("No AppRun entry point found in extracted AppImage");
            }
            var type = apprun_file.query_file_type(FileQueryInfoFlags.NONE);
            if (type == FileType.DIRECTORY) {
                throw new AppImageAssetsError.APPRUN_FILE_MISSING("AppRun entry point is a directory, expected executable");
            }
            return apprun_path;
        }

        /**
         * Quick compatibility check: verify AppImage has required root files.
         * Attempts extraction of .DirIcon, AppRun, and *.desktop directly.
         */
        public static bool check_compatibility(string appimage_path) {
            var format = detect_format(appimage_path);
            if (format == AppImageFormat.UNKNOWN) {
                return false;
            }

            string? temp_dir = null;
            try {
                temp_dir = Utils.FileUtils.create_temp_dir("appmgr-compat-");
            } catch (Error e) {
                debug("Failed to create temp dir for compatibility check: %s", e.message);
                return false;
            }

            bool has_desktop = false;
            bool has_icon = false;
            bool has_apprun = false;

            try {
                // Check .desktop file
                has_desktop = extract_entry(appimage_path, temp_dir, "*.desktop") &&
                              find_file_in_root(temp_dir, "*.desktop") != null;

                // Check icon (.DirIcon preferred)
                has_icon = extract_entry(appimage_path, temp_dir, DIRICON_NAME) &&
                           File.new_for_path(Path.build_filename(temp_dir, DIRICON_NAME)).query_exists();
                if (!has_icon) {
                    has_icon = (extract_entry(appimage_path, temp_dir, "*.png") &&
                                find_file_in_root(temp_dir, "*.png") != null) ||
                               (extract_entry(appimage_path, temp_dir, "*.svg") &&
                                find_file_in_root(temp_dir, "*.svg") != null);
                }

                // Check AppRun
                has_apprun = extract_entry(appimage_path, temp_dir, "AppRun") &&
                             File.new_for_path(Path.build_filename(temp_dir, "AppRun")).query_exists();

            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }

            return has_desktop && has_icon && has_apprun;
        }

        /**
         * Extract all contents from AppImage (used for portable installation).
         */
        public static bool extract_all(string appimage_path, string output_dir) {
            var format = detect_format(appimage_path);
            int64 offset = get_payload_offset(appimage_path);

            if (format == AppImageFormat.SQUASHFS && offset > 0) {
                return run_unsquashfs_extract(appimage_path, output_dir, null, offset);
            }

            if (format == AppImageFormat.DWARFS) {
                return run_dwarfs_extract(appimage_path, output_dir, "*");
            }

            return false;
        }

        // --- Private implementation ---

        private static bool extract_entry(string appimage_path, string output_dir, string pattern) {
            var format = detect_format(appimage_path);
            int64 offset = get_payload_offset(appimage_path);

            if (format == AppImageFormat.SQUASHFS && offset > 0) {
                return run_unsquashfs_extract(appimage_path, output_dir, pattern, offset);
            }

            if (format == AppImageFormat.DWARFS) {
                return run_dwarfs_extract(appimage_path, output_dir, pattern);
            }

            // Try both as fallback if format detection failed
            if (offset > 0 && run_unsquashfs_extract(appimage_path, output_dir, pattern, offset)) {
                return true;
            }
            return run_dwarfs_extract(appimage_path, output_dir, pattern);
        }

        private static void init_unsquashfs() {
            if (unsquashfs_checked) return;
            unsquashfs_checked = true;

            // Check well-known locations
            string[] candidates = {
                "/usr/lib/appimage-thumbnailer/unsquashfs",
                "/usr/lib/app-manager/unsquashfs"
            };

            foreach (var path in candidates) {
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) {
                    unsquashfs_path = path;
                    return;
                }
            }

            // Check PATH
            unsquashfs_path = Environment.find_program_in_path("unsquashfs");
        }

        private static void init_dwarfs() {
            if (dwarfs_checked) return;
            dwarfs_checked = true;

            string? env_dir = Environment.get_variable("APP_MANAGER_DWARFS_DIR");
            if (env_dir != null && env_dir.strip() != "") {
                var path = Path.build_filename(env_dir.strip(), "dwarfsextract");
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) {
                    dwarfsextract_path = path;
                    return;
                }
            }

            string[] candidates = {
                "/usr/lib/appimage-thumbnailer/dwarfsextract",
                "/usr/lib/app-manager/dwarfsextract"
            };

            var xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
            if (xdg_data_home == null || xdg_data_home.strip() == "") {
                xdg_data_home = Path.build_filename(Environment.get_home_dir(), ".local", "share");
            }

            string[] user_dirs = {
                Path.build_filename(xdg_data_home, "app-manager", "dwarfs"),
                Path.build_filename(Environment.get_home_dir(), ".local", "share", "app-manager", "dwarfs")
            };

            foreach (var dir in user_dirs) {
                var path = Path.build_filename(dir, "dwarfsextract");
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) {
                    dwarfsextract_path = path;
                    return;
                }
            }

            foreach (var path in candidates) {
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) {
                    dwarfsextract_path = path;
                    return;
                }
            }

            dwarfsextract_path = Environment.find_program_in_path("dwarfsextract");
        }

        private static bool run_unsquashfs_extract(string appimage_path, string output_dir, string? pattern, int64 offset) {
            init_unsquashfs();
            if (unsquashfs_path == null) {
                return false;
            }

            try {
                // unsquashfs wants to create a new directory, so use a subdir
                var extract_dir = Path.build_filename(output_dir, "squashfs-root");

                string[] cmd;
                if (pattern != null) {
                    cmd = {
                        unsquashfs_path,
                        "-o", offset.to_string(),
                        "-no-progress",
                        "-no-xattrs",
                        "-d", extract_dir,
                        appimage_path,
                        strip_leading_slash(pattern)
                    };
                } else {
                    cmd = {
                        unsquashfs_path,
                        "-o", offset.to_string(),
                        "-no-progress",
                        "-no-xattrs",
                        "-d", extract_dir,
                        appimage_path
                    };
                }

                string? stdout_str;
                string? stderr_str;
                int exit_status;
                Process.spawn_sync(null, cmd, null, SpawnFlags.SEARCH_PATH, null, 
                                   out stdout_str, out stderr_str, out exit_status);

                if (exit_status != 0) {
                    debug("unsquashfs failed (%d): %s", exit_status, stderr_str ?? "");
                    return false;
                }

                // Move extracted files from squashfs-root to output_dir
                move_extracted_files(extract_dir, output_dir);
                return true;

            } catch (Error e) {
                debug("Failed to run unsquashfs: %s", e.message);
                return false;
            }
        }

        private static bool run_dwarfs_extract(string appimage_path, string output_dir, string pattern) {
            init_dwarfs();
            if (dwarfsextract_path == null) {
                return false;
            }

            try {
                var cmd = new string[] {
                    dwarfsextract_path,
                    "-i", appimage_path,
                    "-O", "auto",
                    "--pattern", strip_leading_slash(pattern),
                    "-o", output_dir,
                    "--log-level=error"
                };

                string? stdout_str;
                string? stderr_str;
                int exit_status;
                Process.spawn_sync(null, cmd, null, SpawnFlags.SEARCH_PATH, null,
                                   out stdout_str, out stderr_str, out exit_status);

                if (exit_status != 0) {
                    var err = stderr_str ?? "";
                    if (!err.contains("no filesystem found")) {
                        debug("dwarfsextract failed (%d): %s", exit_status, err);
                    }
                    return false;
                }

                return true;

            } catch (Error e) {
                debug("Failed to run dwarfsextract: %s", e.message);
                return false;
            }
        }

        private static void move_extracted_files(string from_dir, string to_dir) {
            try {
                var dir = Dir.open(from_dir);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var src = Path.build_filename(from_dir, name);
                    var dst = Path.build_filename(to_dir, name);
                    var src_file = File.new_for_path(src);
                    var dst_file = File.new_for_path(dst);

                    if (dst_file.query_exists()) {
                        // If destination exists and is a directory, merge
                        if (FileUtils.test(src, FileTest.IS_DIR) && FileUtils.test(dst, FileTest.IS_DIR)) {
                            move_extracted_files(src, dst);
                            continue;
                        }
                    }

                    src_file.move(dst_file, FileCopyFlags.OVERWRITE | FileCopyFlags.NOFOLLOW_SYMLINKS);
                }

                // Remove the now-empty source directory
                DirUtils.remove(from_dir);

            } catch (Error e) {
                debug("Failed to move extracted files: %s", e.message);
            }
        }

        private static string? find_file_in_root(string directory, string pattern) {
            try {
                var dir = Dir.open(directory);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var path = Path.build_filename(directory, name);

                    // Skip directories
                    if (FileUtils.test(path, FileTest.IS_DIR)) {
                        continue;
                    }

                    if (pattern == "*.desktop" && name.has_suffix(".desktop")) {
                        return path;
                    } else if (pattern == "*.png" && name.has_suffix(".png")) {
                        return path;
                    } else if (pattern == "*.svg" && name.has_suffix(".svg")) {
                        return path;
                    }
                }
            } catch (Error e) {
                debug("Failed to search directory %s: %s", directory, e.message);
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
                return file_path;
            }

            var visited = new HashSet<string>();
            var current_path = file_path;
            visited.add(Path.get_basename(file_path));

            for (int i = 0; i < MAX_SYMLINK_ITERATIONS; i++) {
                string target;
                try {
                    target = FileUtils.read_link(current_path);
                } catch (Error e) {
                    throw new AppImageAssetsError.EXTRACTION_FAILED("Unable to read symlink: %s".printf(e.message));
                }

                var normalized = normalize_path(target);
                if (normalized == null) {
                    throw new AppImageAssetsError.EXTRACTION_FAILED("Invalid symlink target: %s".printf(target));
                }

                if (visited.contains(normalized)) {
                    throw new AppImageAssetsError.SYMLINK_LOOP("Symlink loop detected at: %s".printf(normalized));
                }
                visited.add(normalized);

                // Extract symlink target
                if (!extract_entry(appimage_path, extract_root, normalized)) {
                    throw new AppImageAssetsError.EXTRACTION_FAILED("Failed to extract symlink target: %s".printf(normalized));
                }

                current_path = Path.build_filename(extract_root, normalized);
                var current_file = File.new_for_path(current_path);

                if (!current_file.query_exists()) {
                    throw new AppImageAssetsError.EXTRACTION_FAILED("Symlink target not found: %s".printf(normalized));
                }

                var current_type = current_file.query_file_type(FileQueryInfoFlags.NONE);
                if (current_type != FileType.SYMBOLIC_LINK) {
                    return current_path;
                }
            }

            throw new AppImageAssetsError.SYMLINK_LIMIT_EXCEEDED("Symlink chain exceeded %d iterations".printf(MAX_SYMLINK_ITERATIONS));
        }

        private static string? find_summary_in_dir_recursive(string dir_path) {
            try {
                var dir = Dir.open(dir_path);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var path = Path.build_filename(dir_path, name);

                    if (FileUtils.test(path, FileTest.IS_DIR)) {
                        var summary = find_summary_in_dir_recursive(path);
                        if (summary != null) {
                            return summary;
                        }
                    } else if (name.has_suffix(".metainfo.xml") || name.has_suffix(".appdata.xml")) {
                        var summary = parse_metainfo_summary(path);
                        if (summary != null) {
                            return summary;
                        }
                    }
                }
            } catch (Error e) {
                debug("Failed to search metainfo dir %s: %s", dir_path, e.message);
            }
            return null;
        }

        private static string? find_best_metainfo_file(string dir_path, string? desktop_id_hint, string? app_name_hint) {
            string? best_path = null;
            int best_score = 0;
            collect_best_metainfo_file(dir_path, desktop_id_hint, app_name_hint, ref best_path, ref best_score);
            return best_path;
        }

        private static void collect_best_metainfo_file(string dir_path, string? desktop_id_hint, string? app_name_hint, ref string? best_path, ref int best_score) {
            try {
                var dir = Dir.open(dir_path);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var path = Path.build_filename(dir_path, name);

                    if (FileUtils.test(path, FileTest.IS_DIR)) {
                        collect_best_metainfo_file(path, desktop_id_hint, app_name_hint, ref best_path, ref best_score);
                        continue;
                    }

                    if (!name.has_suffix(".metainfo.xml") && !name.has_suffix(".appdata.xml")) {
                        continue;
                    }

                    var score = score_metainfo_file(path, desktop_id_hint, app_name_hint);
                    if (score > best_score) {
                        best_score = score;
                        best_path = path;
                    }
                }
            } catch (Error e) {
                debug("Failed to scan metainfo dir %s: %s", dir_path, e.message);
            }
        }

        private static int score_metainfo_file(string xml_path, string? desktop_id_hint, string? app_name_hint) {
            int score = 1;
            try {
                string contents;
                FileUtils.get_contents(xml_path, out contents);

                var basename = Path.get_basename(xml_path);
                var normalized_desktop_id = normalize_component_hint(desktop_id_hint);
                var normalized_app_name = app_name_hint != null ? app_name_hint.strip() : null;

                if (normalized_desktop_id != null && normalized_desktop_id != "") {
                    if (basename == "%s.metainfo.xml".printf(normalized_desktop_id) || basename == "%s.appdata.xml".printf(normalized_desktop_id)) {
                        score = 6;
                    }

                    if (contents.contains("<launchable type=\"desktop-id\">%s.desktop</launchable>".printf(normalized_desktop_id))) {
                        score = int.max(score, 5);
                    }

                    if (contents.contains("<id>%s</id>".printf(normalized_desktop_id))) {
                        score = int.max(score, 4);
                    }
                }

                if (normalized_app_name != null && normalized_app_name != "" && contents.contains("<name>%s</name>".printf(normalized_app_name))) {
                    score = int.max(score, 3);
                }
            } catch (Error e) {
                debug("Failed to score metainfo file %s: %s", xml_path, e.message);
            }

            return score;
        }

        private static string? normalize_component_hint(string? desktop_id_hint) {
            if (desktop_id_hint == null) {
                return null;
            }

            var normalized = desktop_id_hint.strip();
            if (normalized == "") {
                return null;
            }

            if (normalized.has_suffix(".desktop")) {
                normalized = normalized.substring(0, normalized.length - ".desktop".length);
            }

            return normalized;
        }

        private static string? parse_metainfo_summary(string xml_path) {
            try {
                string contents;
                FileUtils.get_contents(xml_path, out contents);

                var start_tag = "<summary>";
                var end_tag = "</summary>";
                var start = contents.index_of(start_tag);
                if (start < 0) return null;

                start += start_tag.length;
                var end = contents.index_of(end_tag, start);
                if (end < 0) return null;

                var summary = contents.substring(start, end - start).strip();
                if (summary.length > 0) {
                    debug("Found summary in metainfo: %s", xml_path);
                    return summary;
                }
            } catch (Error e) {
                debug("Failed to parse metainfo summary %s: %s", xml_path, e.message);
            }
            return null;
        }

        private static string? find_version_in_dir_recursive(string dir_path) {
            try {
                var dir = Dir.open(dir_path);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var path = Path.build_filename(dir_path, name);

                    if (FileUtils.test(path, FileTest.IS_DIR)) {
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

        private static string? parse_metainfo_version(string xml_path) {
            try {
                string contents;
                FileUtils.get_contents(xml_path, out contents);

                var release_start = contents.index_of("<release version");
                if (release_start < 0) {
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

                var version_attr = "version=\"";
                var version_start = release_tag.index_of(version_attr);
                if (version_start < 0) {
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

        private static string strip_leading_slash(string path) {
            var result = path;
            while (result.has_prefix("/")) {
                result = result.substring(1);
            }
            return result;
        }

        private static string? normalize_path(string? raw_path) {
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

            var parts = new ArrayList<string>();
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
    }

    // Backwards compatibility - DwarfsTools.extract_all used by installer.vala
    internal class DwarfsTools : Object {
        public static bool extract_all(string archive, string output_dir) {
            return AppImageAssets.extract_all(archive, output_dir);
        }
    }
}
