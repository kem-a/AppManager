using AppManager.Core;
using AppManager.Utils;

namespace AppManager {
    public class DetailsWindow : Adw.NavigationPage {
        private InstallationRecord record;
        private InstallationRegistry registry;
        private bool update_available;
        private bool update_loading = false;
        private Adw.ButtonRow? update_action_row;
        private Gtk.Spinner? update_spinner;
        private Gtk.ListBox? update_list;
        
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

        public void set_update_loading(bool loading) {
            update_loading = loading;
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
            
            // Extract current values from desktop file
            var exec_from_desktop = desktop_props.get("Exec") ?? "";
            var current_args = extract_exec_args(exec_from_desktop);
            var current_icon = desktop_props.get("Icon") ?? "";
            var current_keywords = desktop_props.get("Keywords") ?? "";
            var current_wmclass = desktop_props.get("StartupWMClass") ?? "";
            
            // Command line arguments (loaded from .desktop file)
            var exec_row = new Adw.EntryRow();
            exec_row.title = I18n.tr("Command line arguments");
            exec_row.text = current_args;
            
            // Restore defaults button for command line args - visible when custom value is set
            var restore_exec_button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            restore_exec_button.add_css_class("flat");
            restore_exec_button.set_valign(Gtk.Align.CENTER);
            restore_exec_button.tooltip_text = I18n.tr("Restore default");
            restore_exec_button.set_visible(record.custom_commandline_args != null);
            restore_exec_button.clicked.connect(() => {
                // Undo: clear custom, restore original to .desktop
                record.custom_commandline_args = null;
                registry.register(record);
                var original_val = record.original_commandline_args ?? "";
                exec_row.text = original_val;
                update_desktop_file_property(record.desktop_file, "Exec", build_exec_with_args(exec_from_desktop, original_val));
                restore_exec_button.set_visible(false);
            });
            exec_row.add_suffix(restore_exec_button);
            
            exec_row.changed.connect(() => {
                var new_val = exec_row.text.strip();
                var original_val = record.original_commandline_args ?? "";
                // Determine if value differs from original
                if (new_val == original_val) {
                    // Matches original, clear custom
                    record.custom_commandline_args = null;
                } else if (new_val == "") {
                    // User cleared the value, mark as CLEARED
                    record.custom_commandline_args = CLEARED_VALUE;
                } else {
                    // Custom value set
                    record.custom_commandline_args = new_val;
                }
                registry.register(record);
                // Update .desktop file
                update_desktop_file_property(record.desktop_file, "Exec", build_exec_with_args(exec_from_desktop, exec_row.text));
                restore_exec_button.set_visible(record.custom_commandline_args != null);
            });
            props_group.add(exec_row);
            
            // Web page address (with original/custom distinction)
            var webpage_row = new Adw.EntryRow();
            webpage_row.title = I18n.tr("Web Page");
            webpage_row.text = record.get_effective_web_page() ?? "";
            
            // Restore defaults button for web page - visible when custom value is set
            var restore_webpage_button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            restore_webpage_button.add_css_class("flat");
            restore_webpage_button.set_valign(Gtk.Align.CENTER);
            restore_webpage_button.tooltip_text = I18n.tr("Restore default");
            restore_webpage_button.set_visible(record.custom_web_page != null);
            restore_webpage_button.clicked.connect(() => {
                // Undo: clear custom, restore original to .desktop
                record.custom_web_page = null;
                registry.register(record);
                var original_val = record.original_web_page ?? "";
                webpage_row.text = original_val;
                update_desktop_file_property(record.desktop_file, "X-AppImage-Homepage", original_val);
                restore_webpage_button.set_visible(false);
            });
            webpage_row.add_suffix(restore_webpage_button);
            
            webpage_row.changed.connect(() => {
                var new_val = webpage_row.text.strip();
                var original_val = record.original_web_page ?? "";
                // Determine if value differs from original
                if (new_val == original_val) {
                    // Matches original, clear custom
                    record.custom_web_page = null;
                } else if (new_val == "") {
                    // User cleared the value, mark as CLEARED
                    record.custom_web_page = CLEARED_VALUE;
                } else {
                    // Custom value set
                    record.custom_web_page = new_val;
                }
                registry.register(record);
                update_desktop_file_property(record.desktop_file, "X-AppImage-Homepage", new_val);
                restore_webpage_button.set_visible(record.custom_web_page != null);
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
            
            // Update link (with original/custom distinction)
            var update_row = new Adw.EntryRow();
            update_row.title = I18n.tr("Update Link");
            update_row.text = record.get_effective_update_link() ?? "";
            
            // Restore defaults button for update link - visible when custom value is set
            var restore_update_button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            restore_update_button.add_css_class("flat");
            restore_update_button.set_valign(Gtk.Align.CENTER);
            restore_update_button.tooltip_text = I18n.tr("Restore default");
            restore_update_button.set_visible(record.custom_update_link != null);
            restore_update_button.clicked.connect(() => {
                // Undo: clear custom, restore original to .desktop
                record.custom_update_link = null;
                registry.register(record);
                var original_val = record.original_update_link ?? "";
                update_row.text = original_val;
                update_desktop_file_property(record.desktop_file, "X-AppImage-UpdateURL", original_val);
                restore_update_button.set_visible(false);
            });
            update_row.add_suffix(restore_update_button);
            
            // Normalize URL when user leaves the entry (focus out) or presses Enter
            var focus_controller = new Gtk.EventControllerFocus();
            focus_controller.leave.connect(() => {
                var raw_val = update_row.text.strip();
                // Normalize GitHub/GitLab URLs to project base
                var normalized = Updater.normalize_update_url(raw_val);
                var new_val = normalized ?? raw_val;
                
                // Update text field if normalization changed it
                if (new_val != raw_val && new_val != "") {
                    update_row.text = new_val;
                }
                
                var original_val = record.original_update_link ?? "";
                // Determine if value differs from original
                if (new_val == original_val) {
                    // Matches original, clear custom
                    record.custom_update_link = null;
                } else if (new_val == "") {
                    // User cleared the value, mark as CLEARED
                    record.custom_update_link = CLEARED_VALUE;
                } else {
                    // Custom value set
                    record.custom_update_link = new_val;
                }
                registry.register(record);
                update_desktop_file_property(record.desktop_file, "X-AppImage-UpdateURL", new_val);
                restore_update_button.set_visible(record.custom_update_link != null);
            });
            update_row.add_controller(focus_controller);
            
            update_row.entry_activated.connect(() => {
                var raw_val = update_row.text.strip();
                // Normalize GitHub/GitLab URLs to project base
                var normalized = Updater.normalize_update_url(raw_val);
                var new_val = normalized ?? raw_val;
                
                // Update text field if normalization changed it
                if (new_val != raw_val && new_val != "") {
                    update_row.text = new_val;
                }
                
                var original_val = record.original_update_link ?? "";
                // Determine if value differs from original
                if (new_val == original_val) {
                    // Matches original, clear custom
                    record.custom_update_link = null;
                } else if (new_val == "") {
                    // User cleared the value, mark as CLEARED
                    record.custom_update_link = CLEARED_VALUE;
                } else {
                    // Custom value set
                    record.custom_update_link = new_val;
                }
                registry.register(record);
                update_desktop_file_property(record.desktop_file, "X-AppImage-UpdateURL", new_val);
                restore_update_button.set_visible(record.custom_update_link != null);
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

            // Keywords (loaded from .desktop file)
            var keywords_row = new Adw.EntryRow();
            keywords_row.title = I18n.tr("Keywords");
            keywords_row.text = current_keywords;
            
            // Restore defaults button for keywords - visible when custom value is set
            var restore_keywords_button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            restore_keywords_button.add_css_class("flat");
            restore_keywords_button.set_valign(Gtk.Align.CENTER);
            restore_keywords_button.tooltip_text = I18n.tr("Restore default");
            restore_keywords_button.set_visible(record.custom_keywords != null);
            restore_keywords_button.clicked.connect(() => {
                // Undo: clear custom, restore original to .desktop
                record.custom_keywords = null;
                registry.register(record);
                var original_val = record.original_keywords ?? "";
                keywords_row.text = original_val;
                update_desktop_file_property(record.desktop_file, "Keywords", original_val);
                restore_keywords_button.set_visible(false);
            });
            keywords_row.add_suffix(restore_keywords_button);
            
            keywords_row.changed.connect(() => {
                var new_val = keywords_row.text.strip();
                var original_val = record.original_keywords ?? "";
                // Determine if value differs from original
                if (new_val == original_val) {
                    // Matches original, clear custom
                    record.custom_keywords = null;
                } else if (new_val == "") {
                    // User cleared the value, mark as CLEARED
                    record.custom_keywords = CLEARED_VALUE;
                } else {
                    // Custom value set
                    record.custom_keywords = new_val;
                }
                registry.register(record);
                // Update .desktop file
                update_desktop_file_property(record.desktop_file, "Keywords", new_val);
                restore_keywords_button.set_visible(record.custom_keywords != null);
            });
            advanced_group.add_row(keywords_row);

            // Icon name (loaded from .desktop file)
            var icon_row = new Adw.EntryRow();
            icon_row.title = I18n.tr("Icon name");
            icon_row.text = current_icon;
            
            // Restore defaults button for icon - visible when custom value is set
            var restore_icon_button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            restore_icon_button.add_css_class("flat");
            restore_icon_button.set_valign(Gtk.Align.CENTER);
            restore_icon_button.tooltip_text = I18n.tr("Restore default");
            restore_icon_button.set_visible(record.custom_icon_name != null);
            restore_icon_button.clicked.connect(() => {
                // Undo: clear custom, restore original to .desktop
                record.custom_icon_name = null;
                registry.register(record);
                var original_val = record.original_icon_name ?? "";
                icon_row.text = original_val;
                update_desktop_file_property(record.desktop_file, "Icon", original_val);
                restore_icon_button.set_visible(false);
            });
            icon_row.add_suffix(restore_icon_button);
            
            icon_row.changed.connect(() => {
                var new_val = icon_row.text.strip();
                var original_val = record.original_icon_name ?? "";
                // Determine if value differs from original
                if (new_val == original_val) {
                    // Matches original, clear custom
                    record.custom_icon_name = null;
                } else if (new_val == "") {
                    // User cleared the value, mark as CLEARED
                    record.custom_icon_name = CLEARED_VALUE;
                } else {
                    // Custom value set
                    record.custom_icon_name = new_val;
                }
                registry.register(record);
                // Update .desktop file
                update_desktop_file_property(record.desktop_file, "Icon", new_val);
                restore_icon_button.set_visible(record.custom_icon_name != null);
            });
            advanced_group.add_row(icon_row);
            
            // StartupWMClass (loaded from .desktop file)
            var wmclass_row = new Adw.EntryRow();
            wmclass_row.title = I18n.tr("Startup WM Class");
            wmclass_row.text = current_wmclass;
            
            // Restore defaults button for wmclass - visible when custom value is set
            var restore_wmclass_button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            restore_wmclass_button.add_css_class("flat");
            restore_wmclass_button.set_valign(Gtk.Align.CENTER);
            restore_wmclass_button.tooltip_text = I18n.tr("Restore default");
            restore_wmclass_button.set_visible(record.custom_startup_wm_class != null);
            restore_wmclass_button.clicked.connect(() => {
                // Undo: clear custom, restore original to .desktop
                record.custom_startup_wm_class = null;
                registry.register(record);
                var original_val = record.original_startup_wm_class ?? "";
                wmclass_row.text = original_val;
                update_desktop_file_property(record.desktop_file, "StartupWMClass", original_val);
                restore_wmclass_button.set_visible(false);
            });
            wmclass_row.add_suffix(restore_wmclass_button);
            
            wmclass_row.changed.connect(() => {
                var new_val = wmclass_row.text.strip();
                var original_val = record.original_startup_wm_class ?? "";
                // Determine if value differs from original
                if (new_val == original_val) {
                    // Matches original, clear custom
                    record.custom_startup_wm_class = null;
                } else if (new_val == "") {
                    // User cleared the value, mark as CLEARED
                    record.custom_startup_wm_class = CLEARED_VALUE;
                } else {
                    // Custom value set
                    record.custom_startup_wm_class = new_val;
                }
                registry.register(record);
                // Update .desktop file
                update_desktop_file_property(record.desktop_file, "StartupWMClass", new_val);
                restore_wmclass_button.set_visible(record.custom_startup_wm_class != null);
            });
            advanced_group.add_row(wmclass_row);

            // Version
            var version_row = new Adw.EntryRow();
            version_row.title = I18n.tr("Version");
            version_row.text = record.version ?? "";
            version_row.changed.connect(() => {
                record.version = version_row.text.strip() == "" ? null : version_row.text;
                registry.register(record);
                update_desktop_file_property(record.desktop_file, "X-AppImage-Version", record.version ?? "");
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

            // Update Action with spinner
            update_action_row = new Adw.ButtonRow();

            update_action_row.activated.connect(() => {
                if (update_loading) {
                    return;
                }
                if (update_available) {
                    update_requested(record);
                } else {
                    check_update_requested(record);
                }
            });
            
            // Create a box to hold the list and spinner overlay
            var update_wrapper = new Gtk.Overlay();
            
            update_list = new Gtk.ListBox();
            update_list.add_css_class("boxed-list");
            update_list.selection_mode = Gtk.SelectionMode.NONE;
            update_list.append(update_action_row);
            update_wrapper.set_child(update_list);
            
            update_spinner = new Gtk.Spinner();
            update_spinner.valign = Gtk.Align.CENTER;
            update_spinner.halign = Gtk.Align.START;
            update_spinner.margin_start = 16;
            update_spinner.visible = false;
            update_wrapper.add_overlay(update_spinner);
            
            actions_box.append(update_wrapper);
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
            if (update_action_row == null || update_spinner == null) {
                return;
            }

            if (update_loading) {
                update_action_row.title = I18n.tr("Checking...");
                update_action_row.start_icon_name = null;
                update_spinner.visible = true;
                update_spinner.start();
                update_action_row.sensitive = false;
                update_action_row.remove_css_class("suggested-action");
                return;
            }

            update_spinner.visible = false;
            update_spinner.stop();
            update_action_row.sensitive = true;

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
        
        // Extract command line arguments from Exec field (everything after first token)
        private string extract_exec_args(string exec_value) {
            var trimmed = exec_value.strip();
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
                // No arguments
                return "";
            }
            
            // Return only the arguments part
            return trimmed.substring(first_space + 1).strip();
        }
        
        // Build Exec value with new args, preserving the executable path
        private string build_exec_with_args(string current_exec, string new_args) {
            var trimmed = current_exec.strip();
            if (trimmed.length == 0) {
                return "";
            }
            
            // Find the base executable (first token)
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
            
            string base_exec;
            if (first_space == -1) {
                base_exec = trimmed;
            } else {
                base_exec = trimmed.substring(0, first_space);
            }
            
            if (new_args.strip() != "") {
                return "%s %s".printf(base_exec, new_args);
            } else {
                return base_exec;
            }
        }
        
        private void update_desktop_file_property(string desktop_file_path, string key, string value) {
            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(desktop_file_path, KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS);
                
                if (value.strip() == "") {
                    // Remove key if value is empty - Linux Desktop treats empty values as values
                    // Exception: Exec should always be kept (never remove the executable line)
                    if (key != "Exec") {
                        try {
                            keyfile.remove_key("Desktop Entry", key);
                            debug("Removed desktop file property %s (value was empty)", key);
                        } catch (Error e) {
                            // Key might not exist, that's fine
                        }
                    } else {
                        keyfile.set_string("Desktop Entry", key, value);
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

        private Gtk.ListBox create_list_box_for_row(Adw.PreferencesRow row) {
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
