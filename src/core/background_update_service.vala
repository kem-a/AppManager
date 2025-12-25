using Gee;
using Xdp;
using GLib;

namespace AppManager.Core {
    public class BackgroundUpdateService : Object {
        private GLib.Settings settings;
        private InstallationRegistry registry;
        private Updater updater;
        private Xdp.Portal? portal;
        private string update_log_path;

        public BackgroundUpdateService(GLib.Settings settings, InstallationRegistry registry, Installer installer) {
            this.settings = settings;
            this.registry = registry;
            this.updater = new Updater(registry, installer);
            this.update_log_path = Path.build_filename(AppPaths.data_dir, "updates.log");
        }

        public async bool request_background_permission(GLib.Object? parent, Cancellable? cancellable = null) {
            if (settings.get_boolean("background-permission-requested")) {
                return true;
            }

            portal = new Xdp.Portal();

            try {
                var message = I18n.tr("AppManager needs permission to check for updates in the background");
                
                // Build the command list for autostart
                var commandline = new GLib.GenericArray<weak string>();
                var exec_path = AppPaths.current_executable_path ?? "app-manager";
                commandline.add(exec_path);
                commandline.add("--background-update");
                
                var granted = yield portal.request_background(
                    null,
                    message,
                    commandline,
                    Xdp.BackgroundFlags.AUTOSTART,
                    cancellable
                );
                
                if (granted) {
                    // Portal creates the autostart file but doesn't populate Exec line
                    // Write it ourselves to ensure it's complete
                    write_autostart_file();
                }
                
                settings.set_boolean("background-permission-requested", true);
                return granted;
            } catch (Error e) {
                warning("Failed to request background permission: %s", e.message);
                return false;
            }
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
            settings.set_int64("last-update-check", new GLib.DateTime.now_utc().to_unix());
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
