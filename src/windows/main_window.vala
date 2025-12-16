using AppManager.Core;
using AppManager.Utils;

[CCode (cname = "adw_about_dialog_new_from_appdata")]
extern Adw.Dialog about_dialog_new_from_appdata_raw(string resource_path, string? release_notes_version);

namespace AppManager {
    public class MainWindow : Adw.Window {
        private Application app_ref;
        private InstallationRegistry registry;
        private Installer installer;
        private Settings settings;
        private Updater updater;
        private Adw.PreferencesGroup apps_group;
        private Adw.PreferencesPage general_page;
        private Gtk.Stack content_stack;
        private Gtk.Box empty_state_box;
        private Gtk.Label empty_state_label;
        private Gee.ArrayList<Adw.PreferencesRow> app_rows;
        private Gtk.ShortcutsWindow? shortcuts_window;
        private Adw.AboutDialog? about_dialog;
        private Adw.NavigationView navigation_view;
        private Adw.ToastOverlay toast_overlay;
        private Gtk.Button? update_button;
        private Gtk.Label? update_button_label_widget;
        private Gtk.Spinner? update_button_spinner_widget;
        private UpdateWorkflowState update_state = UpdateWorkflowState.READY_TO_CHECK;
        private Gee.HashSet<string> pending_update_keys;
        private Gee.HashMap<string, string> record_size_cache;
        private DetailsWindow? active_details_window;
        private const string SHORTCUTS_RESOURCE = "/com/github/AppManager/ui/main-window-shortcuts.ui";
        private const string APPDATA_RESOURCE = "/com/github/AppManager/com.github.AppManager.metainfo.xml";

        private Gtk.ToggleButton? search_button;
        private Gtk.SearchBar? search_bar;
        private Gtk.SearchEntry? search_entry;
        private GLib.SimpleActionGroup? window_actions;
        private Gtk.MenuButton? main_menu_button;
        private Gtk.Button? refresh_button;
        private string current_search_query = "";
        private bool has_installations = true;

        public MainWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings) {
            Object(application: app);
            debug("MainWindow: constructor called");
            this.title = I18n.tr("AppManager");
            this.app_ref = app;
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            this.updater = new Updater(registry, installer);
            this.pending_update_keys = new Gee.HashSet<string>();
            this.record_size_cache = new Gee.HashMap<string, string>();
            this.active_details_window = null;
            this.app_rows = new Gee.ArrayList<Adw.PreferencesRow>();
            add_css_class("devel");
            this.set_default_size(settings.get_int("window-width"), settings.get_int("window-height"));
            load_custom_css();
            build_ui();
            setup_window_actions();
            refresh_installations();
            registry.changed.connect(on_registry_changed);
        }

        private void on_registry_changed() {
            debug("MainWindow: received registry changed signal");
            refresh_installations();
        }

        private void load_custom_css() {
            var provider = new Gtk.CssProvider();
            string css = """
                .card.accent {
                    background-color: @accent_bg_color;
                    color: @accent_fg_color;
                }
                .card.accent label {
                    color: @accent_fg_color;
                }
                .card.destructive {
                    background-color: @destructive_bg_color;
                    color: @destructive_fg_color;
                }
                .card.destructive label {
                    color: @destructive_fg_color;
                }
                .card.terminal {
                    background-color: #535252ff;
                    color: #ffffff;
                }
                .card.terminal label {
                    color: #ffffff;
                }
                .extracted-app .title > label {
                    color: @accent_color;
                    font-weight: bold;
                }
                .update-indicator {
                    color: @accent_color;
                    font-size: 10px;
                }
            """;
            provider.load_from_string(css);

            var display = Gdk.Display.get_default();
            if (display != null) {
                Gtk.StyleContext.add_provider_for_display(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            } else {
                warning("Custom CSS could not be applied because no display is available");
            }
        }

        private void build_ui() {
            navigation_view = new Adw.NavigationView();
            navigation_view.pop_on_escape = true;
            
            toast_overlay = new Adw.ToastOverlay();
            toast_overlay.set_child(navigation_view);
            this.set_content(toast_overlay);

            general_page = new Adw.PreferencesPage();

            apps_group = new Adw.PreferencesGroup();
            apps_group.title = I18n.tr("My Apps");
            general_page.add(apps_group);

            empty_state_box = build_empty_state();

            content_stack = new Gtk.Stack();
            content_stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE);
            content_stack.set_hexpand(true);
            content_stack.set_vexpand(true);
            content_stack.add_named(general_page, "list");
            content_stack.add_named(empty_state_box, "empty");
            content_stack.set_visible_child_name("list");

            var root_toolbar = create_toolbar_with_header(content_stack, true);
            var root_page = new Adw.NavigationPage(root_toolbar, "main");
            root_page.title = I18n.tr("AppManager");
            navigation_view.add(root_page);

            this.close_request.connect(() => {
                settings.set_int("window-width", this.get_width());
                settings.set_int("window-height", this.get_height());
                return false;
            });
        }

