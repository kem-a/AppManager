namespace AppManager.Core {
    /**
     * Monitors the Applications directory, extracted apps directory,
     * and the registry file for changes.
     * 
     * During migration, monitoring is completely stopped (not just paused).
     * The migration_in_progress flag provides additional protection.
     */
    public class DirectoryMonitor : Object {
        private FileMonitor? applications_monitor;
        private FileMonitor? extracted_monitor;
        private FileMonitor? registry_file_monitor;
        private InstallationRegistry registry;
        
        public signal void changes_detected();
        
        public DirectoryMonitor(InstallationRegistry registry) {
            this.registry = registry;
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
            
            // Only handle deletions - additions are detected via registry file monitoring
            if (event_type != FileMonitorEvent.DELETED && event_type != FileMonitorEvent.MOVED_OUT) {
                return;
            }
            
            var path = file.get_path();
            if (path == null) {
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
                debug("Detected manual deletion of portable app: %s", path);
                changes_detected();
            }
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
