using AppManager.Core;

namespace AppManager {
    public class EnvVarsGroup : Adw.PreferencesGroup {
        private const int MAX_ENV_VARS = 5;
        private Gee.ArrayList<EnvVarRow> rows = new Gee.ArrayList<EnvVarRow>();
        private Adw.ActionRow add_row;
        private Gtk.Button add_button;
        private bool applying_paste = false;

        public signal void changed(EnvVarsGroup group);
        public signal void committed();

        public EnvVarsGroup(string[] env_vars) {
            title = _("Environment Variables");
            description = _("Set custom environment variables for this app");

            add_button = new Gtk.Button.from_icon_name("list-add-symbolic");
            add_button.add_css_class("flat");
            add_button.set_margin_top(8);
            add_button.set_margin_bottom(8);
            add_button.clicked.connect(() => { append_row("", ""); });

            var add_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            add_box.set_halign(Gtk.Align.CENTER);
            add_box.set_hexpand(true);
            add_box.append(add_button);
            add_row = new Adw.ActionRow();
            add_row.set_activatable(false);
            add_row.set_child(add_box);
            add(add_row);

            foreach (var env_var in env_vars) {
                if (env_var == null || env_var.strip() == "") continue;
                var eq = env_var.index_of_char('=');
                // Loading stored values must not unquote or trim them as a paste would.
                append_row(eq < 0 ? env_var : env_var.substring(0, eq),
                           eq < 0 ? "" : env_var.substring(eq + 1), false);
            }
        }

        public string[] get_env_vars() {
            var env_vars = new Gee.ArrayList<string>();
            foreach (var row in rows) {
                var name = (row.name_entry.text ?? "").strip();
                if (name != "") {
                    env_vars.add("%s=%s".printf(name, row.value_entry.text ?? ""));
                }
            }
            return env_vars.to_array();
        }

        private void notify_changed() {
            if (!applying_paste) changed(this);
        }

        private void append_row(string name, string value, bool enforce_limit = true) {
            if (enforce_limit && rows.size >= MAX_ENV_VARS) return;
            var row = new EnvVarRow(name, value);
            row.name_entry.changed.connect(notify_changed);
            row.value_entry.changed.connect(notify_changed);
            row.committed.connect(() => { committed(); });
            row.removed.connect(remove_row);
            row.paste_requested.connect(apply_paste);
            rows.add(row);
            remove(add_row);
            add(row);
            add(add_row);
            add_button.sensitive = rows.size < MAX_ENV_VARS;
        }

        private void remove_row(EnvVarRow row) {
            rows.remove(row);
            remove(row);
            add_button.sensitive = rows.size < MAX_ENV_VARS;
            notify_changed();
            committed();
        }

        private void apply_paste(EnvVarRow row, string text) {
            var assignments = EnvVarPaste.parse(text);
            if (assignments.length == 0) {
                row.restore_name();
                return;
            }
            applying_paste = true;
            row.set_assignment(assignments[0]);
            for (int i = 1; i < assignments.length && rows.size < MAX_ENV_VARS; i++) {
                append_row(assignments[i].name, assignments[i].value);
            }
            applying_paste = false;
            notify_changed();
            committed();
        }
    }

    private class EnvVarRow : Adw.ActionRow {
        public Gtk.Entry name_entry;
        public Gtk.Entry value_entry;
        private bool applying_assignment = false;
        private string previous_name;

        public signal void removed(EnvVarRow row);
        public signal void paste_requested(EnvVarRow row, string text);
        public signal void committed();

        public EnvVarRow(string name, string value) {
            var content = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            content.set_margin_top(8);
            content.set_margin_bottom(8);
            content.set_margin_start(12);
            content.set_margin_end(12);
            content.set_hexpand(true);

            name_entry = create_entry(_("NAME"));
            name_entry.set_max_length(64);
            name_entry.truncate_multiline = false;
            name_entry.text = name;
            previous_name = name_entry.text;
            name_entry.changed.connect(() => { previous_name = name_entry.text; });
            content.append(name_entry);
            var equals_label = new Gtk.Label("=");
            equals_label.add_css_class("dim-label");
            content.append(equals_label);
            value_entry = create_entry(_("value"));
            value_entry.text = value;
            content.append(value_entry);

            var delete_button = new Gtk.Button.from_icon_name("user-trash-symbolic");
            delete_button.add_css_class("flat");
            delete_button.set_valign(Gtk.Align.CENTER);
            delete_button.tooltip_text = _("Remove variable");
            delete_button.clicked.connect(() => { removed(this); });
            content.append(delete_button);
            set_child(content);
            set_activatable(false);

            // User insertions originate on Gtk.Entry's delegate, not the wrapper.
            name_entry.get_delegate().insert_text.connect(on_name_inserted);
        }

        public void set_assignment(EnvAssignment assignment) {
            applying_assignment = true;
            name_entry.text = assignment.name;
            value_entry.text = assignment.value;
            applying_assignment = false;
        }

        public void restore_name() {
            // GTK deletes a selection before insert-text, but emits changed after
            // the complete paste. Keep invalid assignments from erasing that name.
            var name = previous_name;
            applying_assignment = true;
            name_entry.text = name;
            applying_assignment = false;
        }

        private void on_name_inserted(string text, int length, ref int position) {
            if (applying_assignment) return;
            var inserted = length < 0 ? text : text.substring(0, length);
            if (!EnvVarPaste.looks_like_assignment(inserted)) return;
            Signal.stop_emission_by_name(name_entry.get_delegate(), "insert-text");
            paste_requested(this, inserted);
            position = name_entry.text.char_count();
        }

        private Gtk.Entry create_entry(string placeholder) {
            var entry = new Gtk.Entry();
            entry.set_placeholder_text(placeholder);
            entry.set_hexpand(true);
            var focus = new Gtk.EventControllerFocus();
            focus.leave.connect(() => { committed(); });
            entry.add_controller(focus);
            entry.activate.connect(() => { committed(); });
            return entry;
        }
    }
}
