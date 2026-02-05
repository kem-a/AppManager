using Gee;
using GLib;

namespace AppManager.Core {
    public class BackgroundUpdateService : Object {
        private GLib.Settings settings;
        private InstallationRegistry registry;
        private Updater updater;
        private StagedUpdatesManager staged_updates;
        private string update_log_path;
        private uint32 notification_id = 0;
        private DBusConnection? dbus_connection = null;
        private uint action_signal_id = 0;

        public BackgroundUpdateService(GLib.Settings settings, InstallationRegistry registry, Installer installer) {
            this.settings = settings;
            this.registry = registry;
            this.updater = new Updater(registry, installer);
            this.staged_updates = new StagedUpdatesManager();
            this.update_log_path = Path.build_filename(AppPaths.data_dir, "updates.log");
        }

        /**
         * Writes the autostart desktop file to enable background updates.
         * Public so PreferencesDialog can use it when the user enables auto-updates.
         */
        public static void write_autostart_file() {
            try {
                var autostart_dir = Path.build_filename(Environment.get_user_config_dir(), "autostart");
                DirUtils.create_with_parents(autostart_dir, 0755);
                
                var autostart_file = Path.build_filename(autostart_dir, "com.github.AppManager.desktop");
                var exec_path = AppPaths.current_executable_path ?? "app-manager";
                var content = """[Desktop Entry]
Type=Application
Name=AppManager Background Updater
Exec=%s --background-update
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=15
NoDisplay=true
X-XDP-Autostart=com.github.AppManager
""".printf(exec_path);
                FileUtils.set_contents(autostart_file, content);
                debug("Autostart file written to %s", autostart_file);
            } catch (Error e) {
                warning("Failed to write autostart file: %s", e.message);
            }
        }

        /**
         * Updates the autostart desktop file after migration.
         * The current executable path in memory still points to the old location,
         * so we need to calculate the new path based on the migration paths.
         */
        public static void update_autostart_file_after_migration(string old_base, string new_base) {
            var autostart_file = Path.build_filename(
                Environment.get_user_config_dir(),
                "autostart",
                "com.github.AppManager.desktop"
            );
            
            // Only update if autostart file exists
            if (!FileUtils.test(autostart_file, FileTest.EXISTS)) {
                return;
            }
            
            try {
                string contents;
                FileUtils.get_contents(autostart_file, out contents);
                
                // Replace old base path with new base path in Exec line
                var updated = contents.replace(old_base, new_base);
                
                if (updated != contents) {
                    FileUtils.set_contents(autostart_file, updated);
                    debug("Updated autostart file Exec path: %s -> %s", old_base, new_base);
                }
            } catch (Error e) {
                warning("Failed to update autostart file: %s", e.message);
            }
        }

