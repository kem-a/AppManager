using AppManager.Core;
using AppManager.Utils;

namespace AppManager {
    public class DetailsWindow : Adw.NavigationPage {
        private InstallationRecord record;
        private InstallationRegistry registry;
        private bool update_available;
        private Adw.ButtonRow? update_action_row;
        
        public signal void uninstall_requested(InstallationRecord record);
        public signal void update_requested(InstallationRecord record);
        public signal void check_update_requested(InstallationRecord record);
        public signal void extract_requested(InstallationRecord record);

        public DetailsWindow(InstallationRecord record, InstallationRegistry registry, bool update_available = false) {
            Object(title: record.name, tag: record.id);
            this.record = record;
            this.registry = registry;
            this.update_available = update_available;
            this.can_pop = true;
            
            build_ui();
        }

        public bool matches_record(InstallationRecord other) {
            return record.id == other.id;
        }

        public void set_update_available(bool available) {
            update_available = available;
            refresh_update_action_row();
        }

        private void build_ui() {
            var detail_page = new Adw.PreferencesPage();
            
            // Header group with icon, name, and version
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
            var version_label = new Gtk.Label(record.version ?? I18n.tr("Version unknown"));
            version_label.add_css_class("dim-label");
            header_box.append(version_label);
            
            var header_row = new Adw.PreferencesRow();
            header_row.set_activatable(false);
            header_row.set_child(header_box);
            header_group.add(header_row);
            detail_page.add(header_group);
            
            // Load desktop file properties early for Terminal and NoDisplay checks
            var desktop_props = load_desktop_file_properties(record.desktop_file);
            
            // Cards group - adding box directly without PreferencesRow wrapper
            var cards_group = new Adw.PreferencesGroup();
            
            // Cards container (displayed without background)
            var cards_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            cards_box.set_halign(Gtk.Align.CENTER);
            
            // Install mode card
            var mode_button = new Gtk.Button();
            mode_button.add_css_class("card");
            if (record.mode == InstallMode.EXTRACTED) {
                mode_button.add_css_class("accent");
            }
            mode_button.set_valign(Gtk.Align.CENTER);
            mode_button.set_tooltip_text(I18n.tr("Show in Files"));

            var mode_label = new Gtk.Label(record.mode == InstallMode.PORTABLE ? I18n.tr("Portable") : I18n.tr("Extracted"));
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
            
            // Terminal app card (only show if Terminal=true)
            var terminal_value = desktop_props.get("Terminal") ?? "false";
            if (terminal_value.down() == "true") {
                var terminal_card = create_info_card(I18n.tr("Terminal"));
                terminal_card.add_css_class("terminal");
                cards_box.append(terminal_card);
            }
            
            // Hidden from app drawer card (only show if NoDisplay=true)
            var nodisplay_value = desktop_props.get("NoDisplay") ?? "false";
            if (nodisplay_value.down() == "true") {
                var hidden_card = create_info_card(I18n.tr("Hidden"));
                cards_box.append(hidden_card);
            }

            // Add the box directly - it will be added to a separate box without the list background
            cards_group.add(cards_box);
            detail_page.add(cards_group);
            
            // Properties group
            var props_group = new Adw.PreferencesGroup();
            props_group.title = I18n.tr("Properties");
            
            // Command line arguments (extracted from Exec field)
            var exec_row = new Adw.EntryRow();
            exec_row.title = I18n.tr("Command line arguments");
            var full_exec = desktop_props.get("Exec") ?? "";
            var exec_args = extract_exec_arguments(full_exec);
            exec_row.text = exec_args;
            exec_row.changed.connect(() => {
                // Append new arguments to the existing Exec command
                var base_exec = get_base_exec_command(full_exec);
                var new_args = exec_row.text.strip();
                var updated_exec = new_args.length > 0 ? base_exec + " " + new_args : base_exec;
                update_desktop_file_property(record.desktop_file, "Exec", updated_exec);
            });
            props_group.add(exec_row);
            
            // Web page address
            var webpage_row = new Adw.EntryRow();
            webpage_row.title = I18n.tr("Web Page");
            webpage_row.text = desktop_props.get("X-AppImage-Homepage") ?? "";
            webpage_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "X-AppImage-Homepage", webpage_row.text);
            });
            
            // Add open button for web page
            var open_web_button = new Gtk.Button.from_icon_name("external-link-symbolic");
            open_web_button.add_css_class("flat");
            open_web_button.set_valign(Gtk.Align.CENTER);
            open_web_button.tooltip_text = I18n.tr("Open web page");
            open_web_button.clicked.connect(() => {
                var url = webpage_row.text.strip();
                if (url.length > 0) {
                    UiUtils.open_url(url);
                }
            });
            webpage_row.add_suffix(open_web_button);
            
            // Update address (placeholder for future use)
            var update_row = new Adw.EntryRow();
            update_row.title = I18n.tr("Update Link");
            update_row.text = desktop_props.get("X-AppImage-UpdateURL") ?? "";
            update_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "X-AppImage-UpdateURL", update_row.text);
            });
            
            // Update info group holds links that users might want to copy quickly
            var update_group = new Adw.PreferencesGroup();
            update_group.title = I18n.tr("Update info");
            var update_info_button = new Gtk.Button.from_icon_name("dialog-information-symbolic");
                update_info_button.add_css_class("circular");
                update_info_button.add_css_class("flat");
                update_info_button.set_valign(Gtk.Align.CENTER);
                update_info_button.tooltip_text = I18n.tr("How update links work");
                update_info_button.clicked.connect(() => {
                    show_update_info_help();
                });
                update_group.set_header_suffix(update_info_button);
            update_group.add(update_row);
            update_group.add(webpage_row);

            // Advanced
            var advanced_group = new Adw.ExpanderRow();
            advanced_group.title = I18n.tr("Advanced");
            props_group.add(advanced_group);

            // Keywords live in the advanced section to keep the primary view simple
            var keywords_row = new Adw.EntryRow();
            keywords_row.title = I18n.tr("Keywords");
            keywords_row.text = desktop_props.get("Keywords") ?? "";
            keywords_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "Keywords", keywords_row.text);
            });
            advanced_group.add_row(keywords_row);

            // Icon
            var icon_row = new Adw.EntryRow();
            icon_row.title = I18n.tr("Icon name");
            icon_row.text = desktop_props.get("Icon") ?? "";
            icon_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "Icon", icon_row.text);
            });
            advanced_group.add_row(icon_row);
            
            // StartupWMClass
            var wmclass_row = new Adw.EntryRow();
            wmclass_row.title = I18n.tr("Startup WM Class");
            wmclass_row.text = desktop_props.get("StartupWMClass") ?? "";
            wmclass_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "StartupWMClass", wmclass_row.text);
            });
            advanced_group.add_row(wmclass_row);

            // Version
            var version_row = new Adw.EntryRow();
            version_row.title = I18n.tr("Version");
            version_row.text = desktop_props.get("X-AppImage-Version") ?? "";
            version_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "X-AppImage-Version", version_row.text);
                // Update the record version and re-register to save
                record.version = version_row.text;
                registry.register(record);
            });
            advanced_group.add_row(version_row);
            
            // NoDisplay toggle
            var nodisplay_row = new Adw.SwitchRow();
            nodisplay_row.title = I18n.tr("Hide from app drawer");
            nodisplay_row.subtitle = I18n.tr("Don't show in application menu");
            var nodisplay_current = desktop_props.get("NoDisplay") ?? "false";
            nodisplay_row.active = (nodisplay_current.down() == "true");
            nodisplay_row.notify["active"].connect(() => {
                update_desktop_file_property(record.desktop_file, "NoDisplay", nodisplay_row.active ? "true" : "false");
            });
            advanced_group.add_row(nodisplay_row);
            
            detail_page.add(props_group);
            detail_page.add(update_group);
            
            // Actions group
            var actions_group = new Adw.PreferencesGroup();
            actions_group.title = I18n.tr("Actions");
            
            var actions_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            actions_group.add(actions_box);

            // Update Action
            update_action_row = new Adw.ButtonRow();
            // Icon will be set in refresh_update_action_row
            update_action_row.activated.connect(() => {
                if (update_available) {
                    update_requested(record);
                } else {
                    check_update_requested(record);
                }
            });
            actions_box.append(create_list_box_for_row(update_action_row));
            refresh_update_action_row();

            // Only show extract action for non-terminal, portable installs
            if (record.mode == InstallMode.PORTABLE && (desktop_props.get("Terminal") ?? "false").down() != "true") {
                var extract_row = new Adw.ButtonRow();
                extract_row.title = I18n.tr("Extract AppImage");
                extract_row.sensitive = true;
                extract_row.activated.connect(() => {
                    if (extract_row.get_sensitive()) {
                        present_extract_warning();
                    }
                });
                actions_box.append(create_list_box_for_row(extract_row));
            }
            
            var delete_row = new Adw.ButtonRow();
            delete_row.title = I18n.tr("Move to Trash");
            delete_row.start_icon_name = "user-trash-symbolic";
            delete_row.add_css_class("destructive-action");
            delete_row.activated.connect(() => {
                uninstall_requested(record);
            });
            
            actions_box.append(create_list_box_for_row(delete_row));
            detail_page.add(actions_group);
            
            var toolbar = new Adw.ToolbarView();
            var header = new Adw.HeaderBar();
            toolbar.add_top_bar(header);
            toolbar.set_content(detail_page);
            this.child = toolbar;
        }

        private void refresh_update_action_row() {
            if (update_action_row == null) {
                return;
            }

            if (update_available) {
                update_action_row.title = I18n.tr("Update");
                update_action_row.start_icon_name = "software-update-available-symbolic";
                update_action_row.add_css_class("suggested-action");
            } else {
                update_action_row.title = I18n.tr("Check Update");
                update_action_row.start_icon_name = null;
                update_action_row.remove_css_class("suggested-action");
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
                    var icon_file = File.new_for_path(record.icon_path);
                    if (icon_file.query_exists()) {
                        var info = icon_file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                        total_size += info.get_size();
                    }
                }
                
                // Add desktop file size
                if (record.desktop_file != null && record.desktop_file != "") {
                    var desktop_file = File.new_for_path(record.desktop_file);
                    if (desktop_file.query_exists()) {
                        var info = desktop_file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                        total_size += info.get_size();
                    }
                }
            } catch (Error e) {
                warning("Failed to calculate size for %s: %s", record.name, e.message);
            }
            
            return total_size;
        }

        private void show_update_info_help() {
            var body = I18n.tr("Update info lets AppManager fetch new builds for you. Paste the direct download link from your latest release, and the app will poll it for newer AppImages.");
            body += "\n\n" + I18n.tr("Currently only GitHub and GitLab release URLs are supported, so copy the link you normally use to download updates and AppManager will do the rest.");
            var dialog = new Adw.AlertDialog(I18n.tr("Update links"), body);
            dialog.add_response("close", I18n.tr("Got it"));
            dialog.set_close_response("close");
            dialog.present(this);
        }

        private HashTable<string, string> load_desktop_file_properties(string desktop_file_path) {
            var props = new HashTable<string, string>(str_hash, str_equal);
            
            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(desktop_file_path, KeyFileFlags.NONE);
                
                string[] keys = {"Exec", "Icon", "X-AppImage-Version", "StartupWMClass", "Keywords", "X-AppImage-Homepage", "X-AppImage-UpdateURL", "Terminal", "NoDisplay"};
                foreach (var key in keys) {
                    try {
                        var value = keyfile.get_string("Desktop Entry", key);
                        props.set(key, value);
                    } catch (Error e) {
                        // Key doesn't exist, that's okay
                    }
                }
            } catch (Error e) {
                warning("Failed to load desktop file %s: %s", desktop_file_path, e.message);
            }
            
            return props;
        }
        
        private string extract_exec_arguments(string exec_command) {
            // Extract only the arguments from Exec field, not the executable path
            // The first token (before the first space) is the executable, rest are arguments
            var trimmed = exec_command.strip();
            if (trimmed.length == 0) {
                return "";
            }
            
            // Find first unquoted space
            int first_space = -1;
            bool in_quotes = false;
            for (int i = 0; i < trimmed.length; i++) {
                if (trimmed[i] == '"') {
                    in_quotes = !in_quotes;
                } else if (trimmed[i] == ' ' && !in_quotes) {
                    first_space = i;
                    break;
                }
            }
            
            if (first_space == -1) {
                // No arguments, just the executable
                return "";
            }
            
            // Return everything after the first space
            return trimmed.substring(first_space + 1).strip();
        }
        
        private string get_base_exec_command(string exec_command) {
            // Extract only the base executable path from Exec field (first token)
            var trimmed = exec_command.strip();
            if (trimmed.length == 0) {
                return "";
            }
            
            // Find first unquoted space
            int first_space = -1;
            bool in_quotes = false;
            for (int i = 0; i < trimmed.length; i++) {
                if (trimmed[i] == '"') {
                    in_quotes = !in_quotes;
                } else if (trimmed[i] == ' ' && !in_quotes) {
                    first_space = i;
                    break;
                }
            }
            
            if (first_space == -1) {
                // No arguments, return the whole thing
                return trimmed;
            }
            
            // Return only the executable part
            return trimmed.substring(0, first_space);
        }
        
        private void update_desktop_file_property(string desktop_file_path, string key, string value) {
            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(desktop_file_path, KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS);
                
                if (value.strip() == "") {
                    // Remove key if value is empty
                    try {
                        keyfile.remove_key("Desktop Entry", key);
                    } catch (Error e) {
                        // Key might not exist, that's fine
                    }
                } else {
                    keyfile.set_string("Desktop Entry", key, value);
                }
                
                // Save the file
                var data = keyfile.to_data();
                GLib.FileUtils.set_contents(desktop_file_path, data);
                debug("Updated desktop file property %s = %s", key, value);
            } catch (Error e) {
                warning("Failed to update desktop file %s: %s", desktop_file_path, e.message);
            }
        }

        private Gtk.ListBox create_list_box_for_row(Adw.ButtonRow row) {
            var list = new Gtk.ListBox();
            list.add_css_class("boxed-list");
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.append(row);
            return list;
        }

        private void present_extract_warning() {
            var body = I18n.tr("Extracting will unpack the application so it opens faster, but it will consume more disk space. This action cannot be reversed automatically.");
            var dialog = new Adw.AlertDialog(I18n.tr("Extract application?"), body);
            dialog.add_response("cancel", I18n.tr("Cancel"));
            dialog.add_response("extract", I18n.tr("Extract"));
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
    }
}
