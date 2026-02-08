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
        // Track lock files owned by this instance to clean up on exit
        private HashSet<string> owned_lock_files = new HashSet<string>();
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
            { "install", 0, OptionFlags.HIDDEN, OptionArg.FILENAME, ref opt_install, null, "PATH" },
            { "uninstall", 0, OptionFlags.HIDDEN, OptionArg.STRING, ref opt_uninstall, null, "PATH" },
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
            set_option_context_description("""Commands:
  install PATH                Install an AppImage from PATH
  uninstall PATH              Uninstall an AppImage (by path or checksum)
""");
        }

        protected override int handle_local_options(GLib.VariantDict options) {
            if (opt_help) {
                print("""Usage:
  app-manager [OPTION...] [FILE...]

Commands:
  install PATH                Install an AppImage from PATH
  uninstall PATH              Uninstall an AppImage (by path or checksum)

Options:
  -h, --help                  Show help options
  --version                   Display version number
  --background-update         Run background update check
  --is-installed PATH         Check if an AppImage is installed

Examples:
  app-manager                             Launch the GUI
  app-manager app.AppImage                Open installer for app.AppImage
  app-manager install app.AppImage        Install app.AppImage
  app-manager uninstall app.AppImage      Uninstall app.AppImage
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

            // Install symbolic icon to filesystem for external processes (notifications, panel)
            Installer.install_symbolic_icon();

            // Apply shared UI styles (cards/badges) once per app lifecycle.
            UiUtils.ensure_app_card_styles();

            bg_update_service = new BackgroundUpdateService(settings, registry, installer);
            
            // Initialize directory monitoring for manual deletions
            directory_monitor = new DirectoryMonitor(registry);
            directory_monitor.changes_detected.connect(() => {
                // Skip if migration in progress
                if (registry.is_migration_in_progress()) {
                    return;
                }
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
            string[] preferences_accels = { "<Primary>comma" };
            string[] close_accels = { "<Primary>w" };
            string[] search_accels = { "<Primary>f" };
            string[] check_updates_accels = { "<Primary>u" };
            string[] menu_accels = { "F10" };
            this.set_accels_for_action("app.show_shortcuts", shortcut_accels);
            this.set_accels_for_action("app.show_preferences", preferences_accels);
            this.set_accels_for_action("app.close_window", close_accels);
            this.set_accels_for_action("win.toggle_search", search_accels);
            this.set_accels_for_action("win.check_updates", check_updates_accels);
            this.set_accels_for_action("win.show_menu", menu_accels);
        }

        protected override void activate() {
            // Check integrity on app launch to detect manual deletions while app was closed
            // Skip during migration to prevent false uninstallation
            if (!registry.is_migration_in_progress()) {
                var orphaned = registry.reconcile_with_filesystem();
                if (orphaned.size > 0) {
                    debug("Found %d orphaned installation(s) on launch", orphaned.size);
                }
            }

            // Self-install: if running as AppImage and not yet installed, show installer
            if (AppPaths.is_running_as_appimage && !is_self_installed()) {
                show_self_install_window();
                return;
            }

            if (main_window == null) {
                main_window = new MainWindow(this, registry, installer, settings);
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
            var path = file.get_path();
            
            // Prevent duplicate windows using file-based locking
            if (!try_acquire_drop_window_lock(path)) {
                debug("Drop window already open for %s (locked by another instance), ignoring", path);
                return;
            }
            
            if (settings.get_boolean("skip-drop-window")) {
                show_quick_install_dialog(path);
                return;
            }
            
            try {
                debug("Opening drop window for %s", path);
                var window = new DropWindow(this, registry, installer, settings, path);
                window.close_request.connect(() => {
                    release_drop_window_lock(path);
                    return false;
                });
                window.present();
            } catch (Error e) {
                release_drop_window_lock(path);
                critical("Failed to open drop window: %s", e.message);
                this.activate();
            }
        }

        /**
         * Shows a direct install confirmation dialog, bypassing the drag-and-drop window.
         */
        private void show_quick_install_dialog(string appimage_path) {
            AppImageMetadata metadata;
            try {
                metadata = new AppImageMetadata(File.new_for_path(appimage_path));
            } catch (Error e) {
                release_drop_window_lock(appimage_path);
                critical("Failed to read AppImage metadata: %s", e.message);
                return;
            }

            // Check compatibility
            if (!AppImageAssets.check_compatibility(appimage_path)) {
                var err_dialog = new Adw.AlertDialog(
                    _("Incompatible AppImage"),
                    _("This AppImage is incompatible or corrupted. Missing required files (AppRun, .desktop, or icon)."));
                err_dialog.add_response("close", _("Close"));
                err_dialog.present(this.get_active_window());
                release_drop_window_lock(appimage_path);
                return;
            }

            // Check architecture
            if (!metadata.is_architecture_compatible()) {
                var appimage_arch = metadata.architecture ?? _("unknown");
                var err_dialog = new Adw.AlertDialog(
                    _("Architecture Mismatch"),
                    _("This app is built for %s and cannot run here").printf(appimage_arch));
                err_dialog.add_response("close", _("Close"));
                err_dialog.present(this.get_active_window());
                release_drop_window_lock(appimage_path);
                return;
            }

            // Extract app name and version from .desktop file
            string resolved_name = metadata.display_name;
            string? resolved_version = null;
            string? temp_dir = null;
            try {
                temp_dir = Utils.FileUtils.create_temp_dir("appmgr-quick-");
                var desktop_file = AppImageAssets.extract_desktop_entry(appimage_path, temp_dir);
                if (desktop_file != null) {
                    var desktop_info = AppImageAssets.parse_desktop_file(desktop_file);
                    if (desktop_info.name != null && desktop_info.name.strip() != "") {
                        resolved_name = desktop_info.name.strip();
                    }
                    if (desktop_info.appimage_version != null) {
                        resolved_version = desktop_info.appimage_version;
                    }
                }
            } catch (Error e) {
                warning("Desktop file extraction error: %s", e.message);
            } finally {
                if (temp_dir != null) {
                    Utils.FileUtils.remove_dir_recursive(temp_dir);
                }
            }

            // Check for existing installation
            var existing = registry.detect_existing(appimage_path, metadata.checksum, resolved_name);
            if (existing != null) {
                var relation = quick_install_version_relation(existing, resolved_version);
                if (relation == 1) {
                    // Candidate is newer -> update dialog
                    quick_install_present_update(appimage_path, existing, resolved_version);
                } else {
                    // Same or older -> replace dialog
                    quick_install_present_replace(appimage_path, existing, resolved_version, relation == -1);
                }
            } else {
                quick_install_present_warning(appimage_path, resolved_name);
            }
        }

        /**
         * Returns 1 if candidate is newer, -1 if installed is newer, 0 otherwise.
         */
        private int quick_install_version_relation(InstallationRecord record, string? candidate_version) {
            if (record.version == null || candidate_version == null) {
                return 0;
            }
            return VersionUtils.compare(record.version, candidate_version) < 0 ? 1 :
                   VersionUtils.compare(record.version, candidate_version) > 0 ? -1 : 0;
        }

        private Gtk.Overlay quick_install_build_icon_with_badge(string appimage_path, InstallationRecord? record = null) {
            var image = new Gtk.Image();
            image.set_pixel_size(64);
            image.halign = Gtk.Align.CENTER;

            bool icon_set = false;
            if (record != null) {
                var record_icon = UiUtils.load_record_icon(record);
                if (record_icon != null) {
                    image.set_from_paintable(record_icon);
                    icon_set = true;
                }
            }
            if (!icon_set) {
                var texture = UiUtils.load_icon_from_appimage(appimage_path);
                if (texture != null) {
                    image.set_from_paintable(texture);
                } else {
                    image.set_from_icon_name("application-x-executable");
                }
            }

            var overlay = new Gtk.Overlay();
            overlay.set_child(image);
            overlay.halign = Gtk.Align.CENTER;
            overlay.set_size_request(64, 64);

            var badge = new Gtk.Image();
            badge.set_pixel_size(20);
            badge.halign = Gtk.Align.END;
            badge.valign = Gtk.Align.END;
            badge.set_from_icon_name("verify-warning");
            overlay.add_overlay(badge);

            return overlay;
        }

        private void quick_install_present_warning(string appimage_path, string app_name) {
            var parent = this.get_active_window();
            var dialog = new DialogWindow(this, parent, _("Open %s?").printf(app_name), null);

            dialog.append_body(quick_install_build_icon_with_badge(appimage_path));

            var warning_text = _("Origins of %s application can not be verified. Are you sure you want to open it?").printf(app_name);
            var warning_markup = "<b>%s</b>".printf(GLib.Markup.escape_text(warning_text, -1));
            dialog.append_body(UiUtils.create_wrapped_label(warning_markup, true));
            dialog.append_body(UiUtils.create_wrapped_label(_("Install the AppImage to add it to your applications."), false, true));

            dialog.add_option("install", _("Install"));
            dialog.add_option("cancel", _("Cancel"), true);

            dialog.close_request.connect(() => {
                release_drop_window_lock(appimage_path);
                return false;
            });

            dialog.option_selected.connect((response) => {
                if (response == "install") {
                    quick_install_run(appimage_path, InstallMode.PORTABLE, null);
                }
            });

            dialog.present();
        }

        private void quick_install_present_update(string appimage_path, InstallationRecord record, string? candidate_version) {
            var parent = this.get_active_window();
            var dialog = new DialogWindow(this, parent, _("Update %s?").printf(record.name), null);

            dialog.append_body(quick_install_build_icon_with_badge(appimage_path, record));

            var version_text = record.version ?? _("Version unknown");
            var current_label = UiUtils.create_wrapped_label(version_text, false);
            current_label.add_css_class("dim-label");
            dialog.append_body(current_label);

            var new_version = candidate_version ?? _("Unknown version");
            dialog.append_body(UiUtils.create_wrapped_label(_("Will update to version %s").printf(new_version), false));

            dialog.add_option("update", _("Update"), true);
            dialog.add_option("cancel", _("Cancel"));

            dialog.close_request.connect(() => {
                release_drop_window_lock(appimage_path);
                return false;
            });

            dialog.option_selected.connect((response) => {
                if (response == "update") {
                    quick_install_run(appimage_path, record.mode, record);
                }
            });

            dialog.present();
        }

        private void quick_install_present_replace(string appimage_path, InstallationRecord record, string? candidate_version, bool installed_newer) {
            var parent = this.get_active_window();
            var dialog = new DialogWindow(this, parent, _("Replace %s?").printf(record.name), null);

            dialog.append_body(quick_install_build_icon_with_badge(appimage_path, record));

            string replace_text;
            if (installed_newer) {
                replace_text = _("A newer item named %s already exists in this location. Do you want to replace it with the older one you're copying?").printf(record.name);
                if (record.version != null && candidate_version != null) {
                    var versions = _("Installed: %s | Incoming: %s").printf(record.version, candidate_version);
                    dialog.append_body(UiUtils.create_wrapped_label(GLib.Markup.escape_text(versions, -1), true, true));
                }
            } else {
                replace_text = _("An item named %s already exists in this location. Do you want to replace it with one you're copying?").printf(record.name);
            }
            dialog.append_body(UiUtils.create_wrapped_label(GLib.Markup.escape_text(replace_text, -1), true));

            var replace_is_default = !installed_newer;
            dialog.add_option("stop", _("Stop"), !replace_is_default);
            dialog.add_option("replace", _("Replace"), replace_is_default);

            dialog.close_request.connect(() => {
                release_drop_window_lock(appimage_path);
                return false;
            });

            dialog.option_selected.connect((response) => {
                if (response == "replace") {
                    quick_install_run(appimage_path, record.mode, record);
                }
            });

            dialog.present();
        }

        private void quick_install_run(string appimage_path, InstallMode mode, InstallationRecord? existing) {
            // Stage a copy
            string staged_path;
            string staged_dir;
            try {
                staged_dir = Utils.FileUtils.create_temp_dir("appmgr-stage-");
                staged_path = Path.build_filename(staged_dir, Path.get_basename(appimage_path));
                Utils.FileUtils.file_copy(appimage_path, staged_path);
            } catch (Error e) {
                release_drop_window_lock(appimage_path);
                quick_install_show_error(e.message);
                return;
            }

            quick_install_run_async.begin(appimage_path, staged_path, staged_dir, mode, existing);
        }

        private async void quick_install_run_async(string appimage_path, string staged_path, string staged_dir, InstallMode mode, InstallationRecord? existing) {
            SourceFunc callback = quick_install_run_async.callback;
            InstallationRecord? record = null;
            Error? error = null;
            bool upgraded = (existing != null);

            new Thread<void>("appmgr-quick-install", () => {
                try {
                    if (existing != null) {
                        record = installer.upgrade(staged_path, existing);
                    } else {
                        record = installer.install(staged_path, mode);
                    }
                } catch (Error e) {
                    error = e;
                }
                Idle.add((owned) callback);
            });

            yield;

            Utils.FileUtils.remove_dir_recursive(staged_dir);

            // Delete source AppImage on success
            if (error == null) {
                try {
                    var source = File.new_for_path(appimage_path);
                    if (source.query_exists()) {
                        source.delete(null);
                    }
                } catch (Error e) {
                    warning("Failed to delete original AppImage: %s", e.message);
                }
            }

            release_drop_window_lock(appimage_path);

            if (error != null) {
                quick_install_show_error(error.message);
            } else if (record != null) {
                quick_install_show_success(record, upgraded);
            }
        }

        private void quick_install_show_success(InstallationRecord record, bool upgraded) {
            var parent = this.get_active_window();
            var title = upgraded ? _("Successfully Updated") : _("Successfully Installed");

            var image = new Gtk.Image();
            image.set_pixel_size(64);
            image.halign = Gtk.Align.CENTER;
            var record_icon = UiUtils.load_record_icon(record);
            if (record_icon != null) {
                image.set_from_paintable(record_icon);
            } else {
                image.set_from_icon_name("application-x-executable");
            }

            var dialog = new DialogWindow(this, parent, title, image);
            var app_name_markup = "<b>%s</b>".printf(GLib.Markup.escape_text(record.name, -1));
            dialog.append_body(UiUtils.create_wrapped_label(app_name_markup, true));

            var version_text = record.version ?? _("Unknown version");
            var version_label = UiUtils.create_wrapped_label(_("Version %s").printf(version_text), false);
            version_label.add_css_class("dim-label");
            dialog.append_body(version_label);

            dialog.add_option("open", _("Open"), true);
            dialog.add_option("done", _("Done"));
            dialog.option_selected.connect((response) => {
                if (response == "open") {
                    try {
                        if (record.desktop_file != null && record.desktop_file.strip() != "") {
                            var app_info = new DesktopAppInfo.from_filename(record.desktop_file);
                            if (app_info != null) {
                                app_info.launch(null, null);
                            }
                        }
                    } catch (Error e) {
                        warning("Launch error: %s", e.message);
                    }
                }
            });

            dialog.present();
        }

        private void quick_install_show_error(string message) {
            var parent = this.get_active_window();
            var error_icon = new Gtk.Image.from_icon_name("dialog-error-symbolic");
            error_icon.set_pixel_size(64);
            error_icon.halign = Gtk.Align.CENTER;

            var dialog = new DialogWindow(this, parent, _("Installation failed"), error_icon);
            dialog.append_body(UiUtils.create_wrapped_label(GLib.Markup.escape_text(message, -1), true));
            dialog.add_option("dismiss", _("Dismiss"));
            dialog.present();
        }

        /**
         * Opens a drop window for the given file.
         * Public method to allow MainWindow to trigger installs via drag & drop.
         */
        public void open_drop_window(GLib.File file) {
            show_drop_window(file);
        }

        /**
         * Checks if AppManager itself is installed (when running as AppImage).
         */
        private bool is_self_installed() {
            var appimage = AppPaths.appimage_path;
            if (appimage == null) {
                return true; // Not an AppImage, consider "installed"
            }
            try {
                var checksum = Utils.FileUtils.compute_checksum(appimage);
                return registry.is_installed_checksum(checksum);
            } catch (Error e) {
                warning("Failed to compute checksum for self-install check: %s", e.message);
                return true; // On error, don't block the user
            }
        }

        /**
         * Shows the installer window for self-installation.
         */
        private void show_self_install_window() {
            var appimage = AppPaths.appimage_path;
            if (appimage == null) {
                activate();
                return;
            }
            
            // Prevent duplicate windows using file-based locking
            if (!try_acquire_drop_window_lock(appimage)) {
                debug("Self-install window already open for %s (locked by another instance), ignoring", appimage);
                return;
            }
            
            try {
                debug("Opening self-install window for %s", appimage);
                var window = new DropWindow(this, registry, installer, settings, appimage);
                // After successful install, show the main window
                window.close_request.connect(() => {
                    release_drop_window_lock(appimage);
                    // Check if we're now installed
                    if (is_self_installed()) {
                        // Re-activate to show main window
                        Idle.add(() => {
                            activate();
                            return Source.REMOVE;
                        });
                    }
                    return false; // Allow window to close
                });
                window.present();
            } catch (Error e) {
                release_drop_window_lock(appimage);
                critical("Failed to open self-install window: %s", e.message);
                // Fall back to main window
                if (main_window == null) {
                    main_window = new MainWindow(this, registry, installer, settings);
                }
                main_window.present();
            }
        }

        protected override int command_line(GLib.ApplicationCommandLine command_line) {
            if (opt_background_update) {
                return run_background_update(command_line);
            }
            
            var file_list = new ArrayList<GLib.File>();

            // Handle non-option arguments (file paths)
            var args = command_line.get_arguments();

            // Support subcommand-style: app-manager install PATH / app-manager uninstall PATH
            // (--install/--uninstall flags are handled by GLib option parser as hidden options)
            if (args.length > 2 && opt_install == null && args[1] == "install") {
                opt_install = args[2];
            } else if (args.length > 2 && opt_uninstall == null && args[1] == "uninstall") {
                opt_uninstall = args[2];
            }
            debug("command_line: got %u args", args.length);
            for (int _k = 0; _k < args.length; _k++)
                debug("command_line arg[%d] = %s", _k, args[_k]);
            for (int i = 1; i < args.length; i++) {
                var arg = args[i];
                // Skip already-processed option arguments and subcommands
                if (arg == "--install" || arg == "--uninstall" || arg == "--is-installed" ||
                    arg == "--background-update" || arg == "--help" || arg == "-h" || arg == "--version" ||
                    arg == "install" || arg == "uninstall") {
                    if (arg == "--install" || arg == "--uninstall" || arg == "--is-installed" ||
                        arg == "install" || arg == "uninstall") {
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
                var arr = new GLib.File[file_list.size];
                for (int k = 0; k < file_list.size; k++) arr[k] = file_list.get(k);
                this.open(arr, "");
                return 0;
            }

            if (opt_install != null) {
                try {
                    // Check architecture compatibility before installing
                    var metadata = new AppImageMetadata(File.new_for_path(opt_install));
                    if (!metadata.is_architecture_compatible()) {
                        var appimage_arch = metadata.architecture ?? "unknown";
                        command_line.printerr("Install failed: This AppImage is built for %s and cannot run on this system\n", appimage_arch);
                        return 2;
                    }

                    // Check for existing installation to replace/upgrade
                    var existing = detect_existing_for_cli_install(opt_install);
                    InstallationRecord record;
                    if (existing != null) {
                        record = installer.upgrade(opt_install, existing);
                        command_line.print("Updated %s\n", record.name);
                    } else {
                        record = installer.install(opt_install);
                        command_line.print("Installed %s\n", record.name);
                    }
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
            uninstall_record_async.begin(record, parent_window);
        }

        private async void uninstall_record_async(InstallationRecord record, Gtk.Window? parent_window) {
            SourceFunc callback = uninstall_record_async.callback;
            Error? error = null;

            new Thread<void>("appmgr-uninstall", () => {
                try {
                    installer.uninstall(record);
                } catch (Error e) {
                    error = e;
                }
                Idle.add((owned) callback);
            });

            yield;

            if (error != null) {
                var dialog = new Adw.AlertDialog(
                    _("Uninstall failed"),
                    _("%s could not be removed: %s").printf(record.name, error.message)
                );
                dialog.add_response("close", _("Close"));
                dialog.set_default_response("close");
                dialog.present(parent_window ?? main_window);
            } else {
                if (parent_window != null && parent_window is MainWindow) {
                    ((MainWindow)parent_window).add_toast(_("Moved to Trash"));
                }
            }
        }

        public void extract_installation(InstallationRecord record, Gtk.Window? parent_window) {
            var source_path = record.installed_path ?? "";
            if (record.mode != InstallMode.PORTABLE || source_path.strip() == "") {
                present_extract_error(parent_window, record, _("Extraction is only available for portable installations."));
                return;
            }

            extract_installation_async.begin(record, parent_window, source_path);
        }

        private async void extract_installation_async(InstallationRecord record, Gtk.Window? parent_window, string source_path) {
            SourceFunc callback = extract_installation_async.callback;
            InstallationRecord? new_record = null;
            Error? error = null;
            string? staging_dir = null;

            new Thread<void>("appmgr-extract", () => {
                string staged_path = "";
                try {
                    staging_dir = Utils.FileUtils.create_temp_dir("appmgr-extract-");
                    staged_path = Path.build_filename(staging_dir, Path.get_basename(source_path));
                    Utils.FileUtils.file_copy(source_path, staged_path);
                    new_record = installer.reinstall(staged_path, record, InstallMode.EXTRACTED);
                } catch (Error e) {
                    error = e;
                } finally {
                    if (staging_dir != null) {
                        Utils.FileUtils.remove_dir_recursive(staging_dir);
                    }
                }
                Idle.add((owned) callback);
            });

            yield;

            if (error != null) {
                present_extract_error(parent_window, record, error.message);
            } else if (new_record != null) {
                if (parent_window != null && parent_window is MainWindow) {
                    ((MainWindow)parent_window).add_toast(_("Extracted for faster launch"));
                } else {
                    var dialog = new Adw.AlertDialog(
                        _("Extraction complete"),
                        _("%s was extracted and will open faster.").printf(new_record.name)
                    );
                    dialog.add_response("close", _("Close"));
                    dialog.set_close_response("close");
                    dialog.present(parent_window ?? main_window);
                }
            }
        }

        private void present_extract_error(Gtk.Window? parent_window, InstallationRecord record, string message) {
            var dialog = new Adw.AlertDialog(
                _("Extraction failed"),
                _("%s could not be extracted: %s").printf(record.name, message)
            );
            dialog.add_response("close", _("Close"));
            dialog.set_close_response("close");
            dialog.present(parent_window ?? main_window);
        }

        /**
         * Detects if an AppImage being installed via CLI matches an existing installation.
         * Extracts metadata and uses shared registry detection.
         */
        private InstallationRecord? detect_existing_for_cli_install(string appimage_path) {
            try {
                var file = File.new_for_path(appimage_path);
                if (!file.query_exists()) {
                    return null;
                }

                var checksum = Utils.FileUtils.compute_checksum(appimage_path);
                
                // Try to extract app name from .desktop file
                string? app_name = null;
                string? temp_dir = null;
                try {
                    temp_dir = Utils.FileUtils.create_temp_dir("appmgr-cli-");
                    var desktop_file = Core.AppImageAssets.extract_desktop_entry(appimage_path, temp_dir);
                    if (desktop_file != null) {
                        var desktop_info = Core.AppImageAssets.parse_desktop_file(desktop_file);
                        if (desktop_info.name != null && desktop_info.name.strip() != "") {
                            app_name = desktop_info.name.strip();
                        }
                    }
                } finally {
                    if (temp_dir != null) {
                        Utils.FileUtils.remove_dir_recursive(temp_dir);
                    }
                }

                return registry.detect_existing(appimage_path, checksum, app_name);
            } catch (Error e) {
                warning("Failed to detect existing installation: %s", e.message);
            }

            return null;
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
                preferences_dialog = new PreferencesDialog(settings, registry, directory_monitor);
                preferences_dialog.closed.connect(() => {
                    preferences_dialog = null;
                });
            }

            preferences_dialog.present(parent);
        }

        private int run_background_update(GLib.ApplicationCommandLine command_line) {
            if (!settings.get_boolean("auto-check-updates")) {
                debug("Auto-check updates disabled; exiting");
                return 0;
            }

            if (bg_update_service == null) {
                bg_update_service = new BackgroundUpdateService(settings, registry, installer);
            }

            // Run as persistent daemon - this will block until session ends
            bg_update_service.run_daemon();
            return 0;
        }

        /**
         * Returns the path to the lock directory for drop window locks.
         */
        private string get_lock_dir() {
            var dir = Path.build_filename(Environment.get_user_runtime_dir(), "app-manager-locks");
            DirUtils.create_with_parents(dir, 0755);
            return dir;
        }

        /**
         * Returns the lock file path for a given AppImage path.
         */
        private string get_lock_file_path(string appimage_path) {
            // Use checksum of the path to create a unique lock file name
            var checksum = GLib.Checksum.compute_for_string(ChecksumType.MD5, appimage_path);
            return Path.build_filename(get_lock_dir(), "drop-window-%s.lock".printf(checksum));
        }

        /**
         * Tries to acquire an exclusive lock for opening a drop window.
         * Returns true if the lock was acquired, false if already locked.
         */
        private bool try_acquire_drop_window_lock(string appimage_path) {
            var lock_file_path = get_lock_file_path(appimage_path);
            
            // Check if lock file exists and is still valid (process still running)
            if (GLib.FileUtils.test(lock_file_path, FileTest.EXISTS)) {
                try {
                    string contents;
                    GLib.FileUtils.get_contents(lock_file_path, out contents);
                    var pid = int.parse(contents.strip());
                    
                    // Check if the process is still running
                    if (pid > 0 && Posix.kill(pid, 0) == 0) {
                        // Process is still running, lock is valid
                        return false;
                    }
                    // Process is dead, we can take over the lock
                    debug("Stale lock file found for %s (pid %d is dead), taking over", appimage_path, pid);
                } catch (Error e) {
                    // Error reading lock file, try to remove and recreate
                    debug("Error reading lock file: %s", e.message);
                }
            }
            
            // Create lock file with our PID
            try {
                var pid_str = "%d".printf(Posix.getpid());
                GLib.FileUtils.set_contents(lock_file_path, pid_str);
                owned_lock_files.add(lock_file_path);
                return true;
            } catch (Error e) {
                warning("Failed to create lock file %s: %s", lock_file_path, e.message);
                return false;
            }
        }

        /**
         * Releases the lock for a drop window.
         */
        private void release_drop_window_lock(string appimage_path) {
            var lock_file_path = get_lock_file_path(appimage_path);
            
            if (owned_lock_files.contains(lock_file_path)) {
                try {
                    var file = File.new_for_path(lock_file_path);
                    file.delete();
                } catch (Error e) {
                    debug("Failed to delete lock file %s: %s", lock_file_path, e.message);
                }
                owned_lock_files.remove(lock_file_path);
            }
        }

    }
}
