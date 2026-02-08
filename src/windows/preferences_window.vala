using AppManager.Core;
using AppManager.Utils;

namespace AppManager {
    public class PreferencesDialog : Adw.PreferencesDialog {
        private GLib.Settings settings;
        private InstallationRegistry registry;
        private DirectoryMonitor? directory_monitor;
        private int[] update_interval_options = { 86400, 604800, 2592000 };
        private Adw.ExpanderRow? auto_check_expander = null;
        private Adw.SwitchRow? auto_update_row = null;
        private Adw.ComboRow? interval_row = null;
        private Adw.EntryRow? install_dir_row = null;
        private Gtk.Button? browse_button = null;
        private Gtk.Button? reset_button = null;
        private Gtk.Button? apply_button = null;
        private Adw.ActionRow? thumbnailer_row = null;
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

        public PreferencesDialog(GLib.Settings settings, InstallationRegistry? registry = null, DirectoryMonitor? directory_monitor = null) {
            Object();
            this.settings = settings;
            this.registry = registry;
            this.directory_monitor = directory_monitor;
            this.set_title(_("Preferences"));
            this.content_height = 550;
            build_ui();
            
            // Remove focus from entry row when dialog is shown
            this.map.connect(() => {
                GLib.Timeout.add(50, () => {
                    // First deselect text in the entry
                    if (this.install_dir_row != null) {
                        this.install_dir_row.select_region(0, 0);
                    }
                    // Then move focus to apply button
                    if (this.apply_button != null) {
                        this.apply_button.grab_focus();
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void build_ui() {
            var page = new Adw.PreferencesPage();

            // Installation directory group
            var install_group = new Adw.PreferencesGroup();
            install_group.title = _("Installation");
            install_group.description = _("Configure where AppImages are installed (default: ~/Applications)");

            var install_dir_row = new Adw.EntryRow();
            install_dir_row.title = _("Installation directory");
            
            // Get current value - show actual path or placeholder for default
            var current_custom = settings.get_string("applications-dir");
            if (current_custom != null && current_custom.strip() != "") {
                install_dir_row.text = current_custom;
            } else {
                install_dir_row.text = AppPaths.default_applications_dir;
            }
            this.install_dir_row = install_dir_row;

            // Browse button
            var browse_button = new Gtk.Button.from_icon_name("folder-open-symbolic");
            browse_button.valign = Gtk.Align.CENTER;
            browse_button.add_css_class("flat");
            browse_button.tooltip_text = _("Browse for folder");
            browse_button.clicked.connect(on_browse_clicked);
            this.browse_button = browse_button;

            // Reset button (only visible when custom path is set)
            var reset_button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            reset_button.valign = Gtk.Align.CENTER;
            reset_button.add_css_class("flat");
            reset_button.tooltip_text = _("Reset to default");
            reset_button.visible = (current_custom != null && current_custom.strip() != "");
            reset_button.clicked.connect(on_reset_clicked);
            this.reset_button = reset_button;

            // Apply button
            apply_button = new Gtk.Button.from_icon_name("object-select-symbolic");
            apply_button.valign = Gtk.Align.CENTER;
            apply_button.add_css_class("flat");
            apply_button.add_css_class("success");
            apply_button.tooltip_text = _("Apply changes");
            apply_button.clicked.connect(on_apply_install_dir);

            install_dir_row.add_suffix(reset_button);
            install_dir_row.add_suffix(browse_button);
            install_dir_row.add_suffix(apply_button);
            
            // Allow Enter key to apply
            install_dir_row.entry_activated.connect(on_apply_install_dir);

            var skip_drop_row = new Adw.SwitchRow();
            skip_drop_row.title = _("Skip drag-and-drop window");
            skip_drop_row.subtitle = _("Show install dialog directly when opening AppImages");
            settings.bind("skip-drop-window", skip_drop_row, "active", GLib.SettingsBindFlags.DEFAULT);

            install_group.add(install_dir_row);
            install_group.add(skip_drop_row);
            page.add(install_group);

            // Automatic updates group
            var updates_group = new Adw.PreferencesGroup();
            updates_group.title = _("Automatic updates");
            updates_group.description = _("Configure automatic update checking");

            // Add log button to header
            var log_button = new Gtk.Button.from_icon_name("text-x-generic-symbolic");
            log_button.valign = Gtk.Align.CENTER;
            log_button.add_css_class("flat");
            log_button.tooltip_text = _("Open update log");
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
            auto_check_expander.title = _("Background update check");
            auto_check_expander.subtitle = _("Will notify when new app updates are available");
            auto_check_expander.show_enable_switch = true;
            settings.bind("auto-check-updates", auto_check_expander, "enable-expansion", GLib.SettingsBindFlags.DEFAULT);
            this.auto_check_expander = auto_check_expander;

            settings.changed["auto-check-updates"].connect(() => {
                handle_auto_update_toggle(settings.get_boolean("auto-check-updates"));
            });

            // Auto update apps toggle (inside expander)
            var auto_update_row = new Adw.SwitchRow();
            auto_update_row.title = _("Auto update apps");
            auto_update_row.subtitle = _("Will update apps automatically in background");
            settings.bind("auto-update-apps", auto_update_row, "active", GLib.SettingsBindFlags.DEFAULT);
            this.auto_update_row = auto_update_row;

            // Check interval (inside expander)
            var interval_row = new Adw.ComboRow();
            interval_row.title = _("Check interval");
            var interval_model = new Gtk.StringList(null);
            interval_model.append(_("Daily"));
            interval_model.append(_("Weekly"));
            interval_model.append(_("Monthly"));
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
            thumbnails_group.title = _("Thumbnails");

            thumbnailer_row = new Adw.ActionRow();
            thumbnailer_row.title = _("AppImage Thumbnailer");
            thumbnailer_row.subtitle = _("Install appimage-thumbnailer to generate thumbnails for AppImages");
            thumbnailer_row.activatable = true;
            thumbnailer_row.add_suffix(new Gtk.Image.from_icon_name("external-link-symbolic"));
            thumbnailer_row.activated.connect(() => {
                UiUtils.open_url("https://github.com/kem-a/appimage-thumbnailer");
            });
            thumbnails_group.add(thumbnailer_row);

            var thumbnail_background_row = new Adw.SwitchRow();
            thumbnail_background_row.title = _("Hide Nautilus thumbnail background");
            thumbnail_background_row.subtitle = _("Remove the alpha checkerboard behind thumbnails and icons");
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

        private void on_browse_clicked() {
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Select Installation Directory");
            dialog.modal = true;
            
            // Set initial folder to current value
            var current_path = install_dir_row.text;
            if (current_path != null && current_path.strip() != "") {
                var initial_folder = File.new_for_path(current_path);
                if (initial_folder.query_exists()) {
                    dialog.initial_folder = initial_folder;
                }
            }

            dialog.select_folder.begin(this.get_root() as Gtk.Window, null, (obj, res) => {
                try {
                    var folder = dialog.select_folder.end(res);
                    if (folder != null) {
                        install_dir_row.text = folder.get_path();
                    }
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED)) {
                        warning("Failed to select folder: %s", e.message);
                    }
                }
            });
        }

        private void on_reset_clicked() {
            install_dir_row.text = AppPaths.default_applications_dir;
            on_apply_install_dir();
        }

        private void on_apply_install_dir() {
            var new_path = install_dir_row.text.strip();
            var current_setting = settings.get_string("applications-dir");
            var current_effective = AppPaths.applications_dir;

            // Normalize: if new_path equals default, treat as empty (use default)
            string new_setting = new_path;
            if (new_path == AppPaths.default_applications_dir) {
                new_setting = "";
            }

            // Check if anything actually changed
            if (new_setting == current_setting) {
                return; // No change
            }
            
            // Also check if effective path is the same
            string new_effective = new_setting != "" ? new_setting : AppPaths.default_applications_dir;
            if (new_effective == current_effective) {
                // Just update the setting without migration
                settings.set_string("applications-dir", new_setting);
                update_reset_button_visibility(new_setting);
                return;
            }

            if (registry == null) {
                // No registry available, just update setting (for standalone preferences)
                settings.set_string("applications-dir", new_setting);
                update_reset_button_visibility(new_setting);
                return;
            }

            // Validate the new path
            var migration_service = new PathMigrationService(registry, settings);
            var error_msg = migration_service.validate_new_path(new_path);
            if (error_msg != null) {
                show_error_dialog(_("Invalid Path"), error_msg);
                return;
            }

            // Check if there are apps to migrate
            var records = registry.list();
            if (records.length == 0) {
                // No apps, just update setting
                settings.set_string("applications-dir", new_setting);
                update_reset_button_visibility(new_setting);
                show_info_toast(_("Installation directory updated"));
                return;
            }

            // Show confirmation dialog
            show_migration_confirmation(new_setting, records.length);
        }

        private void show_migration_confirmation(string new_setting, int app_count) {
            var dialog = new Adw.AlertDialog(
                _("Move Installed Apps?"),
                _("This will move %d installed app(s) to the new location. This may take a while depending on the size of your apps.").printf(app_count)
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("move", _("Move Apps"));
            dialog.set_response_appearance("move", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";

            // Capture current effective path NOW before any settings changes
            var old_effective = AppPaths.applications_dir;
            var new_effective = new_setting != "" ? new_setting : AppPaths.default_applications_dir;
            
            dialog.response.connect((response) => {
                if (response == "move") {
                    start_migration(old_effective, new_effective, new_setting);
                }
            });

            dialog.present(this.get_root() as Gtk.Window);
        }

        private void start_migration(string old_path, string new_path, string new_setting) {
            var migration_service = new PathMigrationService(registry, settings);
            
            // STOP directory monitoring completely during migration
            // This is simpler and more reliable than pausing
            if (directory_monitor != null) {
                directory_monitor.stop();
            }
            
            // Kill background daemon if running - it may interfere with migration
            // by monitoring folders and triggering reconciliation
            bool daemon_was_running = BackgroundUpdateService.kill_daemon_and_wait();
            
            // Create progress dialog
            var progress_dialog = new Adw.AlertDialog(_("Moving Apps…"), _("Please wait while your apps are being moved."));
            progress_dialog.add_response("cancel", _("Cancel"));
            progress_dialog.close_response = "cancel";
            
            var progress_bar = new Gtk.ProgressBar();
            progress_bar.show_text = true;
            progress_bar.margin_start = 24;
            progress_bar.margin_end = 24;
            progress_bar.margin_top = 12;
            progress_bar.margin_bottom = 12;
            progress_dialog.extra_child = progress_bar;

            migration_service.progress.connect((message, fraction) => {
                progress_bar.fraction = fraction;
                progress_bar.text = message;
            });

            migration_service.migration_complete.connect((success, error_message) => {
                // Clear migration flag first
                registry.set_migration_in_progress(false);
                
                // Start fresh directory monitoring on new paths
                if (directory_monitor != null) {
                    directory_monitor.start();
                }
                
                // If background daemon was running, update autostart file and respawn
                if (daemon_was_running) {
                    // Update autostart Exec path to point to new location
                    BackgroundUpdateService.update_autostart_file_after_migration(old_path, new_path);
                    BackgroundUpdateService.spawn_daemon();
                }
                
                progress_dialog.force_close();
                
                if (success) {
                    update_reset_button_visibility(new_setting);
                    show_info_toast(_("Apps moved successfully"));
                } else {
                    show_error_dialog(_("Migration Failed"), error_message ?? _("Unknown error occurred"));
                }
            });

            progress_dialog.present(this.get_root() as Gtk.Window);

            // Pass explicit old and new paths to avoid GSettings caching issues
            migration_service.migrate.begin(old_path, new_path, new_setting);
        }

        private void update_reset_button_visibility(string new_setting) {
            if (reset_button != null) {
                reset_button.visible = (new_setting != null && new_setting.strip() != "");
            }
        }

        private void show_error_dialog(string title, string message) {
            var dialog = new Adw.AlertDialog(title, message);
            dialog.add_response("ok", _("OK"));
            dialog.default_response = "ok";
            dialog.present(this.get_root() as Gtk.Window);
        }

        private void show_info_toast(string message) {
            var window = this.get_root() as Gtk.Window;
            if (window != null) {
                // Try to find a toast overlay in the parent window
                // For now, just log it - the UI will update visually
                debug("Info: %s", message);
            }
        }

    }
}
