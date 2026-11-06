using Gee;
using GLib;

namespace AppManager.Core {
    /**
     * Represents a staged update discovered by the background service.
     * These are persisted to disk so the UI can show available updates
     * when user opens AppManager after a background check.
     */
    public class StagedUpdate : Object {
        public string record_id { get; set; }
        public string record_name { get; set; }
        public string? available_version { get; set; }
        public int64 discovered_at { get; set; }
        // Why the last attempt to install this update failed, shown as the
        // library's failure badge; null while the update is untried.
        public string? failure { get; set; }

        public StagedUpdate(string record_id, string record_name, string? available_version) {
            Object();
            this.record_id = record_id;
            this.record_name = record_name;
            this.available_version = available_version;
            this.discovered_at = new GLib.DateTime.now_utc().to_unix();
        }

        public StagedUpdate.from_json(Json.Object obj) {
            Object();
            this.record_id = obj.get_string_member_with_default("record_id", "");
            this.record_name = obj.get_string_member_with_default("record_name", "");
            var version = obj.get_string_member_with_default("available_version", "");
            this.available_version = version.length > 0 ? version : null;
            this.discovered_at = obj.get_int_member_with_default("discovered_at", 0);
            var failure = obj.get_string_member_with_default("failure", "");
            this.failure = failure.length > 0 ? failure : null;
        }

        public Json.Node to_json() {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("record_id");
            builder.add_string_value(record_id);
            builder.set_member_name("record_name");
            builder.add_string_value(record_name);
            builder.set_member_name("available_version");
            builder.add_string_value(available_version ?? "");
            builder.set_member_name("discovered_at");
            builder.add_int_value(discovered_at);
            if (failure != null) {
                builder.set_member_name("failure");
                builder.add_string_value(failure);
            }
            builder.end_object();
            return builder.get_root();
        }
    }

    /**
     * Manages staged updates - updates discovered by the background service
     * that are persisted to disk for the UI to display.
     */
    public class StagedUpdatesManager : Object {
        private string file_path;
        private Gee.HashMap<string, StagedUpdate> staged;

        public StagedUpdatesManager() {
            this.file_path = AppPaths.staged_updates_file;
            this.staged = new Gee.HashMap<string, StagedUpdate>();
            load();
        }

        /**
         * Loads staged updates from disk.
         */
        public void load() {
            staged.clear();
            var file = File.new_for_path(file_path);
            if (!file.query_exists()) {
                return;
            }

            try {
                uint8[] contents;
                file.load_contents(null, out contents, null);
                var parser = new Json.Parser();
                parser.load_from_data((string)contents);
                var root = parser.get_root();
                if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
                    var array = root.get_array();
                    array.foreach_element((arr, idx, node) => {
                        if (node.get_node_type() == Json.NodeType.OBJECT) {
                            var update = new StagedUpdate.from_json(node.get_object());
                            staged.set(update.record_id, update);
                        }
                    });
                }
                debug("Loaded %d staged update(s) from %s", staged.size, file_path);
            } catch (Error e) {
                warning("Failed to load staged updates: %s", e.message);
            }
        }

        /**
         * Saves staged updates to disk.
         */
        public void save() {
            try {
                DirUtils.create_with_parents(AppPaths.data_dir, 0755);
                var builder = new Json.Builder();
                builder.begin_array();
                foreach (var update in staged.values) {
                    builder.add_value(update.to_json());
                }
                builder.end_array();

                var generator = new Json.Generator();
                generator.set_root(builder.get_root());
                generator.set_pretty(true);
                generator.to_file(file_path);
                debug("Saved %d staged update(s) to %s", staged.size, file_path);
            } catch (Error e) {
                warning("Failed to save staged updates: %s", e.message);
            }
        }

        /**
         * Adds or updates a staged update for a record.
         */
        public void add(string record_id, string record_name, string? available_version) {
            staged.set(record_id, new StagedUpdate(record_id, record_name, available_version));
        }

        /**
         * Records why installing a record's update failed, staging it first if
         * needed, or clears the reason when failure is null.
         */
        public void set_failure(string record_id, string record_name, string? failure) {
            var update = staged.get(record_id);
            if (update == null) {
                if (failure == null) {
                    return;
                }
                update = new StagedUpdate(record_id, record_name, null);
                staged.set(record_id, update);
            }
            update.failure = failure;
        }

        /**
         * Removes a staged update for a record (e.g., after update is installed).
         */
        public void remove(string record_id) {
            staged.unset(record_id);
        }

        /**
         * Clears all staged updates.
         */
        public void clear() {
            staged.clear();
        }

        /**
         * Returns all staged updates.
         */
        public Gee.Collection<StagedUpdate> list() {
            return staged.values;
        }

        /**
         * Returns staged update for a specific record, or null if none.
         */
        public StagedUpdate? get_for_record(string record_id) {
            return staged.get(record_id);
        }

        /**
         * Returns true if there are any staged updates.
         */
        public bool has_updates() {
            return staged.size > 0;
        }

        /**
         * Returns the number of staged updates.
         */
        public int count() {
            return staged.size;
        }

        /**
         * Returns set of record IDs with staged updates.
         */
        public Gee.Set<string> get_record_ids() {
            return staged.keys;
        }
    }
}
