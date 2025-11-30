# AppManager TODO List

## Background Update Checks using libportal

### Overview
Implement automatic background update checks using the XDG Background Portal (libportal). This allows AppManager to check for AppImage updates in the background without keeping the main application running, while respecting user privacy and system resources.

### Implementation Steps

#### 1. Add libportal Dependency

**File: `meson.build`**
- Add `libportal = dependency('libportal', version: '>= 0.6')` to dependencies
- Add `libportal-gtk4 = dependency('libportal-gtk4', version: '>= 0.6')` for GTK4 integration
- Include in the main executable dependencies array

**File: `data/com.github.AppManager.metainfo.xml`**
- Document the new background permission requirement in the release notes

#### 2. Add GSettings Keys for Background Updates

**File: `data/com.github.AppManager.gschema.xml`**
Add the following keys:

```xml
<key name="auto-check-updates" type="b">
  <default>true</default>
  <summary>Automatically check for updates in background</summary>
  <description>When enabled, AppManager will periodically check for AppImage updates using the XDG Background Portal</description>
</key>

<key name="update-check-interval" type="i">
  <default>86400</default>
  <summary>Update check interval in seconds</summary>
  <description>How often to check for updates (default: 86400 = 24 hours, minimum: 3600 = 1 hour)</description>
</key>

<key name="last-update-check" type="x">
  <default>0</default>
  <summary>Timestamp of last update check</summary>
  <description>Unix timestamp of the last successful background update check</description>
</key>

<key name="background-permission-requested" type="b">
  <default>false</default>
  <summary>Whether background permission was already requested</summary>
  <description>Tracks if the user was already prompted for background permission</description>
</key>
```

#### 3. Create Background Update Checker Service

**New File: `src/core/background_update_service.vala`**

```vala
using AppManager.Core;

namespace AppManager.Core {
    public class BackgroundUpdateService : Object {
        private Settings settings;
        private InstallationRegistry registry;
        private Updater updater;
        private Xdp.Portal? portal;
        
        public signal void updates_found(int count);
        
        public BackgroundUpdateService(Settings settings, InstallationRegistry registry) {
            this.settings = settings;
            this.registry = registry;
            this.updater = new Updater(registry, null);
        }
        
        public async bool request_background_permission(Gtk.Window? parent) {
            if (settings.get_boolean("background-permission-requested")) {
                return true;
            }
            
            portal = new Xdp.Portal();
            
            try {
                var parent_handle = parent != null ? 
                    Xdp.parent_new_gtk(parent) : null;
                
                var result = yield portal.request_background(
                    parent_handle,
                    I18n.tr("AppManager needs permission to check for updates in the background"),
                    null,  // no commandline needed - we use activation
                    Xdp.BackgroundFlags.AUTOSTART,
                    null
                );
                
                settings.set_boolean("background-permission-requested", true);
                return result;
            } catch (Error e) {
                warning("Failed to request background permission: %s", e.message);
                return false;
            }
        }
        
        public async void perform_background_check(Cancellable? cancellable = null) {
            if (!settings.get_boolean("auto-check-updates")) {
                return;
            }
            
            var updates_available = new Gee.ArrayList<UpdateCheckResult>();
            
            foreach (var record in registry.list()) {
                if (cancellable != null && cancellable.is_cancelled()) {
                    break;
                }
                
                var result = yield check_single_app(record, cancellable);
                if (result != null && result.has_update) {
                    updates_available.add(result);
                }
            }
            
            settings.set_int64("last-update-check", new DateTime.now_utc().to_unix());
            
            if (updates_available.size > 0) {
                updates_found(updates_available.size);
            }
        }
        
        private async UpdateCheckResult? check_single_app(
            InstallationRecord record,
            Cancellable? cancellable
        ) {
            var update_url = updater.get_update_url(record);
            if (update_url == null) {
                return null;
            }
            
            // Add lightweight check method to Updater that only fetches
            // release info without downloading assets
            try {
                // TODO: Implement Updater.check_for_update_async()
                // This should return version info without downloading
                return null;
            } catch (Error e) {
                debug("Background check failed for %s: %s", record.name, e.message);
                return null;
            }
        }
        
        public bool should_check_now() {
            if (!settings.get_boolean("auto-check-updates")) {
                return false;
            }
            
            int64 last_check = settings.get_int64("last-update-check");
            int64 now = new DateTime.now_utc().to_unix();
            int interval = settings.get_int("update-check-interval");
            
            return (now - last_check) >= interval;
        }
    }
    
    public class UpdateCheckResult : Object {
        public InstallationRecord record { get; set; }
        public string new_version { get; set; }
        public bool has_update { get; set; }
        
        public UpdateCheckResult(InstallationRecord record, string new_version, bool has_update) {
            Object();
            this.record = record;
            this.new_version = new_version;
            this.has_update = has_update;
        }
    }
}
```

