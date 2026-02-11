using AppManager.Core;
using AppManager.Utils;
using Gee;

namespace AppManager {
    public class DetailsWindow : Adw.NavigationPage {
        private InstallationRecord record;
        private InstallationRegistry registry;
        private Installer installer;
        private bool update_available;
        private bool update_loading = false;
        private bool update_updating = false;  // true when actually updating (vs just checking)
        private Gtk.Button? update_button;
        private Gtk.Spinner? update_spinner;
        private Gtk.Button? extract_button;
        private Adw.Banner? path_banner;
        private Adw.SwitchRow? path_row;
        
        // Shared state for build_ui sub-methods
        private string exec_path;
        private HashTable<string, string> desktop_props;
        
        public signal void uninstall_requested(InstallationRecord record);
        public signal void update_requested(InstallationRecord record);
        public signal void check_update_requested(InstallationRecord record);
        public signal void extract_requested(InstallationRecord record);

        public DetailsWindow(InstallationRecord record, InstallationRegistry registry, Installer installer, bool update_available = false) {
            Object(title: record.name, tag: record.id);
            this.record = record;
            this.registry = registry;
            this.installer = installer;
            this.update_available = update_available;
            this.can_pop = true;
            
            build_ui();
        }

        public bool matches_record(InstallationRecord other) {
            // Compare by name (case-insensitive) since ID is checksum and changes after update
            return record.name.down() == other.name.down();
        }

        public void set_update_available(bool available) {
            update_available = available;
            refresh_update_button();
        }

        public void set_update_loading(bool loading) {
            update_loading = loading;
            refresh_update_button();
        }

        public void set_update_updating(bool updating) {
            update_updating = updating;
            refresh_update_button();
        }

        public void refresh_with_record(InstallationRecord updated_record) {
            this.record = updated_record;
            // Rebuild the entire UI with fresh data
            this.child = null;
            build_ui();
        }

        private void persist_record_and_refresh_desktop() {
            registry.update(record);
            installer.apply_record_customizations_to_desktop(record);
        }

        private void build_ui() {
            // Initialize shared state
            desktop_props = load_desktop_file_properties(record.desktop_file);
            exec_path = installer.resolve_exec_path_for_record(record);
            
            var detail_page = new Adw.PreferencesPage();
            
            // Build UI sections
            detail_page.add(build_header_group());
            detail_page.add(build_cards_group());
            
            var props_group = build_properties_group();
            var update_group = build_update_info_group();
            var advanced_group = build_advanced_group();
            var env_vars_group = build_env_vars_group();
            props_group.add(advanced_group);
            props_group.add(env_vars_group);
            
            detail_page.add(props_group);
            detail_page.add(update_group);
            detail_page.add(build_actions_group());
            
            // Assemble final layout
            var toolbar = new Adw.ToolbarView();
            var header = new Adw.HeaderBar();
            toolbar.add_top_bar(header);

            var content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

            path_banner = new Adw.Banner(_("⚠️ '%s' is not in $PATH. App will not launch from the terminal").printf(AppPaths.local_bin_dir));
            content_box.append(path_banner);
            update_path_banner_visibility();

            content_box.append(detail_page);
            toolbar.set_content(content_box);
            this.child = toolbar;
        }

        private Adw.PreferencesGroup build_header_group() {
            var header_group = new Adw.PreferencesGroup();
            
            var header_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            header_box.set_halign(Gtk.Align.CENTER);
            header_box.set_margin_top(24);
            header_box.set_margin_bottom(12);
            
            // App icon
            if (record.icon_path != null && record.icon_path.strip() != "") {
                var icon_image = UiUtils.load_app_icon(record.icon_path);
                if (icon_image != null) {
                    icon_image.set_pixel_size(128);
                    header_box.append(icon_image);
                }
            }
            
            // App name
            var name_label = new Gtk.Label(record.name);
            name_label.add_css_class("title-1");
            name_label.set_wrap(true);
            name_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            name_label.set_justify(Gtk.Justification.CENTER);
            header_box.append(name_label);
            
            // App version
            var version_label = new Gtk.Label(record.version ?? _("Version unknown"));
            version_label.add_css_class("dim-label");
            header_box.append(version_label);
            
            var header_row = new Adw.PreferencesRow();
            header_row.set_activatable(false);
            header_row.set_child(header_box);
            header_group.add(header_row);
            
            return header_group;
        }

