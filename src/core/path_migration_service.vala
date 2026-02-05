using AppManager.Utils;
using Gee;

namespace AppManager.Core {
    public errordomain MigrationError {
        INVALID_PATH,
        PERMISSION_DENIED,
        DISK_FULL,
        APPS_RUNNING,
        MIGRATION_FAILED
    }

    /**
     * Service for migrating AppImage installations when the user changes
     * the installation directory in preferences.
     */
    public class PathMigrationService : Object {
        private InstallationRegistry registry;
        private Settings settings;

        public signal void progress(string message, double fraction);
        public signal void migration_complete(bool success, string? error_message);

        public PathMigrationService(InstallationRegistry registry, Settings settings) {
            this.registry = registry;
            this.settings = settings;
        }

        /**
         * Validates the new path before migration.
         * Returns null if valid, or an error message if invalid.
         */
        public string? validate_new_path(string new_path) {
            if (new_path.strip() == "") {
                return null; // Empty means use default, which is always valid
            }

            var path = new_path.strip();

            // Check if path is absolute
            if (!Path.is_absolute(path)) {
                return _("Path must be absolute");
            }

            // Check if it's the same as current
            if (path == AppPaths.applications_dir) {
                return _("This is already the current directory");
            }

            // Check if path exists and is writable, or can be created
            var file = File.new_for_path(path);
            if (file.query_exists()) {
                try {
                    var info = file.query_info(FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NONE);
                    if (!info.get_attribute_boolean(FileAttribute.ACCESS_CAN_WRITE)) {
                        return _("Directory is not writable");
                    }
                } catch (Error e) {
                    return _("Cannot access directory: %s").printf(e.message);
                }
                // Check if it's a directory
                if (file.query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY) {
                    return _("Path exists but is not a directory");
                }
            } else {
                // Check if parent exists and is writable
                var parent = file.get_parent();
                if (parent == null) {
                    return _("Invalid path");
                }
                if (!parent.query_exists()) {
                    return _("Parent directory does not exist");
                }
                try {
                    var parent_info = parent.query_info(FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NONE);
                    if (!parent_info.get_attribute_boolean(FileAttribute.ACCESS_CAN_WRITE)) {
                        return _("Cannot create directory: parent is not writable");
                    }
                } catch (Error e) {
                    return _("Cannot access parent directory: %s").printf(e.message);
                }
            }

            return null;
        }

        /**
         * Calculates the total size of all installed apps for disk space checking.
         */
        public int64 calculate_total_size() {
            int64 total = 0;
            foreach (var record in registry.list()) {
                if (record.installed_path != null) {
                    var file = File.new_for_path(record.installed_path);
                    if (file.query_exists()) {
                        try {
                            if (file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                                total += calculate_dir_size(record.installed_path);
                            } else {
                                var info = file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                                total += info.get_size();
                            }
                        } catch (Error e) {
                            warning("Failed to get size of %s: %s", record.installed_path, e.message);
                        }
                    }
                }
            }
            return total;
        }

        private int64 calculate_dir_size(string path) {
            int64 size = 0;
            try {
                var dir = Dir.open(path);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var child_path = Path.build_filename(path, name);
                    var child = File.new_for_path(child_path);
                    if (child.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
                        size += calculate_dir_size(child_path);
                    } else {
                        try {
                            var info = child.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                            size += info.get_size();
                        } catch (Error e) {
                            // Ignore
                        }
                    }
                }
            } catch (Error e) {
                warning("Failed to calculate size of %s: %s", path, e.message);
            }
            return size;
        }

