using Gee;
using GLib;

namespace AppManager.Core {
    public class BackgroundUpdateService : Object {
        private GLib.Settings settings;
        private InstallationRegistry registry;
        private Updater updater;
        private StagedUpdatesManager staged_updates;
        private uint32 notification_id = 0;
        private DBusConnection? dbus_connection = null;
        private uint action_signal_id = 0;
        private bool check_in_progress = false;
        private Cancellable? check_cancellable = null;
        private MainLoop? daemon_loop = null;

        public BackgroundUpdateService(GLib.Settings settings, InstallationRegistry registry, Installer installer) {
            this.settings = settings;
            this.registry = registry;
            this.updater = new Updater(registry, installer);
            this.staged_updates = new StagedUpdatesManager();
        }

        /**
         * Resolves the executable the background updater autostart entry should launch.
         * The running process can still report the pre-self-install or pre-migration
         * AppImage path through $APPIMAGE, so prefer the registered self-install.
         */
        public static string resolve_self_exec_path(InstallationRegistry? registry) {
            // A distro/package install has no meaningful $APPIMAGE and must keep
            // launching itself, even if an old self-install record still exists.
            if (registry != null && AppPaths.is_running_as_appimage) {
                foreach (var record in registry.list()) {
                    if (!record.is_self_app()) {
                        continue;
                    }
                    var path = record.installed_path;
                    if (path == null || path.strip() == "") {
                        continue;
                    }
                    if (File.new_for_path(path).query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                        path = Path.build_filename(path, "AppRun");
                    }
                    if (FileUtils.test(path, FileTest.EXISTS)) {
                        return path;
                    }
                }
            }
            return AppPaths.current_executable_path ?? "app-manager";
        }