        public void add_toast(string message) {
            var toast = new Adw.Toast(message);
            toast_overlay.add_toast(toast);
        }

        private void ensure_apps_group_present() {
            if (apps_group == null) {
                apps_group = new Adw.PreferencesGroup();
                apps_group.title = I18n.tr("My Apps");
            }
            if (apps_group.get_parent() == null) {
                general_page.add(apps_group);
            }
        }

        private void clear_apps_group_rows() {
            if (apps_group == null) {
                return;
            }

            foreach (var row in app_rows) {
                if (row.get_parent() != null) {
                    apps_group.remove(row);
                }
            }
            app_rows.clear();
        }

        private Gtk.Box build_empty_state() {
            empty_state_label = new Gtk.Label(I18n.tr("No AppImage apps installed"));
            empty_state_label.add_css_class("title-1");
            empty_state_label.set_wrap(true);
            empty_state_label.set_justify(Gtk.Justification.CENTER);

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            box.set_hexpand(true);
            box.set_vexpand(true);
            box.set_halign(Gtk.Align.CENTER);
            box.set_valign(Gtk.Align.CENTER);
            box.append(empty_state_label);

            return box;
        }

        private void show_empty_state(string message) {
            if (empty_state_label != null) {
                empty_state_label.set_text(message);
            }
            content_stack.set_visible_child_name("empty");
        }

        private void show_list_state() {
            content_stack.set_visible_child_name("list");
        }

        private void refresh_installations() {
            debug("MainWindow: refresh_installations called");
            ensure_apps_group_present();
            clear_apps_group_rows();
            
            var all_records = registry.list();
            has_installations = all_records.length > 0;
            var filtered_list = new Gee.ArrayList<InstallationRecord>();
            
            foreach (var record in all_records) {
                if (current_search_query != "") {
                    var name = record.name ?? "";
                    if (!name.down().contains(current_search_query)) {
                        continue;
                    }
                }
                filtered_list.add(record);
            }
            
            var records = filtered_list.to_array();

            prune_pending_keys(records);
            prune_size_cache(records);
            update_apps_group_title(records.length);
            update_update_button_sensitive();

            if (records.length == 0) {
                var message = current_search_query != "" ? I18n.tr("No results found") : I18n.tr("No AppImage apps installed");
                show_empty_state(message);
                return;
            }

            show_list_state();

            var sorted = new Gee.ArrayList<InstallationRecord>();
            foreach (var record in records) {
                sorted.add(record);
            }
            sort_records_by_updated(sorted);
            populate_group(apps_group, sorted);
        }

        private void prune_pending_keys(InstallationRecord[] records) {
            var valid = new Gee.HashSet<string>();
            foreach (var record in records) {
                valid.add(record_state_key(record));
            }
            var to_remove = new Gee.ArrayList<string>();
            foreach (var key in pending_update_keys) {
                if (!valid.contains(key)) {
                    to_remove.add(key);
                }
            }
            foreach (var key in to_remove) {
                pending_update_keys.remove(key);
            }
        }

