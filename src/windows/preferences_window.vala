using AppManager.Core;
using AppManager.Utils;

namespace AppManager {
    public class PreferencesDialog : Adw.PreferencesDialog {
        private GLib.Settings settings;
        private int[] update_interval_options = { 86400, 604800, 2592000 };
        private Adw.ExpanderRow? auto_check_expander = null;
        private Adw.SwitchRow? auto_update_row = null;
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
            this.content_height = 500;
            build_ui();
        }

        private void build_ui() {
            var page = new Adw.PreferencesPage();

            // Automatic updates group
            var updates_group = new Adw.PreferencesGroup();
            updates_group.title = I18n.tr("Automatic updates");
            updates_group.description = I18n.tr("Configure automatic update checking");

            // Add log button to header
            var log_button = new Gtk.Button.from_icon_name("text-x-generic-symbolic");
            log_button.valign = Gtk.Align.CENTER;
            log_button.add_css_class("flat");
            log_button.tooltip_text = I18n.tr("Open update log");
            var log_file = File.new_for_path(AppPaths.updates_log_file);
            log_button.sensitive = log_file.query_exists();
            log_button.clicked.connect(() => {
                try {
                    AppInfo.launch_default_for_uri(log_file.get_uri(), null);
                } catch (Error e) {
                    warning("Failed to open update log: %s", e.message);
                }
            });
            updates_group.header_suffix = log_button;

            // Background update check expander row
            var auto_check_expander = new Adw.ExpanderRow();
            auto_check_expander.title = I18n.tr("Background update check");
            auto_check_expander.subtitle = I18n.tr("Will notify when new app updates are available");
            auto_check_expander.show_enable_switch = true;
            settings.bind("auto-check-updates", auto_check_expander, "enable-expansion", GLib.SettingsBindFlags.DEFAULT);
            this.auto_check_expander = auto_check_expander;

            settings.changed["auto-check-updates"].connect(() => {
                handle_auto_update_toggle(settings.get_boolean("auto-check-updates"));
            });

            // Auto update apps toggle (inside expander)
            var auto_update_row = new Adw.SwitchRow();
            auto_update_row.title = I18n.tr("Auto update apps");
            auto_update_row.subtitle = I18n.tr("Will update apps automatically in background");
            settings.bind("auto-update-apps", auto_update_row, "active", GLib.SettingsBindFlags.DEFAULT);
            this.auto_update_row = auto_update_row;

            // Check interval (inside expander)
            var interval_row = new Adw.ComboRow();
            interval_row.title = I18n.tr("Check interval");
            var interval_model = new Gtk.StringList(null);
            interval_model.append(I18n.tr("Daily"));
            interval_model.append(I18n.tr("Weekly"));
            interval_model.append(I18n.tr("Monthly"));
            interval_row.model = interval_model;
            interval_row.selected = interval_index_for_value(settings.get_int("update-check-interval"));
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

            // Add rows to expander
            auto_check_expander.add_row(auto_update_row);
            auto_check_expander.add_row(interval_row);

            updates_group.add(auto_check_expander);

            // Thumbnails group
            var thumbnails_group = new Adw.PreferencesGroup();
            thumbnails_group.title = I18n.tr("Thumbnails");

            var thumbnailer_row = new Adw.ActionRow();
            thumbnailer_row.title = I18n.tr("AppImage Thumbnailer");
            thumbnailer_row.subtitle = I18n.tr("Install appimage-thumbnailer to generate thumbnails for AppImages");
            thumbnailer_row.activatable = true;
            thumbnailer_row.add_suffix(new Gtk.Image.from_icon_name("adw-external-link-symbolic"));
            thumbnailer_row.activated.connect(() => {
                UiUtils.open_url("https://github.com/kem-a/appimage-thumbnailer");
            });
            thumbnails_group.add(thumbnailer_row);

            var thumbnail_background_row = new Adw.SwitchRow();
            thumbnail_background_row.title = I18n.tr("Hide Nautilus thumbnail background");
            thumbnail_background_row.subtitle = I18n.tr("Remove the alpha checkerboard behind thumbnails and icons");
            settings.bind("remove-thumbnail-checkerboard", thumbnail_background_row, "active", GLib.SettingsBindFlags.DEFAULT);

            settings.changed["remove-thumbnail-checkerboard"].connect(() => {
                apply_thumbnail_background_preference(settings.get_boolean("remove-thumbnail-checkerboard"));
            });

            thumbnails_group.add(thumbnail_background_row);

            page.add(updates_group);
            page.add(thumbnails_group);

            this.add(page);

            apply_thumbnail_background_preference(settings.get_boolean("remove-thumbnail-checkerboard"));
        }

        private void handle_auto_update_toggle(bool enabled) {
            if (enabled) {
                BackgroundUpdateService.write_autostart_file();
                BackgroundUpdateService.spawn_daemon();
            } else {
                BackgroundUpdateService.remove_autostart_file();
                BackgroundUpdateService.kill_daemon();
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

    }
}
