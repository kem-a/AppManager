using AppManager.Core;

[CCode (cname = "adw_about_dialog_new_from_appdata")]
extern Adw.Dialog about_dialog_new_from_appdata_raw(string resource_path, string? release_notes_version);

namespace AppManager {
    public class MainWindow : Adw.Window {
        private Application app_ref;
        private InstallationRegistry registry;
        private Installer installer;
        private Settings settings;
        private Adw.PreferencesGroup extracted_group;
        private Adw.PreferencesGroup portable_group;
        private Adw.PreferencesPage general_page;
        private Gtk.ShortcutsWindow? shortcuts_window;
        private Adw.AboutDialog? about_dialog;
        private Adw.NavigationView navigation_view;
        private const string SHORTCUTS_RESOURCE = "/com/github/AppManager/ui/main-window-shortcuts.ui";
        private const string APPDATA_RESOURCE = "/com/github/AppManager/com.github.AppManager.metainfo.xml";

        public MainWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings) {
            Object(application: app);
            this.title = I18n.tr("AppManager");
            this.app_ref = app;
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            add_css_class("devel");
            this.set_default_size(settings.get_int("window-width"), settings.get_int("window-height"));
            build_ui();
            refresh_installations();
            registry.changed.connect(() => {
                refresh_installations();
            });
        }

        private void build_ui() {
            navigation_view = new Adw.NavigationView();
            navigation_view.pop_on_escape = true;
            this.set_content(navigation_view);

            general_page = new Adw.PreferencesPage();
            
            var root_toolbar = create_toolbar_with_header(general_page, true);
            var root_page = new Adw.NavigationPage(root_toolbar, "main");
            root_page.title = I18n.tr("AppManager");
            navigation_view.add(root_page);

            portable_group = new Adw.PreferencesGroup();
            portable_group.title = I18n.tr("Portable AppImages");
            general_page.add(portable_group);

            extracted_group = new Adw.PreferencesGroup();
            extracted_group.title = I18n.tr("Extracted AppImages");
            general_page.add(extracted_group);

            this.close_request.connect(() => {
                settings.set_int("window-width", this.get_width());
                settings.set_int("window-height", this.get_height());
                return false;
            });
        }

        private void refresh_installations() {
            general_page.remove(portable_group);
            general_page.remove(extracted_group);
            
            portable_group = new Adw.PreferencesGroup();
            setup_group_header(portable_group, I18n.tr("Portable AppImages"), AppPaths.applications_dir);
            
            extracted_group = new Adw.PreferencesGroup();
            setup_group_header(extracted_group, I18n.tr("Extracted AppImages"), AppPaths.extracted_root);
            
            general_page.add(portable_group);
            general_page.add(extracted_group);
            
            var records = registry.list();
            var extracted_records = new Gee.ArrayList<InstallationRecord>();
            var portable_records = new Gee.ArrayList<InstallationRecord>();
            
            foreach (var record in records) {
                if (record.mode == InstallMode.EXTRACTED) {
                    extracted_records.add(record);
                } else {
                    portable_records.add(record);
                }
            }

            populate_group(portable_group, portable_records);
            populate_group(extracted_group, extracted_records);

            if (records.length == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.title = I18n.tr("Nothing installed yet");
                empty_row.subtitle = I18n.tr("Install an AppImage by double-clicking it");
                portable_group.add(empty_row);
            }
        }

        private void setup_group_header(Adw.PreferencesGroup group, string title, string path) {
            var display_path = format_display_path(path);

            var header_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            header_container.set_halign(Gtk.Align.START);
           
            var title_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            title_row.set_valign(Gtk.Align.CENTER);
            title_row.set_halign(Gtk.Align.START);

            var title_label = new Gtk.Label(title);
            title_label.add_css_class("title-4");
            title_label.set_xalign(0);
            title_row.append(title_label);

            var folder_button = new Gtk.Button.from_icon_name("folder-open-symbolic");
            folder_button.add_css_class("flat");
            folder_button.set_valign(Gtk.Align.CENTER);
            folder_button.tooltip_text = I18n.tr("Open folder");
            folder_button.clicked.connect(() => {
                open_folder(path);
            });
            title_row.append(folder_button);

            header_container.append(title_row);

            var path_label = new Gtk.Label(display_path);
            path_label.add_css_class("dim-label");
            path_label.add_css_class("caption");
            path_label.set_xalign(0);
            path_label.set_ellipsize(Pango.EllipsizeMode.MIDDLE);
            header_container.append(path_label);

            group.title = null;
            group.description = null;
            group.set_header_suffix(header_container);
            align_group_header_box(group);
        }

