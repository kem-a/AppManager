using AppManager.Core;
using AppManager.Utils;
using GLib;
using Gee;

namespace AppManager {
    public class Application : Adw.Application {
        private MainWindow? main_window;
        private InstallationRegistry registry;
        private Installer installer;
        private Settings settings;
        private BackgroundUpdateService? bg_update_service;
        public Application() {
            Object(application_id: Core.APPLICATION_ID,
                flags: ApplicationFlags.HANDLES_OPEN | ApplicationFlags.HANDLES_COMMAND_LINE);
            settings = new Settings(Core.APPLICATION_ID);
            registry = new InstallationRegistry();
            installer = new Installer(registry, settings);
        }

        protected override void startup() {
            base.startup();
            bg_update_service = new BackgroundUpdateService(settings, registry, installer);
            var quit_action = new GLib.SimpleAction("quit", null);
            quit_action.activate.connect(() => this.quit());
            this.add_action(quit_action);
            string[] quit_accels = { "<Primary>q" };
            this.set_accels_for_action("app.quit", quit_accels);

            var shortcuts_action = new GLib.SimpleAction("show_shortcuts", null);
            shortcuts_action.activate.connect(() => {
                if (main_window != null) {
                    main_window.present_shortcuts_dialog();
                }
            });
            this.add_action(shortcuts_action);

            var about_action = new GLib.SimpleAction("show_about", null);
            about_action.activate.connect(() => {
                if (main_window != null) {
                    main_window.present_about_dialog();
                }
            });
            this.add_action(about_action);

            var close_action = new GLib.SimpleAction("close_window", null);
            close_action.activate.connect(() => {
                var active = this.get_active_window();
                if (active != null) {
                    active.close();
                }
            });
            this.add_action(close_action);

            string[] shortcut_accels = { "<Primary>question" };
            string[] about_accels = { "F1" };
            string[] close_accels = { "<Primary>w" };
            this.set_accels_for_action("app.show_shortcuts", shortcut_accels);
            this.set_accels_for_action("app.show_about", about_accels);
            this.set_accels_for_action("app.close_window", close_accels);
        }

        protected override void activate() {
            if (main_window == null) {
                main_window = new MainWindow(this, registry, installer, settings);

                if (settings.get_boolean("auto-check-updates") && !settings.get_boolean("background-permission-requested")) {
                    request_background_updates.begin();
                }
            }

            if (bg_update_service != null && bg_update_service.should_check_now()) {
                perform_background_check.begin();
            }
            main_window.present();
        }

        protected override void open(GLib.File[] files, string hint) {
            if (files.length == 0) {
                activate();
                return;
            }
            foreach (var file in files) {
                show_drop_window(file);
            }
        }

        private void show_drop_window(GLib.File file) {
            try {
                debug("Opening drop window for %s", file.get_path());
                var window = new DropWindow(this, registry, installer, settings, file.get_path());
                window.present();
            } catch (Error e) {
                critical("Failed to open drop window: %s", e.message);
                this.activate();
            }
        }

        protected override int command_line(GLib.ApplicationCommandLine command_line) {
            string? install_path = null;
            string? uninstall_target = null;
            string? query_path = null;
            var file_list = new ArrayList<GLib.File>();

            var args = command_line.get_arguments();
            debug("command_line: got %u args", args.length);
            for (int _k = 0; _k < args.length; _k++)
                debug("command_line arg[%d] = %s", _k, args[_k]);
            for (int i = 1; i < args.length; i++) {
                var arg = args[i];
                if (arg == "--install" && i + 1 < args.length) {
                    install_path = args[++i];
                } else if (arg == "--uninstall" && i + 1 < args.length) {
                    uninstall_target = args[++i];
                } else if (arg == "--is-installed" && i + 1 < args.length) {
                    query_path = args[++i];
                } else if (arg.length > 0 && arg[0] != '-') {
                    if (arg.has_prefix("file://")) {
                        file_list.add(File.new_for_uri(arg));
                    } else {
                        file_list.add(File.new_for_path(arg));
                    }
                }
            }
            if (file_list.size > 0) {
                this.open(to_file_array(file_list), "");
                return 0;
            }

            if (install_path != null) {
                try {
                    var record = installer.install(install_path);
                    command_line.print("Installed %s\n", record.name);
                    return 0;
                } catch (Error e) {
                    command_line.printerr("Install failed: %s\n", e.message);
                    return 2;
                }
            }

            if (uninstall_target != null) {
                try {
                    var record = locate_record(uninstall_target);
                    if (record == null) {
                        command_line.printerr("No installation matches %s\n", uninstall_target);
                        return 3;
                    }
                    
                    var icon = load_record_icon(record);
                    installer.uninstall(record);
                    
                    present_uninstall_notification(record, icon);

                    command_line.print("Removed %s\n", record.name);
                    return 0;
                } catch (Error e) {
                    command_line.printerr("Uninstall failed: %s\n", e.message);
                    return 4;
                }
            }

            if (query_path != null) {
                try {
                    var checksum = Utils.FileUtils.compute_checksum(query_path);
                    var installed = registry.is_installed_checksum(checksum);
                    command_line.print(installed ? "installed\n" : "missing\n");
                    return installed ? 0 : 1;
                } catch (Error e) {
                    command_line.printerr("Query failed: %s\n", e.message);
                    return 5;
                }
            }

            this.activate();
            return 0;
        }

