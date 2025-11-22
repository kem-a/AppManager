using AppManager.Core;

namespace AppManager {
    public class MainWindow : Adw.PreferencesWindow {
        private InstallationRegistry registry;
        private Installer installer;
        private Settings settings;
            private Adw.PreferencesGroup installs_group;
            private Adw.PreferencesPage general_page;
            private Gtk.ShortcutsWindow? shortcuts_window;
            private Adw.AboutDialog? about_dialog;
            private Gtk.MenuButton? header_menu_button;
            private const string SHORTCUTS_RESOURCE = "/com/github/AppManager/ui/main-window-shortcuts.ui";

        public MainWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings) {
            Object(application: app,
                title: I18n.tr("AppManager"));
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            add_css_class("devel");
            this.set_default_size(settings.get_int("window-width"), settings.get_int("window-height"));
            build_ui();
            this.map.connect(() => {
                setup_header_menu();
            });
            refresh_installations();
            registry.changed.connect(() => {
                refresh_installations();
            });
        }

        private void build_ui() {
            general_page = new Adw.PreferencesPage();
            add(general_page);

            var install_group = new Adw.PreferencesGroup();
            install_group.title = I18n.tr("Installation");
            general_page.add(install_group);

            var mode_row = new Adw.ActionRow();
            mode_row.title = I18n.tr("Default install mode");
            var mode_combo = new Gtk.ComboBoxText();
            var stored_mode = settings.get_string("default-install-mode");
            var normalized_mode = sanitize_mode_id(stored_mode);
            if (stored_mode != normalized_mode) {
                settings.set_string("default-install-mode", normalized_mode);
            }
            mode_combo.append("portable", I18n.tr("Portable (.AppImage)"));
            mode_combo.append("extracted", I18n.tr("Extracted (AppRun)"));
            mode_combo.set_active_id(normalized_mode);
            mode_combo.set_valign(Gtk.Align.CENTER);
            mode_combo.set_vexpand(false);
            mode_combo.set_hexpand(false);
            mode_combo.changed.connect(() => {
                var active_id = sanitize_mode_id(mode_combo.get_active_id());
                mode_combo.set_active_id(active_id);
                settings.set_string("default-install-mode", active_id);
            });
            mode_row.add_suffix(mode_combo);
            mode_row.activatable_widget = mode_combo;
            install_group.add(mode_row);

            var cleanup_row = new Adw.SwitchRow();
            cleanup_row.title = I18n.tr("Auto clean temporary folders");
            cleanup_row.subtitle = I18n.tr("Remove extraction scratch space right after install");
            cleanup_row.active = settings.get_boolean("auto-clean-temp");
            cleanup_row.notify["active"].connect(() => {
                settings.set_boolean("auto-clean-temp", cleanup_row.active);
            });
            install_group.add(cleanup_row);

            var system_icons_row = new Adw.SwitchRow();
            system_icons_row.title = I18n.tr("Use system icon theme");
            system_icons_row.subtitle = I18n.tr("Reference icons by name instead of absolute paths");
            system_icons_row.active = settings.get_boolean("use-system-icons");
            system_icons_row.notify["active"].connect(() => {
                settings.set_boolean("use-system-icons", system_icons_row.active);
            });
            install_group.add(system_icons_row);

            installs_group = new Adw.PreferencesGroup();
            installs_group.title = I18n.tr("Installed AppImages");
            general_page.add(installs_group);

            this.close_request.connect(() => {
                settings.set_int("window-width", this.get_width());
                settings.set_int("window-height", this.get_height());
                return false;
            });
        }

        private string sanitize_mode_id(string? value) {
            if (value != null && value.down() == "extracted") {
                return "extracted";
            }
            return "portable";
        }

        private void refresh_installations() {
            general_page.remove(installs_group);
            installs_group = new Adw.PreferencesGroup();
            installs_group.title = I18n.tr("Installed AppImages");
            general_page.add(installs_group);
            var records = registry.list();
            foreach (var record in records) {
                var row = new Adw.ActionRow();
                row.title = record.name;
                string details_line;
                if (record.version != null && record.version.strip() != "") {
                    details_line = I18n.tr("Version %s").printf(record.version);
                } else {
                    details_line = record.installed_path;
                }
                row.subtitle = "%s\n%s".printf(record.mode_label(), details_line);

                var remove_button = new Gtk.Button.from_icon_name("user-trash-symbolic");
                remove_button.tooltip_text = I18n.tr("Move to trash");
                remove_button.add_css_class("destructive-action");
                remove_button.set_valign(Gtk.Align.CENTER);
                remove_button.clicked.connect(() => { uninstall_record(record); });
                row.add_suffix(remove_button);

                installs_group.add(row);
            }

            if (records.length == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.title = I18n.tr("Nothing installed yet");
                empty_row.subtitle = I18n.tr("Install an AppImage by double-clicking it");
                installs_group.add(empty_row);
            }
        }

        public void present_shortcuts_dialog() {
            ensure_shortcuts_window();
            if (shortcuts_window == null) {
                return;
            }
            shortcuts_window.set_transient_for(this);
            shortcuts_window.present();
        }

        private void setup_header_menu() {
            if (header_menu_button != null) {
                return;
            }

            var header = find_header_bar(this);
            if (header == null) {
                warning("Failed to locate header bar for menu button");
                return;
            }

            header_menu_button = new Gtk.MenuButton();
            header_menu_button.set_icon_name("open-menu-symbolic");
            header_menu_button.menu_model = build_menu_model();
            header_menu_button.tooltip_text = I18n.tr("More actions");
            header.pack_end(header_menu_button);
        }

        private Adw.HeaderBar? find_header_bar(Gtk.Widget widget) {
            var header_bar = widget as Adw.HeaderBar;
            if (header_bar != null) {
                return header_bar;
            }

            for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
                var found = find_header_bar(child);
                if (found != null) {
                    return found;
                }
            }

            return null;
        }

        private GLib.MenuModel build_menu_model() {
            var menu = new GLib.Menu();
            menu.append(I18n.tr("Keyboard shortcuts"), "app.show_shortcuts");
            menu.append(I18n.tr("About AppManager"), "app.show_about");
            return menu;
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
                about_dialog = new Adw.AboutDialog();
                about_dialog.application_name = APPLICATION_NAME;
                about_dialog.application_icon = APPLICATION_ID;
                about_dialog.version = APPLICATION_VERSION;
                about_dialog.developer_name = "Arnis Kemlers";
                about_dialog.website = "https://github.com/kem-a/AppManager";
                about_dialog.issue_url = "https://github.com/kem-a/AppManager/issues";
                about_dialog.license_type = Gtk.License.GPL_3_0;
                about_dialog.copyright = "© 2025 Arnis Kemlers";
            }
            about_dialog.present(this);
        }

        private void uninstall_record(InstallationRecord record) {
            new Thread<void>("appmgr-uninstall", () => {
                try {
                    installer.uninstall(record);
                    Idle.add(() => {
                        refresh_installations();
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
    }
}