        private void prune_size_cache(InstallationRecord[] records) {
            var valid = new Gee.HashSet<string>();
            foreach (var record in records) {
                valid.add(record_state_key(record));
            }
            var to_remove = new Gee.ArrayList<string>();
            foreach (var key in record_size_cache.keys) {
                if (!valid.contains(key)) {
                    to_remove.add(key);
                }
            }
            foreach (var key in to_remove) {
                record_size_cache.unset(key);
            }
        }

        private void update_apps_group_title(int count) {
            if (apps_group == null) {
                return;
            }
            var base_title = I18n.tr("My Apps");
            apps_group.title = count > 0 ? "%s (%d)".printf(base_title, count) : base_title;
        }

        private void sort_records_by_updated(Gee.ArrayList<InstallationRecord> records) {
            records.sort((a, b) => {
                // Use updated_at if available, otherwise use installed_at
                int64 a_time = a.updated_at ?? a.installed_at;
                int64 b_time = b.updated_at ?? b.installed_at;
                
                if (a_time == b_time) {
                    return compare_record_names(a, b);
                }
                return a_time > b_time ? -1 : 1;
            });
        }

        private int compare_record_names(InstallationRecord a, InstallationRecord b) {
            if (a.name == null && b.name == null) {
                return 0;
            }
            if (a.name == null) {
                return 1;
            }
            if (b.name == null) {
                return -1;
            }
            return a.name.collate(b.name);
        }

        private void populate_group(Adw.PreferencesGroup group, Gee.ArrayList<InstallationRecord> records) {
            foreach (var record in records) {
                var row = new Adw.ActionRow();
                row.title = record.name;
                if (record.mode == InstallMode.EXTRACTED) {
                    row.add_css_class("extracted-app");
                }
                
                row.subtitle = build_row_subtitle(record);

                // Add icon if available
                if (record.icon_path != null && record.icon_path.strip() != "") {
                    var icon_image = UiUtils.load_app_icon(record.icon_path);
                    if (icon_image != null) {
                        row.add_prefix(icon_image);
                    }
                }

                // Make row activatable to show detail page
                row.activatable = true;
                row.activated.connect(() => { show_detail_page(record); });

                // Add navigation arrow
                var arrow = new Gtk.Image.from_icon_name("go-next-symbolic");
                arrow.add_css_class("dim-label");

                var suffix_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                suffix_box.set_valign(Gtk.Align.CENTER);

                var state_key = record_state_key(record);
                if (pending_update_keys.contains(state_key)) {
                    var update_dot = new Gtk.Label("●");
                    update_dot.add_css_class("update-indicator");
                    update_dot.set_valign(Gtk.Align.CENTER);
                    update_dot.set_tooltip_text(I18n.tr("Update available"));
                    suffix_box.append(update_dot);
                }

                suffix_box.append(arrow);
                row.add_suffix(suffix_box);

                group.add(row);
                app_rows.add(row);
            }
        }

        private string build_row_subtitle(InstallationRecord record) {
            var parts = new Gee.ArrayList<string>();

            var size_text = format_record_size(record);
            if (size_text != null) {
                parts.add(size_text);
            }

            var time_text = format_time_label(record);
            if (time_text != null) {
                parts.add(time_text);
            }

            if (record.mode == InstallMode.EXTRACTED) {
                parts.add(I18n.tr("extracted"));
            }

            return string.joinv(" ･ ", parts.to_array());
        }

        private string? format_record_size(InstallationRecord record) {
            if (record.installed_path == null || record.installed_path.strip() == "") {
                return null;
            }

            var cache_key = record_state_key(record);
            if (record_size_cache.has_key(cache_key)) {
                return record_size_cache.get(cache_key);
            }

            try {
                var size = AppManager.Utils.FileUtils.get_path_size(record.installed_path);
                if (size <= 0) {
                    return null;
                }

                var formatted = UiUtils.format_size(size);
                if (formatted != null) {
                    record_size_cache.set(cache_key, formatted);
                }
                return formatted;
            } catch (Error e) {
                warning("Failed to calculate size for %s: %s", record.name, e.message);
                return null;
            }
        }

