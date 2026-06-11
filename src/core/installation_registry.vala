using Gee;

namespace AppManager.Core {
    public class InstallationRegistry : Object {
        private HashTable<string, InstallationRecord> records;
        // Tracks apps currently being installed/uninstalled to skip during reconcile
        private HashTable<string, bool> in_flight;
        // Flag to prevent reconciliation during path migration
        private bool migration_in_progress = false;
        private File registry_file;
        private Mutex registry_mutex = Mutex();
        // Separate store for user custom values (custom.json)
        private CustomValuesStore custom_values_store;
        public signal void changed();

        /**
         * Sets the migration in progress flag.
         * When true, reconcile_with_filesystem() will be skipped entirely.
         */
        public void set_migration_in_progress(bool in_progress) {
            registry_mutex.lock();
            migration_in_progress = in_progress;
            debug("Migration in progress: %s", in_progress.to_string());
            registry_mutex.unlock();
        }

        /**
         * Returns true if migration is currently in progress.
         */
        public bool is_migration_in_progress() {
            registry_mutex.lock();
            var result = migration_in_progress;
            registry_mutex.unlock();
            return result;
        }

        public InstallationRegistry() {
            records = new HashTable<string, InstallationRecord>(GLib.str_hash, GLib.str_equal);
            in_flight = new HashTable<string, bool>(GLib.str_hash, GLib.str_equal);
            registry_file = File.new_for_path(AppPaths.registry_file);
            custom_values_store = new CustomValuesStore();
            // Constructor runs in single-threaded context, no locking needed
            load_unlocked();
        }

        public InstallationRecord[] list() {
            registry_mutex.lock();
            var list = new ArrayList<InstallationRecord>();
            foreach (var record in records.get_values()) {
                list.add(record);
            }
            registry_mutex.unlock();
            return list.to_array();
        }

        public bool is_installed_checksum(string checksum) {
            return lookup_by_checksum(checksum) != null;
        }

        /**
         * Returns a free registry id for a new install: the checksum itself, or
         * "checksum-N" when identical content is already installed side by side.
         */
        public string unique_record_id(string checksum) {
            registry_mutex.lock();
            var id = checksum;
            int n = 2;
            while (records.get(id) != null) {
                id = "%s-%d".printf(checksum, n);
                n++;
            }
            registry_mutex.unlock();
            return id;
        }

        public InstallationRecord? lookup_by_checksum(string checksum) {
            registry_mutex.lock();
            InstallationRecord? result = null;
            foreach (var record in records.get_values()) {
                if (record.source_checksum == checksum) {
                    result = record;
                    break;
                }
            }
            registry_mutex.unlock();
            return result;
        }

        public InstallationRecord? lookup_by_installed_path(string path) {
            registry_mutex.lock();
            InstallationRecord? result = null;
            foreach (var record in records.get_values()) {
                if (record.installed_path == path) {
                    result = record;
                    break;
                }
            }
            registry_mutex.unlock();
            return result;
        }

        public InstallationRecord? lookup_by_source(string path) {
            registry_mutex.lock();
            InstallationRecord? result = null;
            foreach (var record in records.get_values()) {
                if (record.source_path == path) {
                    result = record;
                    break;
                }
            }
            registry_mutex.unlock();
            return result;
        }

        public InstallationRecord? lookup_by_name(string name) {
            registry_mutex.lock();
            var target = name.down();
            InstallationRecord? result = null;
            foreach (var record in records.get_values()) {
                if (record.name != null && record.name.strip().down() == target) {
                    result = record;
                    break;
                }
            }
            registry_mutex.unlock();
            return result;
        }

        /**
         * Detects if an AppImage matches an existing installation.
         * Checks by source path, checksum, and app name.
         */
        public InstallationRecord? detect_existing(string source_path, string checksum, string? app_name) {
            var by_source = lookup_by_source(source_path);
            if (by_source != null) {
                return by_source;
            }

            var by_checksum = lookup_by_checksum(checksum);
            if (by_checksum != null) {
                return by_checksum;
            }

            if (app_name != null && app_name.strip() != "") {
                var by_name = lookup_by_name(app_name);
                if (by_name != null) {
                    return by_name;
                }
            }

            return null;
        }

