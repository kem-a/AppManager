using AppManager.Utils;
using Gee;

namespace AppManager.Core {
    public errordomain InstallerError {
        ALREADY_INSTALLED,
        DESKTOP_MISSING,
        EXTRACTION_FAILED,
        SEVEN_ZIP_MISSING,
        UNINSTALL_FAILED,
        UNKNOWN
    }

    public class Installer : Object {
        private InstallationRegistry registry;
        private Settings settings;
        private string[] uninstall_prefix;

        public signal void progress(string message);

        public Installer(InstallationRegistry registry, Settings settings) {
            this.registry = registry;
            this.settings = settings;
            this.uninstall_prefix = resolve_uninstall_prefix();
            migrate_uninstall_execs();
        }

        public InstallationRecord install(string file_path, InstallMode override_mode = InstallMode.PORTABLE) throws Error {
            return install_sync(file_path, override_mode, null);
        }

        public InstallationRecord upgrade(string file_path, InstallationRecord old_record) throws Error {
            return reinstall(file_path, old_record, old_record.mode);
        }

        public InstallationRecord reinstall(string file_path, InstallationRecord old_record, InstallMode mode) throws Error {
            var preserved_props = preserve_desktop_properties(old_record.desktop_file);
            uninstall(old_record);
            return install_sync(file_path, mode, preserved_props);
        }

        private InstallationRecord install_sync(string file_path, InstallMode override_mode, HashTable<string, string>? preserved_props) throws Error {
            var file = File.new_for_path(file_path);
            var metadata = new AppImageMetadata(file);
            if (preserved_props == null && registry.is_installed_checksum(metadata.checksum)) {
                throw new InstallerError.ALREADY_INSTALLED("AppImage already installed");
            }

            InstallMode mode = override_mode;

            var record = new InstallationRecord(metadata.checksum, metadata.display_name, mode);
            record.source_path = metadata.path;
            record.source_checksum = metadata.checksum;

            try {
                if (mode == InstallMode.PORTABLE) {
                    install_portable(metadata, record, preserved_props);
                } else {
                    install_extracted(metadata, record, preserved_props);
                }

                // Only delete source after successful installation
                if (File.new_for_path(file_path).query_exists()) {
                    File.new_for_path(file_path).delete();
                }

                registry.register(record);
                return record;
            } catch (Error e) {
                // Cleanup on failure
                cleanup_failed_installation(record);
                throw e;
            }
        }

        private void install_portable(AppImageMetadata metadata, InstallationRecord record, HashTable<string, string>? preserved_props) throws Error {
            progress("Preparing Applications folder…");
            record.installed_path = metadata.path;
            finalize_desktop_and_icon(record, metadata, metadata.path, metadata.path, preserved_props);
        }