        private string? format_time_label(InstallationRecord record) {
            // Determine label type: if app has been updated, always show "Updated", otherwise "Installed"
            bool is_updated = record.updated_at != null;
            
            // Use updated_at if available, otherwise use installed_at for the timestamp
            int64 timestamp = is_updated ? record.updated_at : record.installed_at;
            
            if (timestamp <= 0) {
                return null;
            }

            var now = GLib.get_real_time();
            var delta = now - timestamp;
            if (delta < 0) {
                delta = 0;
            }

            var seconds = delta / 1000000;
            if (seconds < 60) {
                return is_updated ? I18n.tr("Updated just now") : I18n.tr("Installed just now");
            }

            if (seconds < 3600) {
                var minutes = (int)(seconds / 60);
                if (minutes == 0) {
                    minutes = 1;
                }
                return is_updated ? I18n.tr("Updated %d min ago").printf(minutes) : I18n.tr("Installed %d min ago").printf(minutes);
            }

            if (seconds < 86400) {
                var hours = (int)(seconds / 3600);
                if (hours == 0) {
                    hours = 1;
                }
                return is_updated ? I18n.tr("Updated %d hours ago").printf(hours) : I18n.tr("Installed %d hours ago").printf(hours);
            }

            var days = (int)(seconds / 86400);
            if (days == 0) {
                days = 1;
            }
            return is_updated ? I18n.tr("Updated %d days ago").printf(days) : I18n.tr("Installed %d days ago").printf(days);
        }



        public void present_shortcuts_dialog() {
            ensure_shortcuts_window();
            if (shortcuts_window == null) {
                return;
            }
            shortcuts_window.set_transient_for(this);
            shortcuts_window.present();
        }

        private GLib.MenuModel build_menu_model() {
            var menu = new GLib.Menu();
            menu.append(I18n.tr("Preferences"), "app.show_preferences");
            menu.append(I18n.tr("Keyboard shortcuts"), "app.show_shortcuts");
            menu.append(I18n.tr("About AppManager"), "app.show_about");
            return menu;
        }

        private Adw.ToolbarView create_toolbar_with_header(Gtk.Widget content, bool include_menu_button) {
            var toolbar = new Adw.ToolbarView();
            var header = new Adw.HeaderBar();

            if (include_menu_button) {
                search_button = new Gtk.ToggleButton();
                search_button.icon_name = "system-search-symbolic";
                search_button.tooltip_text = I18n.tr("Search");
                header.pack_start(search_button);

                refresh_button = new Gtk.Button();
                refresh_button.icon_name = "view-refresh-symbolic";
                refresh_button.tooltip_text = I18n.tr("Refresh app list");
                refresh_button.clicked.connect(on_refresh_clicked);
                header.pack_start(refresh_button);

                main_menu_button = new Gtk.MenuButton();
                main_menu_button.set_icon_name("open-menu-symbolic");
                main_menu_button.menu_model = build_menu_model();
                main_menu_button.tooltip_text = I18n.tr("More actions");
                header.pack_end(main_menu_button);
                ensure_update_button(header);
            }

            toolbar.add_top_bar(header);

            if (include_menu_button) {
                search_bar = new Gtk.SearchBar();
                search_bar.show_close_button = true;
                if (search_button != null) {
                    search_button.bind_property("active", search_bar, "search-mode-enabled", GLib.BindingFlags.BIDIRECTIONAL);
                }
                
                search_entry = new Gtk.SearchEntry();
                search_entry.placeholder_text = I18n.tr("Search apps...");
                search_entry.search_changed.connect(on_search_changed);
                search_bar.set_child(search_entry);
                search_bar.connect_entry(search_entry);
                
                toolbar.add_top_bar(search_bar);
            }

            toolbar.set_content(content);
            return toolbar;
        }

        private void on_search_changed() {
            if (search_entry != null) {
                current_search_query = search_entry.text.strip().down();
                refresh_installations();
            }
        }

