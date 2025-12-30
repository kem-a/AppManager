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
        public int64 installed_at { get; set; }
        public int64 updated_at { get; set; default = 0; }
        public string? version { get; set; }
        public string? etag { get; set; }
        public string? last_release_tag { get; set; }  // Stores release tag_name for apps without version
        
        // Original values captured from AppImage's .desktop during install/update
        public string? original_commandline_args { get; set; }
        public string? original_keywords { get; set; }
        public string? original_icon_name { get; set; }
        public string? original_startup_wm_class { get; set; }
        public string? original_update_link { get; set; }
        public string? original_web_page { get; set; }
        public string? entry_exec { get; set; }
        public bool is_terminal { get; set; default = false; }
        
        // Custom values set by user (null means use original, CLEARED_VALUE means user cleared it, other means user set custom value)
        public string? custom_commandline_args { get; set; }
        public string? custom_keywords { get; set; }
        public string? custom_icon_name { get; set; }
        public string? custom_startup_wm_class { get; set; }
        public string? custom_update_link { get; set; }
        public string? custom_web_page { get; set; }

        public InstallationRecord(string id, string name, InstallMode mode) {
            Object(id: id, name: name, mode: mode, installed_at: (int64)GLib.get_real_time());
        }

        /**
         * Gets the effective value for a property, considering original and custom values.
         * Returns custom value if set (CLEARED means null), otherwise returns original.
         */
        public string? get_effective_commandline_args() {
            if (custom_commandline_args == CLEARED_VALUE) return null;
            return custom_commandline_args ?? original_commandline_args;
        }

        public string? get_effective_keywords() {
            if (custom_keywords == CLEARED_VALUE) return null;
            return custom_keywords ?? original_keywords;
        }

        public string? get_effective_icon_name() {
            if (custom_icon_name == CLEARED_VALUE) return null;
            return custom_icon_name ?? original_icon_name;
        }

        public string? get_effective_startup_wm_class() {
            if (custom_startup_wm_class == CLEARED_VALUE) return null;
            return custom_startup_wm_class ?? original_startup_wm_class;
        }

        public string? get_effective_update_link() {
            if (custom_update_link == CLEARED_VALUE) return null;
            return custom_update_link ?? original_update_link;
        }

        public string? get_effective_web_page() {
            if (custom_web_page == CLEARED_VALUE) return null;
            return custom_web_page ?? original_web_page;
        }

        /**
         * Returns true if this record has any custom values worth preserving.
         */
        public bool has_custom_values() {
            return custom_commandline_args != null ||
                   custom_keywords != null ||
                   custom_icon_name != null ||
                   custom_startup_wm_class != null ||
                   custom_update_link != null ||
                   custom_web_page != null;
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
            builder.set_member_name("version");
            builder.add_string_value(version ?? "");
            builder.set_member_name("etag");
            builder.add_string_value(etag ?? "");
            builder.set_member_name("last_release_tag");
            builder.add_string_value(last_release_tag ?? "");
            builder.set_member_name("entry_exec");
            builder.add_string_value(entry_exec ?? "");
            builder.set_member_name("is_terminal");
            builder.add_boolean_value(is_terminal);
            
            // Original values from AppImage's .desktop
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
            
            // Custom values set by user - only write if set (not null)
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
            
            builder.end_object();
            return builder.get_root();
        }

        /**
         * Serializes only the name and custom values for uninstalled app history.
         * Used when app is uninstalled to preserve user customizations.
         */
        public Json.Node to_history_json() {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("name");
            builder.add_string_value(name);
            
            // Only write custom values if set
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
            var version = obj.get_string_member_with_default("version", "");
            record.version = version == "" ? null : version;
            var etag = obj.get_string_member_with_default("etag", "");
            record.etag = etag == "" ? null : etag;
            var last_release_tag = obj.get_string_member_with_default("last_release_tag", "");
            record.last_release_tag = last_release_tag == "" ? null : last_release_tag;
            var entry_exec = obj.get_string_member_with_default("entry_exec", "");
            record.entry_exec = entry_exec == "" ? null : entry_exec;
            if (obj.has_member("is_terminal")) {
                record.is_terminal = obj.get_boolean_member("is_terminal");
            }
            
            // Original values from AppImage's .desktop
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
            
            return record;
        }

        /**
         * Loads custom values from a history JSON object (uninstalled app's saved custom values).
         * Only sets values that are currently null (doesn't overwrite existing custom values).
         */
        public void apply_history(Json.Object obj) {
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