        private string? parse_bin_from_apprun(string apprun_path) {
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

        private void install_extracted(AppImageMetadata metadata, InstallationRecord record, HashTable<string, string>? preserved_props) throws Error {
            progress("Extracting AppImage…");
            var base_name = metadata.sanitized_basename();
            DirUtils.create_with_parents(AppPaths.extracted_root, 0755);
            var dest_dir = Utils.FileUtils.unique_path(Path.build_filename(AppPaths.extracted_root, base_name));
            string staging_dir = "";
            try {
                var staging_template = Path.build_filename(AppPaths.extracted_root, "%s-extract-XXXXXX".printf(base_name));
                staging_dir = DirUtils.mkdtemp(staging_template);
                run_appimage_extract(metadata.path, staging_dir);
                var extracted_root = Path.build_filename(staging_dir, "squashfs-root");
                var extracted_file = File.new_for_path(extracted_root);
                if (!extracted_file.query_exists() || extracted_file.query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY) {
                    throw new InstallerError.EXTRACTION_FAILED("AppImage extraction did not produce squashfs-root");
                }
                extracted_file.move(File.new_for_path(dest_dir), FileCopyFlags.NONE, null, null);
            } catch (Error e) {
                Utils.FileUtils.remove_dir_recursive(dest_dir);
                if (staging_dir != "") {
                    Utils.FileUtils.remove_dir_recursive(staging_dir);
                }
                throw e;
            }
            if (staging_dir != "") {
                Utils.FileUtils.remove_dir_recursive(staging_dir);
            }
            string app_run;
            try {
                app_run = AppImageAssets.ensure_apprun_present(dest_dir);
            } catch (Error e) {
                Utils.FileUtils.remove_dir_recursive(dest_dir);
                throw e;
            }
            ensure_executable(app_run);
            
            // Check if desktop file Exec points to AppRun, and if so, resolve the actual binary
            string exec_target = app_run;
            try {
                var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-desktop-check-");
                try {
                    var desktop_path = AppImageAssets.extract_desktop_entry(metadata.path, temp_dir);
                    var key_file = new KeyFile();
                    key_file.load_from_file(desktop_path, KeyFileFlags.NONE);
                    if (key_file.has_key("Desktop Entry", "Exec")) {
                        var exec_value = key_file.get_string("Desktop Entry", "Exec");
                        // Check if Exec contains AppRun (without path or with relative path)
                        if ("AppRun" in exec_value) {
                            // Try to parse BIN from AppRun
                            var bin_name = parse_bin_from_apprun(app_run);
                            if (bin_name != null && bin_name != "") {
                                var bin_path = Path.build_filename(dest_dir, bin_name);
                                if (File.new_for_path(bin_path).query_exists()) {
                                    ensure_executable(bin_path);
                                    exec_target = bin_path;
                                    debug("Resolved exec from AppRun BIN=%s to %s", bin_name, exec_target);
                                }
                            }
                        }
                    }
                } finally {
                    Utils.FileUtils.remove_dir_recursive(temp_dir);
                }
            } catch (Error e) {
                warning("Failed to check desktop Exec for AppRun resolution: %s", e.message);
            }
            
            record.installed_path = dest_dir;
            finalize_desktop_and_icon(record, metadata, exec_target, metadata.path, preserved_props);
        }

        private void finalize_desktop_and_icon(InstallationRecord record, AppImageMetadata metadata, string exec_target, string appimage_for_assets, HashTable<string, string>? preserved_props) throws Error {
            string exec_path = exec_target.dup();
            string assets_path = appimage_for_assets.dup();
            progress("Extracting desktop entry…");
            var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-");
            try {
                var desktop_path = AppImageAssets.extract_desktop_entry(assets_path, temp_dir);
                var icon_path = AppImageAssets.extract_icon(assets_path, temp_dir);
                string desktop_name = metadata.display_name;
                string? desktop_version = null;
                bool is_terminal_app = false;
                try {
                    var desktop_info = AppImageAssets.parse_desktop_file(desktop_path);
                    if (desktop_info.name != null && desktop_info.name.strip() != "") {
                        desktop_name = desktop_info.name.strip();
                    }
                    if (desktop_info.version != null) {
                        desktop_version = desktop_info.version;
                    }
                    is_terminal_app = desktop_info.is_terminal;
                } catch (Error e) {
                    warning("Failed to parse desktop metadata: %s", e.message);
                }
                record.name = desktop_name;
                record.version = desktop_version;

                var slug = slugify_app_name(desktop_name);
                if (slug == "") {
                    slug = metadata.sanitized_basename().down();
                }

                var rename_for_extracted = record.mode == InstallMode.EXTRACTED;
                string renamed_path;
                if (rename_for_extracted) {
                    renamed_path = ensure_install_name(record.installed_path, slug, true);
                } else {
                    var app_name = desktop_name.strip()
                        .replace("/", " ")
                        .replace("\\", " ")
                        .replace("\n", " ")
                        .replace("\r", " ");
                    if (app_name == "") {
                        app_name = slug;
                    }
                    renamed_path = move_portable_to_applications(record.installed_path, app_name);
                }
                if (renamed_path != record.installed_path) {
                    if (rename_for_extracted) {
                        var exec_basename = Path.get_basename(exec_path);
                        exec_path = Path.build_filename(renamed_path, exec_basename);
                    } else {
                        exec_path = renamed_path;
                        assets_path = renamed_path;
                    }
                    record.installed_path = renamed_path;
                }

                string final_slug;
                if (rename_for_extracted) {
                    final_slug = derive_slug_from_path(record.installed_path, true);
                } else {
                    final_slug = slugify_app_name(Path.get_basename(record.installed_path));
                    if (final_slug == "") {
                        final_slug = slug;
                    }
                }
                
                // Extract original Icon name from desktop file
                string? original_icon_name = null;
                try {
                    var key_file = new KeyFile();
                    key_file.load_from_file(desktop_path, KeyFileFlags.NONE);
                    if (key_file.has_key("Desktop Entry", "Icon")) {
                        original_icon_name = key_file.get_string("Desktop Entry", "Icon");
                    }
                } catch (Error e) {
                    warning("Failed to read original icon name: %s", e.message);
                }
                
                // Derive icon name without path and extension
                string icon_name_for_desktop;
                if (original_icon_name != null && original_icon_name != "") {
                    // Strip path if present
                    var icon_basename = Path.get_basename(original_icon_name);
                    // Strip .svg or .png extension
                    if (icon_basename.has_suffix(".svg")) {
                        icon_name_for_desktop = icon_basename.substring(0, icon_basename.length - 4);
                    } else if (icon_basename.has_suffix(".png")) {
                        icon_name_for_desktop = icon_basename.substring(0, icon_basename.length - 4);
                    } else {
                        icon_name_for_desktop = icon_basename;
                    }
                } else {
                    // Fallback to slug if no icon name in desktop file
                    icon_name_for_desktop = final_slug;
                }
                
                // Install icon to ~/.local/share/icons with extension
                var icon_file_basename = Path.get_basename(icon_path);
                var icon_extension = "";
                if (icon_file_basename.has_suffix(".svg")) {
                    icon_extension = ".svg";
                } else if (icon_file_basename.has_suffix(".png")) {
                    icon_extension = ".png";
                }
                var stored_icon = Path.build_filename(AppPaths.icons_dir, "%s%s".printf(icon_name_for_desktop, icon_extension));
                Utils.FileUtils.file_copy(icon_path, stored_icon);
                
                var desktop_contents = rewrite_desktop(desktop_path, exec_path, icon_name_for_desktop, record.installed_path, is_terminal_app, record.mode, preserved_props);
                var desktop_filename = "%s-%s.desktop".printf("appmanager", final_slug);
                var desktop_destination = Path.build_filename(AppPaths.desktop_dir, desktop_filename);
                Utils.FileUtils.ensure_parent(desktop_destination);
                if (!GLib.FileUtils.set_contents(desktop_destination, desktop_contents)) {
                    throw new InstallerError.UNKNOWN("Unable to write desktop file");
                }
                record.desktop_file = desktop_destination;
                record.icon_path = stored_icon;

                // Create symlink for terminal applications
                if (is_terminal_app) {
                    progress("Creating symlink for terminal application…");
                    record.bin_symlink = create_bin_symlink(exec_path, final_slug);
                }
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
        }

        private HashTable<string, string>? preserve_desktop_properties(string? desktop_file_path) {
            if (desktop_file_path == null || desktop_file_path == "") {
                return null;
            }

            var props = new HashTable<string, string>(str_hash, str_equal);
            var fields_to_preserve = new string[] {
                "X-AppImage-Homepage",
                "X-AppImage-UpdateURL",
                "Keywords",
                "StartupWMClass",
                "NoDisplay",
                "Terminal"
            };

            bool has_props = false;
            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(desktop_file_path, KeyFileFlags.NONE);

                foreach (var field in fields_to_preserve) {
                    try {
                        var value = keyfile.get_string("Desktop Entry", field);
                        if (value != null && value.strip() != "") {
                            props.set(field, value);
                            has_props = true;
                        }
                    } catch (Error e) {
                        // Field doesn't exist, that's okay
                    }
                }
            } catch (Error e) {
                warning("Failed to preserve desktop file properties from %s: %s", desktop_file_path, e.message);
                return null;
            }

            return has_props ? props : null;
        }

        public void uninstall(InstallationRecord record) throws Error {
            uninstall_sync(record);
        }

        private void uninstall_sync(InstallationRecord record) throws Error {
            try {
                var installed_file = File.new_for_path(record.installed_path);
                if (installed_file.query_exists()) {
                    if (installed_file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                        Utils.FileUtils.remove_dir_recursive(record.installed_path);
                    } else {
                        installed_file.trash(null);
                    }
                }
                if (record.desktop_file != null && File.new_for_path(record.desktop_file).query_exists()) {
                    File.new_for_path(record.desktop_file).delete(null);
                }
                if (record.icon_path != null && File.new_for_path(record.icon_path).query_exists()) {
                    File.new_for_path(record.icon_path).delete(null);
                }
                if (record.bin_symlink != null && File.new_for_path(record.bin_symlink).query_exists()) {
                    File.new_for_path(record.bin_symlink).delete(null);
                }
                registry.unregister(record.id);
            } catch (Error e) {
                throw new InstallerError.UNINSTALL_FAILED(e.message);
            }
        }

        private void cleanup_failed_installation(InstallationRecord record) {
            try {
                if (record.installed_path != null) {
                    var installed_file = File.new_for_path(record.installed_path);
                    if (installed_file.query_exists()) {
                        if (installed_file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                            Utils.FileUtils.remove_dir_recursive(record.installed_path);
                        } else {
                            installed_file.delete(null);
                        }
                    }
                }
                if (record.desktop_file != null && File.new_for_path(record.desktop_file).query_exists()) {
                    File.new_for_path(record.desktop_file).delete(null);
                }
                if (record.icon_path != null && File.new_for_path(record.icon_path).query_exists()) {
                    File.new_for_path(record.icon_path).delete(null);
                }
                if (record.bin_symlink != null && File.new_for_path(record.bin_symlink).query_exists()) {
                    File.new_for_path(record.bin_symlink).delete(null);
                }
            } catch (Error e) {
                warning("Failed to cleanup after installation error: %s", e.message);
            }
        }

        private string rewrite_desktop(string desktop_path, string exec_target, string icon_name, string installed_path, bool is_terminal, InstallMode mode, HashTable<string, string>? preserved_props) throws Error {
            string contents;
            if (!GLib.FileUtils.get_contents(desktop_path, out contents)) {
                throw new InstallerError.DESKTOP_MISSING("Failed to read desktop file");
            }

            // Track which preserved properties we've seen/applied
            var applied_preserved = new Gee.HashSet<string>();
            var custom_fields = new string[] {"X-AppImage-Homepage", "X-AppImage-UpdateURL", "Keywords", "StartupWMClass", "NoDisplay", "Terminal"};

            var output_lines = new Gee.ArrayList<string>();
            bool actions_handled = false;
            bool no_display_handled = false;
            bool startup_wm_class_handled = false;
            bool skipping_uninstall_block = false;
            bool in_desktop_entry = false;

            foreach (var line in contents.split("\n")) {
                var trimmed = line.strip();

                // Handle section headers
                if (trimmed.has_prefix("[") && trimmed.has_suffix("]")) {
                    if (trimmed == "[Desktop Action Uninstall]") {
                        skipping_uninstall_block = true;
                        in_desktop_entry = false;
                        continue;
                    }
                    skipping_uninstall_block = false;
                    in_desktop_entry = trimmed == "[Desktop Entry]";
                    output_lines.add(line);
                    continue;
                }

                // Skip existing uninstall action block
                if (skipping_uninstall_block) {
                    continue;
                }

                // Pass through non-Desktop Entry sections unchanged
                if (!in_desktop_entry) {
                    output_lines.add(line);
                    continue;
                }

                // Drop TryExec to avoid GNOME misreporting installed apps
                if (trimmed.has_prefix("TryExec=")) {
                    continue;
                }
                // Replace Exec in Desktop Entry section
                if (trimmed.has_prefix("Exec=")) {
                    // For both PORTABLE and EXTRACTED modes: preserve command-line arguments from original desktop file
                    var exec_value = trimmed.substring("Exec=".length).strip();
                    var parts = exec_value.split(" ", 2);
                    string args = (parts.length > 1) ? " " + parts[1] : "";
                    output_lines.add("Exec=\"%s\"%s".printf(exec_target, args));
                    continue;
                }

                // Replace Icon in Desktop Entry section
                if (trimmed.has_prefix("Icon=")) {
                    output_lines.add("Icon=%s".printf(icon_name));
                    continue;
                }

                // Handle StartupWMClass
                if (trimmed.has_prefix("StartupWMClass=")) {
                    startup_wm_class_handled = true;
                    if (preserved_props != null && preserved_props.contains("StartupWMClass")) {
                        output_lines.add("StartupWMClass=%s".printf(preserved_props.get("StartupWMClass")));
                        applied_preserved.add("StartupWMClass");
                    } else {
                        output_lines.add(line);
                    }
                    continue;
                }

                // Handle Keywords
                if (trimmed.has_prefix("Keywords=")) {
                    if (preserved_props != null && preserved_props.contains("Keywords")) {
                        output_lines.add("Keywords=%s".printf(preserved_props.get("Keywords")));
                        applied_preserved.add("Keywords");
                    } else {
                        output_lines.add(line);
                    }
                    continue;
                }

                // Handle NoDisplay for terminal apps
                if (trimmed.has_prefix("NoDisplay=")) {
                    no_display_handled = true;
                    if (preserved_props != null && preserved_props.contains("NoDisplay")) {
                        output_lines.add("NoDisplay=%s".printf(preserved_props.get("NoDisplay")));
                        applied_preserved.add("NoDisplay");
                    } else if (is_terminal) {
                        output_lines.add("NoDisplay=true");
                    } else {
                        output_lines.add(line);
                    }
                    continue;
                }

                // Handle Terminal
                if (trimmed.has_prefix("Terminal=")) {
                    if (preserved_props != null && preserved_props.contains("Terminal")) {
                        output_lines.add("Terminal=%s".printf(preserved_props.get("Terminal")));
                        applied_preserved.add("Terminal");
                    } else {
                        output_lines.add(line);
                    }
                    continue;
                }

                // Handle custom X-AppImage fields
                if (trimmed.has_prefix("X-AppImage-Homepage=")) {
                    if (preserved_props != null && preserved_props.contains("X-AppImage-Homepage")) {
                        output_lines.add("X-AppImage-Homepage=%s".printf(preserved_props.get("X-AppImage-Homepage")));
                        applied_preserved.add("X-AppImage-Homepage");
                    } else {
                        output_lines.add(line);
                    }
                    continue;
                }

                if (trimmed.has_prefix("X-AppImage-UpdateURL=")) {
                    if (preserved_props != null && preserved_props.contains("X-AppImage-UpdateURL")) {
                        output_lines.add("X-AppImage-UpdateURL=%s".printf(preserved_props.get("X-AppImage-UpdateURL")));
                        applied_preserved.add("X-AppImage-UpdateURL");
                    } else {
                        output_lines.add(line);
                    }
                    continue;
                }

                if (trimmed.has_prefix("Actions=")) {
                    actions_handled = true;
                    var value = trimmed.substring("Actions=".length);
                    var actions = new Gee.ArrayList<string>();
                    foreach (var part in value.split(";")) {
                        var action = part.strip();
                        if (action != "" && action != "Uninstall") {
                            actions.add(action);
                        }
                    }
                    actions.add("Uninstall");
                    var action_builder = new StringBuilder();
                    bool first_action = true;
                    foreach (var action_name in actions) {
                        if (!first_action) {
                            action_builder.append(";");
                        }
                        action_builder.append(action_name);
                        first_action = false;
                    }
                    action_builder.append(";");
                    output_lines.add("Actions=%s".printf(action_builder.str));
                    continue;
                }

                // Keep all other lines unchanged
                output_lines.add(line);
            }

            // Add preserved custom fields that weren't in the new desktop file
            if (preserved_props != null) {
                int insert_pos = -1;
                for (int i = 0; i < output_lines.size; i++) {
                    var line = output_lines[i].strip();
                    if (line == "[Desktop Entry]") {
                        insert_pos = i + 1;
                    } else if (insert_pos > 0 && line.has_prefix("[") && line.has_suffix("]")) {
                        break;
                    } else if (insert_pos > 0) {
                        insert_pos = i + 1;
                    }
                }

                foreach (var field in custom_fields) {
                    if (preserved_props.contains(field) && !applied_preserved.contains(field)) {
                        var value = preserved_props.get(field);
                        if (value != null && value.strip() != "") {
                            if (insert_pos > 0) {
                                output_lines.insert(insert_pos, "%s=%s".printf(field, value));
                                insert_pos++;
                            } else {
                                output_lines.add("%s=%s".printf(field, value));
                            }
                        }
                    }
                }
            }

            // Add Actions line if not present
            if (!actions_handled) {
                // Find end of Desktop Entry section to insert Actions
                int insert_pos = -1;
                for (int i = 0; i < output_lines.size; i++) {
                    var line = output_lines[i].strip();
                    if (line == "[Desktop Entry]") {
                        insert_pos = i + 1;
                    } else if (insert_pos > 0 && line.has_prefix("[") && line.has_suffix("]")) {
                        break;
                    } else if (insert_pos > 0) {
                        insert_pos = i + 1;
                    }
                }
                if (insert_pos > 0) {
                    output_lines.insert(insert_pos, "Actions=Uninstall;");
                } else {
                    output_lines.add("Actions=Uninstall;");
                }
            }

            // Add NoDisplay for terminal apps if not already set
            if (is_terminal && !no_display_handled) {
                int insert_pos = -1;
                for (int i = 0; i < output_lines.size; i++) {
                    var line = output_lines[i].strip();
                    if (line == "[Desktop Entry]") {
                        insert_pos = i + 1;
                    } else if (insert_pos > 0 && line.has_prefix("[") && line.has_suffix("]")) {
                        break;
                    } else if (insert_pos > 0) {
                        insert_pos = i + 1;
                    }
                }
                if (insert_pos > 0) {
                    output_lines.insert(insert_pos, "NoDisplay=true");
                } else {
                    output_lines.add("NoDisplay=true");
                }
            }

            // Add StartupWMClass if not present
            if (!startup_wm_class_handled) {
                int insert_pos = -1;
                for (int i = 0; i < output_lines.size; i++) {
                    var line = output_lines[i].strip();
                    if (line == "[Desktop Entry]") {
                        insert_pos = i + 1;
                    } else if (insert_pos > 0 && line.has_prefix("[") && line.has_suffix("]")) {
                        break;
                    } else if (insert_pos > 0) {
                        insert_pos = i + 1;
                    }
                }
                if (insert_pos > 0) {
                    output_lines.insert(insert_pos, "StartupWMClass=%s".printf(icon_name));
                } else {
                    output_lines.add("StartupWMClass=%s".printf(icon_name));
                }
            }

            // Add Uninstall action block
            var uninstall_exec = build_uninstall_exec(installed_path);
            output_lines.add("");
            output_lines.add("[Desktop Action Uninstall]");
            output_lines.add("Name=%s".printf(I18n.tr("Move to Trash")));
            output_lines.add("Exec=%s".printf(uninstall_exec));
            output_lines.add("Icon=user-trash");

            var final_builder = new StringBuilder();
            foreach (var output_line in output_lines) {
                final_builder.append(output_line);
                final_builder.append("\n");
            }
            return final_builder.str;
        }

        private void ensure_executable(string path) {
            if (Posix.chmod(path, 0755) != 0) {
                warning("Failed to chmod %s", path);
            }
        }

        private string escape_exec_arg(string value) {
            return value.replace("\"", "\\\"");
        }

        private string build_uninstall_exec(string installed_path) {
            var parts = new Gee.ArrayList<string>();
            foreach (var token in uninstall_prefix) {
                parts.add(quote_exec_token(token));
            }
            parts.add("--uninstall");
            parts.add("\"%s\"".printf(escape_exec_arg(installed_path)));
            var builder = new StringBuilder();
            for (int i = 0; i < parts.size; i++) {
                if (i > 0) {
                    builder.append(" ");
                }
                builder.append(parts.get(i));
            }
            return builder.str;
        }

        private string quote_exec_token(string token) {
            for (int i = 0; i < token.length; i++) {
                var ch = token[i];
                if (ch == ' ' || ch == '\t') {
                    return "\"%s\"".printf(escape_exec_arg(token));
                }
            }
            return token;
        }

        private string slugify_app_name(string name) {
            var normalized = name.strip().down();
            var builder = new StringBuilder();
            bool last_was_separator = false;
            for (int i = 0; i < normalized.length; i++) {
                char ch = normalized[i];
                if (ch == '\0') {
                    break;
                }
                if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
                    builder.append_c(ch);
                    last_was_separator = false;
                    continue;
                }
                if (!last_was_separator && builder.len > 0) {
                    builder.append_c('_');
                }
                last_was_separator = true;
            }
            return builder.len > 0 ? builder.str : "";
        }

