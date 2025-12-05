namespace AppManager.Core {
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
        public string? version { get; set; }
        public string? etag { get; set; }

        public InstallationRecord(string id, string name, InstallMode mode) {
            Object(id: id, name: name, mode: mode, installed_at: (int64)GLib.get_real_time());
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
            builder.set_member_name("version");
            builder.add_string_value(version ?? "");
            builder.set_member_name("etag");
            builder.add_string_value(etag ?? "");
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
            var version = obj.get_string_member_with_default("version", "");
            record.version = version == "" ? null : version;
            var etag = obj.get_string_member_with_default("etag", "");
            record.etag = etag == "" ? null : etag;
            return record;
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