        private Adw.PreferencesGroup build_cards_group() {
            var cards_group = new Adw.PreferencesGroup();
            
            var cards_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            cards_box.set_halign(Gtk.Align.CENTER);
            
            // Install mode card
            var mode_button = new Gtk.Button();
            mode_button.add_css_class("card");
            if (record.mode == InstallMode.EXTRACTED) {
                mode_button.add_css_class("accent");
            }
            mode_button.set_valign(Gtk.Align.CENTER);
            mode_button.set_tooltip_text(_("Show in Files"));

            var mode_label = new Gtk.Label(record.mode == InstallMode.PORTABLE ? _("Portable") : _("Extracted"));
            mode_label.add_css_class("caption");
            mode_label.set_margin_start(8);
            mode_label.set_margin_end(8);
            mode_label.set_margin_top(6);
            mode_label.set_margin_bottom(6);
            mode_button.set_child(mode_label);

            mode_button.clicked.connect(() => {
                var parent_window = this.get_root() as Gtk.Window;
                var target_path = determine_reveal_path();
                UiUtils.open_folder(target_path, parent_window);
            });
            cards_box.append(mode_button);
            
            // Size on disk card
            var size = calculate_installation_size(record);
            var size_card = create_info_card(UiUtils.format_size(size));
            cards_box.append(size_card);
            
            // Terminal app card (only show if is_terminal)
            if (record.is_terminal) {
                var terminal_card = create_info_card(_("Terminal"));
                terminal_card.add_css_class("terminal");
                cards_box.append(terminal_card);
            }
            
            // Zsync delta updates badge (only show if app supports zsync)
            if (record.zsync_update_info != null && record.zsync_update_info.strip() != "") {
                var zsync_card = create_info_card("Zsync");
                zsync_card.set_tooltip_text(_("This app supports efficient delta updates"));
                cards_box.append(zsync_card);
            }
            
            // Hidden from app drawer card (only show if NoDisplay=true)
            var nodisplay_value = desktop_props.get("NoDisplay") ?? "false";
            if (nodisplay_value.down() == "true") {
                var hidden_card = create_info_card(_("Hidden"));
                cards_box.append(hidden_card);
            }

            cards_group.add(cards_box);
            return cards_group;
        }

        private Adw.PreferencesGroup build_properties_group() {
            var props_group = new Adw.PreferencesGroup();
            props_group.title = _("Properties");
            
            // Command line arguments
            var current_args = record.get_effective_commandline_args() ?? "";
            var exec_row = new Adw.EntryRow();
            exec_row.title = _("Command line arguments");
            exec_row.text = current_args;
            
            var restore_exec_button = create_restore_button(record.custom_commandline_args != null);
            restore_exec_button.clicked.connect(() => {
                record.custom_commandline_args = null;
                exec_row.text = record.original_commandline_args ?? "";
                persist_record_and_refresh_desktop();
                restore_exec_button.set_visible(false);
            });
            exec_row.add_suffix(restore_exec_button);
            
            exec_row.changed.connect(() => {
                var new_val = exec_row.text.strip();
                var original_val = record.original_commandline_args ?? "";
                if (new_val == original_val) {
                    record.custom_commandline_args = null;
                } else if (new_val == "") {
                    record.custom_commandline_args = CLEARED_VALUE;
                } else {
                    record.custom_commandline_args = new_val;
                }
                persist_record_and_refresh_desktop();
                restore_exec_button.set_visible(record.custom_commandline_args != null);
            });
            props_group.add(exec_row);
            
            return props_group;
        }