        private string ensure_install_name(string current_path, string slug, bool is_extracted) throws Error {
            if (slug == "") {
                return current_path;
            }
            var parent = Path.get_dirname(current_path);
            string desired;
            if (is_extracted) {
                desired = Path.build_filename(parent, slug);
            } else {
                desired = Path.build_filename(parent, slug + get_path_extension(current_path));
            }

            if (desired == current_path) {
                return current_path;
            }

            if (File.new_for_path(desired).query_exists()) {
                var current_slug = derive_slug_from_path(current_path, is_extracted);
                if (current_slug != slug) {
                    return current_path;
                }
            }

            var final_target = Utils.FileUtils.unique_path(desired);
            if (final_target == current_path) {
                return current_path;
            }
            var source = File.new_for_path(current_path);
            var dest = File.new_for_path(final_target);
            source.move(dest, FileCopyFlags.NONE, null, null);
            return final_target;
        }

        private string move_portable_to_applications(string source_path, string app_name) throws Error {
            DirUtils.create_with_parents(AppPaths.applications_dir, 0755);
            var desired = Path.build_filename(AppPaths.applications_dir, app_name);
            var final_path = Utils.FileUtils.unique_path(desired);
            var source = File.new_for_path(source_path);
            var dest = File.new_for_path(final_path);
            source.move(dest, FileCopyFlags.NONE, null, null);
            ensure_executable(final_path);
            return final_path;
        }

