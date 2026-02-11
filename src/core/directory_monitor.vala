namespace AppManager.Core {
    /**
     * Monitors the Applications directory, extracted apps directory,
     * and the registry file for changes.
     * 
     * During migration, monitoring is completely stopped (not just paused).
     * The migration_in_progress flag provides additional protection.
     *
     * Deletion events for portable apps are debounced with a grace period
     * to avoid false uninstalls when an app's built-in updater replaces
     * the AppImage file (e.g. Bitwarden). If the file reappears within
     * the grace window the pending removal is cancelled.
     */
    public class DirectoryMonitor : Object {
        private FileMonitor? applications_monitor;
        private FileMonitor? extracted_monitor;
        private FileMonitor? registry_file_monitor;
        private InstallationRegistry registry;
        
        /** Pending deletion checks: installed_path → GLib timeout source id */
        private HashTable<string, uint> pending_deletions;
        
        /**
         * Grace period (in milliseconds) before a deletion is considered real.
         * Gives built-in app updaters time to replace the file.
         */
        private const uint DELETION_GRACE_PERIOD_MS = 2000;
        
        public signal void changes_detected();
        
        public DirectoryMonitor(InstallationRegistry registry) {
            this.registry = registry;
            this.pending_deletions = new HashTable<string, uint>(GLib.str_hash, GLib.str_equal);
        }
        
        public void start() {
            try {
                // Monitor ~/Applications directory
                var applications_dir = File.new_for_path(AppPaths.applications_dir);
                applications_monitor = applications_dir.monitor_directory(
                    FileMonitorFlags.NONE,
                    null
                );
                applications_monitor.changed.connect(on_applications_changed);
                
                // Monitor ~/Applications/.extracted directory
                var extracted_dir = File.new_for_path(AppPaths.extracted_root);
                extracted_monitor = extracted_dir.monitor_directory(
                    FileMonitorFlags.NONE,
                    null
                );
                extracted_monitor.changed.connect(on_extracted_changed);
                
                // Monitor registry file for changes by other processes
                var registry_file = File.new_for_path(AppPaths.registry_file);
                registry_file_monitor = registry_file.monitor_file(
                    FileMonitorFlags.NONE,
                    null
                );
                registry_file_monitor.changed.connect(on_registry_file_changed);
                
                debug("Directory monitoring started for %s", AppPaths.applications_dir);
            } catch (Error e) {
                warning("Failed to start directory monitoring: %s", e.message);
            }
        }
        
        public void stop() {
            // Cancel all pending deletion timers
            cancel_all_pending_deletions();
            
            if (applications_monitor != null) {
                applications_monitor.cancel();
                applications_monitor = null;
            }
            if (extracted_monitor != null) {
                extracted_monitor.cancel();
                extracted_monitor = null;
            }
            if (registry_file_monitor != null) {
                registry_file_monitor.cancel();
                registry_file_monitor = null;
            }
            debug("Directory monitoring stopped");
        }
        
        private void on_registry_file_changed(File file, File? other_file, FileMonitorEvent event_type) {
            if (event_type != FileMonitorEvent.CHANGED && event_type != FileMonitorEvent.CHANGES_DONE_HINT) {
                return;
            }
            
            // Skip if migration is in progress
            if (registry.is_migration_in_progress()) {
                return;
            }
            
            debug("Registry file changed by another process, reloading");
            registry.reload(true);
        }
        
        private void on_applications_changed(File file, File? other_file, FileMonitorEvent event_type) {
            // Skip if migration is in progress
            if (registry.is_migration_in_progress()) {
                return;
            }
            
            var path = file.get_path();
            if (path == null) {
                return;
            }
            
            // When a file is created/changed at a path we have a pending deletion
            // for, the app's built-in updater has replaced the file – cancel the
            // pending uninstall.
            if (event_type == FileMonitorEvent.CREATED ||
                event_type == FileMonitorEvent.MOVED_IN ||
                event_type == FileMonitorEvent.CHANGES_DONE_HINT) {
                cancel_pending_deletion(path);
                return;
            }
            
            // Only handle deletions - additions are detected via registry file monitoring
            if (event_type != FileMonitorEvent.DELETED && event_type != FileMonitorEvent.MOVED_OUT) {
                return;
            }
            
            // Check if this file is in the registry as a PORTABLE installation
            var record = registry.lookup_by_installed_path(path);
            if (record != null && record.mode == InstallMode.PORTABLE) {
                // Skip if the app is in-flight (being installed/uninstalled)
                if (registry.is_in_flight(record.id)) {
                    debug("Ignoring deletion of in-flight app: %s", path);
                    return;
                }
                // Don't reconcile immediately – schedule a delayed check so that
                // apps with built-in updaters (e.g. Bitwarden) that replace their
                // own AppImage file are not mistakenly considered uninstalled.
                schedule_pending_deletion(path, record.name);
            }
        }
        
        /**
         * Schedules a delayed filesystem re-check for a deleted portable app.
         * If the file reappears within DELETION_GRACE_PERIOD_MS (e.g. replaced
         * by a built-in updater), the check is cancelled via cancel_pending_deletion().
         */
        private void schedule_pending_deletion(string path, string app_name) {
            // Cancel any existing timer for this path first
            cancel_pending_deletion(path);
            
            debug("Scheduling deletion check for '%s' in %u ms", app_name, DELETION_GRACE_PERIOD_MS);
            
            // We need owned copies for the closure
            var owned_path = path.dup();
            var owned_name = app_name.dup();
            
            var source_id = GLib.Timeout.add(DELETION_GRACE_PERIOD_MS, () => {
                // Remove from pending table (timer has fired)
                pending_deletions.remove(owned_path);
                
                // Skip if migration started during the grace period
                if (registry.is_migration_in_progress()) {
                    return GLib.Source.REMOVE;
                }
                
                // Re-check whether the file truly no longer exists
                var check_file = File.new_for_path(owned_path);
                if (!check_file.query_exists()) {
                    debug("Confirmed deletion of portable app after grace period: %s", owned_name);
                    changes_detected();
                } else {
                    debug("File reappeared during grace period (built-in update?), keeping: %s", owned_name);
                }
                
                return GLib.Source.REMOVE;
            });
            
            pending_deletions.insert(path.dup(), source_id);
        }
        
        /**
         * Cancels a pending deletion check for the given path.
         * Called when the file reappears (CREATED / MOVED_IN / CHANGES_DONE_HINT).
         */
        private void cancel_pending_deletion(string path) {
            if (pending_deletions.contains(path)) {
                var source_id = pending_deletions.get(path);
                GLib.Source.remove(source_id);
                pending_deletions.remove(path);
                debug("Cancelled pending deletion check – file reappeared: %s", path);
            }
        }
        
        /**
         * Cancels all pending deletion timers (used during stop()).
         */
        private void cancel_all_pending_deletions() {
            foreach (var source_id in pending_deletions.get_values()) {
                GLib.Source.remove(source_id);
            }
            pending_deletions.remove_all();
        }
        
        private void on_extracted_changed(File file, File? other_file, FileMonitorEvent event_type) {
            // Skip if migration is in progress
            if (registry.is_migration_in_progress()) {
                return;
            }
            
            if (event_type != FileMonitorEvent.DELETED && event_type != FileMonitorEvent.MOVED_OUT) {
                return;
            }
            
            var path = file.get_path();
            if (path == null) {
                return;
            }
            
            // For extracted apps, we need to check if the parent directory was deleted
            foreach (var record in registry.list()) {
                if (record.mode == InstallMode.EXTRACTED) {
                    if (path.has_prefix(record.installed_path) || path == record.installed_path) {
                        if (registry.is_in_flight(record.id)) {
                            debug("Ignoring deletion of in-flight extracted app: %s", record.name);
                            break;
                        }
                        debug("Detected manual deletion of extracted app: %s", record.name);
                        changes_detected();
                        break;
                    }
                }
            }
        }
    }
}