        /**
         * Strips a trailing " N" copy suffix so secondary copies share a base name.
         * "AppManager 2" -> "AppManager"; "AppManager" -> "AppManager".
         */
        public static string base_name_of(string name) {
            var trimmed = name.strip();
            var space = trimmed.last_index_of_char(' ');
            if (space <= 0) {
                return trimmed;
            }
            var suffix = trimmed.substring(space + 1);
            if (suffix == "") {
                return trimmed;
            }
            for (int i = 0; i < suffix.length; i++) {
                if (suffix[i] < '0' || suffix[i] > '9') {
                    return trimmed;
                }
            }
            return trimmed.substring(0, space).strip();
        }

        /**
         * Returns the suffix index to assign to a newly installed copy of the given
         * app name. 0 when no installation shares the base name (primary install);
         * otherwise the next free index >= 2 used for "Name N" secondary copies.
         */
        public int next_copy_index(string app_name) {
            var target = base_name_of(app_name).down();
            registry_mutex.lock();
            var used = new Gee.HashSet<int>();
            int base_count = 0;
            foreach (var record in records.get_values()) {
                if (record.name == null) {
                    continue;
                }
                if (base_name_of(record.name).down() != target) {
                    continue;
                }
                base_count++;
                if (record.copy_index >= 2) {
                    used.add(record.copy_index);
                }
            }
            registry_mutex.unlock();

            if (base_count == 0) {
                return 0;
            }
            int candidate = 2;
            while (used.contains(candidate)) {
                candidate++;
            }
            return candidate;
        }

        /**
         * Marks an app as "in-flight" (being installed/uninstalled).
         * Reconcile will skip in-flight apps to prevent race conditions.
         */
        public void mark_in_flight(string id) {
            registry_mutex.lock();
            in_flight.insert(id, true);
            registry_mutex.unlock();
        }
        
        /**
         * Clears the in-flight flag for an app.
         */
        public void clear_in_flight(string id) {
            registry_mutex.lock();
            in_flight.remove(id);
            registry_mutex.unlock();
        }
        
        /**
         * Checks if an app is currently in-flight.
         */
        public bool is_in_flight(string id) {
            registry_mutex.lock();
            var result = in_flight.contains(id);
            registry_mutex.unlock();
            return result;
        }

        public void register(InstallationRecord record) {
            registry_mutex.lock();
            records.insert(record.id, record);
            // Clear in-flight flag now that registration is complete
            in_flight.remove(record.id);
            save_unlocked();
            registry_mutex.unlock();
            // Persist custom values to custom.json
            custom_values_store.save_from_record(record);
            notify_changed();
        }

        /**
         * Updates an existing record in-place and persists the registry.
         *
         * Unlike register(), this does not touch reinstall history. This is intended for
         * user-driven edits of an already-installed record (custom args, keywords, links, etc.).
         */
        public void update(InstallationRecord record, bool notify = true) {
            registry_mutex.lock();
            records.insert(record.id, record);
            save_unlocked();
            registry_mutex.unlock();
            // Persist custom values to custom.json
            custom_values_store.save_from_record(record);
            if (notify) {
                notify_changed();
            }
        }

        public void unregister(string id) {
            registry_mutex.lock();
            // Before removing, save custom values for potential reinstall
            var record = records.get(id);
            if (record != null) {
                // Custom values remain in custom.json automatically (no removal needed)
                // Just ensure they are persisted if not already
                custom_values_store.save_from_record(record);
            }
            records.remove(id);
            // Clear in-flight flag
            in_flight.remove(id);
            save_unlocked();
            registry_mutex.unlock();
            notify_changed();
        }
        
        /**
         * Applies custom values from the store to a record if available.
         * Called during fresh install to restore user's previous settings.
         */
        public void apply_history_to_record(InstallationRecord record) {
            custom_values_store.apply_to_record(record);
        }

        public void persist(bool notify = true) {
            registry_mutex.lock();
            save_unlocked();
            registry_mutex.unlock();
            if (notify) {
                notify_changed();
            }
        }

