using GLib;

namespace AppManager.Core {
    public class DesktopEntry : Object {
        private KeyFile key_file;
        private string? file_path;

        public string? name { get; set; }
        public string? exec { get; set; }
        public string? icon { get; set; }
        public string? keywords { get; set; }
        public string? categories { get; set; }
        public string? startup_wm_class { get; set; }
        public bool terminal { get; set; }
        public bool no_display { get; set; }
        public string? mime_type { get; set; }
        public bool dbus_activatable { get; set; }
        public string? appimage_homepage { get; set; }
        public string? appimage_update_url { get; set; }
        public string? appimage_version { get; set; }
        public string? actions { get; set; }

        public DesktopEntry(string? path = null) {
            key_file = new KeyFile();
            if (path != null) {
                try {
                    load(path);
                } catch (Error e) {
                    warning("Failed to load desktop file %s: %s", path, e.message);
                }
            }
        }

        public void load(string path) throws Error {
            file_path = path;
            key_file.load_from_file(path, KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS);
            
            // Standard keys
            name = get_string("Name");
            exec = get_string("Exec");
            icon = get_string("Icon");
            keywords = get_string("Keywords");
            categories = get_string("Categories");
            startup_wm_class = get_string("StartupWMClass");
            mime_type = get_string("MimeType");
            terminal = get_boolean("Terminal");
            no_display = get_boolean("NoDisplay");
            dbus_activatable = get_boolean("DBusActivatable");
            actions = get_string("Actions");

            // X-AppImage keys
            appimage_homepage = get_string("X-AppImage-Homepage");
            appimage_update_url = get_string("X-AppImage-UpdateURL");
            appimage_version = get_string("X-AppImage-Version") ?? find_key_in_any_group("X-AppImage-Version");
        }

        public void save(string? path = null) throws Error {
            var target_path = path ?? file_path;
            if (target_path == null) {
                throw new FileError.FAILED("No path specified for saving desktop file");
            }

            set_string("Name", name);
            set_string("Exec", exec);
            set_string("Icon", icon);
            set_string("Keywords", keywords);
            set_string("Categories", categories);
            set_string("StartupWMClass", startup_wm_class);
            set_string("MimeType", mime_type);
            set_boolean("Terminal", terminal);
            set_boolean("NoDisplay", no_display);
            set_string("Actions", actions);
            
            set_string("X-AppImage-Homepage", appimage_homepage);
            set_string("X-AppImage-UpdateURL", appimage_update_url);
            set_string("X-AppImage-Version", appimage_version);

            key_file.save_to_file(target_path);
        }

        public string to_data() {
            set_string("Name", name);
            set_string("Exec", exec);
            set_string("Icon", icon);
            set_string("Keywords", keywords);
            set_string("Categories", categories);
            set_string("StartupWMClass", startup_wm_class);
            set_string("MimeType", mime_type);
            set_boolean("Terminal", terminal);
            set_boolean("NoDisplay", no_display);
            set_string("Actions", actions);
            
            set_string("X-AppImage-Homepage", appimage_homepage);
            set_string("X-AppImage-UpdateURL", appimage_update_url);
            set_string("X-AppImage-Version", appimage_version);
            
            return key_file.to_data(null, null);
        }

        public void set_action_group(string action_name, string name, string exec, string icon) {
            var group = "Desktop Action %s".printf(action_name);
            key_file.set_string(group, "Name", name);
            key_file.set_string(group, "Exec", exec);
            key_file.set_string(group, "Icon", icon);
        }

        public void remove_key(string key, string group = "Desktop Entry") {
            try {
                if (key_file.has_key(group, key)) {
                    key_file.remove_key(group, key);
                }
            } catch (Error e) {}
        }

        public string? get_string(string key, string group = "Desktop Entry") {
            try {
                if (key_file.has_key(group, key)) {
                    var val = key_file.get_string(group, key);
                    return val.strip() != "" ? val.strip() : null;
                }
            } catch (Error e) {}
            return null;
        }

        public bool get_boolean(string key, string group = "Desktop Entry") {
            try {
                if (key_file.has_key(group, key)) {
                    return key_file.get_boolean(group, key);
                }
            } catch (Error e) {}
            return false;
        }

        public void set_string(string key, string? value, string group = "Desktop Entry") {
            if (value != null && value.strip() != "") {
                key_file.set_string(group, key, value.strip());
            } else {
                try {
                    if (key_file.has_key(group, key)) {
                        key_file.remove_key(group, key);
                    }
                } catch (Error e) {}
            }
        }

        public void set_boolean(string key, bool value, string group = "Desktop Entry") {
            if (value) {
                key_file.set_boolean(group, key, true);
            } else {
                // Usually false means remove the key or set to false. 
                // For NoDisplay/Terminal, default is false, so removing is cleaner.
                try {
                    if (key_file.has_key(group, key)) {
                        key_file.remove_key(group, key);
                    }
                } catch (Error e) {}
            }
        }
        
        private string? find_key_in_any_group(string key) {
            try {
                foreach (var group in key_file.get_groups()) {
                    if (key_file.has_key(group, key)) {
                        var value = key_file.get_string(group, key).strip();
                        if (value.length > 0) {
                            return value;
                        }
                    }
                }
            } catch (Error e) {
                // Ignore errors when searching
            }
            return null;
        }
        
        // Expose underlying KeyFile for advanced usage
        public KeyFile get_key_file() {
            return key_file;
        }

        // --- Static Utility Methods ---