        private Adw.PreferencesGroup build_update_info_group() {
            var update_group = new Adw.PreferencesGroup();
            update_group.title = _("Update info");
            
            var update_info_button = new Gtk.Button.from_icon_name("dialog-information-symbolic");
            update_info_button.add_css_class("circular");
            update_info_button.add_css_class("flat");
            update_info_button.set_valign(Gtk.Align.CENTER);
            update_info_button.tooltip_text = _("How update links work");
            update_info_button.clicked.connect(() => {
                show_update_info_help();
            });
            update_group.set_header_suffix(update_info_button);
            
            // Update link row
            var update_row = build_update_link_row();
            update_group.add(update_row);
            
            // Web page row
            var webpage_row = build_webpage_row();
            update_group.add(webpage_row);
            
            return update_group;
        }

        private Adw.EntryRow build_update_link_row() {
            var update_row = new Adw.EntryRow();
            update_row.title = _("Update Link");
            update_row.text = record.get_effective_update_link() ?? "";
            
            var restore_update_button = create_restore_button(record.custom_update_link != null);
            restore_update_button.clicked.connect(() => {
                record.custom_update_link = null;
                update_row.text = record.original_update_link ?? "";
                persist_record_and_refresh_desktop();
                restore_update_button.set_visible(false);
            });
            update_row.add_suffix(restore_update_button);
            
            // Normalize URL when user leaves the entry or presses Enter
            var focus_controller = new Gtk.EventControllerFocus();
            focus_controller.leave.connect(() => {
                apply_update_link_value(update_row, restore_update_button);
            });
            update_row.add_controller(focus_controller);
            
            update_row.entry_activated.connect(() => {
                apply_update_link_value(update_row, restore_update_button);
            });
            
            return update_row;
        }

        private void apply_update_link_value(Adw.EntryRow row, Gtk.Button restore_button) {
            var raw_val = row.text.strip();
            var normalized = Updater.normalize_update_url(raw_val);
            var new_val = normalized ?? raw_val;
            
            if (new_val != raw_val && new_val != "") {
                row.text = new_val;
            }
            
            var original_val = record.original_update_link ?? "";
            if (new_val == original_val) {
                record.custom_update_link = null;
            } else if (new_val == "") {
                record.custom_update_link = CLEARED_VALUE;
            } else {
                record.custom_update_link = new_val;
            }
            persist_record_and_refresh_desktop();
            restore_button.set_visible(record.custom_update_link != null);
        }

        private Adw.EntryRow build_webpage_row() {
            var webpage_row = new Adw.EntryRow();
            webpage_row.title = _("Web Page");
            webpage_row.text = record.get_effective_web_page() ?? "";
            
            var restore_webpage_button = create_restore_button(record.custom_web_page != null);
            restore_webpage_button.clicked.connect(() => {
                record.custom_web_page = null;
                webpage_row.text = record.original_web_page ?? "";
                persist_record_and_refresh_desktop();
                restore_webpage_button.set_visible(false);
            });
            webpage_row.add_suffix(restore_webpage_button);
            
            webpage_row.changed.connect(() => {
                var new_val = webpage_row.text.strip();
                var original_val = record.original_web_page ?? "";
                if (new_val == original_val) {
                    record.custom_web_page = null;
                } else if (new_val == "") {
                    record.custom_web_page = CLEARED_VALUE;
                } else {
                    record.custom_web_page = new_val;
                }
                persist_record_and_refresh_desktop();
                restore_webpage_button.set_visible(record.custom_web_page != null);
            });
            
            var open_web_button = new Gtk.Button.from_icon_name("external-link-symbolic");
            open_web_button.add_css_class("flat");
            open_web_button.set_valign(Gtk.Align.CENTER);
            open_web_button.tooltip_text = _("Open web page");
            open_web_button.clicked.connect(() => {
                var url = webpage_row.text.strip();
                if (url.length > 0) {
                    UiUtils.open_url(url);
                }
            });
            webpage_row.add_suffix(open_web_button);
            
            return webpage_row;
        }