        /**
         * Reloads registry contents from disk.
         * Useful when another AppManager process (or external tooling) modified the registry file.
         */
        public void reload(bool notify = true) {
            registry_mutex.lock();
            // Preserve in-flight apps across reload
            var preserved_in_flight = new HashTable<string, bool>(GLib.str_hash, GLib.str_equal);
            foreach (var id in in_flight.get_keys()) {
                preserved_in_flight.insert(id, true);
            }
            records = new HashTable<string, InstallationRecord>(GLib.str_hash, GLib.str_equal);
            in_flight = preserved_in_flight;
            load_unlocked();
            registry_mutex.unlock();
            // Reload custom values store
            custom_values_store.reload();
            if (notify) {
                notify_changed();
            }
        }

        /**
         * Reconciles the registry with the filesystem.
         * Removes registry entries for apps that no longer exist on disk
         * and cleans up their desktop files, icons, and symlinks.
         * Returns the list of orphaned records that were cleaned up.
         */
        public Gee.ArrayList<InstallationRecord> reconcile_with_filesystem() {
            registry_mutex.lock();
            
            // Skip reconciliation entirely during migration to prevent false uninstallations
            if (migration_in_progress) {
                debug("Skipping reconcile_with_filesystem: migration in progress");
                registry_mutex.unlock();
                return new Gee.ArrayList<InstallationRecord>();
            }
            
            var orphaned = new Gee.ArrayList<InstallationRecord>();
            var records_to_remove = new Gee.ArrayList<string>();
            
            foreach (var record in records.get_values()) {
                // Skip apps that are currently being installed/uninstalled
                if (in_flight.contains(record.id)) {
                    debug("Skipping in-flight app during reconcile: %s", record.name);
                    continue;
                }
                
                var installed_file = File.new_for_path(record.installed_path);
                if (!installed_file.query_exists()) {
                    debug("Found orphaned record: %s (path: %s)", record.name, record.installed_path);
                    orphaned.add(record);
                    records_to_remove.add(record.id);
                    
                    // Custom values remain in custom.json for potential reinstall
                    
                    // Clean up associated files
                    cleanup_record_files(record);
                }
            }
            
            // Remove orphaned records from registry
            foreach (var id in records_to_remove) {
                records.remove(id);
            }
            
            if (records_to_remove.size > 0) {
                save_unlocked();
            }
            registry_mutex.unlock();
            
            if (records_to_remove.size > 0) {
                notify_changed();
            }
            
            return orphaned;
        }

        private void cleanup_record_files(InstallationRecord record) {
            try {
                // Clean up desktop file
                if (record.desktop_file != null) {
                    var desktop_file = File.new_for_path(record.desktop_file);
                    if (desktop_file.query_exists()) {
                        desktop_file.delete(null);
                        debug("Cleaned up desktop file: %s", record.desktop_file);
                    }
                }
                
                // Clean up icon
                if (record.icon_path != null) {
                    var icon_file = File.new_for_path(record.icon_path);
                    if (icon_file.query_exists()) {
                        icon_file.delete(null);
                        debug("Cleaned up icon: %s", record.icon_path);
                    }
                }
                
                // Clean up bin symlink
                if (record.bin_symlink != null) {
                    var symlink_file = File.new_for_path(record.bin_symlink);
                    if (symlink_file.query_exists()) {
                        symlink_file.delete(null);
                        debug("Cleaned up bin symlink: %s", record.bin_symlink);
                    }
                }
            } catch (Error e) {
                warning("Failed to cleanup files for orphaned record %s: %s", record.name, e.message);
            }
        }

