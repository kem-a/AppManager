namespace AppManager.Utils {
    public class FileUtils {
        public static string compute_checksum(string path) throws Error {
            var checksum = new GLib.Checksum(GLib.ChecksumType.SHA256);
            var stream = File.new_for_path(path).read();
            var buffer = new uint8[64 * 1024];
            ssize_t read = 0;
            while ((read = stream.read(buffer, null)) > 0) {
                checksum.update(buffer, (size_t)read);
            }
            stream.close();
            return checksum.get_string();
        }

        public static void ensure_parent(string path) throws Error {
            var parent = Path.get_dirname(path);
            if (parent == null || parent == ".") {
                return;
            }
            DirUtils.create_with_parents(parent, 0755);
        }

        public static string unique_path(string desired_path) {
            if (!File.new_for_path(desired_path).query_exists()) {
                return desired_path;
            }
            var dir = Path.get_dirname(desired_path);
            var filename = Path.get_basename(desired_path);
            var stem = filename;
            var ext = "";
            var dot = filename.last_index_of_char('.');
            if (dot > 0) {
                stem = filename.substring(0, dot);
                ext = filename.substring(dot);
            }
            for (int i = 1; i < 1000; i++) {
                var candidate = Path.build_filename(dir, "%s-%d%s".printf(stem, i, ext));
                if (!File.new_for_path(candidate).query_exists()) {
                    return candidate;
                }
            }
            return desired_path;
        }

        public static string create_temp_dir(string prefix) throws Error {
            var template = Path.build_filename("/tmp", prefix + "XXXXXX");
            return DirUtils.mkdtemp(template);
        }

        public static void file_copy(string source_path, string dest_path) throws Error {
            ensure_parent(dest_path);
            var src = File.new_for_path(source_path);
            var dest = File.new_for_path(dest_path);
            src.copy(dest, FileCopyFlags.OVERWRITE, null, null);
        }

        public static void remove_dir_recursive(string path) {
            try {
                if (!File.new_for_path(path).query_exists()) {
                    return;
                }
                var enumerator = File.new_for_path(path).enumerate_children("standard::name", FileQueryInfoFlags.NONE);
                FileInfo info;
                while ((info = enumerator.next_file()) != null) {
                    var child = enumerator.get_child(info);
                    if (info.get_file_type() == FileType.DIRECTORY) {
                        remove_dir_recursive(child.get_path());
                    } else {
                        child.delete(null);
                    }
                }
                File.new_for_path(path).delete(null);
            } catch (Error e) {
                warning("Failed to delete %s: %s", path, e.message);
            }
        }

        public static int64 get_path_size(string path) throws Error {
            var file = File.new_for_path(path);
            if (!file.query_exists()) {
                return 0;
            }
            
            // Use NOFOLLOW_SYMLINKS to avoid counting symlink targets (which may be
            // counted again at their real location, or point outside the directory).
            var info = file.query_info(FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            
            // Skip symlinks entirely - they're just small pointer files
            if (info.get_file_type() == FileType.SYMBOLIC_LINK) {
                return 0;
            }
            
            if (info.get_file_type() == FileType.DIRECTORY) {
                int64 size = 0;
                var enumerator = file.enumerate_children(FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo child_info;
                while ((child_info = enumerator.next_file()) != null) {
                    // Skip symlinks to avoid double-counting
                    if (child_info.get_file_type() == FileType.SYMBOLIC_LINK) {
                        continue;
                    }
                    var child = file.get_child(child_info.get_name());
                    if (child_info.get_file_type() == FileType.DIRECTORY) {
                        size += get_path_size(child.get_path());
                    } else {
                        size += child_info.get_size();
                    }
                }
                return size;
            } else {
                return info.get_size();
            }
        }

        public static void ensure_directory(string path, int mode = 0755) throws Error {
            if (GLib.FileUtils.test(path, FileTest.IS_DIR)) {
                return;
            }

            if (DirUtils.create_with_parents(path, mode) != 0) {
                throw new FileError.FAILED("Failed to create directory at %s".printf(path));
            }
        }

        public static void write_text_file(string path, string content) throws Error {
            GLib.FileUtils.set_contents(path, content);
        }

        public static string read_text_file_or_empty(string path) {
            string data = "";
            size_t length = 0;

            try {
                GLib.FileUtils.get_contents(path, out data, out length);
            } catch (Error e) {
                data = "";
            }

            return data;
        }

        public static void ensure_line_in_file(string path, string line) throws Error {
            var existing = read_text_file_or_empty(path);

            foreach (var l in existing.split("\n")) {
                if (l.strip() == line) {
                    return;
                }
            }

            var builder = new StringBuilder();
            builder.append(existing);

            if (existing.length > 0 && !existing.has_suffix("\n")) {
                builder.append("\n");
            }

            builder.append(line);
            builder.append("\n");

            write_text_file(path, builder.str);
        }

        public static void remove_line_in_file(string path, string line) throws Error {
            string existing;
            size_t length;

            try {
                GLib.FileUtils.get_contents(path, out existing, out length);
            } catch (Error e) {
                return;
            }

            var lines = existing.split("\n");
            var builder = new StringBuilder();
            bool removed = false;

            for (int i = 0; i < lines.length; i++) {
                var current = lines[i];
                if (current.strip() == line) {
                    removed = true;
                    continue;
                }

                builder.append(current);
                if (i < lines.length - 1) {
                    builder.append("\n");
                }
            }

            if (!removed) {
                return;
            }

            var sanitized = builder.str;
            while (sanitized.has_suffix("\n\n")) {
                sanitized = sanitized.substring(0, sanitized.length - 1);
            }

            write_text_file(path, sanitized);
        }

        public static void delete_file_if_exists(string path) throws Error {
            var file = File.new_for_path(path);
            if (!file.query_exists()) {
                return;
            }

            file.delete();
        }

        /**
         * Detect image extension from file content (magic bytes).
         * Returns ".png", ".svg", or empty string if unknown.
         */
        public static string detect_image_extension(string path) {
            try {
                var file = File.new_for_path(path);
                if (!file.query_exists()) {
                    return "";
                }

                var stream = file.read();
                var buffer = new uint8[16];
                size_t bytes_read;
                stream.read_all(buffer, out bytes_read);
                stream.close();

                if (bytes_read < 4) {
                    return "";
                }

                // PNG magic bytes: 0x89 0x50 0x4E 0x47 (\x89PNG)
                if (buffer[0] == 0x89 && buffer[1] == 0x50 && buffer[2] == 0x4E && buffer[3] == 0x47) {
                    return ".png";
                }

                // SVG detection: look for XML declaration or <svg tag
                // Read more content for SVG detection
                string content;
                size_t length;
                GLib.FileUtils.get_contents(path, out content, out length);
                var trimmed = content.strip();
                if (trimmed.has_prefix("<?xml") || trimmed.has_prefix("<svg") || trimmed.has_prefix("<!DOCTYPE svg")) {
                    return ".svg";
                }

            } catch (Error e) {
                debug("Failed to detect image type for %s: %s", path, e.message);
            }

            return "";
        }

        public static void ensure_executable(string path) {
            if (Posix.chmod(path, 0755) != 0) {
                warning("Failed to chmod %s", path);
            }
        }

        public static string escape_exec_arg(string value) {
            return value.replace("\"", "\\\"");
        }

        public static string quote_exec_token(string token) {
            for (int i = 0; i < token.length; i++) {
                var ch = token[i];
                if (ch == ' ' || ch == '\t') {
                    return "\"%s\"".printf(escape_exec_arg(token));
                }
            }
            return token;
        }
    }
}