        private Adw.ExpanderRow build_advanced_group() {
            var advanced_group = new Adw.ExpanderRow();
            advanced_group.title = _("Advanced");

            // Keywords
            advanced_group.add_row(build_keywords_row());
            
            // Icon name
            advanced_group.add_row(build_icon_row());
            
            // StartupWMClass
            advanced_group.add_row(build_wmclass_row());
            
            // Version
            advanced_group.add_row(build_version_row());
            
            // NoDisplay toggle
            advanced_group.add_row(build_nodisplay_row());
            
            // Add to PATH toggle
            advanced_group.add_row(build_path_row());
            
            return advanced_group;
        }

        private const int MAX_ENV_VARS = 5;

        private Adw.ExpanderRow build_env_vars_group() {
            var env_expander = new Adw.ExpanderRow();
            env_expander.title = _("Environment Variables");
            env_expander.subtitle = _("Set custom environment variables for this app");

            // Load existing env vars
            var env_vars = record.custom_env_vars ?? new string[0];

            // Track all env var rows for management
            var env_rows = new Gee.ArrayList<Gtk.Widget>();

            // Helper to rebuild the record's env vars from current rows
            void save_env_vars_from_rows() {
                var new_env_vars = new Gee.ArrayList<string>();
                foreach (var widget in env_rows) {
                    if (widget is Adw.ActionRow) {
                        var row = (Adw.ActionRow) widget;
                        var box = row.get_child() as Gtk.Box;
                        if (box != null) {
                            string? name_val = null;
                            string? value_val = null;
                            var child = box.get_first_child();
                            while (child != null) {
                                if (child is Gtk.Entry) {
                                    var entry = (Gtk.Entry) child;
                                    if (name_val == null) {
                                        name_val = entry.text.strip();
                                    } else {
                                        value_val = entry.text.strip();
                                    }
                                }
                                child = child.get_next_sibling();
                            }
                            if (name_val != null && name_val != "") {
                                var env_str = "%s=%s".printf(name_val, value_val ?? "");
                                new_env_vars.add(env_str);
                            }
                        }
                    }
                }
                record.custom_env_vars = new_env_vars.size > 0 ? new_env_vars.to_array() : null;
                persist_record_and_refresh_desktop();
            }

            // Create a row for a single env var
            Adw.ActionRow create_env_var_row(string? initial_name, string? initial_value, Gtk.Button add_button) {
                var row = new Adw.ActionRow();
                
                var content_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                content_box.set_margin_top(8);
                content_box.set_margin_bottom(8);
                content_box.set_margin_start(12);
                content_box.set_margin_end(12);
                content_box.set_hexpand(true);
                
                var name_entry = new Gtk.Entry();
                name_entry.set_placeholder_text(_("NAME"));
                name_entry.set_hexpand(true);
                name_entry.set_max_length(64);
                name_entry.text = initial_name ?? "";
                name_entry.changed.connect(() => {
                    save_env_vars_from_rows();
                });
                content_box.append(name_entry);
                
                var equals_label = new Gtk.Label("=");
                equals_label.add_css_class("dim-label");
                content_box.append(equals_label);
                
                var value_entry = new Gtk.Entry();
                value_entry.set_placeholder_text(_("value"));
                value_entry.set_hexpand(true);
                value_entry.set_max_length(256);
                value_entry.text = initial_value ?? "";
                value_entry.changed.connect(() => {
                    save_env_vars_from_rows();
                });
                content_box.append(value_entry);
                
                var delete_button = new Gtk.Button.from_icon_name("user-trash-symbolic");
                delete_button.add_css_class("flat");
                delete_button.set_valign(Gtk.Align.CENTER);
                delete_button.tooltip_text = _("Remove variable");
                delete_button.clicked.connect(() => {
                    env_rows.remove(row);
                    env_expander.remove(row);
                    save_env_vars_from_rows();
                    // Re-enable add button if under limit
                    if (env_rows.size < MAX_ENV_VARS) {
                        add_button.sensitive = true;
                    }
                });
                content_box.append(delete_button);
                
                row.set_child(content_box);
                row.set_activatable(false);
                
                return row;
            }

            // Add button row
            var add_row = new Adw.ActionRow();
            add_row.set_activatable(false);
            
            var add_button = new Gtk.Button.from_icon_name("list-add-symbolic");
            add_button.add_css_class("flat");
            add_button.set_halign(Gtk.Align.CENTER);
            add_button.set_margin_top(8);
            add_button.set_margin_bottom(8);
            
            // Populate existing env vars
            foreach (var env_var in env_vars) {
                if (env_var == null || env_var.strip() == "") continue;
                var eq_pos = env_var.index_of_char('=');
                string name_part = "";
                string value_part = "";
                if (eq_pos >= 0) {
                    name_part = env_var.substring(0, eq_pos);
                    value_part = env_var.substring(eq_pos + 1);
                } else {
                    name_part = env_var;
                }
                var row = create_env_var_row(name_part, value_part, add_button);
                env_rows.add(row);
                env_expander.add_row(row);
            }

            // Update add button sensitivity
            add_button.sensitive = env_rows.size < MAX_ENV_VARS;
            
            add_button.clicked.connect(() => {
                if (env_rows.size >= MAX_ENV_VARS) {
                    return;
                }
                var row = create_env_var_row(null, null, add_button);
                env_rows.add(row);
                // Remove add_row, add new row, re-add add_row to keep button at bottom
                env_expander.remove(add_row);
                env_expander.add_row(row);
                env_expander.add_row(add_row);
                // Disable add button if at limit
                if (env_rows.size >= MAX_ENV_VARS) {
                    add_button.sensitive = false;
                }
            });
            
            var add_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            add_box.set_halign(Gtk.Align.CENTER);
            add_box.set_hexpand(true);
            add_box.append(add_button);
            add_row.set_child(add_box);
            
            env_expander.add_row(add_row);
            
            return env_expander;
        }

