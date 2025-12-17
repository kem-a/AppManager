using AppManager.Core;

namespace AppManager {
    public class PreferencesDialog : Adw.PreferencesDialog {
        private GLib.Settings settings;
        private int[] update_interval_options = { 86400, 604800, 2592000 };
        private bool portal_available = false;
        private Adw.SwitchRow? auto_check_row = null;
        private Adw.ComboRow? interval_row = null;
        private const string GTK_CONFIG_SUBDIR = "gtk-4.0";
        private const string APP_CSS_FILENAME = "AppManager.css";
        private const string APP_CSS_IMPORT_LINE = "@import url(\"AppManager.css\");";
        private const string APP_CSS_CONTENT = "/* Remove checkered alpha channel drawing around thumbnails and icons. Creates more cleaner look */\n" +
            ".thumbnail,\n" +
            ".icon .thumbnail,\n" +
            ".grid-view .thumbnail {\n" +
            "  background: none;\n" +
            "  box-shadow: none;\n" +
            "}\n";

        public PreferencesDialog(GLib.Settings settings) {
            Object();
            this.settings = settings;
            this.set_title(I18n.tr("Preferences"));
            this.content_height = 660;
            check_portal_availability.begin();
            build_ui();
        }

        private void build_ui() {
            var page = new Adw.PreferencesPage();

            var thumbnails_group = new Adw.PreferencesGroup();
            thumbnails_group.title = I18n.tr("Thumbnails");

            var thumbnail_background_row = new Adw.SwitchRow();
            thumbnail_background_row.title = I18n.tr("Hide checkered thumbnail background");
            thumbnail_background_row.subtitle = I18n.tr("Remove the alpha checkerboard behind thumbnails and icons");
            settings.bind("remove-thumbnail-checkerboard", thumbnail_background_row, "active", GLib.SettingsBindFlags.DEFAULT);

            settings.changed["remove-thumbnail-checkerboard"].connect(() => {
                apply_thumbnail_background_preference(settings.get_boolean("remove-thumbnail-checkerboard"));
            });

            thumbnails_group.add(thumbnail_background_row);

            var updates_group = new Adw.PreferencesGroup();
            updates_group.title = I18n.tr("Automatic updates");
            updates_group.description = I18n.tr("Configure automatic update checking");

            var auto_check_row = new Adw.SwitchRow();
            auto_check_row.title = I18n.tr("Check for updates automatically");
            auto_check_row.subtitle = I18n.tr("Periodically check for new versions in the background");
            settings.bind("auto-check-updates", auto_check_row, "active", GLib.SettingsBindFlags.DEFAULT);
            this.auto_check_row = auto_check_row;

            settings.changed["auto-check-updates"].connect(() => {
                handle_auto_update_toggle(settings.get_boolean("auto-check-updates"));
            });

            var interval_row = new Adw.ComboRow();
            interval_row.title = I18n.tr("Check interval");
            var interval_model = new Gtk.StringList(null);
            interval_model.append(I18n.tr("Daily"));
            interval_model.append(I18n.tr("Weekly"));
            interval_model.append(I18n.tr("Monthly"));
            interval_row.model = interval_model;
            interval_row.selected = interval_index_for_value(settings.get_int("update-check-interval"));
            settings.bind("auto-check-updates", interval_row, "sensitive", GLib.SettingsBindFlags.GET);
            this.interval_row = interval_row;

            interval_row.notify["selected"].connect(() => {
                var selected_index = (int) interval_row.selected;
                if (selected_index < 0 || selected_index >= update_interval_options.length) {
                    return;
                }
                settings.set_int("update-check-interval", update_interval_options[selected_index]);
            });

            settings.changed["update-check-interval"].connect(() => {
                interval_row.selected = interval_index_for_value(settings.get_int("update-check-interval"));
            });

            updates_group.add(auto_check_row);
            updates_group.add(interval_row);

            var links_group = new Adw.PreferencesGroup();
            links_group.title = I18n.tr("Find more AppImages");
            links_group.description = I18n.tr("Browse these sources to discover and download AppImages");

            var pkgforge_row = new Adw.ActionRow();
            pkgforge_row.title = "Anylinux AppImages";
            pkgforge_row.subtitle = "pkgforge-dev.github.io";
            pkgforge_row.activatable = true;
            pkgforge_row.add_suffix(new Gtk.Image.from_icon_name("external-link-symbolic"));
            pkgforge_row.activated.connect(() => {
                open_url("https://pkgforge-dev.github.io/Anylinux-AppImages/");
            });
            links_group.add(pkgforge_row);

            var appimagehub_row = new Adw.ActionRow();
            appimagehub_row.title = "AppImageHub";
            appimagehub_row.subtitle = "appimagehub.com";
            appimagehub_row.activatable = true;
            appimagehub_row.add_suffix(new Gtk.Image.from_icon_name("external-link-symbolic"));
            appimagehub_row.activated.connect(() => {
                open_url("https://www.appimagehub.com/");
            });
            links_group.add(appimagehub_row);

            var appimage_catalog_row = new Adw.ActionRow();
            appimage_catalog_row.title = "AppImage Catalog";
            appimage_catalog_row.subtitle = "appimage.github.io";
            appimage_catalog_row.activatable = true;
            appimage_catalog_row.add_suffix(new Gtk.Image.from_icon_name("external-link-symbolic"));
            appimage_catalog_row.activated.connect(() => {
                open_url("https://appimage.github.io/");
            });
            links_group.add(appimage_catalog_row);

            page.add(thumbnails_group);
            page.add(updates_group);
            page.add(links_group);

            this.add(page);

            apply_thumbnail_background_preference(settings.get_boolean("remove-thumbnail-checkerboard"));
        }

