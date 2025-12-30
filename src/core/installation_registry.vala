using Gee;

namespace AppManager.Core {
    public class InstallationRegistry : Object {
        private HashTable<string, InstallationRecord> records;
        // History stores uninstalled apps' name and custom values as JSON objects
        private HashTable<string, Json.Object> history;
        private File registry_file;
        public signal void changed();

        public InstallationRegistry() {
            records = new HashTable<string, InstallationRecord>(GLib.str_hash, GLib.str_equal);
            history = new HashTable<string, Json.Object>(GLib.str_hash, GLib.str_equal);
            registry_file = File.new_for_path(AppPaths.registry_file);
            load();
        }

        public InstallationRecord[] list() {
            var list = new ArrayList<InstallationRecord>();
            foreach (var record in records.get_values()) {
                list.add(record);
            }
            return list.to_array();
        }

        public bool is_installed_checksum(string checksum) {
            return lookup_by_checksum(checksum) != null;
        }

        public InstallationRecord? lookup_by_checksum(string checksum) {
            foreach (var record in records.get_values()) {
                if (record.source_checksum == checksum) {
                    return record;
                }
            }
            return null;
        }

        public InstallationRecord? lookup_by_installed_path(string path) {
            foreach (var record in records.get_values()) {
                if (record.installed_path == path) {
                    return record;
                }
            }
            return null;
        }

        public InstallationRecord? lookup_by_source(string path) {
            foreach (var record in records.get_values()) {
                if (record.source_path == path) {
                    return record;
                }
            }
            return null;
        }

        public void register(InstallationRecord record) {
            records.insert(record.id, record);
            // Remove any history entry for this app name since it's now registered
            // This prevents duplicate entries in the JSON (don't persist yet - we'll save below)
            remove_history(record.name, false);
            save();
            notify_changed();
        }

        /**
         * Updates an existing record in-place and persists the registry.
         *
         * Unlike register(), this does not touch reinstall history. This is intended for
         * user-driven edits of an already-installed record (custom args, keywords, links, etc.).
         */
        public void update(InstallationRecord record, bool notify = true) {
            records.insert(record.id, record);
            save();
            if (notify) {
                notify_changed();
            }
        }

        public void unregister(string id) {
            // Before removing, save custom values to history for potential reinstall
            var record = records.get(id);
            if (record != null) {
                save_to_history(record);
            }
            records.remove(id);
            save();
            notify_changed();
        }
        
        /**
         * Saves custom values from a record to history for later restoration.
         * Only saves if record has custom values worth preserving.
         */
        private void save_to_history(InstallationRecord record) {
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
            return history.get(app_name.down());
        }
        
        /**
         * Removes historical custom values for an app by name.
         * Called after successful registration to prevent duplicate entries.
         * @param persist If true, saves registry to disk. Set to false when save will happen later.
         */
        public void remove_history(string app_name, bool persist = true) {
            var key = app_name.down();
            if (history.contains(key)) {
                history.remove(key);
                if (persist) {
                    save();
                }
                debug("Removed history for %s", app_name);
            }
        }
        
        /**
         * Applies historical custom values to a record if available.
         * Called during fresh install to restore user's previous settings.
         */
        public void apply_history_to_record(InstallationRecord record) {
            var history_obj = lookup_history(record.name);
            if (history_obj != null) {
                debug("Restoring history for %s", record.name);
                record.apply_history(history_obj);
            }
        }

        public void persist(bool notify = true) {
            save();
            if (notify) {
                notify_changed();
            }
        }

        /**
         * Reloads registry contents from disk.
         * Useful when another AppManager process (or external tooling) modified the registry file.
         */
        public void reload(bool notify = true) {
            records = new HashTable<string, InstallationRecord>(GLib.str_hash, GLib.str_equal);
            history = new HashTable<string, Json.Object>(GLib.str_hash, GLib.str_equal);
            load();
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
            var orphaned = new Gee.ArrayList<InstallationRecord>();
            var records_to_remove = new Gee.ArrayList<string>();
            
            foreach (var record in records.get_values()) {
                var installed_file = File.new_for_path(record.installed_path);
                if (!installed_file.query_exists()) {
                    debug("Found orphaned record: %s (path: %s)", record.name, record.installed_path);
                    orphaned.add(record);
                    records_to_remove.add(record.id);
                    
                    // Save custom values to history before removing (same as unregister)
                    save_to_history(record);
                    
                    // Clean up associated files
                    cleanup_record_files(record);
                }
            }
            
            // Remove orphaned records from registry
            foreach (var id in records_to_remove) {
                records.remove(id);
            }
            
            if (records_to_remove.size > 0) {
                save();
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

        private void load() {
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

        private void save() {
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