        /**
         * Delegate types for customizable entry row fields.
         */
        private delegate string? GetEffectiveFunc();
        private delegate string? GetOriginalFunc();
        private delegate string? GetCustomFunc();
        private delegate void SetCustomFunc(string? val);

        /**
         * Generic factory for entry rows with restore button and change tracking.
         */
        private Adw.EntryRow build_customizable_entry_row(
            string title,
            GetEffectiveFunc get_effective,
            GetOriginalFunc get_original,
            GetCustomFunc get_custom,
            SetCustomFunc set_custom
        ) {
            var row = new Adw.EntryRow();
            row.title = title;
            row.text = get_effective() ?? "";
            
            var restore_button = create_restore_button(get_custom() != null);
            restore_button.clicked.connect(() => {
                set_custom(null);
                row.text = get_original() ?? "";
                persist_record_and_refresh_desktop();
                restore_button.set_visible(false);
            });
            row.add_suffix(restore_button);
            
            row.changed.connect(() => {
                var new_val = row.text.strip();
                var original_val = get_original() ?? "";
                if (new_val == original_val) {
                    set_custom(null);
                } else if (new_val == "") {
                    set_custom(CLEARED_VALUE);
                } else {
                    set_custom(new_val);
                }
                persist_record_and_refresh_desktop();
                restore_button.set_visible(get_custom() != null);
            });
            
            return row;
        }

        private Adw.EntryRow build_keywords_row() {
            return build_customizable_entry_row(
                _("Keywords"),
                () => record.get_effective_keywords(),
                () => record.original_keywords,
                () => record.custom_keywords,
                (v) => { record.custom_keywords = v; }
            );
        }

        private Adw.EntryRow build_icon_row() {
            return build_customizable_entry_row(
                _("Icon name"),
                () => record.get_effective_icon_name(),
                () => record.original_icon_name,
                () => record.custom_icon_name,
                (v) => { record.custom_icon_name = v; }
            );
        }