        private void on_refresh_clicked() {
            debug("Refresh button clicked, syncing with filesystem");

            var before_count = registry.list().length;

            // Reload from disk so installs done by another process show up.
            registry.reload(false);

            // Then reconcile to drop entries whose files were deleted manually.
            var orphaned = registry.reconcile_with_filesystem();

            var after_count = registry.list().length;
            var added = after_count - before_count;

            // Always refresh the UI even when the registry didn't emit a signal.
            refresh_installations();

            if (added > 0 && orphaned.size > 0) {
                add_toast(I18n.tr("Refreshed: added %d, removed %d").printf(added, orphaned.size));
            } else if (added > 0) {
                var message = added == 1
                    ? I18n.tr("Found 1 new app")
                    : I18n.tr("Found %d new apps").printf(added);
                add_toast(message);
            } else if (orphaned.size > 0) {
                var message = orphaned.size == 1
                    ? I18n.tr("Removed 1 orphaned app from registry")
                    : I18n.tr("Removed %d orphaned apps from registry").printf(orphaned.size);
                add_toast(message);
            } else {
                add_toast(I18n.tr("App list is up to date"));
            }
        }

        private void setup_window_actions() {
            var search_action = new GLib.SimpleAction("toggle_search", null);
            search_action.activate.connect(() => {
                toggle_search_mode();
            });
            add_window_action(search_action);

            var check_updates_action = new GLib.SimpleAction("check_updates", null);
            check_updates_action.activate.connect(on_check_updates_accel);
            add_window_action(check_updates_action);

            var refresh_action = new GLib.SimpleAction("refresh", null);
            refresh_action.activate.connect(() => {
                on_refresh_clicked();
            });
            add_window_action(refresh_action);

            var show_menu_action = new GLib.SimpleAction("show_menu", null);
            show_menu_action.activate.connect(() => {
                if (main_menu_button != null) {
                    main_menu_button.activate();
                }
            });
            add_window_action(show_menu_action);
        }

        private void add_window_action(GLib.Action action) {
            var group = ensure_window_action_group();
            group.add_action(action);
        }

        private GLib.SimpleActionGroup ensure_window_action_group() {
            if (window_actions == null) {
                window_actions = new GLib.SimpleActionGroup();
                this.insert_action_group("win", window_actions);
            }
            return window_actions;
        }

        private void on_check_updates_accel() {
            if (update_state == UpdateWorkflowState.CHECKING || update_state == UpdateWorkflowState.UPDATING) {
                add_toast(I18n.tr("Updates already running"));
                return;
            }
            start_update_check();
        }

        private void toggle_search_mode() {
            if (search_bar == null) {
                return;
            }

            var enable = !search_bar.search_mode_enabled;
            search_bar.search_mode_enabled = enable;

            if (search_button != null) {
                search_button.set_active(enable);
            }

            if (enable && search_entry != null) {
                search_entry.grab_focus();
                search_entry.set_position(-1);
            }
        }

        private void ensure_update_button(Adw.HeaderBar header) {
            if (update_button == null) {
                update_button = new Gtk.Button();
                var button_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                button_box.set_valign(Gtk.Align.CENTER);
                button_box.set_halign(Gtk.Align.CENTER);

                update_button_spinner_widget = new Gtk.Spinner();
                update_button_spinner_widget.set_visible(false);
                update_button_spinner_widget.set_valign(Gtk.Align.CENTER);
                button_box.append(update_button_spinner_widget);

                update_button_label_widget = new Gtk.Label("");
                update_button_label_widget.add_css_class("title-6");
                update_button_label_widget.set_valign(Gtk.Align.CENTER);
                button_box.append(update_button_label_widget);

                update_button.set_child(button_box);
                update_button.clicked.connect(handle_update_button_clicked);
                set_update_button_state(UpdateWorkflowState.READY_TO_CHECK);
            }
            if (update_button.get_parent() == null) {
                header.pack_end(update_button);
            }
        }