        private async void check_portal_availability() {
            try {
                var connection = yield Bus.get(BusType.SESSION);
                var result = yield connection.call(
                    "org.freedesktop.portal.Desktop",
                    "/org/freedesktop/portal/desktop",
                    "org.freedesktop.DBus.Introspectable",
                    "Introspect",
                    null,
                    null,
                    DBusCallFlags.NONE,
                    -1,
                    null
                );
                string xml;
                result.get("(s)", out xml);
                portal_available = xml.contains("org.freedesktop.portal.Background");
            } catch (Error e) {
                warning("Failed to check portal availability: %s", e.message);
                portal_available = false;
            }
            
            // Update UI after check completes
            update_portal_ui_state();
        }

        private void update_portal_ui_state() {
            if (auto_check_row == null || interval_row == null) {
                return;
            }
            
            if (!portal_available) {
                auto_check_row.subtitle = I18n.tr("Background updates require the XDG portal, which is unavailable on this system.");
                auto_check_row.sensitive = false;
                interval_row.sensitive = false;
            }
        }

        private void handle_auto_update_toggle(bool enabled) {
            var autostart_file = Path.build_filename(
                Environment.get_user_config_dir(),
                "autostart",
                "com.github.AppManager.desktop"
            );
            
            if (enabled) {
                // Write autostart file when enabled
                try {
                    var autostart_dir = Path.build_filename(Environment.get_user_config_dir(), "autostart");
                    DirUtils.create_with_parents(autostart_dir, 0755);
                    
                    var content = """[Desktop Entry]
Type=Application
Name=AppManager Background Updater
Exec=app-manager --background-update
X-GNOME-Autostart-enabled=true
NoDisplay=true
X-XDP-Autostart=com.github.AppManager
""";
                    FileUtils.set_contents(autostart_file, content);
                    debug("Created autostart file: %s", autostart_file);
                } catch (Error e) {
                    warning("Failed to write autostart file: %s", e.message);
                }
            } else {
                // Remove autostart file when disabled
                var file = File.new_for_path(autostart_file);
                if (file.query_exists()) {
                    try {
                        file.delete();
                        debug("Removed autostart file: %s", autostart_file);
                    } catch (Error e) {
                        warning("Failed to remove autostart file: %s", e.message);
                    }
                }
            }
        }

        private uint interval_index_for_value(int value) {
            for (int i = 0; i < update_interval_options.length; i++) {
                if (update_interval_options[i] == value) {
                    return (uint) i;
                }
            }
            return 0;
        }

        private void apply_thumbnail_background_preference(bool enabled) {
            var gtk_config_dir = Path.build_filename(Environment.get_user_config_dir(), GTK_CONFIG_SUBDIR);
            var gtk_css_path = Path.build_filename(gtk_config_dir, "gtk.css");
            var app_css_path = Path.build_filename(gtk_config_dir, APP_CSS_FILENAME);

            try {
                if (enabled) {
                    AppManager.Utils.FileUtils.ensure_directory(gtk_config_dir);
                    AppManager.Utils.FileUtils.write_text_file(app_css_path, APP_CSS_CONTENT);
                    AppManager.Utils.FileUtils.ensure_line_in_file(gtk_css_path, APP_CSS_IMPORT_LINE);
                } else {
                    AppManager.Utils.FileUtils.remove_line_in_file(gtk_css_path, APP_CSS_IMPORT_LINE);
                    AppManager.Utils.FileUtils.delete_file_if_exists(app_css_path);
                }
            } catch (Error e) {
                warning("Failed to update thumbnail background preference: %s", e.message);
            }
        }

        private void open_url(string url) {
            try {
                AppInfo.launch_default_for_uri(url, null);
            } catch (Error e) {
                warning("Failed to open URL %s: %s", url, e.message);
            }
        }
    }
}