        private Adw.EntryRow build_wmclass_row() {
            return build_customizable_entry_row(
                _("Startup WM Class"),
                () => record.get_effective_startup_wm_class(),
                () => record.original_startup_wm_class,
                () => record.custom_startup_wm_class,
                (v) => { record.custom_startup_wm_class = v; }
            );
        }

        private Adw.EntryRow build_version_row() {
            var version_row = new Adw.EntryRow();
            version_row.title = _("Version");
            version_row.text = record.version ?? "";
            version_row.changed.connect(() => {
                record.version = version_row.text.strip() == "" ? null : version_row.text;
                registry.update(record);
                installer.set_desktop_entry_property(record.desktop_file, "X-AppImage-Version", record.version ?? "");
            });
            return version_row;
        }

        private Adw.SwitchRow build_nodisplay_row() {
            var nodisplay_row = new Adw.SwitchRow();
            nodisplay_row.title = _("Hide from app drawer");
            nodisplay_row.subtitle = _("Don't show in application menu");
            var nodisplay_current = desktop_props.get("NoDisplay") ?? "false";
            nodisplay_row.active = (nodisplay_current.down() == "true");
            nodisplay_row.notify["active"].connect(() => {
                installer.set_desktop_entry_property(record.desktop_file, "NoDisplay", nodisplay_row.active ? "true" : "false");
            });
            return nodisplay_row;
        }

        private Adw.SwitchRow build_path_row() {
            path_row = new Adw.SwitchRow();
            path_row.title = _("Add to $PATH");
            path_row.subtitle = _("Create a launcher in %s so you can run it from the terminal").printf(AppPaths.local_bin_dir);

            var symlink_name = "";

            if (record.entry_exec != null && record.entry_exec.strip() != "") {
                symlink_name = Path.get_basename(record.entry_exec.strip());
            }

            if (symlink_name == "" && record.installed_path != null && record.installed_path.strip() != "") {
                symlink_name = installer.derive_slug_from_path(record.installed_path, record.mode == InstallMode.EXTRACTED);
            }
            
            if (symlink_name == "") {
                symlink_name = Path.get_basename(exec_path).down();
            }

            bool is_terminal_app = record.is_terminal;
            bool symlink_exists = record.bin_symlink != null && record.bin_symlink.strip() != "" && File.new_for_path(record.bin_symlink).query_exists();

            // Terminal apps must always stay on PATH
            if (is_terminal_app && !symlink_exists) {
                if (installer.ensure_bin_symlink_for_record(record, exec_path, symlink_name)) {
                    symlink_exists = true;
                }
            }

            // Clean up stale metadata if the recorded symlink is gone
            if (!is_terminal_app && record.bin_symlink != null && !symlink_exists) {
                installer.remove_bin_symlink_for_record(record);
            }

            path_row.active = is_terminal_app || symlink_exists;
            path_row.sensitive = !is_terminal_app;

            path_row.notify["active"].connect(() => {
                if (is_terminal_app) {
                    path_row.active = true;
                    return;
                }

                if (path_row.active) {
                    if (installer.ensure_bin_symlink_for_record(record, exec_path, symlink_name)) {
                        symlink_exists = true;
                    } else {
                        path_row.active = false;
                    }
                } else {
                    if (installer.remove_bin_symlink_for_record(record)) {
                        symlink_exists = false;
                    } else {
                        path_row.active = true;
                    }
                }
                update_path_banner_visibility();
            });
            
            return path_row;
        }