        private string get_path_extension(string path) {
            var base_name = Path.get_basename(path);
            var dot_index = base_name.last_index_of_char('.');
            return dot_index >= 0 ? base_name.substring(dot_index) : "";
        }

        private string derive_slug_from_path(string path, bool is_extracted) {
            var base_name = Path.get_basename(path);
            if (!is_extracted) {
                var dot_index = base_name.last_index_of_char('.');
                if (dot_index > 0) {
                    base_name = base_name.substring(0, dot_index);
                }
            }
            return base_name.down();
        }

        private string[] resolve_uninstall_prefix() {
            var prefix = new Gee.ArrayList<string>();
            if (is_flatpak_sandbox()) {
                var flatpak_id = flatpak_app_id();
                if (flatpak_id != null) {
                    var trimmed = flatpak_id.strip();
                    if (trimmed != "") {
                        prefix.add("flatpak");
                        prefix.add("run");
                        prefix.add(trimmed);
                        return list_to_string_array(prefix);
                    }
                }
            }
            string? resolved = Environment.find_program_in_path("app-manager");
            if (resolved == null || resolved.strip() == "") {
                resolved = current_executable_path();
            }
            if (resolved == null || resolved.strip() == "") {
                resolved = "app-manager";
            }
            prefix.add(resolved);
            return list_to_string_array(prefix);
        }