        private void handle_update_button_clicked() {
            switch (update_state) {
                case UpdateWorkflowState.READY_TO_CHECK:
                    start_update_check();
                    break;
                case UpdateWorkflowState.READY_TO_UPDATE:
                    start_update_install();
                    break;
                case UpdateWorkflowState.CHECKING:
                case UpdateWorkflowState.UPDATING:
                    add_toast(I18n.tr("Updates already running"));
                    break;
            }
        }

        private void start_update_check() {
            set_update_button_state(UpdateWorkflowState.CHECKING);
            new Thread<void>("appmgr-check-updates", () => {
                var probes = updater.probe_updates();
                Idle.add(() => {
                    handle_probe_results(probes);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void handle_probe_results(Gee.ArrayList<UpdateProbeResult> probes) {
            pending_update_keys.clear();
            int available = 0;
            foreach (var result in probes) {
                if (result.has_update) {
                    pending_update_keys.add(record_state_key(result.record));
                    available++;
                }
                sync_details_window_state(result.record);
            }
            refresh_installations();
            if (available > 0) {
                add_toast(I18n.tr("%d app(s) have updates").printf(available));
                set_update_button_state(UpdateWorkflowState.READY_TO_UPDATE);
            } else {
                add_toast(I18n.tr("No updates available right now"));
                set_update_button_state(UpdateWorkflowState.READY_TO_CHECK);
            }
        }

        private void start_update_install() {
            if (pending_update_keys.size == 0) {
                add_toast(I18n.tr("Nothing queued for updating"));
                set_update_button_state(UpdateWorkflowState.READY_TO_CHECK);
                return;
            }

            refresh_installations();
            set_update_button_state(UpdateWorkflowState.UPDATING);
            new Thread<void>("appmgr-update", () => {
                var results = updater.update_all();
                Idle.add(() => {
                    handle_update_results(results);
                    finalize_update_workflow(results);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void trigger_single_update(InstallationRecord record) {
            new Thread<void>("appmgr-update-single", () => {
                var result = updater.update_single(record);
                var payload = new Gee.ArrayList<UpdateResult>();
                payload.add(result);
                Idle.add(() => {
                    handle_update_results(payload);
                    finalize_single_update(result);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void finalize_single_update(UpdateResult result) {
            var key = record_state_key(result.record);
            if (result.status == UpdateStatus.UPDATED) {
                pending_update_keys.remove(key);
                record_size_cache.unset(result.record.id);
            }
            refresh_installations();
            sync_details_window_state(result.record);
            update_global_update_state_from_pending();
        }

        private void finalize_update_workflow(Gee.ArrayList<UpdateResult> results) {
            var remaining = new Gee.HashSet<string>();
            foreach (var result in results) {
                var key = record_state_key(result.record);
                if (!pending_update_keys.contains(key)) {
                    continue;
                }
                if (result.status != UpdateStatus.UPDATED) {
                    remaining.add(key);
                } else {
                    record_size_cache.unset(result.record.id);
                }
                sync_details_window_state(result.record);
            }
            pending_update_keys.clear();
            foreach (var key in remaining) {
                pending_update_keys.add(key);
            }
            refresh_installations();

            if (pending_update_keys.size > 0) {
                set_update_button_state(UpdateWorkflowState.READY_TO_UPDATE);
            } else {
                set_update_button_state(UpdateWorkflowState.READY_TO_CHECK);
            }
        }

        private void update_global_update_state_from_pending() {
            if (update_state == UpdateWorkflowState.CHECKING || update_state == UpdateWorkflowState.UPDATING) {
                return;
            }
            if (pending_update_keys.size > 0) {
                set_update_button_state(UpdateWorkflowState.READY_TO_UPDATE);
            } else {
                set_update_button_state(UpdateWorkflowState.READY_TO_CHECK);
            }
        }

        private void set_update_button_state(UpdateWorkflowState state) {
            update_state = state;
            if (update_button == null || update_button_label_widget == null || update_button_spinner_widget == null) {
                return;
            }

            var busy = (state == UpdateWorkflowState.CHECKING || state == UpdateWorkflowState.UPDATING);
            update_update_button_sensitive(busy);

            if (busy) {
                update_button_spinner_widget.set_visible(true);
                update_button_spinner_widget.start();
            } else {
                update_button_spinner_widget.stop();
                update_button_spinner_widget.set_visible(false);
            }

            string label;
            switch (state) {
                case UpdateWorkflowState.CHECKING:
                    label = I18n.tr("Checking updates");
                    break;
                case UpdateWorkflowState.READY_TO_UPDATE:
                    label = I18n.tr("Update Apps");
                    break;
                case UpdateWorkflowState.UPDATING:
                    label = I18n.tr("Updating apps");
                    break;
                default:
                    label = I18n.tr("Check updates");
                    break;
            }
            update_button_label_widget.set_text(label);

            update_button.remove_css_class("suggested-action");
            if (state == UpdateWorkflowState.READY_TO_UPDATE || state == UpdateWorkflowState.UPDATING) {
                update_button.add_css_class("suggested-action");
            }
        }

        private void update_update_button_sensitive(bool force_busy = false) {
            if (update_button == null) {
                return;
            }
            if (force_busy) {
                update_button.set_sensitive(false);
                return;
            }
            update_button.set_sensitive(has_installations);
        }

        private void handle_update_results(Gee.ArrayList<UpdateResult> results) {
            if (results.size == 0) {
                add_toast(I18n.tr("No installed apps to update"));
                return;
            }

            int updated = 0;
            int failed = 0;
            int missing_address = 0;
            int unsupported = 0;
            int already_current = 0;

            foreach (var result in results) {
                switch (result.status) {
                    case UpdateStatus.UPDATED:
                        updated++;
                        break;
                    case UpdateStatus.FAILED:
                        failed++;
                        break;
                    case UpdateStatus.SKIPPED:
                        if (result.skip_reason == null) {
                            break;
                        }
                        switch (result.skip_reason) {
                            case UpdateSkipReason.NO_UPDATE_URL:
                                missing_address++;
                                break;
                            case UpdateSkipReason.UNSUPPORTED_SOURCE:
                                unsupported++;
                                break;
                            case UpdateSkipReason.ALREADY_CURRENT:
                                already_current++;
                                break;
                            default:
                                break;
                        }
                        break;
                }
            }

            if (updated > 0) {
                add_toast(I18n.tr("Updated %d app(s)").printf(updated));
            }
            if (failed > 0) {
                add_toast(I18n.tr("%d update(s) failed").printf(failed));
            }

            var total = results.size;
            var supported = total - missing_address;
            var actionable = supported - unsupported;

            if (supported == 0) {
                add_toast(I18n.tr("Add update addresses in Details to enable updates"));
            } else if (updated == 0 && failed == 0 && actionable > 0 && already_current == actionable) {
                add_toast(I18n.tr("All supported apps are already up to date"));
            }

            if (unsupported > 0) {
                add_toast(I18n.tr("%d app(s) use unsupported update links").printf(unsupported));
            }
        }

        private string record_state_key(InstallationRecord record) {
            if (record.desktop_file != null && record.desktop_file.strip() != "") {
                return record.desktop_file;
            }
            if (record.installed_path != null && record.installed_path.strip() != "") {
                return record.installed_path;
            }
            return record.id;
        }

        private void start_single_probe(InstallationRecord record, DetailsWindow? source = null) {
            new Thread<void>("appmgr-probe-single", () => {
                var result = updater.probe_single(record);
                Idle.add(() => {
                    handle_single_probe_result(result, source);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void handle_single_probe_result(UpdateProbeResult result, DetailsWindow? source) {
            var key = record_state_key(result.record);
            if (result.has_update) {
                pending_update_keys.add(key);
            } else {
                pending_update_keys.remove(key);
            }

            refresh_installations();
            sync_details_window_state(result.record);
            update_global_update_state_from_pending();

            if (source != null && source.matches_record(result.record)) {
                source.set_update_available(result.has_update);
            }

            if (result.has_update) {
                add_toast(I18n.tr("Update available for %s").printf(result.record.name));
            } else if (result.message != null && result.message.strip() != "") {
                add_toast(result.message);
            }
        }

        private void sync_details_window_state(InstallationRecord record) {
            if (active_details_window == null) {
                return;
            }
            if (!active_details_window.matches_record(record)) {
                return;
            }
            var has_update = pending_update_keys.contains(record_state_key(record));
            active_details_window.set_update_available(has_update);
        }

        private enum UpdateWorkflowState {
            READY_TO_CHECK,
            CHECKING,
            READY_TO_UPDATE,
            UPDATING
        }

        private void ensure_shortcuts_window() {
            if (shortcuts_window != null) {
                return;
            }
            try {
                var builder = new Gtk.Builder();
                builder.add_from_resource(SHORTCUTS_RESOURCE);
                shortcuts_window = builder.get_object("shortcuts_window") as Gtk.ShortcutsWindow;
                if (shortcuts_window == null) {
                    warning("Failed to create shortcuts window");
                    return;
                }
                shortcuts_window.set_transient_for(this);

                var section = builder.get_object("general_section") as Gtk.ShortcutsSection;
                if (section != null) {
                    section.title = I18n.tr("General");
                }
                var navigation = builder.get_object("navigation_group") as Gtk.ShortcutsGroup;
                if (navigation != null) {
                    navigation.title = I18n.tr("Navigation");
                }
                var window_group = builder.get_object("window_group") as Gtk.ShortcutsGroup;
                if (window_group != null) {
                    window_group.title = I18n.tr("Window");
                }
                assign_shortcut_title(builder, "shortcut_check_updates", I18n.tr("Check for updates"));
                assign_shortcut_title(builder, "shortcut_refresh", I18n.tr("Refresh app list"));
                assign_shortcut_title(builder, "shortcut_main_menu", I18n.tr("Show main menu"));
                assign_shortcut_title(builder, "shortcut_search", I18n.tr("Search"));
                assign_shortcut_title(builder, "shortcut_show_overlay", I18n.tr("Show shortcuts"));
                assign_shortcut_title(builder, "shortcut_about", I18n.tr("About AppManager"));
                assign_shortcut_title(builder, "shortcut_close_window", I18n.tr("Close window"));
                assign_shortcut_title(builder, "shortcut_quit", I18n.tr("Quit AppManager"));
            } catch (Error e) {
                warning("Failed to load shortcuts UI: %s", e.message);
            }
        }

        private void assign_shortcut_title(Gtk.Builder builder, string id, string title) {
            var shortcut = builder.get_object(id) as Gtk.ShortcutsShortcut;
            if (shortcut != null) {
                shortcut.title = title;
            }
        }

        public void present_about_dialog() {
            if (about_dialog == null) {
                about_dialog = (Adw.AboutDialog) about_dialog_new_from_appdata_raw(APPDATA_RESOURCE, null);
                about_dialog.version = APPLICATION_VERSION;
            }
            about_dialog.present(this);
        }

        private void show_detail_page(InstallationRecord record) {
            var has_update = pending_update_keys.contains(record_state_key(record));
            var details_window = new DetailsWindow(record, registry, has_update);
            details_window.uninstall_requested.connect((r) => {
                navigation_view.pop();
                if (active_details_window == details_window) {
                    active_details_window = null;
                }
                app_ref.uninstall_record(r, this);
            });
            details_window.update_requested.connect((r) => {
                trigger_single_update(r);
            });
            details_window.check_update_requested.connect((r) => {
                start_single_probe(r, details_window);
            });
            details_window.extract_requested.connect((r) => {
                navigation_view.pop();
                if (active_details_window == details_window) {
                    active_details_window = null;
                }
                app_ref.extract_installation(r, this);
            });
            details_window.destroy.connect(() => {
                if (active_details_window == details_window) {
                    active_details_window = null;
                }
            });
            active_details_window = details_window;
            navigation_view.push(details_window);
        }
    }
}
