using Gee;

namespace AppManager.Core {
    public class InstallationRegistry : Object {
        private HashTable<string, InstallationRecord> records;
        private File registry_file;
        public signal void changed();

        public InstallationRegistry() {
            records = new HashTable<string, InstallationRecord>(GLib.str_hash, GLib.str_equal);
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
            save();
            notify_changed();
        }

        public void unregister(string id) {
            records.remove(id);
            save();
            notify_changed();
        }

        public void persist(bool notify = true) {
            save();
            if (notify) {
                notify_changed();
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
                if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
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
                builder.begin_array();
                foreach (var record in records.get_values()) {
                    builder.add_value(record.to_json());
                }
                builder.end_array();
                var generator = new Json.Generator();
                generator.set_root(builder.get_root());
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