        public static string? parse_bin_from_apprun(string apprun_path) {
            try {
                string contents;
                if (!GLib.FileUtils.get_contents(apprun_path, out contents)) {
                    return null;
                }
                
                // Search for BIN= line in AppRun
                foreach (var line in contents.split("\n")) {
                    var trimmed = line.strip();
                    if (trimmed.has_prefix("BIN=")) {
                        // Extract the value: BIN="$APPDIR/curseforge" -> curseforge
                        var value = trimmed.substring("BIN=".length).strip();
                        // Remove quotes
                        if (value.has_prefix("\"") && value.has_suffix("\"")) {
                            value = value.substring(1, value.length - 2);
                        } else if (value.has_prefix("'") && value.has_suffix("'")) {
                            value = value.substring(1, value.length - 2);
                        }
                        
                        // Extract basename from path like "$APPDIR/curseforge" or "${APPDIR}/curseforge"
                        if ("$APPDIR" in value || "${APPDIR}" in value) {
                            // Remove $APPDIR/ or ${APPDIR}/
                            value = value.replace("$APPDIR/", "").replace("${APPDIR}/", "");
                            value = value.replace("$APPDIR", "").replace("${APPDIR}", "");
                            // Clean up any leading slashes
                            if (value.has_prefix("/")) {
                                value = value.substring(1);
                            }
                        }
                        
                        return value.strip();
                    }
                }
            } catch (Error e) {
                warning("Failed to parse AppRun file: %s", e.message);
            }
            return null;
        }

        /**
         * Resolves the actual executable from a .desktop Exec value.
         */
        public static string? resolve_exec_from_desktop(string exec_value, string? app_run_path) {
            var base_exec = extract_base_exec_token(exec_value);
            var normalized_exec = base_exec != null ? strip_appdir_prefix(base_exec) : null;
            
            if (normalized_exec != null && normalized_exec.strip() != "" && !is_apprun_token(normalized_exec)) {
                return normalized_exec.strip();
            }
            
            // Try to resolve from AppRun BIN variable
            if (app_run_path != null && app_run_path.strip() != "") {
                var bin_name = parse_bin_from_apprun(app_run_path);
                if (bin_name != null && bin_name.strip() != "") {
                    return bin_name.strip();
                }
            }
            
            return null;
        }

        /**
         * Extracts command line arguments from an Exec value (everything after first token).
         */
        public static string? extract_exec_arguments(string exec_value) {
            var trimmed = exec_value.strip();
            int first_space = -1;
            bool in_quotes = false;
            
            for (int i = 0; i < trimmed.length; i++) {
                if (trimmed[i] == '"') {
                    in_quotes = !in_quotes;
                } else if (trimmed[i] == ' ' && !in_quotes) {
                    first_space = i;
                    break;
                }
            }
            
            if (first_space != -1) {
                return trimmed.substring(first_space + 1).strip();
            }
            return null;
        }

        public static string? extract_base_exec_token(string exec_value) {
            var trimmed = exec_value.strip();
            if (trimmed == "") {
                return null;
            }

            var builder = new StringBuilder();
            bool in_quotes = false;
            for (int i = 0; i < trimmed.length; i++) {
                var ch = trimmed[i];
                if (ch == '"') {
                    in_quotes = !in_quotes;
                    continue;
                }
                if (ch == ' ' && !in_quotes) {
                    break;
                }
                builder.append_c(ch);
            }

            var token = builder.str.strip();
            return token == "" ? null : token;
        }

        public static string strip_appdir_prefix(string token) {
            var value = token.strip();
            value = value.replace("$APPDIR/", "").replace("${APPDIR}/", "");
            value = value.replace("$APPDIR", "").replace("${APPDIR}", "");
            while (value.has_prefix("/")) {
                value = value.substring(1);
            }
            return value;
        }

        public static bool is_apprun_token(string token) {
            var base_name = Path.get_basename(token.strip());
            var lower = base_name.down();
            return lower == "apprun" || lower == "apprun.sh";
        }

        public static string relativize_exec_to_installed(string exec_token, string installed_path) {
            if (exec_token.strip() == "" || installed_path.strip() == "") {
                return exec_token;
            }
            if (!Path.is_absolute(exec_token)) {
                return exec_token;
            }
            var prefix = installed_path;
            if (!prefix.has_suffix("/")) {
                prefix = prefix + "/";
            }
            if (exec_token.has_prefix(prefix)) {
                return exec_token.substring(prefix.length);
            }
            return exec_token;
        }
        
        public static string resolve_exec_path(string exec_value, string? installed_path) {
            var trimmed = exec_value.strip();
            if (trimmed == "") {
                return installed_path ?? "";
            }

            // Extract first token respecting quotes
            bool in_quotes = false;
            var builder = new StringBuilder();
            for (int i = 0; i < trimmed.length; i++) {
                var ch = trimmed[i];
                if (ch == '"') {
                    in_quotes = !in_quotes;
                    continue;
                }
                if (ch == ' ' && !in_quotes) {
                    break;
                }
                builder.append_c(ch);
            }

            var base_exec = builder.str.strip();
            if (base_exec == "") {
                return installed_path ?? "";
            }

            // If already absolute, return it
            if (Path.is_absolute(base_exec)) {
                return base_exec;
            }

            // If relative, resolve against installed_path when it is a directory
            if (installed_path != null && File.new_for_path(installed_path).query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                return Path.build_filename(installed_path, base_exec);
            }

            // Fall back to the stored installed path or the token itself
            return installed_path ?? base_exec;
        }
    }
}