        /**
         * Removes the autostart desktop file to disable background updates.
         * Public so PreferencesDialog can use it when the user disables auto-updates.
         */
        public static void remove_autostart_file() {
            var autostart_file = Path.build_filename(
                Environment.get_user_config_dir(),
                "autostart",
                "com.github.AppManager.desktop"
            );
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

        /**
         * Spawns the background daemon process if not already running.
         * Called when user enables auto-updates in preferences.
         */
        public static void spawn_daemon() {
            // Check if daemon is already running
            if (is_daemon_running()) {
                debug("Background daemon already running, not spawning another");
                return;
            }

            try {
                var exec_path = AppPaths.current_executable_path ?? "app-manager";
                string[] argv = { exec_path, "--background-update" };
                Pid child_pid;
                Process.spawn_async(
                    null,
                    argv,
                    null,
                    GLib.SpawnFlags.SEARCH_PATH | GLib.SpawnFlags.DO_NOT_REAP_CHILD,
                    null,
                    out child_pid
                );
                debug("Spawned background daemon with PID %d", (int) child_pid);
                
                // Don't wait for the child - let it run independently
                ChildWatch.add(child_pid, (pid, status) => {
                    Process.close_pid(pid);
                });
            } catch (SpawnError e) {
                warning("Failed to spawn background daemon: %s", e.message);
            }
        }

        /**
         * Kills any running background daemon process.
         * Called when user disables auto-updates in preferences.
         */
        public static void kill_daemon() {
            try {
                // Use pkill with SIGKILL (-9) to ensure the daemon is terminated
                // Match just "--background-update" to avoid issues with path variations
                // Use "--" to indicate end of options since pattern starts with "-"
                string[] argv = { "pkill", "-9", "-f", "--", "--background-update" };
                int exit_status;
                Process.spawn_sync(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                debug("Killed background daemon (exit status: %d)", exit_status);
            } catch (SpawnError e) {
                warning("Failed to kill background daemon: %s", e.message);
            }
        }

        /**
         * Kills any running background daemon and waits for it to fully terminate.
         * Returns true if daemon was running and was killed, false if it wasn't running.
         * This should be called before migration to ensure no background monitoring.
         */
        public static bool kill_daemon_and_wait() {
            if (!is_daemon_running()) {
                return false;
            }
            
            kill_daemon();
            
            // Wait for daemon to fully terminate (up to 5 seconds)
            for (int i = 0; i < 50; i++) {
                if (!is_daemon_running()) {
                    debug("Background daemon terminated after %d ms", i * 100);
                    return true;
                }
                Thread.usleep(100000); // 100ms
            }
            
            warning("Background daemon did not terminate within 5 seconds");
            return true;
        }

        /**
         * Checks if the background daemon is already running.
         * Public so PreferencesDialog can check before migration.
         */
        public static bool is_daemon_running() {
            try {
                // Match just "--background-update" to avoid issues with path variations
                // Use "--" to indicate end of options since pattern starts with "-"
                string[] argv = { "pgrep", "-f", "--", "--background-update" };
                int exit_status;
                Process.spawn_sync(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                return exit_status == 0;
            } catch (SpawnError e) {
                return false;
            }
        }

        public async void perform_background_check(Cancellable? cancellable = null) {
            log_debug("background update: start");

            if (!settings.get_boolean("auto-check-updates")) {
                log_debug("background update: auto-check disabled; skipping");
                return;
            }

            var records = registry.list();
            if (records.length == 0) {
                log_debug("background update: no installed records");
                settings.set_int64("last-update-check", new GLib.DateTime.now_utc().to_unix());
                return;
            }

            bool auto_update_enabled = settings.get_boolean("auto-update-apps");

            if (auto_update_enabled) {
                // Auto-update mode: download and install updates
                perform_auto_updates(cancellable);
            } else {
                // Notify-only mode: probe for updates and send notification
                perform_update_probe(cancellable);
            }

            settings.set_int64("last-update-check", new GLib.DateTime.now_utc().to_unix());
        }

        /**
         * Probes for available updates and sends a notification if any are found.
         * Does not download or install updates. Saves staged updates to disk.
         */
        private void perform_update_probe(Cancellable? cancellable) {
            log_debug("background update: probing for updates (notify-only mode)");

            var probe_results = updater.probe_updates(cancellable);
            int updates_available = 0;
            var app_names = new Gee.ArrayList<string>();

            // Clear previous staged updates and add newly discovered ones
            staged_updates.clear();

            foreach (var result in probe_results) {
                if (result.has_update) {
                    updates_available++;
                    var app_name = result.record.name ?? result.record.id;
                    app_names.add(app_name);
                    
                    // Stage the update so UI can display it
                    staged_updates.add(result.record.id, app_name, result.available_version);
                    
                    log_debug("background update: update available for %s (version: %s)".printf(
                        app_name, result.available_version ?? "unknown"));
                    append_update_log("UPDATE_AVAILABLE %s: %s".printf(
                        app_name, result.available_version ?? "unknown"));
                }
            }

            // Save staged updates to disk
            staged_updates.save();

            if (updates_available > 0) {
                send_updates_notification(updates_available, app_names);
            }

            log_debug("background update: probe finished (updates_available=%d)".printf(updates_available));
        }

        /**
         * Downloads and installs available updates (original behavior).
         */
        private void perform_auto_updates(Cancellable? cancellable) {
            log_debug("background update: performing auto-updates");

            var results = updater.update_all(cancellable);

            int updated = 0;
            int skipped = 0;
            int failed = 0;

            foreach (var result in results) {
                switch (result.status) {
                    case UpdateStatus.UPDATED:
                        updated++;
                        log_debug("background update: updated %s".printf(result.record.name ?? result.record.id));
                        append_update_log("UPDATED %s".printf(result.record.name ?? result.record.id));
                        break;
                    case UpdateStatus.SKIPPED:
                        skipped++;
                        append_update_log("SKIPPED %s: %s".printf(result.record.name ?? result.record.id, result.message));
                        break;
                    case UpdateStatus.FAILED:
                        failed++;
                        append_update_log("FAILED %s: %s".printf(result.record.name ?? result.record.id, result.message));
                        break;
                }
            }

            log_debug("background update: finished (updated=%d skipped=%d failed=%d)".printf(updated, skipped, failed));
        }

        /**
         * Sends a desktop notification about available updates via D-Bus.
         * Uses org.freedesktop.Notifications directly since background daemon
         * may not have a full GLib.Application context.
         * The notification includes a default action to open AppManager.
         */
        private void send_updates_notification(int count, Gee.ArrayList<string> app_names) {
            string title = _("App updates available");
            // Always show aggregate count
            string body = _("%d app update(s) available").printf(count);

            try {
                if (dbus_connection == null) {
                    dbus_connection = Bus.get_sync(BusType.SESSION);
                }

                // Build actions array: pairs of (action_key, label)
                // "default" action is invoked when user clicks the notification body
                string[] actions = { "default", _("Open AppManager") };

                // Hints dict - empty for now
                var hints_builder = new VariantBuilder(new VariantType("a{sv}"));

                var result = dbus_connection.call_sync(
                    "org.freedesktop.Notifications",
                    "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications",
                    "Notify",
                    new Variant("(susss@as@a{sv}i)",
                        "AppManager",                    // app_name
                        (uint32) 0,                      // replaces_id
                        "com.github.AppManager",         // app_icon
                        title,                           // summary
                        body,                            // body
                        new Variant.strv(actions),       // actions
                        hints_builder.end(),             // hints
                        -1                               // expire_timeout (-1 = default)
                    ),
                    VariantType.TUPLE,
                    DBusCallFlags.NONE,
                    -1,
                    null
                );

                // Store notification ID for action handling
                result.get("(u)", out notification_id);
                log_debug("background update: sent notification %u for %d update(s)".printf(notification_id, count));
                
                // Set up action handler after successful notification
                setup_notification_action_handler();
            } catch (Error e) {
                log_debug("background update: failed to send notification: %s".printf(e.message));
                warning("Failed to send notification via D-Bus: %s", e.message);
            }
        }

        /**
         * Sets up a D-Bus signal handler for notification actions.
         * When user clicks the notification, it opens AppManager.
         */
        private void setup_notification_action_handler() {
            if (dbus_connection == null || action_signal_id != 0) {
                return;
            }

            action_signal_id = dbus_connection.signal_subscribe(
                "org.freedesktop.Notifications",
                "org.freedesktop.Notifications",
                "ActionInvoked",
                "/org/freedesktop/Notifications",
                null,
                DBusSignalFlags.NONE,
                (conn, sender, object_path, interface_name, signal_name, parameters) => {
                    on_notification_action(conn, sender, object_path, interface_name, signal_name, parameters);
                }
            );
        }

        /**
         * Checks for staged updates on login and sends a notification if background update check is enabled.
         * This is called when the background daemon starts (on system login).
         */
        private void check_staged_updates_on_login() {
            if (!settings.get_boolean("auto-check-updates")) {
                log_debug("background daemon: auto-check disabled, skipping staged updates check on login");
                return;
            }

            // Reload staged updates from disk
            staged_updates.load();

            if (staged_updates.has_updates()) {
                int count = staged_updates.count();
                var app_names = new Gee.ArrayList<string>();
                
                foreach (var update in staged_updates.list()) {
                    app_names.add(update.record_name);
                }

                log_debug("background daemon: found %d staged update(s) on login, sending notification".printf(count));
                send_updates_notification(count, app_names);
            } else {
                log_debug("background daemon: no staged updates found on login");
            }
        }

        /**
         * Handles notification action invocations.
         * Opens AppManager when user clicks the notification.
         */
        private void on_notification_action(DBusConnection conn, string? sender, string object_path,
                                           string interface_name, string signal_name, Variant parameters) {
            uint32 id;
            string action_key;
            parameters.get("(us)", out id, out action_key);

            if (id == notification_id && action_key == "default") {
                launch_app_manager();
            }
        }

        /**
         * Launches the AppManager GUI application.
         */
        private void launch_app_manager() {
            try {
                var exec_path = AppPaths.current_executable_path ?? "app-manager";
                string[] argv = { exec_path };
                Pid child_pid;
                Process.spawn_async(
                    null,
                    argv,
                    null,
                    GLib.SpawnFlags.SEARCH_PATH | GLib.SpawnFlags.DO_NOT_REAP_CHILD,
                    null,
                    out child_pid
                );

                ChildWatch.add(child_pid, (pid, status) => {
                    Process.close_pid(pid);
                });
            } catch (SpawnError e) {
                warning("Failed to launch AppManager: %s", e.message);
            }
        }

        public bool should_check_now() {
            if (!settings.get_boolean("auto-check-updates")) {
                return false;
            }

            int64 last_check = settings.get_int64("last-update-check");
            int64 now = new GLib.DateTime.now_utc().to_unix();
            int interval = settings.get_int("update-check-interval");

            return (now - last_check) >= interval;
        }

        /**
         * Runs a persistent background daemon that periodically checks for updates.
         * This method blocks and runs a GLib main loop until the process is terminated.
         */
        public void run_daemon() {
            log_debug("background daemon: starting persistent service");

            // On login, check for staged updates and notify if auto-update is enabled
            check_staged_updates_on_login();

            // Check immediately on startup if interval has elapsed
            if (should_check_now()) {
                log_debug("background daemon: interval elapsed, checking now");
                perform_background_check.begin(null);
            } else {
                log_debug("background daemon: not yet time to check, waiting");
            }

            // Check periodically whether we should perform an update check
            // This allows the daemon to respect interval changes without restart
            Timeout.add_seconds(DAEMON_CHECK_INTERVAL, () => {
                if (!settings.get_boolean("auto-check-updates")) {
                    log_debug("background daemon: auto-check disabled, skipping");
                    return Source.CONTINUE;
                }

                if (should_check_now()) {
                    log_debug("background daemon: interval elapsed, checking now");
                    perform_background_check.begin(null);
                }

                return Source.CONTINUE;
            });

            // Run the main loop - this blocks until the session ends
            var loop = new MainLoop();
            loop.run();
        }

        private void log_debug(string message) {
            debug("%s", message);
            append_update_log(message);
        }

        private void append_update_log(string message) {
            DirUtils.create_with_parents(AppPaths.data_dir, 0755);
            var ts = new GLib.DateTime.now_local().format("%FT%T%z");
            var line = "%s %s\n".printf(ts, message);
            var file = FileStream.open(update_log_path, "a");
            if (file != null) {
                file.puts(line);
                file.flush();
            }
        }
    }
}
