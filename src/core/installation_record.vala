namespace AppManager.Core {
    // Special value to indicate user explicitly cleared a property
    public const string CLEARED_VALUE = "__CLEARED__";

    public enum InstallMode {
        PORTABLE,
        EXTRACTED
    }

    public class InstallationRecord : Object {
        public string id { get; construct; }
        public string name { get; set; }
        public InstallMode mode { get; set; }
        public string source_checksum { get; set; }
        public string source_path { get; set; }
        public string installed_path { get; set; }
        public string desktop_file { get; set; }
        public string? icon_path { get; set; }
        public string? bin_symlink { get; set; }
        // Additional desktop entries installed from usr/share/applications/ inside the AppImage
        // (issue #106 — multi-component apps like WPS Office). Custom env vars and command-line
        // args propagate to sub-entries too; these arrays track files for cleanup on uninstall/upgrade.
        public string[]? extra_desktop_files { get; set; }   // ~/.local/share/applications/<name>.desktop
        public string[]? extra_icon_paths    { get; set; }   // ~/.local/share/icons/<name>.<ext>
        public string[]? extra_bin_symlinks  { get; set; }   // ~/.local/bin/<sub-binary>
        public int64 installed_at { get; set; }
        public int64 updated_at { get; set; default = 0; }
        // Copy index for side-by-side installs of the same app. 0 means the primary
        // install (no suffix); >=2 means a secondary copy shown as "Name N".
        public int copy_index { get; set; default = 0; }
        public string? version { get; set; }
        public string? description { get; set; }  // App description from metainfo <summary> or desktop Comment
        public string? last_modified { get; set; }  // HTTP Last-Modified header for change detection
        public int64 content_length { get; set; default = 0; }  // HTTP Content-Length for change detection
        public string? last_release_tag { get; set; }  // Stores release tag_name for apps without version
        
        // Zsync update info from .upd_info section (e.g., gh-releases-zsync|owner|repo|latest|*.zsync)
        // If set, app uses zsync delta updates instead of full downloads
        public string? zsync_update_info { get; set; }
        
        // SHA-1 checksum from zsync file header - used for reliable update detection
        // when app filename has no version (e.g., zen-x86_64.AppImage)
        public string? zsync_sha1 { get; set; }
        
        // Original values captured from AppImage's .desktop during install/update
        // original_name is the name AppManager assigns at install (base name, plus the
        // " N" suffix for secondary copies); it is the restore target for custom_name.
        public string? original_name { get; set; }
        public string? original_commandline_args { get; set; }
        public string? original_keywords { get; set; }
        public string? original_icon_name { get; set; }
        public string? original_startup_wm_class { get; set; }
        public string? original_update_link { get; set; }
        public string? original_web_page { get; set; }
        // Per-action original Exec args from the bundled .desktop, captured at install/update.
        // Each entry is "action_name=args" (mirroring custom_env_vars storage shape).
        public string[]? original_action_args { get; set; }
        // Per-sub-entry pristine Exec args from the bundled .desktop, captured at install/update.
        // Each entry is "<installed_desktop_basename>=<args>"; used to re-apply custom env vars and
        // command-line args to sub-entries on live edits without compounding previously-added args.
        public string[]? original_sub_args { get; set; }
        public string? entry_exec { get; set; }
        public bool is_terminal { get; set; default = false; }

        // Custom values set by user (null means use original, CLEARED_VALUE means user cleared it, other means user set custom value)
        public string? custom_name { get; set; }
        public string? custom_commandline_args { get; set; }
        public string? custom_keywords { get; set; }
        public string? custom_icon_name { get; set; }
        public string? custom_startup_wm_class { get; set; }
        public string? custom_update_link { get; set; }
        public string? custom_web_page { get; set; }
        // Boolean toggle overrides. Only set when the user deviates from the default,
        // so they survive updates. Stored as "true"/"false"; null means "use default".
        // - custom_no_display: default comes from the bundled .desktop file at install/update.
        // - custom_add_to_path: default is true (every app gets a bin symlink).
        public string? custom_no_display { get; set; }
        public string? custom_add_to_path { get; set; }
        
        // Environment variables as array of "NAME=VALUE" strings (max 5)
        public string[]? custom_env_vars { get; set; }
        
        // Whether to include pre-release versions when checking for updates (GitHub only)
        public bool prerelease_enabled { get; set; default = false; }
        public bool updates_enabled { get; set; default = true; }

        public InstallationRecord(string id, string name, InstallMode mode) {
            Object(id: id, name: name, mode: mode, installed_at: (int64)GLib.get_real_time());
        }

        /**
         * Helper: gets effective value considering CLEARED_VALUE sentinel.
         */
        private static string? get_effective(string? custom, string? original) {
            if (custom == CLEARED_VALUE) return null;
            return custom ?? original;
        }

        public string? get_effective_name() {
            // Name must never resolve to empty: fall back to original_name, then the
            // current record name so older records (no original_name) still work.
            if (custom_name != null && custom_name != CLEARED_VALUE && custom_name.strip() != "") {
                return custom_name;
            }
            return (original_name != null && original_name.strip() != "") ? original_name : name;
        }

        public string? get_effective_commandline_args() {
            return get_effective(custom_commandline_args, original_commandline_args);
        }

        public string? get_effective_keywords() {
            return get_effective(custom_keywords, original_keywords);
        }

        public string? get_effective_icon_name() {
            return get_effective(custom_icon_name, original_icon_name);
        }

        public string? get_effective_startup_wm_class() {
            return get_effective(custom_startup_wm_class, original_startup_wm_class);
        }

        public string? get_effective_update_link() {
            return get_effective(custom_update_link, original_update_link);
        }

        public string? get_effective_web_page() {
            return get_effective(custom_web_page, original_web_page);
        }

        /**
         * Returns true if this record has any custom values worth preserving.
         */
        public bool has_custom_values() {
            return !updates_enabled ||
                   prerelease_enabled ||
                   custom_name != null ||
                   custom_commandline_args != null ||
                   custom_keywords != null ||
                   custom_icon_name != null ||
                   custom_startup_wm_class != null ||
                   custom_update_link != null ||
                   custom_web_page != null ||
                   custom_no_display != null ||
                   custom_add_to_path != null ||
                   (custom_env_vars != null && custom_env_vars.length > 0);
        }

        public Json.Node to_json() {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_string_value(id);
            builder.set_member_name("name");
            builder.add_string_value(name);
            builder.set_member_name("mode");
            builder.add_string_value(mode_to_string(mode));
            builder.set_member_name("source_checksum");
            builder.add_string_value(source_checksum);
            builder.set_member_name("source_path");
            builder.add_string_value(source_path);
            builder.set_member_name("installed_path");
            builder.add_string_value(installed_path);
            builder.set_member_name("desktop_file");
            builder.add_string_value(desktop_file);
            builder.set_member_name("icon_path");
            builder.add_string_value(icon_path ?? "");
            builder.set_member_name("bin_symlink");
            builder.add_string_value(bin_symlink ?? "");
            builder.set_member_name("installed_at");
            builder.add_int_value(installed_at);
            builder.set_member_name("updated_at");
            builder.add_int_value(updated_at);
            builder.set_member_name("copy_index");
            builder.add_int_value(copy_index);
            builder.set_member_name("version");
            builder.add_string_value(version ?? "");
            builder.set_member_name("description");
            builder.add_string_value(description ?? "");
            builder.set_member_name("last_modified");
            builder.add_string_value(last_modified ?? "");
            builder.set_member_name("content_length");
            builder.add_int_value(content_length);
            builder.set_member_name("last_release_tag");
            builder.add_string_value(last_release_tag ?? "");
            builder.set_member_name("entry_exec");
            builder.add_string_value(entry_exec ?? "");
            builder.set_member_name("is_terminal");
            builder.add_boolean_value(is_terminal);
            
            // Zsync update info (if app supports zsync delta updates)
            if (zsync_update_info != null && zsync_update_info.strip() != "") {
                builder.set_member_name("zsync_update_info");
                builder.add_string_value(zsync_update_info);
            }
            
            // Zsync SHA-1 checksum for reliable update detection
            if (zsync_sha1 != null && zsync_sha1.strip() != "") {
                builder.set_member_name("zsync_sha1");
                builder.add_string_value(zsync_sha1);
            }
            
            // Original values from AppImage's .desktop
            builder.set_member_name("original_name");
            builder.add_string_value(original_name ?? "");
            builder.set_member_name("original_commandline_args");
            builder.add_string_value(original_commandline_args ?? "");
            builder.set_member_name("original_keywords");
            builder.add_string_value(original_keywords ?? "");
            builder.set_member_name("original_icon_name");
            builder.add_string_value(original_icon_name ?? "");
            builder.set_member_name("original_startup_wm_class");
            builder.add_string_value(original_startup_wm_class ?? "");
            builder.set_member_name("original_update_link");
            builder.add_string_value(original_update_link ?? "");
            builder.set_member_name("original_web_page");
            builder.add_string_value(original_web_page ?? "");

            if (original_action_args != null && original_action_args.length > 0) {
                builder.set_member_name("original_action_args");
                builder.begin_array();
                foreach (var pair in original_action_args) {
                    builder.add_string_value(pair);
                }
                builder.end_array();
            }

            if (original_sub_args != null && original_sub_args.length > 0) {
                builder.set_member_name("original_sub_args");
                builder.begin_array();
                foreach (var pair in original_sub_args) {
                    builder.add_string_value(pair);
                }
                builder.end_array();
            }

            if (extra_desktop_files != null && extra_desktop_files.length > 0) {
                builder.set_member_name("extra_desktop_files");
                builder.begin_array();
                foreach (var p in extra_desktop_files) {
                    builder.add_string_value(p);
                }
                builder.end_array();
            }
            if (extra_icon_paths != null && extra_icon_paths.length > 0) {
                builder.set_member_name("extra_icon_paths");
                builder.begin_array();
                foreach (var p in extra_icon_paths) {
                    builder.add_string_value(p);
                }
                builder.end_array();
            }
            if (extra_bin_symlinks != null && extra_bin_symlinks.length > 0) {
                builder.set_member_name("extra_bin_symlinks");
                builder.begin_array();
                foreach (var p in extra_bin_symlinks) {
                    builder.add_string_value(p);
                }
                builder.end_array();
            }

            // Pre-release channel preference
            builder.set_member_name("prerelease_enabled");
            builder.add_boolean_value(prerelease_enabled);
            builder.set_member_name("updates_enabled");
            builder.add_boolean_value(updates_enabled);
            
            builder.end_object();
            return builder.get_root();
        }

        /**
         * Helper: writes all custom values to JSON builder.
         */
        private void serialize_custom_values(Json.Builder builder) {
            builder.set_member_name("updates_enabled");
            builder.add_boolean_value(updates_enabled);
            
            builder.set_member_name("prerelease_enabled");
            builder.add_boolean_value(prerelease_enabled);

            if (custom_name != null) {
                builder.set_member_name("custom_name");
                builder.add_string_value(custom_name);
            }
            if (custom_commandline_args != null) {
                builder.set_member_name("custom_commandline_args");
                builder.add_string_value(custom_commandline_args);
            }
            if (custom_keywords != null) {
                builder.set_member_name("custom_keywords");
                builder.add_string_value(custom_keywords);
            }
            if (custom_icon_name != null) {
                builder.set_member_name("custom_icon_name");
                builder.add_string_value(custom_icon_name);
            }
            if (custom_startup_wm_class != null) {
                builder.set_member_name("custom_startup_wm_class");
                builder.add_string_value(custom_startup_wm_class);
            }
            if (custom_update_link != null) {
                builder.set_member_name("custom_update_link");
                builder.add_string_value(custom_update_link);
            }
            if (custom_web_page != null) {
                builder.set_member_name("custom_web_page");
                builder.add_string_value(custom_web_page);
            }
            if (custom_no_display != null) {
                builder.set_member_name("custom_no_display");
                builder.add_string_value(custom_no_display);
            }
            if (custom_add_to_path != null) {
                builder.set_member_name("custom_add_to_path");
                builder.add_string_value(custom_add_to_path);
            }
            if (custom_env_vars != null && custom_env_vars.length > 0) {
                builder.set_member_name("custom_env_vars");
                builder.begin_array();
                foreach (var env_var in custom_env_vars) {
                    builder.add_string_value(env_var);
                }
                builder.end_array();
            }
        }

        /**
         * Serializes name and all custom values to a JSON node.
         * Used by CustomValuesStore to persist user customizations separately.
         */
        public Json.Node to_custom_values_json() {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("name");
            builder.add_string_value(name);
            serialize_custom_values(builder);
            builder.end_object();
            return builder.get_root();
        }

        public static InstallationRecord from_json(Json.Object obj) {
            var id = obj.get_string_member("id");
            var name = obj.get_string_member("name");
            var mode = parse_mode(obj.get_string_member("mode"));
            var record = new InstallationRecord(id, name, mode);
            record.source_checksum = obj.get_string_member("source_checksum");
            record.source_path = obj.get_string_member("source_path");
            record.installed_path = obj.get_string_member("installed_path");
            record.desktop_file = obj.get_string_member("desktop_file");
            var icon = obj.get_string_member_with_default("icon_path", "");
            record.icon_path = icon == "" ? null : icon;
            var bin = obj.get_string_member_with_default("bin_symlink", "");
            record.bin_symlink = bin == "" ? null : bin;
            record.installed_at = (int64)obj.get_int_member("installed_at");
            record.updated_at = (int64)obj.get_int_member_with_default("updated_at", 0);
            record.copy_index = (int)obj.get_int_member_with_default("copy_index", 0);
            var version = obj.get_string_member_with_default("version", "");
            record.version = version == "" ? null : version;
            var description = obj.get_string_member_with_default("description", "");
            record.description = description == "" ? null : description;
            var last_modified = obj.get_string_member_with_default("last_modified", "");
            record.last_modified = last_modified == "" ? null : last_modified;
            record.content_length = (int64)obj.get_int_member_with_default("content_length", 0);
            var last_release_tag = obj.get_string_member_with_default("last_release_tag", "");
            record.last_release_tag = last_release_tag == "" ? null : last_release_tag;
            var entry_exec = obj.get_string_member_with_default("entry_exec", "");
            record.entry_exec = entry_exec == "" ? null : entry_exec;
            if (obj.has_member("is_terminal")) {
                record.is_terminal = obj.get_boolean_member("is_terminal");
            }
            if (obj.has_member("prerelease_enabled")) {
                record.prerelease_enabled = obj.get_boolean_member("prerelease_enabled");
            }
            if (obj.has_member("updates_enabled")) {
                record.updates_enabled = obj.get_boolean_member("updates_enabled");
            }
            
            // Zsync update info (if app supports zsync delta updates)
            if (obj.has_member("zsync_update_info")) {
                var zsync_info = obj.get_string_member("zsync_update_info");
                record.zsync_update_info = (zsync_info != null && zsync_info.strip() != "") ? zsync_info : null;
            }
            
            // Zsync SHA-1 checksum
            if (obj.has_member("zsync_sha1")) {
                var sha1 = obj.get_string_member("zsync_sha1");
                record.zsync_sha1 = (sha1 != null && sha1.strip() != "") ? sha1 : null;
            }
            
            // Original values from AppImage's .desktop
            var original_name = obj.get_string_member_with_default("original_name", "");
            // Older records have no original_name; fall back to the stored name so the
            // editable App Name field always has a sensible restore target.
            record.original_name = original_name == "" ? name : original_name;
            var original_commandline_args = obj.get_string_member_with_default("original_commandline_args", "");
            record.original_commandline_args = original_commandline_args == "" ? null : original_commandline_args;
            var original_keywords = obj.get_string_member_with_default("original_keywords", "");
            record.original_keywords = original_keywords == "" ? null : original_keywords;
            var original_icon_name = obj.get_string_member_with_default("original_icon_name", "");
            record.original_icon_name = original_icon_name == "" ? null : original_icon_name;
            var original_startup_wm_class = obj.get_string_member_with_default("original_startup_wm_class", "");
            record.original_startup_wm_class = original_startup_wm_class == "" ? null : original_startup_wm_class;
            var original_update_link = obj.get_string_member_with_default("original_update_link", "");
            record.original_update_link = original_update_link == "" ? null : original_update_link;
            var original_web_page = obj.get_string_member_with_default("original_web_page", "");
            record.original_web_page = original_web_page == "" ? null : original_web_page;

            if (obj.has_member("original_action_args")) {
                var arr = obj.get_array_member("original_action_args");
                var list = new string[arr.get_length()];
                for (uint i = 0; i < arr.get_length(); i++) {
                    list[i] = arr.get_string_element(i);
                }
                record.original_action_args = list;
            }

            if (obj.has_member("original_sub_args")) {
                var arr = obj.get_array_member("original_sub_args");
                var list = new string[arr.get_length()];
                for (uint i = 0; i < arr.get_length(); i++) {
                    list[i] = arr.get_string_element(i);
                }
                record.original_sub_args = list;
            }

            if (obj.has_member("extra_desktop_files")) {
                var arr = obj.get_array_member("extra_desktop_files");
                var list = new string[arr.get_length()];
                for (uint i = 0; i < arr.get_length(); i++) {
                    list[i] = arr.get_string_element(i);
                }
                record.extra_desktop_files = list;
            }
            if (obj.has_member("extra_icon_paths")) {
                var arr = obj.get_array_member("extra_icon_paths");
                var list = new string[arr.get_length()];
                for (uint i = 0; i < arr.get_length(); i++) {
                    list[i] = arr.get_string_element(i);
                }
                record.extra_icon_paths = list;
            }
            if (obj.has_member("extra_bin_symlinks")) {
                var arr = obj.get_array_member("extra_bin_symlinks");
                var list = new string[arr.get_length()];
                for (uint i = 0; i < arr.get_length(); i++) {
                    list[i] = arr.get_string_element(i);
                }
                record.extra_bin_symlinks = list;
            }

            // Legacy support: migrate old update_link/web_page to original_* fields
            if (record.original_update_link == null) {
                var legacy_update_link = obj.get_string_member_with_default("update_link", "");
                record.original_update_link = legacy_update_link == "" ? null : legacy_update_link;
            }
            if (record.original_web_page == null) {
                var legacy_web_page = obj.get_string_member_with_default("web_page", "");
                record.original_web_page = legacy_web_page == "" ? null : legacy_web_page;
            }
            
            // Custom values set by user - only present if explicitly set
            if (obj.has_member("custom_name")) {
                record.custom_name = obj.get_string_member("custom_name");
            }
            if (obj.has_member("custom_commandline_args")) {
                record.custom_commandline_args = obj.get_string_member("custom_commandline_args");
            }
            if (obj.has_member("custom_keywords")) {
                record.custom_keywords = obj.get_string_member("custom_keywords");
            }
            if (obj.has_member("custom_icon_name")) {
                record.custom_icon_name = obj.get_string_member("custom_icon_name");
            }
            if (obj.has_member("custom_startup_wm_class")) {
                record.custom_startup_wm_class = obj.get_string_member("custom_startup_wm_class");
            }
            if (obj.has_member("custom_update_link")) {
                record.custom_update_link = obj.get_string_member("custom_update_link");
            }
            if (obj.has_member("custom_web_page")) {
                record.custom_web_page = obj.get_string_member("custom_web_page");
            }
            if (obj.has_member("custom_no_display")) {
                record.custom_no_display = obj.get_string_member("custom_no_display");
            }
            if (obj.has_member("custom_add_to_path")) {
                record.custom_add_to_path = obj.get_string_member("custom_add_to_path");
            }
            if (obj.has_member("custom_env_vars")) {
                var env_array = obj.get_array_member("custom_env_vars");
                var env_list = new string[env_array.get_length()];
                for (uint i = 0; i < env_array.get_length(); i++) {
                    env_list[i] = env_array.get_string_element(i);
                }
                record.custom_env_vars = env_list;
            }
            
            return record;
        }

        /**
         * Loads custom values from a history JSON object (uninstalled app's saved custom values).
         * Only sets values that are currently null (doesn't overwrite existing custom values).
         */
        public void apply_history(Json.Object obj) {
            if (obj.has_member("updates_enabled")) {
                updates_enabled = obj.get_boolean_member("updates_enabled");
            }
            if (obj.has_member("prerelease_enabled")) {
                prerelease_enabled = obj.get_boolean_member("prerelease_enabled");
            }
            if (custom_name == null && obj.has_member("custom_name")) {
                custom_name = obj.get_string_member("custom_name");
            }
            if (custom_commandline_args == null && obj.has_member("custom_commandline_args")) {
                custom_commandline_args = obj.get_string_member("custom_commandline_args");
            }
            if (custom_keywords == null && obj.has_member("custom_keywords")) {
                custom_keywords = obj.get_string_member("custom_keywords");
            }
            if (custom_icon_name == null && obj.has_member("custom_icon_name")) {
                custom_icon_name = obj.get_string_member("custom_icon_name");
            }
            if (custom_startup_wm_class == null && obj.has_member("custom_startup_wm_class")) {
                custom_startup_wm_class = obj.get_string_member("custom_startup_wm_class");
            }
            if (custom_update_link == null && obj.has_member("custom_update_link")) {
                custom_update_link = obj.get_string_member("custom_update_link");
            }
            if (custom_web_page == null && obj.has_member("custom_web_page")) {
                custom_web_page = obj.get_string_member("custom_web_page");
            }
            if (custom_no_display == null && obj.has_member("custom_no_display")) {
                custom_no_display = obj.get_string_member("custom_no_display");
            }
            if (custom_add_to_path == null && obj.has_member("custom_add_to_path")) {
                custom_add_to_path = obj.get_string_member("custom_add_to_path");
            }
            if (custom_env_vars == null && obj.has_member("custom_env_vars")) {
                var env_array = obj.get_array_member("custom_env_vars");
                var env_list = new string[env_array.get_length()];
                for (uint i = 0; i < env_array.get_length(); i++) {
                    env_list[i] = env_array.get_string_element(i);
                }
                custom_env_vars = env_list;
            }
        }

        public static InstallMode parse_mode(string value) {
            if (value == null || value.strip() == "") {
                return InstallMode.PORTABLE;
            }
            var normalized = value.strip().down();
            switch (normalized) {
                case "portable":
                    return InstallMode.PORTABLE;
                case "extracted":
                    return InstallMode.EXTRACTED;
            }
            if (normalized.contains("extracted")) {
                return InstallMode.EXTRACTED;
            }
            return InstallMode.PORTABLE;
        }

        public string mode_label() {
            switch (mode) {
                case InstallMode.PORTABLE:
                    return "Portable";
                case InstallMode.EXTRACTED:
                    return "Extracted";
                default:
                    return "Portable";
            }
        }

        private static string mode_to_string(InstallMode mode) {
            return mode == InstallMode.EXTRACTED ? "extracted" : "portable";
        }
    }
}