        /**
         * Writes the autostart desktop file to enable background updates.
         * Public so PreferencesDialog can use it when the user enables auto-updates.
         */
        public static void write_autostart_file(InstallationRegistry? registry = null) {
            try {
                var autostart_dir = Path.build_filename(Environment.get_user_config_dir(), "autostart");
                DirUtils.create_with_parents(autostart_dir, 0755);
                
                var autostart_file = Path.build_filename(autostart_dir, "com.github.AppManager.desktop");
                var exec_path = resolve_self_exec_path(registry);
                var exec_token = Utils.FileUtils.quote_exec_token(exec_path);
                var content = """[Desktop Entry]
Type=Application
Name=AppManager Background Updater
Exec=%s --background-update
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=15
NoDisplay=true
X-XDP-Autostart=com.github.AppManager
""".printf(exec_token);
                FileUtils.set_contents(autostart_file, content);
                debug("Autostart file written to %s", autostart_file);
            } catch (Error e) {
                warning("Failed to write autostart file: %s", e.message);
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
        public static void spawn_daemon(InstallationRegistry? registry = null) {
            // Check if daemon is already running
            if (is_daemon_running()) {
                debug("Background daemon already running, not spawning another");
                return;
            }

            try {
                var exec_path = resolve_self_exec_path(registry);
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
         * pgrep/pkill match every user by default. Scope them to this process's
         * effective user so another account's daemon is neither detected as ours
         * nor blocks starting our own.
         */
        private static string current_uid() {
            return "%u".printf((uint) Posix.geteuid());
        }

        /**
         * Kills any running background daemon.
         * Called when user disables auto-updates in preferences.
         */
        public static void kill_daemon() {
            try {
                // Send SIGTERM (pkill's default) so the daemon runs its shutdown
                // handler and exits cleanly, letting the AppImage runtime unmount
                // its dwarfs mount. SIGKILL (-9) would orphan that mount in /tmp.
                // Match just "--background-update" to avoid issues with path variations
                // Use "--" to indicate end of options since pattern starts with "-"
                string[] argv = { "pkill", "-f", "-u", current_uid(), "--", "--background-update" };
                int exit_status;
                Process.spawn_sync(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                debug("Stopped background daemon (exit status: %d)", exit_status);
            } catch (SpawnError e) {
                warning("Failed to stop background daemon: %s", e.message);
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
            
            // Migration must not race a live daemon. If the graceful SIGTERM
            // didn't land in time (e.g. daemon blocked mid update-check), escalate
            // to SIGKILL. This can orphan the dwarfs mount, but a safe migration
            // outweighs a stale /tmp symlink that cleanup_stale() reaps next launch.
            warning("Background daemon did not terminate within 5 seconds; sending SIGKILL");
            try {
                string[] argv = { "pkill", "-9", "-f", "-u", current_uid(), "--", "--background-update" };
                Process.spawn_sync(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null, null, null, null);
            } catch (SpawnError e) {
                warning("Failed to force-kill background daemon: %s", e.message);
            }
            return true;
        }

        /**
         * Async variant of kill_daemon_and_wait(): runs the same blocking
         * wait on a worker thread so the caller's main loop keeps spinning.
         * Calling the synchronous version from the UI thread stalls it for
         * up to 5 seconds, long enough for the desktop shell to declare the
         * window unresponsive and offer its "Wait / Force Quit" dialog.
         */
        public static async bool kill_daemon_and_wait_async() {
            SourceFunc callback = kill_daemon_and_wait_async.callback;
            bool was_running = false;

            new Thread<void>("kill-update-daemon", () => {
                was_running = kill_daemon_and_wait();
                Idle.add((owned) callback);
            });

            yield;
            return was_running;
        }

        /**
         * Checks if the background daemon is already running.
         * Public so PreferencesDialog can check before migration.
         */
        public static bool is_daemon_running() {
            try {
                // Match just "--background-update" to avoid issues with path variations
                // Use "--" to indicate end of options since pattern starts with "-"
                string[] argv = { "pgrep", "-f", "-u", current_uid(), "--", "--background-update" };
                int exit_status;
                Process.spawn_sync(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                return exit_status == 0;
            } catch (SpawnError e) {
                return false;
            }
        }

        public async void perform_background_check(Cancellable? cancellable = null) {
            log_debug("background update: start");

            // Reload registry from disk to pick up changes made by the GUI process
            // (installs, upgrades, uninstalls) since the daemon last checked.
            registry.reload(false);

            if (!settings.get_boolean("auto-check-updates")) {
                log_debug("background update: auto-check disabled; skipping");
                return;
            }

            if (!NetworkMonitor.get_default().get_network_available()) {
                log_debug("background update: network unavailable; skipping (will retry)");
                return;
            }

            var records = registry.list();
            if (records.length == 0) {
                log_debug("background update: no installed records");
                settings.set_int64("last-update-check", new GLib.DateTime.now_utc().to_unix());
                return;
            }

            bool auto_update_enabled = settings.get_boolean("auto-update-apps");
            bool check_completed = false;
            ArrayList<UpdateResult>? update_results = null;
            ArrayList<UpdateProbeResult>? probe_results = null;
            if (auto_update_enabled) {
                log_debug("background update: performing auto-updates");
            } else {
                log_debug("background update: probing for updates (notify-only mode)");
            }

            // Off the main loop, so a stop signal can cancel a running check.
            SourceFunc callback = perform_background_check.callback;
            new Thread<void>("appmgr-background-check", () => {
                try {
                    TlsSession.with_session(() => {
                        if (auto_update_enabled) {
                            // Auto-update mode: download and install updates
                            update_results = updater.update_all(cancellable);
                        } else {
                            // Notify-only mode: probe for updates and send notification
                            probe_results = updater.probe_updates(cancellable);
                        }
                        check_completed = true;
                    });
                } catch (Error e) {
                    warning("background_check: TLS session error: %s", e.message);
                }
                Idle.add((owned) callback);
            });
            yield;

            bool cancelled = cancellable != null && cancellable.is_cancelled();
            if (update_results != null) {
                handle_update_results(update_results, cancelled);
            } else if (probe_results != null && !cancelled) {
                // A partial probe must not replace the staged updates.
                handle_probe_results(probe_results);
            }

            // Only stamp on a completed check. A failed run (TLS error, no
            // network) must retry on the next tick instead of consuming the
            // full update-check-interval (issue #141). So does a stopped one.
            if (check_completed && !cancelled) {
                settings.set_int64("last-update-check", new GLib.DateTime.now_utc().to_unix());
            } else {
                log_debug("background update: check did not complete; will retry on next tick");
            }
        }

        /**
         * Stages the updates a probe found and sends a notification if any.
         * Does not download or install updates. Saves staged updates to disk.
         */
        private void handle_probe_results(ArrayList<UpdateProbeResult> probe_results) {
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
                send_notification(
                    _("App updates available"),
                    _("%d app update(s) available").printf(updates_available)
                );
            }

            log_debug("background update: probe finished (updates_available=%d)".printf(updates_available));
        }

        /**
         * Logs auto-update results, updates staged updates and notifies about failures.
         */
        private void handle_update_results(ArrayList<UpdateResult> results, bool cancelled) {
            int updated = 0;
            int skipped = 0;
            int failed = 0;
            bool staged_changed = false;

            foreach (var result in results) {
                switch (result.status) {
                    case UpdateStatus.UPDATED:
                        updated++;
                        log_debug("background update: updated %s".printf(result.record.name ?? result.record.id));
                        append_update_log("UPDATED %s".printf(result.record.name ?? result.record.id));
                        // Remove from staged updates on successful install
                        staged_updates.remove(result.record.id);
                        staged_changed = true;
                        break;
                    case UpdateStatus.SKIPPED:
                        skipped++;
                        append_update_log("SKIPPED %s: %s".printf(result.record.name ?? result.record.id, result.message));
                        break;
                    case UpdateStatus.FAILED:
                        // After a stop request this is the cancellation itself.
                        if (cancelled) {
                            break;
                        }
                        failed++;
                        append_update_log("FAILED %s: %s".printf(result.record.name ?? result.record.id, result.message));
                        // Staged with its reason, so the window lists it as pending
                        // with a failure badge for a retry.
                        staged_updates.set_failure(result.record.id, result.record.name ?? result.record.id, result.message);
                        staged_changed = true;
                        break;
                }
            }

            if (staged_changed) {
                staged_updates.save();
            }

            if (failed > 0) {
                send_notification(
                    _("App updates failed"),
                    _("%d app update(s) failed").printf(failed)
                );
            }

            log_debug("background update: finished (updated=%d skipped=%d failed=%d)".printf(updated, skipped, failed));
        }

        /**
         * Sends a desktop notification via D-Bus.
         * Uses org.freedesktop.Notifications directly since background daemon
         * may not have a full GLib.Application context.
         * The notification includes a default action to open AppManager.
         */
        private void send_notification(string title, string body) {
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

                result.get("(u)", out notification_id);
                log_debug("background update: sent notification %u: %s".printf(notification_id, title));
                
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
         * Checks for staged updates on login and sends a notification only in notify-only mode.
         * This is called when the background daemon starts (on system login).
         * When auto-update is enabled, no notification is sent - updates are installed silently.
         */
        private void check_staged_updates_on_login() {
            if (!settings.get_boolean("auto-check-updates")) {
                log_debug("background daemon: auto-check disabled, skipping staged updates check on login");
                return;
            }

            // Only notify in notify-only mode; auto-update installs silently
            if (settings.get_boolean("auto-update-apps")) {
                log_debug("background daemon: auto-update enabled, skipping staged update notification on login");
                return;
            }

            // Reload staged updates from disk
            staged_updates.load();

            if (staged_updates.has_updates()) {
                int count = staged_updates.count();

                log_debug("background daemon: found %d staged update(s) on login, sending notification".printf(count));
                send_notification(
                    _("App updates available"),
                    _("%d app update(s) available").printf(count)
                );
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

        /**
         * Runs a background check if one is due and none is already running.
         * Single entry point for all triggers: periodic tick, resume from
         * suspend, and network reconnection.
         */
        private void maybe_check() {
            if (check_in_progress) {
                return;
            }
            if (!should_check_now()) {
                return;
            }
            check_in_progress = true;
            check_cancellable = new Cancellable();
            perform_background_check.begin(check_cancellable, (obj, res) => {
                perform_background_check.end(res);
                check_in_progress = false;
                if (check_cancellable.is_cancelled()) {
                    daemon_loop.quit();
                }
            });
        }

        // A running check is cancelled and quits the loop once it returns, so
        // an install already under way finishes instead of being cut off.
        private void stop_daemon() {
            if (check_in_progress) {
                check_cancellable.cancel();
            } else {
                daemon_loop.quit();
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

            var loop = new MainLoop();
            daemon_loop = loop;

            // Quit cleanly when the session manager / systemd asks us to stop.
            // GApplication installs no signal handlers and this daemon runs its
            // own MainLoop, so without this it would ignore SIGTERM on shutdown
            // and be SIGKILLed after the stop timeout (issue #114). Install the
            // handlers first so a stop request during the initial check is honored.
            Unix.signal_add(Posix.Signal.TERM, () => {
                log_debug("background daemon: SIGTERM received, stopping");
                stop_daemon();
                return Source.REMOVE;
            });
            Unix.signal_add(Posix.Signal.INT, () => {
                log_debug("background daemon: SIGINT received, stopping");
                stop_daemon();
                return Source.REMOVE;
            });

            // On login, re-notify about staged updates (notify-only mode only)
            check_staged_updates_on_login();

            // Check immediately on startup if interval has elapsed
            log_debug("background daemon: startup check");
            maybe_check();

            // Check periodically whether we should perform an update check
            // This allows the daemon to respect interval changes without restart
            var check_source_id = Timeout.add_seconds(DAEMON_CHECK_INTERVAL, () => {
                maybe_check();
                return Source.CONTINUE;
            });

            // Re-check as soon as the network comes back, so an overdue check
            // blocked by offline state doesn't wait for the next tick.
            var network_monitor = NetworkMonitor.get_default();
            ulong network_handler_id = network_monitor.network_changed.connect((available) => {
                if (available) {
                    log_debug("background daemon: network available, evaluating check");
                    maybe_check();
                }
            });

            // Re-evaluate after resume from suspend. GLib timers run on
            // CLOCK_MONOTONIC and freeze while the machine sleeps, so without
            // this a laptop that mostly suspends almost never reaches the
            // periodic tick (issue #141).
            DBusConnection? system_bus = null;
            uint sleep_signal_id = 0;
            try {
                system_bus = Bus.get_sync(BusType.SYSTEM);
                sleep_signal_id = system_bus.signal_subscribe(
                    "org.freedesktop.login1",
                    "org.freedesktop.login1.Manager",
                    "PrepareForSleep",
                    "/org/freedesktop/login1",
                    null,
                    DBusSignalFlags.NONE,
                    (conn, sender, object_path, interface_name, signal_name, parameters) => {
                        bool sleeping;
                        parameters.get("(b)", out sleeping);
                        if (!sleeping) {
                            log_debug("background daemon: resumed from suspend, scheduling check");
                            Timeout.add_seconds(RESUME_CHECK_DELAY, () => {
                                maybe_check();
                                return Source.REMOVE;
                            });
                        }
                    }
                );
            } catch (Error e) {
                warning("background daemon: could not subscribe to PrepareForSleep: %s", e.message);
            }

            // Run the main loop - this blocks until a stop signal quits it
            loop.run();

            // Clean shutdown: drop the periodic check and any D-Bus subscription
            // so we exit promptly instead of leaking sources and getting killed.
            Source.remove(check_source_id);
            network_monitor.disconnect(network_handler_id);
            if (system_bus != null && sleep_signal_id != 0) {
                system_bus.signal_unsubscribe(sleep_signal_id);
            }
            if (dbus_connection != null && action_signal_id != 0) {
                dbus_connection.signal_unsubscribe(action_signal_id);
                action_signal_id = 0;
            }
            log_debug("background daemon: stopped");
        }

        private void log_debug(string message) {
            debug("%s", message);
            append_update_log(message);
        }

        private void append_update_log(string message) {
            UpdateLog.append(message);
        }
    }
}