        private Adw.PreferencesGroup build_actions_group() {
            var actions_group = new Adw.PreferencesGroup();
            actions_group.title = _("Actions");
            
            var actions_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            actions_box.set_halign(Gtk.Align.CENTER);
            actions_group.add(actions_box);

            // First row: Update and Extract buttons
            var row1 = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            row1.set_halign(Gtk.Align.CENTER);

            // Update button with spinner overlay
            var update_wrapper = new Gtk.Overlay();
            update_button = new Gtk.Button();
            update_button.add_css_class("pill");
            update_button.width_request = 200;
            update_button.hexpand = false;
            update_button.clicked.connect(() => {
                if (update_loading) {
                    return;
                }
                if (update_available) {
                    update_requested(record);
                } else {
                    check_update_requested(record);
                }
            });
            update_wrapper.set_child(update_button);
            
            update_spinner = new Gtk.Spinner();
            update_spinner.valign = Gtk.Align.CENTER;
            update_spinner.halign = Gtk.Align.START;
            update_spinner.margin_start = 12;
            update_spinner.visible = false;
            update_wrapper.add_overlay(update_spinner);
            
            row1.append(update_wrapper);
            refresh_update_button();

            // Extract button
            extract_button = new Gtk.Button.with_label(_("Extract AppImage"));
            extract_button.add_css_class("pill");
            extract_button.width_request = 200;
            extract_button.hexpand = false;
            var can_extract = record.mode == InstallMode.PORTABLE && !record.is_terminal;
            extract_button.sensitive = can_extract;
            extract_button.clicked.connect(() => {
                present_extract_warning();
            });
            row1.append(extract_button);

            actions_box.append(row1);

            // Second row: Delete button
            var delete_button = new Gtk.Button();
            delete_button.add_css_class("pill");
            delete_button.width_request = 200;
            delete_button.hexpand = false;
            var delete_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            delete_box.set_halign(Gtk.Align.CENTER);
            delete_box.append(new Gtk.Image.from_icon_name("user-trash-symbolic"));
            delete_box.append(new Gtk.Label(_("Move to Trash")));
            delete_button.set_child(delete_box);
            delete_button.add_css_class("destructive-action");
            delete_button.clicked.connect(() => {
                uninstall_requested(record);
            });
            
            actions_box.append(delete_button);
            
            return actions_group;
        }

        private Gtk.Button create_restore_button(bool visible) {
            var button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            button.add_css_class("flat");
            button.set_valign(Gtk.Align.CENTER);
            button.tooltip_text = _("Restore default");
            button.set_visible(visible);
            return button;
        }

        private void refresh_update_button() {
            if (update_button == null || update_spinner == null) {
                return;
            }

            if (update_loading) {
                if (update_updating) {
                    update_button.set_label(_("Updating..."));
                } else {
                    update_button.set_label(_("Checking..."));
                }
                update_spinner.visible = true;
                update_spinner.start();
                update_button.sensitive = false;
                update_button.remove_css_class("suggested-action");
                return;
            }

            update_spinner.visible = false;
            update_spinner.stop();
            update_button.sensitive = true;
            update_updating = false;  // Reset updating state

            if (update_available) {
                var update_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                update_box.set_halign(Gtk.Align.CENTER);
                update_box.append(new Gtk.Image.from_icon_name("software-update-available-symbolic"));
                update_box.append(new Gtk.Label(_("Update")));
                update_button.set_child(update_box);
                update_button.add_css_class("suggested-action");
            } else {
                update_button.set_label(_("Check Update"));
                update_button.remove_css_class("suggested-action");
            }
        }

        private string determine_reveal_path() {
            var installed_path = record.installed_path ?? "";
            if (record.mode == InstallMode.PORTABLE) {
                return AppPaths.applications_dir;
            }
            if (installed_path.strip() == "") {
                return AppPaths.applications_dir;
            }

            var file = File.new_for_path(installed_path);
            if (!file.query_exists()) {
                return AppPaths.applications_dir;
            }
            if (file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                return installed_path;
            }

            return Path.get_dirname(installed_path);
        }

        private Gtk.Box create_info_card(string text) {
            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            card.add_css_class("card");
            
            var label = new Gtk.Label(text);
            label.add_css_class("caption");
            label.set_margin_start(8);
            label.set_margin_end(8);
            label.set_margin_top(6);
            label.set_margin_bottom(6);
            
            card.append(label);
            return card;
        }