        /**
         * Internal load function without locking.
         * Note: Caller must hold registry_mutex or ensure exclusive access.
         *
         * Handles migration from old format where custom values and history
         * were stored in installations.json. On first load after migration,
         * custom values are extracted to custom.json and stripped from
         * installations.json.
         */
        private void load_unlocked() {
            if (!registry_file.query_exists(null)) {
                return;
            }
            try {
                var path = registry_file.get_path();
                if (path == null) {
                    return;
                }
                string contents;
                if (!GLib.FileUtils.get_contents(path, out contents)) {
                    warning("Failed to read registry file %s", path);
                    return;
                }
                var parser = new Json.Parser();
                parser.load_from_data(contents, contents.length);
                var root = parser.get_root();
                
                // Tracks whether we found custom values or history in the old format
                bool needs_migration = false;
                var legacy_history = new HashTable<string, Json.Object>(GLib.str_hash, GLib.str_equal);
                
                if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                    // New format with "installations" array
                    var root_obj = root.get_object();
                    
                    // Load installations
                    if (root_obj.has_member("installations")) {
                        var installations = root_obj.get_array_member("installations");
                        foreach (var node in installations.get_elements()) {
                            if (node.get_node_type() == Json.NodeType.OBJECT) {
                                var obj = node.get_object();
                                // Check if this is a full installation or just history (no id field)
                                if (obj.has_member("id")) {
                                    var record = InstallationRecord.from_json(obj);
                                    records.insert(record.id, record);
                                    // Detect if this record has custom values embedded (old format)
                                    if (record.has_custom_values()) {
                                        needs_migration = true;
                                    }
                                } else if (obj.has_member("name")) {
                                    // This is a history entry (uninstalled app with custom values)
                                    // Migrate to custom.json
                                    var name = obj.get_string_member("name");
                                    legacy_history.insert(name.down(), obj);
                                    needs_migration = true;
                                }
                            }
                        }
                    }
                    
                    // Legacy history array support
                    if (root_obj.has_member("history")) {
                        var history_array = root_obj.get_array_member("history");
                        foreach (var node in history_array.get_elements()) {
                            if (node.get_node_type() == Json.NodeType.OBJECT) {
                                var obj = node.get_object();
                                if (obj.has_member("name")) {
                                    var name = obj.get_string_member("name");
                                    if (legacy_history.get(name.down()) == null) {
                                        legacy_history.insert(name.down(), obj);
                                    }
                                    needs_migration = true;
                                }
                            }
                        }
                    }
                } else if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
                    // Legacy format: just an array of installations
                    foreach (var node in root.get_array().get_elements()) {
                        if (node.get_node_type() == Json.NodeType.OBJECT) {
                            var obj = node.get_object();
                            var record = InstallationRecord.from_json(obj);
                            records.insert(record.id, record);
                            if (record.has_custom_values()) {
                                needs_migration = true;
                            }
                        }
                    }
                }
                
                // Migrate custom values from old format to custom.json
                if (needs_migration && !custom_values_store.has_entries()) {
                    debug("Migrating custom values from installations.json to custom.json");
                    
                    // Migrate from installed records
                    var records_array = new ArrayList<InstallationRecord>();
                    foreach (var record in records.get_values()) {
                        records_array.add(record);
                    }
                    custom_values_store.migrate_from_records(records_array.to_array());
                    
                    // Migrate from history entries
                    if (legacy_history.size() > 0) {
                        custom_values_store.migrate_from_history(legacy_history);
                    }
                    
                    // Re-save installations.json without custom values or history entries
                    save_unlocked();
                    debug("Migration to custom.json complete");
                } else {
                    // Normal load: apply custom values from custom.json to loaded records
                    foreach (var record in records.get_values()) {
                        custom_values_store.apply_to_record(record);
                    }
                }
            } catch (Error e) {
                warning("Failed to load registry: %s", e.message);
            }
        }

        /**
         * Internal save function without locking.
         * Note: Caller must hold registry_mutex.
         */
        private void save_unlocked() {
            try {
                var builder = new Json.Builder();
                builder.begin_object();
                
                // Save installations only (custom values are in custom.json)
                builder.set_member_name("installations");
                builder.begin_array();
                
                // Add installed apps
                foreach (var record in records.get_values()) {
                    builder.add_value(record.to_json());
                }
                
                builder.end_array();
                
                builder.end_object();
                var generator = new Json.Generator();
                generator.set_root(builder.get_root());
                generator.set_pretty(true);
                var json = generator.to_data(null);
                FileUtils.set_contents(registry_file.get_path(), json);
            } catch (Error e) {
                warning("Failed to save registry: %s", e.message);
            }
        }

        private void notify_changed() {
            GLib.Idle.add(() => {
                changed();
                return GLib.Source.REMOVE;
            });
        }
    }
}