        /**
         * Migrates all installations from the current directory to a new directory.
         * This is an async operation that reports progress.
         */
        public async void migrate(string new_path) throws MigrationError {
            // CRITICAL: Set migration flag BEFORE any file operations to prevent
            // reconcile_with_filesystem from detecting moved files as deleted
            registry.set_migration_in_progress(true);
            
            var old_base = AppPaths.applications_dir;
            var new_base = new_path.strip();
            
            // Use default if empty
            if (new_base == "") {
                new_base = AppPaths.default_applications_dir;
            }

            if (old_base == new_base) {
                // Same path, nothing to do - clear flag since we won't emit signal
                registry.set_migration_in_progress(false);
                return;
            }

            var records = registry.list();
            if (records.length == 0) {
                // No apps installed, just update the setting
                settings.set_string("applications-dir", new_path.strip());
                // DO NOT clear migration flag here - PreferencesDialog will clear it
                // after receiving migration_complete and restarting monitors
                migration_complete(true, null);
                return;
            }

            // Create new directory
            if (DirUtils.create_with_parents(new_base, 0755) != 0) {
                // Exception path - clear flag since no signal will be emitted
                registry.set_migration_in_progress(false);
                throw new MigrationError.PERMISSION_DENIED(_("Failed to create directory: %s").printf(new_base));
            }

            // Create .installed subdirectory for extracted apps
            var new_extracted_root = Path.build_filename(new_base, EXTRACTED_DIRNAME);
            if (DirUtils.create_with_parents(new_extracted_root, 0755) != 0) {
                // Exception path - clear flag since no signal will be emitted
                registry.set_migration_in_progress(false);
                throw new MigrationError.PERMISSION_DENIED(_("Failed to create extracted directory: %s").printf(new_extracted_root));
            }

            int total = records.length;
            int current = 0;
            var errors = new ArrayList<string>();

            // Simple migration loop - the migration_in_progress flag protects us
            foreach (var record in records) {
                current++;
                double fraction = (double)current / (double)total;
                progress(_("Migrating %s (%d/%d)…").printf(record.name, current, total), fraction);

                try {
                    yield migrate_record(record, old_base, new_base);
                } catch (Error e) {
                    errors.add("%s: %s".printf(record.name, e.message));
                    warning("Failed to migrate %s: %s", record.name, e.message);
                }
                
                // Yield to allow UI updates
                Idle.add(migrate.callback);
                yield;
            }

            // Update the setting AFTER migration is complete
            settings.set_string("applications-dir", new_path.strip());

            // Save registry with updated paths
            registry.persist(false);  // Don't notify - we'll do that after migration flag is cleared

            // Refresh desktop database so the system sees the updated paths
            update_desktop_database();

            // Emit signal - PreferencesDialog will clear migration flag and restart monitors
            if (errors.size > 0) {
                var error_msg = string.joinv("\n", errors.to_array());
                migration_complete(false, _("Some apps failed to migrate:\n%s").printf(error_msg));
            } else {
                migration_complete(true, null);
            }
        }

