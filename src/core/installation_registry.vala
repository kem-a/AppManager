using Gee;

namespace AppManager.Core {
    public class InstallationRegistry : Object {
        private HashTable<string, InstallationRecord> records;
        // History stores uninstalled apps' name and custom values as JSON objects
        private HashTable<string, Json.Object> history;
        // Tracks apps currently being installed/uninstalled to skip during reconcile
        private HashTable<string, bool> in_flight;
        private File registry_file;
        private Mutex registry_mutex = Mutex();
        public signal void changed();

        public InstallationRegistry() {
            records = new HashTable<string, InstallationRecord>(GLib.str_hash, GLib.str_equal);
            history = new HashTable<string, Json.Object>(GLib.str_hash, GLib.str_equal);
            in_flight = new HashTable<string, bool>(GLib.str_hash, GLib.str_equal);
            registry_file = File.new_for_path(AppPaths.registry_file);
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
            // Remove any history entry for this app name since it's now registered
            // This prevents duplicate entries in the JSON (don't persist yet - we'll save below)
            remove_history_unlocked(record.name);
            // Clear in-flight flag now that registration is complete
            in_flight.remove(record.id);
            save_unlocked();
            registry_mutex.unlock();
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
            if (notify) {
                notify_changed();
            }
        }

        public void unregister(string id) {
            registry_mutex.lock();
            // Before removing, save custom values to history for potential reinstall
            var record = records.get(id);
            if (record != null) {
                save_to_history_unlocked(record);
            }
            records.remove(id);
            // Clear in-flight flag
            in_flight.remove(id);
            save_unlocked();
            registry_mutex.unlock();
            notify_changed();
        }
        
        /**
         * Saves custom values from a record to history for later restoration.
         * Only saves if record has custom values worth preserving.
         * Note: Caller must hold registry_mutex.
         */
        private void save_to_history_unlocked(InstallationRecord record) {
            if (record.has_custom_values()) {
                var history_node = record.to_history_json();
                history.insert(record.name.down(), history_node.get_object());
                debug("Saved history for %s", record.name);
            }
        }
        
        /**
         * Looks up historical custom values for an app by name.
         * Returns null if no history exists.
         */
        public Json.Object? lookup_history(string app_name) {
            registry_mutex.lock();
            var result = history.get(app_name.down());
            registry_mutex.unlock();
            return result;
        }
        
        /**
         * Removes historical custom values for an app by name.
         * Called after successful registration to prevent duplicate entries.
         * @param persist If true, saves registry to disk. Set to false when save will happen later.
         */
        public void remove_history(string app_name, bool persist = true) {
            registry_mutex.lock();
            var key = app_name.down();
            if (history.contains(key)) {
                history.remove(key);
                if (persist) {
                    save_unlocked();
                }
                debug("Removed history for %s", app_name);
            }
            registry_mutex.unlock();
        }
        
        /**
         * Removes history entry without locking.
         * Note: Caller must hold registry_mutex.
         */
        private void remove_history_unlocked(string app_name) {
            var key = app_name.down();
            if (history.contains(key)) {
                history.remove(key);
                debug("Removed history for %s", app_name);
            }
        }
        
        /**
         * Applies historical custom values to a record if available.
         * Called during fresh install to restore user's previous settings.
         */
        public void apply_history_to_record(InstallationRecord record) {
            registry_mutex.lock();
            var history_obj = history.get(record.name.down());
            registry_mutex.unlock();
            if (history_obj != null) {
                debug("Restoring history for %s", record.name);
                record.apply_history(history_obj);
            }
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
            history = new HashTable<string, Json.Object>(GLib.str_hash, GLib.str_equal);
            in_flight = preserved_in_flight;
            load_unlocked();
            registry_mutex.unlock();
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
                    
                    // Save custom values to history before removing (same as unregister)
                    save_to_history_unlocked(record);
                    
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
                if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                    // New format with "installations" array, history entries stored alongside
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
                                } else if (obj.has_member("name")) {
                                    // This is a history entry (uninstalled app with custom values)
                                    var name = obj.get_string_member("name");
                                    history.insert(name.down(), obj);
                                }
                            }
                        }
                    }
                    
                    // Legacy history array support (for migration)
                    if (root_obj.has_member("history")) {
                        var history_array = root_obj.get_array_member("history");
                        foreach (var node in history_array.get_elements()) {
                            if (node.get_node_type() == Json.NodeType.OBJECT) {
                                var obj = node.get_object();
                                if (obj.has_member("name")) {
                                    var name = obj.get_string_member("name");
                                    // Only add if not already in history
                                    if (history.get(name.down()) == null) {
                                        history.insert(name.down(), obj);
                                    }
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
                        }
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
                
                // Save all entries (installations and history) in single "installations" array
                builder.set_member_name("installations");
                builder.begin_array();
                
                // Add installed apps
                foreach (var record in records.get_values()) {
                    builder.add_value(record.to_json());
                }
                
                // Add history entries (uninstalled apps with custom values)
                foreach (var history_obj in history.get_values()) {
                    var node = new Json.Node(Json.NodeType.OBJECT);
                    node.set_object(history_obj);
                    builder.add_value(node);
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