        private int64 calculate_installation_size(InstallationRecord record) {
            int64 total_size = 0;
            
            try {
                // Add installed path size (AppImage or extracted directory)
                if (record.installed_path != null && record.installed_path != "") {
                    total_size += AppManager.Utils.FileUtils.get_path_size(record.installed_path);
                }
                
                // Add icon size if exists
                if (record.icon_path != null && record.icon_path != "") {
                    total_size += AppManager.Utils.FileUtils.get_path_size(record.icon_path);
                }
                
                // Add desktop file size
                if (record.desktop_file != null && record.desktop_file != "") {
                    total_size += AppManager.Utils.FileUtils.get_path_size(record.desktop_file);
                }
            } catch (Error e) {
                warning("Failed to calculate size for %s: %s", record.name, e.message);
            }
            
            return total_size;
        }

        private void show_update_info_help() {
            var body = _("Update info lets AppManager fetch new builds for you. Paste the download link and AppManager will do the rest.");
            body += "\n\n" + _("Currently GitHub and GitLab URL formats are fully supported. Direct download links also work if the server provides Last-Modified or Content-Length headers.");
            var dialog = new Adw.AlertDialog(_("Update links"), body);
            dialog.add_response("close", _("Got it"));
            dialog.set_close_response("close");
            dialog.present(this);
        }

        private HashTable<string, string> load_desktop_file_properties(string desktop_file_path) {
            var props = new HashTable<string, string>(str_hash, str_equal);
            
            var entry = new DesktopEntry(desktop_file_path);
            if (entry.no_display) {
                props.set("NoDisplay", "true");
            }
            
            return props;
        }
        
        private void present_extract_warning() {
            var body = _("Extracting will unpack the application so it opens faster, but it will consume more disk space. This action cannot be reversed automatically.");
            var dialog = new Adw.AlertDialog(_("Extract application?"), body);
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("extract", _("Extract"));
            dialog.set_response_appearance("extract", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_close_response("cancel");
            dialog.set_default_response("cancel");
            dialog.response.connect((response) => {
                if (response == "extract") {
                    extract_requested(record);
                }
            });
            dialog.present(this);
        }

        private void update_path_banner_visibility() {
            if (path_banner == null || path_row == null) {
                return;
            }

            bool needs_path = path_row.active;
            bool path_missing = !path_contains_local_bin();

            path_banner.set_revealed(needs_path && path_missing);
        }

        private bool path_contains_local_bin() {
            var home_bin = AppPaths.local_bin_dir;
            var home_bin_file = File.new_for_path(home_bin);
            
            // 1. Check current environment PATH
            var path_env = Environment.get_variable("PATH") ?? "";
            if (check_path_string(path_env, home_bin, home_bin_file)) {
                return true;
            }
            
            // 2. Fallback: Try to get PATH from user's shell
            try {
                string shell = Environment.get_variable("SHELL");
                if (shell == null || shell == "") {
                    shell = "/bin/sh";
                }
                
                string std_out;
                string std_err;
                int exit_status;
                
                // Use interactive login shell to ensure we get the full user configuration
                // (sources .bashrc, .zshrc, .profile, etc.)
                string[] argv = { shell, "-i", "-l", "-c", "echo $PATH" };
                
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, out std_out, out std_err, out exit_status);
                
                if (exit_status == 0 && std_out != null) {
                    if (check_path_string(std_out, home_bin, home_bin_file)) {
                        return true;
                    }
                }
            } catch (Error e) {
                warning("Failed to probe shell PATH: %s", e.message);
            }
            
            return false;
        }

        private bool check_path_string(string path_str, string home_bin, File home_bin_file) {
            foreach (var segment in path_str.split(":")) {
                var clean_segment = segment.strip();
                if (clean_segment == "") {
                    continue;
                }
                
                if (clean_segment == home_bin) {
                    return true;
                }
                
                if (File.new_for_path(clean_segment).equal(home_bin_file)) {
                    return true;
                }
            }
            return false;
        }

    }
}