        private string format_display_path(string path) {
            var home = Environment.get_home_dir();
            if (path.has_prefix(home)) {
                if (path.length == home.length) {
                    return "~";
                }
                var remainder = path.substring(home.length);
                if (!remainder.has_prefix("/")) {
                    remainder = "/" + remainder;
                }
                return "~" + remainder;
            }
            return path;
        }

        private void open_folder(string path) {
            try {
                var file = File.new_for_path(path);
                var launcher = new Gtk.FileLauncher(file);
                launcher.launch.begin(this, null);
            } catch (Error e) {
                warning("Failed to open folder %s: %s", path, e.message);
            }
        }

        private void align_group_header_box(Adw.PreferencesGroup group) {
            var outer_box = group.get_first_child();
            if (outer_box == null) {
                return;
            }

            for (var child = outer_box.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child.has_css_class("header")) {
                    child.set_halign(Gtk.Align.START);
                    child.set_hexpand(false);
                    return;
                }
            }
        }

        private void populate_group(Adw.PreferencesGroup group, Gee.ArrayList<InstallationRecord> records) {
            foreach (var record in records) {
                var row = new Adw.ActionRow();
                row.title = record.name;
                
                string version_text;
                if (record.version != null && record.version.strip() != "") {
                    version_text = I18n.tr("Version %s").printf(record.version);
                } else {
                    version_text = I18n.tr("Version unknown");
                }
                row.subtitle = version_text;

                // Add icon if available
                if (record.icon_path != null && record.icon_path.strip() != "") {
                    var icon_image = load_app_icon(record.icon_path);
                    if (icon_image != null) {
                        row.add_prefix(icon_image);
                    }
                }

                // Make row activatable to show detail page
                row.activatable = true;
                row.activated.connect(() => { show_detail_page(record); });

                // Add navigation arrow
                var arrow = new Gtk.Image.from_icon_name("go-next-symbolic");
                arrow.add_css_class("dim-label");
                row.add_suffix(arrow);

                group.add(row);
            }
        }

        private Gtk.Image? load_app_icon(string icon_path) {
            // Extract icon name from the path (without extension)
            var icon_file = File.new_for_path(icon_path);
            var icon_basename = icon_file.get_basename();
            string icon_name = icon_basename;
            
            // Remove file extension to get icon name
            var last_dot = icon_basename.last_index_of(".");
            if (last_dot > 0) {
                icon_name = icon_basename.substring(0, last_dot);
            }

            // First try to load from icon theme
            var icon_theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
            if (icon_theme.has_icon(icon_name)) {
                var icon_image = new Gtk.Image.from_icon_name(icon_name);
                icon_image.set_pixel_size(48);
                debug("Loaded icon '%s' from icon theme", icon_name);
                return icon_image;
            }

            // Fallback to loading from file path
            if (icon_file.query_exists()) {
                try {
                    var icon_texture = Gdk.Texture.from_file(icon_file);
                    var icon_image = new Gtk.Image.from_paintable(icon_texture);
                    icon_image.set_pixel_size(48);
                    debug("Loaded icon from file: %s", icon_path);
                    return icon_image;
                } catch (Error e) {
                    warning("Failed to load icon from file %s: %s", icon_path, e.message);
                }
            } else {
                debug("Icon file does not exist: %s", icon_path);
            }

            return null;
        }

        public void present_shortcuts_dialog() {
            ensure_shortcuts_window();
            if (shortcuts_window == null) {
                return;
            }
            shortcuts_window.set_transient_for(this);
            shortcuts_window.present();
        }

        private GLib.MenuModel build_menu_model() {
            var menu = new GLib.Menu();
            menu.append(I18n.tr("Keyboard shortcuts"), "app.show_shortcuts");
            menu.append(I18n.tr("About AppManager"), "app.show_about");
            return menu;
        }

        private Adw.ToolbarView create_toolbar_with_header(Gtk.Widget content, bool include_menu_button) {
            var toolbar = new Adw.ToolbarView();
            var header = new Adw.HeaderBar();

            if (include_menu_button) {
                var menu_button = new Gtk.MenuButton();
                menu_button.set_icon_name("open-menu-symbolic");
                menu_button.menu_model = build_menu_model();
                menu_button.tooltip_text = I18n.tr("More actions");
                header.pack_end(menu_button);
            }

            toolbar.add_top_bar(header);
            toolbar.set_content(content);
            return toolbar;
        }


        private void ensure_shortcuts_window() {
            if (shortcuts_window != null) {
                return;
            }
            try {
                var builder = new Gtk.Builder();
                builder.add_from_resource(SHORTCUTS_RESOURCE);
                shortcuts_window = builder.get_object("shortcuts_window") as Gtk.ShortcutsWindow;
                if (shortcuts_window == null) {
                    warning("Failed to create shortcuts window");
                    return;
                }
                shortcuts_window.set_transient_for(this);

                var section = builder.get_object("general_section") as Gtk.ShortcutsSection;
                if (section != null) {
                    section.title = I18n.tr("General");
                }
                var navigation = builder.get_object("navigation_group") as Gtk.ShortcutsGroup;
                if (navigation != null) {
                    navigation.title = I18n.tr("Navigation");
                }
                var window_group = builder.get_object("window_group") as Gtk.ShortcutsGroup;
                if (window_group != null) {
                    window_group.title = I18n.tr("Window");
                }
                assign_shortcut_title(builder, "shortcut_show_overlay", I18n.tr("Show shortcuts"));
                assign_shortcut_title(builder, "shortcut_about", I18n.tr("About AppManager"));
                assign_shortcut_title(builder, "shortcut_close_window", I18n.tr("Close window"));
                assign_shortcut_title(builder, "shortcut_quit", I18n.tr("Quit AppManager"));
            } catch (Error e) {
                warning("Failed to load shortcuts UI: %s", e.message);
            }
        }

        private void assign_shortcut_title(Gtk.Builder builder, string id, string title) {
            var shortcut = builder.get_object(id) as Gtk.ShortcutsShortcut;
            if (shortcut != null) {
                shortcut.title = title;
            }
        }

        public void present_about_dialog() {
            if (about_dialog == null) {
                about_dialog = (Adw.AboutDialog) about_dialog_new_from_appdata_raw(APPDATA_RESOURCE, null);
                about_dialog.version = APPLICATION_VERSION;
            }
            about_dialog.present(this);
        }

        private void show_detail_page(InstallationRecord record) {
            var detail_page = new Adw.PreferencesPage();
            
            // Header group with icon, name, and version
            var header_group = new Adw.PreferencesGroup();
            
            var header_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            header_box.set_halign(Gtk.Align.CENTER);
            header_box.set_margin_top(24);
            header_box.set_margin_bottom(12);
            
            // App icon
            if (record.icon_path != null && record.icon_path.strip() != "") {
                var icon_image = load_app_icon(record.icon_path);
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
            header_row.set_child(header_box);
            header_group.add(header_row);
            detail_page.add(header_group);
            
            // Properties group
            var props_group = new Adw.PreferencesGroup();
            props_group.title = I18n.tr("Properties");
            
            // Load desktop file properties
            var desktop_props = load_desktop_file_properties(record.desktop_file);
            
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
            
            // Icon
            var icon_row = new Adw.EntryRow();
            icon_row.title = I18n.tr("Icon");
            icon_row.text = desktop_props.get("Icon") ?? "";
            icon_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "Icon", icon_row.text);
            });
            props_group.add(icon_row);
            
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
            props_group.add(version_row);
            
            // StartupWMClass
            var wmclass_row = new Adw.EntryRow();
            wmclass_row.title = I18n.tr("Startup WM Class");
            wmclass_row.text = desktop_props.get("StartupWMClass") ?? "";
            wmclass_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "StartupWMClass", wmclass_row.text);
            });
            props_group.add(wmclass_row);
            
            // Keywords
            var keywords_row = new Adw.EntryRow();
            keywords_row.title = I18n.tr("Keywords");
            keywords_row.text = desktop_props.get("Keywords") ?? "";
            keywords_row.changed.connect(() => {
                update_desktop_file_property(record.desktop_file, "Keywords", keywords_row.text);
            });
            props_group.add(keywords_row);
            
            // Terminal app toggle
            var terminal_row = new Adw.SwitchRow();
            terminal_row.title = I18n.tr("Terminal app");
            terminal_row.subtitle = I18n.tr("Run in terminal emulator");
            var terminal_value = desktop_props.get("Terminal") ?? "false";
            terminal_row.active = (terminal_value.down() == "true");
            terminal_row.notify["active"].connect(() => {
                update_desktop_file_property(record.desktop_file, "Terminal", terminal_row.active ? "true" : "false");
            });
            props_group.add(terminal_row);
            
            // NoDisplay toggle
            var nodisplay_row = new Adw.SwitchRow();
            nodisplay_row.title = I18n.tr("Hide from app drawer");
            nodisplay_row.subtitle = I18n.tr("Don't show in application menu");
            var nodisplay_value = desktop_props.get("NoDisplay") ?? "false";
            nodisplay_row.active = (nodisplay_value.down() == "true");
            nodisplay_row.notify["active"].connect(() => {
                update_desktop_file_property(record.desktop_file, "NoDisplay", nodisplay_row.active ? "true" : "false");
            });
            props_group.add(nodisplay_row);
            
            detail_page.add(props_group);
            
            // Actions group
            var actions_group = new Adw.PreferencesGroup();
            actions_group.title = I18n.tr("Actions");
            
            var uninstall_row = new Adw.ActionRow();
            uninstall_row.title = I18n.tr("Uninstall");
            uninstall_row.subtitle = I18n.tr("Move this AppImage to trash");
            uninstall_row.activatable = true;
            uninstall_row.activated.connect(() => {
                navigation_view.pop();
                uninstall_record(record);
            });
            
            var trash_icon = new Gtk.Image.from_icon_name("user-trash-symbolic");
            trash_icon.add_css_class("error");
            uninstall_row.add_prefix(trash_icon);
            
            actions_group.add(uninstall_row);
            detail_page.add(actions_group);
            
            var detail_toolbar = create_toolbar_with_header(detail_page, false);
            
            var nav_page = new Adw.NavigationPage(detail_toolbar, record.id);
            nav_page.title = record.name;
            nav_page.can_pop = true;
            navigation_view.push(nav_page);
        }
        
        private HashTable<string, string> load_desktop_file_properties(string desktop_file_path) {
            var props = new HashTable<string, string>(str_hash, str_equal);
            
            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(desktop_file_path, KeyFileFlags.NONE);
                
                string[] keys = {"Exec", "Icon", "X-AppImage-Version", "StartupWMClass", "Keywords", "Terminal", "NoDisplay"};
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
                FileUtils.set_contents(desktop_file_path, data);
                debug("Updated desktop file property %s = %s", key, value);
            } catch (Error e) {
                warning("Failed to update desktop file %s: %s", desktop_file_path, e.message);
            }
        }

        private void uninstall_record(InstallationRecord record) {
            new Thread<void>("appmgr-uninstall", () => {
                try {
                    installer.uninstall(record);
                    Idle.add(() => {
                        refresh_installations();
                        present_uninstall_notification(record);
                        return GLib.Source.REMOVE;
                    });
                } catch (Error e) {
                    var message = e.message;
                    Idle.add(() => {
                        var dialog = new Adw.AlertDialog(
                            I18n.tr("Uninstall failed"),
                            I18n.tr("%s could not be removed: %s").printf(record.name, message)
                        );
                        dialog.add_response("close", I18n.tr("Close"));
                        dialog.set_default_response("close");
                        dialog.present(this);
                        return GLib.Source.REMOVE;
                    });
                }
            });
        }

        private void present_uninstall_notification(InstallationRecord record) {
            if (app_ref == null) {
                return;
            }
            UninstallNotification.present(app_ref, this, record);
        }
    }
}