        private string[] list_to_string_array(Gee.ArrayList<string> list) {
            var result = new string[list.size];
            for (int i = 0; i < list.size; i++) {
                result[i] = list.get(i);
            }
            return result;
        }

        private bool is_flatpak_sandbox() {
            return GLib.FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }

        private string? flatpak_app_id() {
            var env_id = Environment.get_variable("FLATPAK_ID");
            if (env_id != null && env_id.strip() != "") {
                return env_id;
            }
            try {
                var info = new KeyFile();
                info.load_from_file("/.flatpak-info", KeyFileFlags.NONE);
                if (info.has_key("Application", "name")) {
                    return info.get_string("Application", "name");
                }
            } catch (Error e) {
                warning("Failed to read flatpak info: %s", e.message);
            }
            return null;
        }

        private string? current_executable_path() {
            try {
                var path = GLib.FileUtils.read_link("/proc/self/exe");
                if (path != null && path.strip() != "") {
                    return path;
                }
            } catch (Error e) {
                warning("Failed to resolve self executable: %s", e.message);
            }
            return null;
        }

        private void run_appimage_extract(string appimage_path, string working_dir) throws Error {
            ensure_executable(appimage_path);
            var cmd = new string[2];
            cmd[0] = appimage_path;
            cmd[1] = "--appimage-extract";
            string? stdout_str;
            string? stderr_str;
            int exit_status;
            Process.spawn_sync(working_dir, cmd, null, 0, null, out stdout_str, out stderr_str, out exit_status);
            if (exit_status != 0) {
                warning("AppImage extract stdout: %s", stdout_str ?? "");
                warning("AppImage extract stderr: %s", stderr_str ?? "");
                // Fallback for DwarFS-based AppImages that the runtime cannot extract
                var dwarfs_output = Path.build_filename(working_dir, "squashfs-root");
                DirUtils.create_with_parents(dwarfs_output, 0755);
                if (DwarfsTools.extract_all(appimage_path, dwarfs_output)) {
                    return;
                }
                throw new InstallerError.EXTRACTION_FAILED("AppImage self-extract failed");
            }
        }

