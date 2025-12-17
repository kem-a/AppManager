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
        private DirectoryMonitor? directory_monitor;
        private PreferencesDialog? preferences_dialog;
        private static bool opt_version = false;
        private static bool opt_help = false;
        private static bool opt_background_update = false;
        private static string? opt_install = null;
        private static string? opt_uninstall = null;
        private static string? opt_is_installed = null;
        
        private const OptionEntry[] options = {
            { "help", 'h', 0, OptionArg.NONE, ref opt_help, "Show help options", null },
            { "version", 0, 0, OptionArg.NONE, ref opt_version, "Display version number", null },
            { "background-update", 0, 0, OptionArg.NONE, ref opt_background_update, "Run background update check", null },
            { "install", 0, 0, OptionArg.FILENAME, ref opt_install, "Install an AppImage from PATH", "PATH" },
            { "uninstall", 0, 0, OptionArg.STRING, ref opt_uninstall, "Uninstall an AppImage (by path or checksum)", "PATH" },
            { "is-installed", 0, 0, OptionArg.FILENAME, ref opt_is_installed, "Check if an AppImage is installed", "PATH" },
            { null }
        };
        
        public Application() {
            Object(application_id: Core.APPLICATION_ID,
                flags: ApplicationFlags.HANDLES_OPEN | ApplicationFlags.HANDLES_COMMAND_LINE | ApplicationFlags.NON_UNIQUE);
            settings = new Settings(Core.APPLICATION_ID);
            registry = new InstallationRegistry();
            installer = new Installer(registry, settings);
            
            add_main_option_entries(options);
            set_option_context_parameter_string("[FILE...]");
            set_option_context_summary("AppImage Manager - Manage and update AppImages on your system");
        }

        protected override int handle_local_options(GLib.VariantDict options) {
            if (opt_help) {
                print("""Usage:
  app-manager [OPTION...] [FILE...]

Application Options:
  -h, --help                  Show help options
  --version                   Display version number
  --background-update         Run background update check
  --install PATH              Install an AppImage from PATH
  --uninstall PATH            Uninstall an AppImage (by path or checksum)
  --is-installed PATH         Check if an AppImage is installed

Examples:
  app-manager                             Launch the GUI
  app-manager app.AppImage                Open installer for app.AppImage
  app-manager --install app.AppImage      Install app.AppImage
  app-manager --uninstall app.AppImage    Uninstall app.AppImage
  app-manager --is-installed app.AppImage Check installation status
  app-manager --background-update         Run background update check

""");
                return 0;
            }
            
            if (opt_version) {
                print("AppManager %s\n", Core.APPLICATION_VERSION);
                return 0;
            }
            
            return -1;  // Continue processing
        }

        protected override void startup() {
            base.startup();

            // Add bundled icons to the theme search path so symbolic update icon is always available
            var display = Gdk.Display.get_default();
            if (display != null) {
                var theme = Gtk.IconTheme.get_for_display(display);
                // Register bundled icons (hicolor layout) from the resource bundle
                theme.add_resource_path("/com/github/AppManager/icons/hicolor");
            }

            bg_update_service = new BackgroundUpdateService(settings, registry, installer);
            
            // Initialize directory monitoring for manual deletions
            directory_monitor = new DirectoryMonitor(registry);
            directory_monitor.changes_detected.connect(() => {
                // Reconcile registry with filesystem when changes are detected
                var orphaned = registry.reconcile_with_filesystem();
                if (orphaned.size > 0) {
                    debug("Reconciled %d orphaned installation(s)", orphaned.size);
                }
            });
            directory_monitor.start();
            
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

            var preferences_action = new GLib.SimpleAction("show_preferences", null);
            preferences_action.activate.connect(() => {
                present_preferences();
            });
            this.add_action(preferences_action);

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
            string[] preferences_accels = { "<Primary>comma" };
            string[] close_accels = { "<Primary>w" };
            string[] search_accels = { "<Primary>f" };
            string[] check_updates_accels = { "<Primary>u" };
            string[] refresh_accels = { "<Primary>r" };
            string[] menu_accels = { "F10" };
            this.set_accels_for_action("app.show_shortcuts", shortcut_accels);
            this.set_accels_for_action("app.show_about", about_accels);
            this.set_accels_for_action("app.show_preferences", preferences_accels);
            this.set_accels_for_action("app.close_window", close_accels);
            this.set_accels_for_action("win.toggle_search", search_accels);
            this.set_accels_for_action("win.check_updates", check_updates_accels);
            this.set_accels_for_action("win.refresh", refresh_accels);
            this.set_accels_for_action("win.show_menu", menu_accels);
        }

        protected override void activate() {
            if (main_window == null) {
                // Check integrity on app launch to detect manual deletions while app was closed
                var orphaned = registry.reconcile_with_filesystem();
                if (orphaned.size > 0) {
                    debug("Found %d orphaned installation(s) on launch", orphaned.size);
                }
                
                main_window = new MainWindow(this, registry, installer, settings);

                if (settings.get_boolean("auto-check-updates") && !settings.get_boolean("background-permission-requested")) {
                    request_background_updates.begin();
                }
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
            if (opt_background_update) {
                return run_background_update(command_line);
            }
            
            var file_list = new ArrayList<GLib.File>();

            // Handle non-option arguments (file paths)
            var args = command_line.get_arguments();
            debug("command_line: got %u args", args.length);
            for (int _k = 0; _k < args.length; _k++)
                debug("command_line arg[%d] = %s", _k, args[_k]);
            for (int i = 1; i < args.length; i++) {
                var arg = args[i];
                // Skip already-processed option arguments
                if (arg == "--install" || arg == "--uninstall" || arg == "--is-installed" ||
                    arg == "--background-update" || arg == "--help" || arg == "-h" || arg == "--version") {
                    if (arg == "--install" || arg == "--uninstall" || arg == "--is-installed") {
                        i++; // Skip the value
                    }
                    continue;
                }
                if (arg.length > 0 && arg[0] != '-') {
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

            if (opt_install != null) {
                try {
                    var record = installer.install(opt_install);
                    command_line.print("Installed %s\n", record.name);
                    return 0;
                } catch (Error e) {
                    command_line.printerr("Install failed: %s\n", e.message);
                    return 2;
                }
            }

            if (opt_uninstall != null) {
                try {
                    var record = locate_record(opt_uninstall);
                    if (record == null) {
                        command_line.printerr("No installation matches %s\n", opt_uninstall);
                        return 3;
                    }
                    
                    installer.uninstall(record);

                    command_line.print("Removed %s\n", record.name);
                    return 0;
                } catch (Error e) {
                    command_line.printerr("Uninstall failed: %s\n", e.message);
                    return 4;
                }
            }

            if (opt_is_installed != null) {
                try {
                    var checksum = Utils.FileUtils.compute_checksum(opt_is_installed);
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
                try {
                    installer.uninstall(record);
                    Idle.add(() => {
                        if (parent_window != null && parent_window is MainWindow) {
                            ((MainWindow)parent_window).add_toast(I18n.tr("Moved to Trash"));
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

        private void present_preferences() {
            Gtk.Widget? parent = this.get_active_window();
            if (parent == null) {
                parent = main_window;
            }

            if (parent == null) {
                return;
            }

            if (preferences_dialog == null) {
                preferences_dialog = new PreferencesDialog(settings);
                preferences_dialog.closed.connect(() => {
                    preferences_dialog = null;
                });
            }

            preferences_dialog.present(parent);
        }

        private async void request_background_updates() {
            if (bg_update_service == null) {
                return;
            }
            yield bg_update_service.request_background_permission(main_window);
        }

        private int run_background_update(GLib.ApplicationCommandLine command_line) {
            if (!settings.get_boolean("auto-check-updates")) {
                debug("Auto-check updates disabled; exiting");
                return 0;
            }

            if (bg_update_service == null) {
                bg_update_service = new BackgroundUpdateService(settings, registry, installer);
            }

            if (!bg_update_service.should_check_now()) {
                debug("Not time to check yet; exiting");
                return 0;
            }

            var loop = new MainLoop();
            var cancellable = new Cancellable();

            bg_update_service.perform_background_check.begin(cancellable, (obj, res) => {
                bg_update_service.perform_background_check.end(res);
                loop.quit();
            });

            loop.run();
            return 0;
        }

    }
}