        public void uninstall_record(InstallationRecord record, Gtk.Window? parent_window) {
            new Thread<void>("appmgr-uninstall", () => {
                var icon = load_record_icon(record);
                try {
                    installer.uninstall(record);
                    Idle.add(() => {
                        if (parent_window != null && parent_window is MainWindow) {
                            ((MainWindow)parent_window).add_toast(I18n.tr("Moved to Trash"));
                        } else {
                            present_uninstall_notification(record, icon);
                        }
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
                        dialog.present(parent_window ?? main_window);
                        return GLib.Source.REMOVE;
                    });
                }
            });
        }

        public void extract_installation(InstallationRecord record, Gtk.Window? parent_window) {
            var source_path = record.installed_path ?? "";
            if (record.mode != InstallMode.PORTABLE || source_path.strip() == "") {
                present_extract_error(parent_window, record, I18n.tr("Extraction is only available for portable installations."));
                return;
            }

            new Thread<void>("appmgr-extract", () => {
                string? staging_dir = null;
                string staged_path = "";
                try {
                    staging_dir = Utils.FileUtils.create_temp_dir("appmgr-extract-");
                    staged_path = Path.build_filename(staging_dir, Path.get_basename(source_path));
                    Utils.FileUtils.file_copy(source_path, staged_path);
                } catch (Error e) {
                    var message = e.message;
                    Idle.add(() => {
                        present_extract_error(parent_window, record, message);
                        return GLib.Source.REMOVE;
                    });
                    if (staging_dir != null) {
                        Utils.FileUtils.remove_dir_recursive(staging_dir);
                    }
                    return;
                }

                try {
                    var new_record = installer.reinstall(staged_path, record, InstallMode.EXTRACTED);
                    Idle.add(() => {
                        if (parent_window != null && parent_window is MainWindow) {
                            ((MainWindow)parent_window).add_toast(I18n.tr("Extracted for faster launch"));
                        } else {
                            var dialog = new Adw.AlertDialog(
                                I18n.tr("Extraction complete"),
                                I18n.tr("%s was extracted and will open faster.").printf(new_record.name)
                            );
                            dialog.add_response("close", I18n.tr("Close"));
                            dialog.set_close_response("close");
                            dialog.present(parent_window ?? main_window);
                        }
                        return GLib.Source.REMOVE;
                    });
                } catch (Error e) {
                    var message = e.message;
                    Idle.add(() => {
                        present_extract_error(parent_window, record, message);
                        return GLib.Source.REMOVE;
                    });
                } finally {
                    if (staging_dir != null) {
                        Utils.FileUtils.remove_dir_recursive(staging_dir);
                    }
                }
            });
        }

        private void present_extract_error(Gtk.Window? parent_window, InstallationRecord record, string message) {
            var dialog = new Adw.AlertDialog(
                I18n.tr("Extraction failed"),
                I18n.tr("%s could not be extracted: %s").printf(record.name, message)
            );
            dialog.add_response("close", I18n.tr("Close"));
            dialog.set_close_response("close");
            dialog.present(parent_window ?? main_window);
        }

        private Icon? load_record_icon(InstallationRecord record) {
            if (record.icon_path != null && File.new_for_path(record.icon_path).query_exists()) {
                try {
                    var file = File.new_for_path(record.icon_path);
                    var bytes = file.load_bytes(null);
                    return new BytesIcon(bytes);
                } catch (Error e) {
                    warning("Failed to load icon for notification: %s", e.message);
                }
            }
            return null;
        }

        private GLib.File[] to_file_array(ArrayList<GLib.File> files) {
            var result = new GLib.File[files.size];
            for (int i = 0; i < files.size; i++) {
                result[i] = files.get(i);
            }
            return result;
        }

        private InstallationRecord? locate_record(string target) {
            var by_path = registry.lookup_by_installed_path(target) ?? registry.lookup_by_source(target);
            if (by_path != null) {
                return by_path;
            }
            try {
                if (File.new_for_path(target).query_exists()) {
                    var checksum = Utils.FileUtils.compute_checksum(target);
                    var by_checksum = registry.lookup_by_checksum(checksum);
                    if (by_checksum != null) {
                        return by_checksum;
                    }
                }
            } catch (Error e) {
                warning("Failed to compute checksum for %s: %s", target, e.message);
            }
            return null;
        }

        private void present_uninstall_notification(InstallationRecord record, Icon? icon = null) {
            var notification = new Notification(record.name);
            notification.set_body(I18n.tr("Moved to Trash"));
            notification.set_priority(NotificationPriority.URGENT);
            
            if (icon != null) {
                notification.set_icon(icon);
            }
            
            var notification_id = "app-uninstall-%s".printf(record.id);
            this.send_notification(notification_id, notification);
            
            this.hold();
            GLib.Timeout.add(5000, () => {
                this.withdraw_notification(notification_id);
                this.release();
                return GLib.Source.REMOVE;
            });
        }

        private async void request_background_updates() {
            if (bg_update_service == null) {
                return;
            }
            yield bg_update_service.request_background_permission(main_window);
        }

        private async void perform_background_check() {
            if (bg_update_service == null) {
                return;
            }
            var cancellable = new Cancellable();
            yield bg_update_service.perform_background_check(cancellable);
        }

    }
}