#### 4. Integrate into Application Class

**File: `src/application.vala`**

Modifications needed:

1. Add private field: `private BackgroundUpdateService? bg_update_service;`

2. In `startup()` method, after creating registry:
   ```vala
   bg_update_service = new BackgroundUpdateService(settings, registry);
   bg_update_service.updates_found.connect(on_background_updates_found);
   ```

3. In `activate()` method, request permission on first launch:
   ```vala
   protected override void activate() {
       if (main_window == null) {
           main_window = new MainWindow(this, registry, installer, settings);
           
           // Request background permission on first launch
           if (settings.get_boolean("auto-check-updates") && 
               !settings.get_boolean("background-permission-requested")) {
               request_background_updates.begin();
           }
       }
       
       // Check if background check is due when window opens
       if (bg_update_service.should_check_now()) {
           perform_background_check.begin();
       }
       
       main_window.present();
   }
   ```

4. Add helper methods:
   ```vala
   private async void request_background_updates() {
       yield bg_update_service.request_background_permission(main_window);
   }
   
   private async void perform_background_check() {
       var cancellable = new Cancellable();
       yield bg_update_service.perform_background_check(cancellable);
   }
   
   private void on_background_updates_found(int count) {
       send_update_notification(count);
   }
   
   private void send_update_notification(int count) {
       var notification = new GLib.Notification(
           ngettext(
               "Update available for %d app",
               "Updates available for %d apps",
               count
           ).printf(count)
       );
       
       notification.set_body(I18n.tr("Click to view and install updates"));
       notification.set_default_action("app.activate");
       notification.add_button(I18n.tr("View Updates"), "app.activate");
       
       send_notification("updates-available", notification);
   }
   ```

#### 5. Add Check-Only Method to Updater

**File: `src/core/updater.vala`**

Add a lightweight version check method that doesn't download:

```vala
public async UpdateCheckInfo? check_for_update_async(
    InstallationRecord record,
    Cancellable? cancellable = null
) throws Error {
    var update_url = read_update_url(record);
    if (update_url == null || update_url.strip() == "") {
        return null;
    }
    
    var source = resolve_update_source(update_url, record.version);
    if (source == null) {
        return null;
    }
    
    var release = fetch_release_for_source(source, cancellable);
    if (release == null) {
        return null;
    }
    
    var latest_version = release.normalized_version;
    var current_version = source.current_version;
    
    if (latest_version != null && current_version != null) {
        if (compare_versions(latest_version, current_version) > 0) {
            var asset = source.select_asset(release.assets);
            if (asset != null) {
                return new UpdateCheckInfo(
                    true,
                    latest_version,
                    current_version,
                    release.tag_name ?? latest_version
                );
            }
        }
    }
    
    return new UpdateCheckInfo(false, current_version, current_version, null);
}

public class UpdateCheckInfo : Object {
    public bool has_update { get; set; }
    public string latest_version { get; set; }
    public string current_version { get; set; }
    public string? display_version { get; set; }
    
    public UpdateCheckInfo(bool has_update, string latest, string current, string? display) {
        Object();
        this.has_update = has_update;
        this.latest_version = latest;
        this.current_version = current;
        this.display_version = display;
    }
}
```

#### 6. Add Preferences UI

