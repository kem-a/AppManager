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
            uninstall(old_record);
            return install_sync(file_path, mode, old_record);
        }

        private InstallationRecord install_sync(string file_path, InstallMode override_mode, InstallationRecord? old_record) throws Error {
            var file = File.new_for_path(file_path);
            var metadata = new AppImageMetadata(file);
            if (old_record == null && registry.is_installed_checksum(metadata.checksum)) {
                throw new InstallerError.ALREADY_INSTALLED("AppImage already installed");
            }

            InstallMode mode = override_mode;

            var record = new InstallationRecord(metadata.checksum, metadata.display_name, mode);
            
            // Mark as in-flight immediately to prevent reconcile from interfering
            registry.mark_in_flight(record.id);
            
            record.source_path = metadata.path;
            record.source_checksum = metadata.checksum;
            
            // Preserve installed_at and set updated_at for upgrades
            if (old_record != null) {
                record.installed_at = old_record.installed_at;
                record.updated_at = (int64)GLib.get_real_time();
                
                // Carry over last_modified, content_length and release tag from old record
                record.last_modified = old_record.last_modified;
                record.content_length = old_record.content_length;
                record.last_release_tag = old_record.last_release_tag;
                
                // Carry over custom values from old record (user customizations survive updates)
                record.custom_commandline_args = old_record.custom_commandline_args;
                record.custom_keywords = old_record.custom_keywords;
                record.custom_icon_name = old_record.custom_icon_name;
                record.custom_startup_wm_class = old_record.custom_startup_wm_class;
                record.custom_update_link = old_record.custom_update_link;
                record.custom_web_page = old_record.custom_web_page;
                // Note: original_* values will be updated from the new AppImage's .desktop
            }
            // Note: For fresh installs, history is applied in finalize_desktop_and_icon()
            // after the app name is resolved from the .desktop file

            bool is_upgrade = (old_record != null);

            try {
                if (mode == InstallMode.PORTABLE) {
                    install_portable(metadata, record, is_upgrade);
                } else {
                    install_extracted(metadata, record, is_upgrade);
                }

                // Only delete source after successful installation
                if (File.new_for_path(file_path).query_exists()) {
                    File.new_for_path(file_path).delete();
                }

                debug("Installer: calling registry.register() for %s", record.name);
                registry.register(record);
                debug("Installer: registry.register() completed");
                
                // Update MIME database so file associations work
                update_desktop_database();
                
                return record;
            } catch (Error e) {
                // Cleanup on failure and clear in-flight flag
                registry.clear_in_flight(record.id);
                cleanup_failed_installation(record);
                throw e;
            }
        }

        private void install_portable(AppImageMetadata metadata, InstallationRecord record, bool is_upgrade) throws Error {
            progress("Preparing Applications folder…");
            record.installed_path = metadata.path;
            finalize_desktop_and_icon(record, metadata, metadata.path, metadata.path, is_upgrade, null);
        }

        private void install_extracted(AppImageMetadata metadata, InstallationRecord record, bool is_upgrade) throws Error {
            progress("Extracting AppImage…");
            var base_name = metadata.sanitized_basename();
            DirUtils.create_with_parents(AppPaths.extracted_root, 0755);
            var dest_dir = Utils.FileUtils.unique_path(Path.build_filename(AppPaths.extracted_root, base_name));
            string staging_dir = "";
            try {
                var staging_template = Path.build_filename(AppPaths.extracted_root, "%s-extract-XXXXXX".printf(base_name));
                staging_dir = DirUtils.mkdtemp(staging_template);
                run_appimage_extract(metadata.path, staging_dir);
                var extracted_root = Path.build_filename(staging_dir, SQUASHFS_ROOT_DIR);
                var extracted_file = File.new_for_path(extracted_root);
                if (!extracted_file.query_exists()) {
                    throw new InstallerError.EXTRACTION_FAILED("AppImage extraction did not produce %s".printf(SQUASHFS_ROOT_DIR));
                }
                
                // Some AppImages create squashfs-root as a symlink (e.g., to AppDir).
                // Resolve the symlink to get the actual directory to move.
                var file_type = extracted_file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                if (file_type == FileType.SYMBOLIC_LINK) {
                    try {
                        var link_target = GLib.FileUtils.read_link(extracted_root);
                        string resolved_path;
                        if (Path.is_absolute(link_target)) {
                            resolved_path = link_target;
                        } else {
                            resolved_path = Path.build_filename(staging_dir, link_target);
                        }
                        extracted_file = File.new_for_path(resolved_path);
                        debug("%s is a symlink, resolved to: %s", SQUASHFS_ROOT_DIR, resolved_path);
                    } catch (Error e) {
                        throw new InstallerError.EXTRACTION_FAILED("Failed to resolve %s symlink: %s".printf(SQUASHFS_ROOT_DIR, e.message));
                    }
                }
                
                if (extracted_file.query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY) {
                    throw new InstallerError.EXTRACTION_FAILED("AppImage extraction did not produce a valid directory");
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
            Utils.FileUtils.ensure_executable(app_run);
            
            // Check if desktop file Exec points to AppRun, and if so, resolve the actual binary
            string exec_target = app_run;
            try {
                var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-desktop-check-");
                try {
                    var desktop_path = AppImageAssets.extract_desktop_entry(metadata.path, temp_dir);
                    var entry = new DesktopEntry(desktop_path);
                    if (entry.exec != null) {
                        var exec_value = entry.exec;
                        // Check if Exec contains AppRun (without path or with relative path)
                        if ("AppRun" in exec_value) {
                            // Try to parse BIN from AppRun
                            var bin_name = DesktopEntry.parse_bin_from_apprun(app_run);
                            if (bin_name != null && bin_name != "") {
                                var bin_path = Path.build_filename(dest_dir, bin_name);
                                if (File.new_for_path(bin_path).query_exists()) {
                                    Utils.FileUtils.ensure_executable(bin_path);
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
                finalize_desktop_and_icon(record, metadata, exec_target, metadata.path, is_upgrade, app_run);
        }

        /**
         * Derives icon name without path and extension.
         */
        private string derive_icon_name(string? original_icon_name, string fallback_slug) {
            if (original_icon_name == null || original_icon_name == "") {
                return fallback_slug;
            }
            
            var icon_basename = Path.get_basename(original_icon_name);
            if (icon_basename.has_suffix(".svg")) {
                return icon_basename.substring(0, icon_basename.length - 4);
            }
            if (icon_basename.has_suffix(".png")) {
                return icon_basename.substring(0, icon_basename.length - 4);
            }
            return icon_basename;
        }

        /**
         * Detects icon file extension from filename or content.
         */
        private string detect_icon_extension(string icon_path) {
            var icon_file_basename = Path.get_basename(icon_path);
            if (icon_file_basename.has_suffix(".svg")) {
                return ".svg";
            }
            if (icon_file_basename.has_suffix(".png")) {
                return ".png";
            }
            // No extension in filename (e.g., .DirIcon), detect from content
            return Utils.FileUtils.detect_image_extension(icon_path);
        }

        /**
         * Derives fallback StartupWMClass from bundled desktop file name.
         */
        private string derive_fallback_wmclass(string desktop_path) {
            var bundled_desktop_basename = Path.get_basename(desktop_path);
            if (bundled_desktop_basename.has_suffix(".desktop")) {
                return bundled_desktop_basename.substring(0, bundled_desktop_basename.length - 8);
            }
            return bundled_desktop_basename;
        }

        private void finalize_desktop_and_icon(InstallationRecord record, AppImageMetadata metadata, string exec_target, string appimage_for_assets, bool is_upgrade, string? app_run_path) throws Error {
            string exec_path = exec_target.dup();
            string assets_path = appimage_for_assets.dup();
            string? resolved_entry_exec = null;
            progress("Extracting desktop entry…");
            var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-");
            try {
                var desktop_path = AppImageAssets.extract_desktop_entry(assets_path, temp_dir);
                var icon_path = AppImageAssets.extract_icon(assets_path, temp_dir);
                
                // Try to extract AppRun if not provided (for portable mode)
                string? effective_app_run = app_run_path;
                if (effective_app_run == null) {
                    effective_app_run = AppImageAssets.extract_apprun(assets_path, temp_dir);
                }

                string desktop_name = metadata.display_name;
                string? desktop_version = null;
                bool is_terminal_app = false;
                
                // Use DesktopEntry to parse the file once
                var desktop_entry = new DesktopEntry(desktop_path);
                
                if (desktop_entry.name != null && desktop_entry.name.strip() != "") {
                    desktop_name = desktop_entry.name.strip();
                }
                if (desktop_entry.appimage_version != null) {
                    desktop_version = desktop_entry.appimage_version;
                }
                
                // Fall back to metainfo if no version from desktop entry
                if (desktop_version == null) {
                    desktop_version = AppImageAssets.extract_version_from_metainfo(assets_path, temp_dir);
                }
                
                is_terminal_app = desktop_entry.terminal;
                
                record.name = desktop_name;
                record.version = desktop_version;
                record.is_terminal = is_terminal_app;
                
                // For fresh installs or upgrades, apply history now that we have the real app name
                // This restores user's custom settings if they uninstalled and are reinstalling,
                // or if for some reason the old_record didn't have custom values
                // Note: During upgrade, custom values were already copied from old_record in install_sync(),
                // but apply_history won't overwrite existing custom values (only fills in nulls)
                registry.apply_history_to_record(record);

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
                
                // Extract original values from desktop entry
                var original_icon_name = desktop_entry.icon;
                var original_keywords = desktop_entry.keywords;
                var original_startup_wm_class = desktop_entry.startup_wm_class;
                var original_homepage = desktop_entry.appimage_homepage;
                var original_update_url = desktop_entry.appimage_update_url;
                
                // Check for zsync update info from .upd_info ELF section
                // If present and is zsync format, store it for delta updates
                string? zsync_info = null;
                if (metadata.update_info != null && metadata.update_info.strip() != "") {
                    var update_info = metadata.update_info.strip();
                    // Check if it's a zsync format (gh-releases-zsync|... or zsync|...)
                    if (update_info.has_prefix("gh-releases-zsync|") || update_info.has_prefix("zsync|")) {
                        zsync_info = update_info;
                        // Use normalized URL as the display update link
                        original_update_url = Updater.normalize_update_url(update_info);
                        // If web page is blank, use the normalized zsync URL as web page
                        if (original_homepage == null || original_homepage.strip() == "") {
                            original_homepage = original_update_url;
                        }
                    } else {
                        // Not zsync, use as regular update URL
                        original_update_url = update_info;
                    }
                }
                
                var exec_value = desktop_entry.exec;
                var original_exec_args = exec_value != null ? DesktopEntry.extract_exec_arguments(exec_value) : null;
                resolved_entry_exec = exec_value != null ? DesktopEntry.resolve_exec_from_desktop(exec_value, effective_app_run) : null;
                
                // Derive icon name without path and extension
                var icon_name_for_desktop = derive_icon_name(original_icon_name, final_slug);
                
                // Install icon to flat ~/.local/share/icons directory
                var icon_extension = detect_icon_extension(icon_path);
                var stored_icon = Path.build_filename(AppPaths.icons_dir, "%s%s".printf(icon_name_for_desktop, icon_extension));
                Utils.FileUtils.file_copy(icon_path, stored_icon);
                
                // Derive fallback StartupWMClass from bundled desktop file name (without .desktop extension)
                var fallback_startup_wm_class = derive_fallback_wmclass(desktop_path);
                
                // Store original values temporarily in record for get_effective_* methods to work
                record.original_icon_name = icon_name_for_desktop;
                record.original_keywords = original_keywords;
                record.original_startup_wm_class = original_startup_wm_class ?? fallback_startup_wm_class;
                record.original_commandline_args = original_exec_args;
                record.original_update_link = original_update_url;
                record.original_web_page = original_homepage;
                record.zsync_update_info = zsync_info;  // Store zsync info if present
                
                // For fresh install with history (reinstall), use effective values (considers CLEARED_VALUE)
                var effective_icon = record.get_effective_icon_name() ?? icon_name_for_desktop;
                var effective_keywords = record.get_effective_keywords();
                var effective_wmclass = record.get_effective_startup_wm_class();
                var effective_args = record.get_effective_commandline_args();
                var effective_update_link = record.get_effective_update_link();
                var effective_web_page = record.get_effective_web_page();
                
                var desktop_contents = rewrite_desktop(desktop_path, exec_path, record, is_terminal_app, final_slug, is_upgrade, effective_icon, effective_keywords, effective_wmclass, effective_args, effective_update_link, effective_web_page);
                
                // Preserve original bundled desktop filename for proper desktop integration
                var desktop_filename = Path.get_basename(desktop_path);
                var desktop_destination = Path.build_filename(AppPaths.desktop_dir, desktop_filename);
                Utils.FileUtils.ensure_parent(desktop_destination);
                
                // Always write desktop file - custom values from JSON are applied via get_effective_*()
                // The old desktop file is deleted during uninstall, so we must write the new one
                if (!GLib.FileUtils.set_contents(desktop_destination, desktop_contents)) {
                    throw new InstallerError.UNKNOWN("Unable to write desktop file");
                }
                record.desktop_file = desktop_destination;
                record.icon_path = stored_icon;
                
                if (resolved_entry_exec != null && resolved_entry_exec.strip() != "") {
                    var stored_exec = resolved_entry_exec.strip();
                    if (record.mode == InstallMode.EXTRACTED && record.installed_path.strip() != "") {
                        stored_exec = DesktopEntry.relativize_exec_to_installed(stored_exec, record.installed_path);
                    }
                    record.entry_exec = stored_exec;
                }

                // original_* values were already set above before get_effective_* calls

                // Create symlink for all applications by default (improves compatibility)
                progress("Creating symlink for application…");
                var symlink_name = final_slug;

                if (resolved_entry_exec != null && resolved_entry_exec.strip() != "") {
                    symlink_name = Path.get_basename(resolved_entry_exec.strip());
                }

                if (record.original_startup_wm_class == Core.APPLICATION_ID) {
                    symlink_name = "app-manager";
                }
                record.bin_symlink = create_bin_symlink(exec_path, symlink_name);
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
        }
        public void uninstall(InstallationRecord record) throws Error {
            uninstall_sync(record);
        }

        private void uninstall_sync(InstallationRecord record) throws Error {
            try {
                // Mark as in-flight and unregister FIRST to prevent reconcile race conditions
                // This ensures the record is removed from registry before the file is deleted,
                // so DirectoryMonitor won't see it as orphaned during the deletion.
                registry.mark_in_flight(record.id);
                registry.unregister(record.id);
                
                // Now safely delete the files
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
                
                // Update MIME database after removing desktop file
                update_desktop_database();
            } catch (Error e) {
                // Clear in-flight flag on error
                registry.clear_in_flight(record.id);
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

        private string rewrite_desktop(string desktop_path, string exec_target, InstallationRecord record, bool is_terminal, string slug, bool is_upgrade, string? effective_icon_name, string? effective_keywords, string? effective_startup_wm_class, string? effective_commandline_args, string? effective_update_link, string? effective_web_page) throws Error {
            var entry = new DesktopEntry(desktop_path);
            
            // Update Exec with optional environment variables
            var args = effective_commandline_args ?? "";
            var env_vars = record.custom_env_vars;
            
            string exec_line;
            if (env_vars != null && env_vars.length > 0) {
                // Use 'env' command to set environment variables
                var env_builder = new StringBuilder("env ");
                foreach (var env_var in env_vars) {
                    if (env_var != null && env_var.strip() != "") {
                        // Parse NAME=value and quote the value
                        var eq_pos = env_var.index_of_char('=');
                        if (eq_pos >= 0) {
                            var name_part = env_var.substring(0, eq_pos);
                            var value_part = env_var.substring(eq_pos + 1);
                            env_builder.append("%s=\"%s\" ".printf(name_part, value_part));
                        } else {
                            // No value, just the name
                            env_builder.append(env_var);
                            env_builder.append(" ");
                        }
                    }
                }
                if (args.strip() != "") {
                    exec_line = "%s\"%s\" %s".printf(env_builder.str, exec_target, args);
                } else {
                    exec_line = "%s\"%s\"".printf(env_builder.str, exec_target);
                }
            } else {
                if (args.strip() != "") {
                    exec_line = "\"%s\" %s".printf(exec_target, args);
                } else {
                    exec_line = "\"%s\"".printf(exec_target);
                }
            }
            entry.exec = exec_line;
            
            // Update Icon
            entry.icon = (effective_icon_name != null && effective_icon_name.strip() != "") ? effective_icon_name : null;
            
            // Update StartupWMClass
            entry.startup_wm_class = (effective_startup_wm_class != null && effective_startup_wm_class.strip() != "") ? effective_startup_wm_class : null;
            
            // Update Keywords
            entry.keywords = (effective_keywords != null && effective_keywords.strip() != "") ? effective_keywords : null;
            
            // Update NoDisplay
            if (is_terminal) {
                entry.no_display = true;
            }
            
            // Update X-AppImage fields
            entry.appimage_homepage = (effective_web_page != null && effective_web_page.strip() != "") ? effective_web_page : null;
            entry.appimage_update_url = (effective_update_link != null && effective_update_link.strip() != "") ? effective_update_link : null;
            
            // Ensure Uninstall action exists
            var actions_str = entry.actions ?? "";
            var actions = new Gee.ArrayList<string>();
            foreach (var part in actions_str.split(";")) {
                var action = part.strip();
                if (action != "" && action != "Uninstall") {
                    actions.add(action);
                }
            }
            actions.add("Uninstall");
            
            var action_builder = new StringBuilder();
            foreach (var action_name in actions) {
                action_builder.append(action_name);
                action_builder.append(";");
            }
            entry.actions = action_builder.str;
            
            // Remove TryExec
            entry.remove_key("TryExec");
            
            // Disable DBusActivatable - AppImages don't have D-Bus service files,
            // so we must force the launcher to use Exec= instead of D-Bus activation
            entry.remove_key("DBusActivatable");
            
            // Add Uninstall action block
            var uninstall_exec = build_uninstall_exec(record.installed_path);
            entry.set_action_group("Uninstall", I18n.tr("Move to Trash"), uninstall_exec, "user-trash");
            
            return entry.to_data();
        }

        private string build_uninstall_exec(string installed_path) {
            var parts = new Gee.ArrayList<string>();
            foreach (var token in uninstall_prefix) {
                parts.add(Utils.FileUtils.quote_exec_token(token));
            }
            parts.add("--uninstall");
            parts.add("\"%s\"".printf(Utils.FileUtils.escape_exec_arg(installed_path)));
            var builder = new StringBuilder();
            for (int i = 0; i < parts.size; i++) {
                if (i > 0) {
                    builder.append(" ");
                }
                builder.append(parts.get(i));
            }
            return builder.str;
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
            Utils.FileUtils.ensure_executable(final_path);
            return final_path;
        }

        private string get_path_extension(string path) {
            var base_name = Path.get_basename(path);
            var dot_index = base_name.last_index_of_char('.');
            return dot_index >= 0 ? base_name.substring(dot_index) : "";
        }

        public string derive_slug_from_path(string path, bool is_extracted) {
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
            string? resolved = current_executable_path();
            if (resolved == null || resolved.strip() == "") {
                resolved = Environment.find_program_in_path("app-manager");
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
            return AppPaths.current_executable_path;
        }

        private void run_appimage_extract(string appimage_path, string working_dir) throws Error {
            Utils.FileUtils.ensure_executable(appimage_path);
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
                var dwarfs_output = Path.build_filename(working_dir, SQUASHFS_ROOT_DIR);
                DirUtils.create_with_parents(dwarfs_output, 0755);
                if (DwarfsTools.extract_all(appimage_path, dwarfs_output)) {
                    return;
                }
                throw new InstallerError.EXTRACTION_FAILED("AppImage self-extract failed");
            }
        }

        private string? create_bin_symlink(string exec_path, string slug) {
            try {
                var bin_dir = AppPaths.local_bin_dir;
                
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

        public bool ensure_bin_symlink_for_record(InstallationRecord record, string exec_path, string slug) {
            if (exec_path.strip() == "") {
                return false;
            }

            var link = create_bin_symlink(exec_path, slug);
            if (link == null) {
                return false;
            }

            record.bin_symlink = link;
            registry.persist(false);
            return true;
        }

        /**
         * Resolve the effective executable path for an installed record based on its desktop file.
         * This mirrors the runtime resolution used when creating the desktop entry, but can be
         * called later (e.g., from the Details window) without reimplementing parsing logic.
         */
        public string resolve_exec_path_for_record(InstallationRecord record) {
            var installed_path = record.installed_path ?? "";
            var stored_exec = record.entry_exec;

            // For extracted AppImages (directory), always use AppRun
            if (installed_path != "" && File.new_for_path(installed_path).query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                return Path.build_filename(installed_path, "AppRun");
            }

            if (stored_exec != null && stored_exec.strip() != "") {
                var token = stored_exec.strip();
                if (Path.is_absolute(token)) {
                    return token;
                }
            }

            if (installed_path != "" && File.new_for_path(installed_path).query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY) {
                return installed_path;
            }

            string exec_value = "";

            if (record.desktop_file != null && record.desktop_file.strip() != "") {
                var entry = new DesktopEntry(record.desktop_file);
                exec_value = entry.exec ?? "";
            }

            return DesktopEntry.resolve_exec_path(exec_value, record.installed_path);
        }

        public bool remove_bin_symlink_for_record(InstallationRecord record) {
            if (record.bin_symlink == null || record.bin_symlink.strip() == "") {
                return true;
            }
            try {
                var file = File.new_for_path(record.bin_symlink);
                if (file.query_exists()) {
                    file.delete(null);
                    debug("Removed symlink: %s", record.bin_symlink);
                }
                record.bin_symlink = null;
                registry.persist(false);
                return true;
            } catch (Error e) {
                warning("Failed to remove symlink for %s: %s", record.name, e.message);
                return false;
            }
        }

        /**
         * Rewrites an installed record's desktop file to reflect the record's effective values
         * (custom values and cleared values). This centralizes desktop entry edits that used to
         * be scattered across the UI.
         */
        public void apply_record_customizations_to_desktop(InstallationRecord record) {
            if (record.desktop_file == null || record.desktop_file.strip() == "") {
                return;
            }

            var desktop_path = record.desktop_file;
            if (!File.new_for_path(desktop_path).query_exists()) {
                return;
            }

            bool is_terminal = false;
            var entry = new DesktopEntry(desktop_path);
            is_terminal = entry.terminal;

            var exec_target = resolve_exec_path_for_record(record);

            var effective_icon = record.get_effective_icon_name();
            var effective_keywords = record.get_effective_keywords();
            var effective_wmclass = record.get_effective_startup_wm_class();
            var effective_args = record.get_effective_commandline_args();
            var effective_update_link = record.get_effective_update_link();
            var effective_web_page = record.get_effective_web_page();

            try {
                var new_contents = rewrite_desktop(
                    desktop_path,
                    exec_target,
                    record,
                    is_terminal,
                    "",
                    false,
                    effective_icon,
                    effective_keywords,
                    effective_wmclass,
                    effective_args,
                    effective_update_link,
                    effective_web_page
                );

                if (!GLib.FileUtils.set_contents(desktop_path, new_contents)) {
                    warning("Failed to write updated desktop file: %s", desktop_path);
                }
            } catch (Error e) {
                warning("Failed to rewrite desktop file %s: %s", desktop_path, e.message);
            }
        }

        /**
         * Updates a single key inside the [Desktop Entry] group.
         * If value is empty, the key is removed (except Exec, which is preserved).
         */
        public void set_desktop_entry_property(string desktop_file_path, string key, string value) {
            if (desktop_file_path == null || desktop_file_path.strip() == "") {
                return;
            }

            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(desktop_file_path, KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS);

                if (value.strip() == "") {
                    if (key != "Exec") {
                        try {
                            keyfile.remove_key("Desktop Entry", key);
                        } catch (Error e) {
                            // Key may not exist
                        }
                    } else {
                        keyfile.set_string("Desktop Entry", key, value);
                    }
                } else {
                    keyfile.set_string("Desktop Entry", key, value);
                }

                var data = keyfile.to_data();
                GLib.FileUtils.set_contents(desktop_file_path, data);
            } catch (Error e) {
                warning("Failed to update desktop file %s: %s", desktop_file_path, e.message);
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
            
            try {
                var entry = new DesktopEntry(record.desktop_file);
                var uninstall_exec = build_uninstall_exec(record.installed_path);
                entry.set_action_group("Uninstall", I18n.tr("Move to Trash"), uninstall_exec, "user-trash");
                entry.save();
            } catch (Error e) {
                warning("Failed to sanitize uninstall action for %s: %s", record.name, e.message);
            }
        }

        /**
         * Updates the MIME database and desktop file cache so that file associations work.
         * Runs update-desktop-database on ~/.local/share/applications.
         */
        private void update_desktop_database() {
            try {
                string[] argv = { "update-desktop-database", AppPaths.desktop_dir };
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                if (exit_status != 0) {
                    debug("update-desktop-database returned non-zero exit status: %d", exit_status);
                }
            } catch (Error e) {
                // update-desktop-database may not be available on all systems
                debug("Failed to run update-desktop-database: %s", e.message);
            }
        }
    }
}