        private async void migrate_record(InstallationRecord record, string old_base, string new_base) throws Error {
            if (record.installed_path == null || record.installed_path.strip() == "") {
                return;
            }

            var old_path = record.installed_path;
            
            // Only migrate if the app is under the old base directory
            if (!old_path.has_prefix(old_base)) {
                debug("Skipping %s - not under old base path", record.name);
                return;
            }

            // Calculate new path by replacing the base
            var relative_path = old_path.substring(old_base.length);
            if (relative_path.has_prefix("/")) {
                relative_path = relative_path.substring(1);
            }
            var new_path = Path.build_filename(new_base, relative_path);

            // Create parent directories
            var new_parent = Path.get_dirname(new_path);
            DirUtils.create_with_parents(new_parent, 0755);

            // Move the file/directory
            var old_file = File.new_for_path(old_path);
            var new_file = File.new_for_path(new_path);

            if (!old_file.query_exists()) {
                warning("Source file doesn't exist: %s", old_path);
                record.installed_path = new_path; // Update path anyway
                return;
            }

            // Use move for same filesystem, copy+delete for cross-filesystem
            try {
                old_file.move(new_file, FileCopyFlags.OVERWRITE | FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
            } catch (IOError.NOT_SUPPORTED e) {
                // Cross-filesystem move, need to copy and delete
                if (old_file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                    yield copy_directory_recursive(old_path, new_path);
                    Utils.FileUtils.remove_dir_recursive(old_path);
                } else {
                    old_file.copy(new_file, FileCopyFlags.OVERWRITE | FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
                    old_file.delete(null);
                }
            }

            // Update record path
            record.installed_path = new_path;

            // Update desktop file - replace old base directory with new base directory
            // This updates both the app's Exec path AND the AppManager uninstall path
            if (record.desktop_file != null && File.new_for_path(record.desktop_file).query_exists()) {
                update_desktop_file(record.desktop_file, old_path, new_path, old_base, new_base);
            }

            // Update symlink if exists
            if (record.bin_symlink != null && record.bin_symlink.strip() != "") {
                update_symlink(record.bin_symlink, old_path, new_path);
            }
        }

        private async void copy_directory_recursive(string src, string dest) throws Error {
            DirUtils.create_with_parents(dest, 0755);
            var dir = Dir.open(src);
            string? name;
            while ((name = dir.read_name()) != null) {
                var src_child = Path.build_filename(src, name);
                var dest_child = Path.build_filename(dest, name);
                var src_file = File.new_for_path(src_child);
                var dest_file = File.new_for_path(dest_child);
                
                var file_type = src_file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                if (file_type == FileType.DIRECTORY) {
                    yield copy_directory_recursive(src_child, dest_child);
                } else if (file_type == FileType.SYMBOLIC_LINK) {
                    // Copy symlink
                    try {
                        var link_target = GLib.FileUtils.read_link(src_child);
                        dest_file.make_symbolic_link(link_target, null);
                    } catch (Error e) {
                        warning("Failed to copy symlink %s: %s", src_child, e.message);
                    }
                } else {
                    src_file.copy(dest_file, FileCopyFlags.OVERWRITE | FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
                }
            }
        }

        private void update_desktop_file(string desktop_path, string old_app_path, string new_app_path, string old_base, string new_base) {
            try {
                uint8[] contents;
                File.new_for_path(desktop_path).load_contents(null, out contents, null);
                var content = (string)contents;
                
                // Replace old base directory with new base directory throughout the file
                // This handles:
                // - Exec= line (the app's own path)
                // - Uninstall action (references AppManager's path in the same base directory)
                // - Any other paths that reference the old installation directory
                var updated = content.replace(old_base, new_base);
                
                if (updated != content) {
                    GLib.FileUtils.set_contents(desktop_path, updated);
                    debug("Updated desktop file: %s (replaced %s with %s)", desktop_path, old_base, new_base);
                } else {
                    debug("No changes needed in desktop file: %s (base path %s not found)", desktop_path, old_base);
                }
            } catch (Error e) {
                warning("Failed to update desktop file %s: %s", desktop_path, e.message);
            }
        }

        private void update_symlink(string symlink_path, string old_target, string new_target) {
            try {
                var symlink_file = File.new_for_path(symlink_path);
                if (!symlink_file.query_exists()) {
                    return;
                }

                // Read current target
                var current_target = GLib.FileUtils.read_link(symlink_path);
                
                // Only update if it points to the old path
                if (current_target == old_target || current_target.has_prefix(old_target + "/")) {
                    var new_symlink_target = current_target.replace(old_target, new_target);
                    
                    // Delete old symlink and create new one
                    symlink_file.delete(null);
                    symlink_file.make_symbolic_link(new_symlink_target, null);
                    debug("Updated symlink: %s -> %s", symlink_path, new_symlink_target);
                }
            } catch (Error e) {
                warning("Failed to update symlink %s: %s", symlink_path, e.message);
            }
        }

        /**
         * Resets to the default installation directory.
         * This is equivalent to migrating to ~/Applications.
         */
        public async void reset_to_default() throws MigrationError {
            yield migrate("");
        }

        /**
         * Updates the desktop database so file managers and app launchers
         * see the changes to .desktop files.
         */
        private void update_desktop_database() {
            try {
                string[] argv = { "update-desktop-database", AppPaths.desktop_dir };
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                if (exit_status != 0) {
                    debug("update-desktop-database returned non-zero exit status: %d", exit_status);
                } else {
                    debug("Desktop database updated successfully");
                }
            } catch (Error e) {
                // update-desktop-database may not be available on all systems
                debug("Failed to run update-desktop-database: %s", e.message);
            }
        }
    }
}