**File: `src/windows/main_window.vala`**

Add a preferences page with update settings:

```vala
private Adw.PreferencesGroup create_update_preferences() {
    var group = new Adw.PreferencesGroup();
    group.title = I18n.tr("Updates");
    group.description = I18n.tr("Configure automatic update checking");
    
    var auto_check_row = new Adw.SwitchRow();
    auto_check_row.title = I18n.tr("Check for updates automatically");
    auto_check_row.subtitle = I18n.tr("Periodically check for new versions in the background");
    settings.bind("auto-check-updates", auto_check_row, "active", SettingsBindFlags.DEFAULT);
    
    var interval_row = new Adw.ComboRow();
    interval_row.title = I18n.tr("Check interval");
    var interval_model = new Gtk.StringList(null);
    interval_model.append(I18n.tr("Every hour"));     // 3600
    interval_model.append(I18n.tr("Every 6 hours"));  // 21600
    interval_model.append(I18n.tr("Daily"));          // 86400
    interval_model.append(I18n.tr("Weekly"));         // 604800
    interval_row.model = interval_model;
    
    // Bind to GSettings with custom conversion
    settings.bind("auto-check-updates", interval_row, "sensitive", SettingsBindFlags.GET);
    
    group.add(auto_check_row);
    group.add(interval_row);
    
    return group;
}
```

#### 7. Update Meson Build Files

**File: `src/meson.build`**

1. Add libportal dependencies to the dependency list
2. Add `background_update_service.vala` to source files list
3. Ensure proper linking order

**File: `src/core/meson.build`** (if exists) or main meson.build:
Add to sources: `'core/background_update_service.vala'`

#### 8. Testing Strategy

1. **Manual Testing:**
   - Enable auto-check-updates in dconf-editor
   - Verify permission request dialog appears on first launch
   - Check that notification appears when updates are found
   - Verify background checks happen after interval expires
   - Test with various interval settings

2. **Logging:**
   - Add debug logs to track when background checks occur
   - Log permission grant/deny results
   - Log update check results

3. **Edge Cases:**
   - Test with no network connection
   - Test with apps that have no update URL
   - Test permission denial scenario
   - Test rapid app restarts

#### 9. Documentation Updates

**File: `README.md`**
- Add section explaining background update feature
- Document the libportal dependency
- Explain privacy implications (only checks when permitted)

**File: `docs/ARCHITECTURE.md`**
- Document the background update architecture
- Explain the portal-based approach
- Document GSettings keys

#### 10. Post-Install Setup

**File: `meson/post_install.sh`**

Ensure GSettings schemas are compiled after installation.

### Dependencies Required

- `libportal >= 0.6`
- `libportal-gtk4 >= 0.6`
- XDG Desktop Portal implementation (usually provided by desktop environment)

### Privacy Considerations

- User must explicitly grant permission via portal dialog
- Only checks for updates, never downloads without user action
- Respects user-configured intervals
- Can be completely disabled via GSettings
- No telemetry or tracking

### Benefits of This Approach

1. **System Integration:** Uses standard XDG portals, works across different desktop environments
2. **User Privacy:** Requires explicit permission, transparent to user
3. **Resource Efficient:** Only runs when needed, not a constant background service
4. **No Conflicts:** Portal handles scheduling, no confusion with main app window
5. **Future-Proof:** Portal API is stable and maintained by Flatpak/desktop ecosystem

### Alternative Considered: systemd User Timers

Systemd timers were considered but libportal is preferred because:
- Better cross-desktop compatibility (works on non-systemd systems)
- Automatic permission UI via portal
- Integrated with desktop notifications
- Sandboxing-friendly (works in Flatpak)
- Simpler user experience (no manual systemctl commands)

### Implementation Priority

- [ ] High: Add libportal dependency and GSettings keys
- [ ] High: Implement BackgroundUpdateService
- [ ] High: Add permission request in Application
- [ ] Medium: Implement check-only updater method
- [ ] Medium: Add preferences UI
- [ ] Low: Polish notification messages
- [ ] Low: Update documentation