        private string? create_bin_symlink(string exec_path, string slug) {
            try {
                var bin_dir = Path.build_filename(Environment.get_home_dir(), ".local", "bin");
                DirUtils.create_with_parents(bin_dir, 0755);
                
                var symlink_path = Path.build_filename(bin_dir, slug);
                var symlink_file = File.new_for_path(symlink_path);
                
                // Remove existing symlink if it exists
                if (symlink_file.query_exists()) {
                    symlink_file.delete(null);
                }
                
                // Create symlink
                symlink_file.make_symbolic_link(exec_path, null);
                debug("Created symlink: %s -> %s", symlink_path, exec_path);
                return symlink_path;
            } catch (Error e) {
                warning("Failed to create symlink for %s: %s", slug, e.message);
                return null;
            }
        }

        private void migrate_uninstall_execs() {
            foreach (var record in registry.list()) {
                if (record.desktop_file == null || record.desktop_file == "") {
                    continue;
                }
                try {
                    sanitize_uninstall_action(record);
                } catch (Error e) {
                    warning("Failed to sanitize uninstall action for %s: %s", record.name, e.message);
                }
            }
        }

        private void sanitize_uninstall_action(InstallationRecord record) throws Error {
            if (record.desktop_file == null || record.installed_path == null) {
                return;
            }
            string contents;
            if (!GLib.FileUtils.get_contents(record.desktop_file, out contents)) {
                return;
            }
            var builder = new StringBuilder();
            bool in_uninstall_block = false;
            bool modified = false;
            foreach (var line in contents.split("\n")) {
                var trimmed = line.strip();
                if (trimmed == "[Desktop Action Uninstall]") {
                    in_uninstall_block = true;
                    builder.append(line + "\n");
                    continue;
                }
                if (in_uninstall_block && trimmed.has_prefix("[")) {
                    in_uninstall_block = false;
                }
                if (in_uninstall_block && trimmed.has_prefix("Exec=")) {
                    var uninstall_exec = build_uninstall_exec(record.installed_path);
                    builder.append("Exec=%s\n".printf(uninstall_exec));
                    modified = true;
                    continue;
                }
                builder.append(line + "\n");
            }
            if (modified) {
                if (!GLib.FileUtils.set_contents(record.desktop_file, builder.str)) {
                    throw new InstallerError.UNKNOWN("Unable to update desktop file");
                }
            }
        }
    }
}
