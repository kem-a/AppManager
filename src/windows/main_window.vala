using AppManager.Core;
using AppManager.Utils;

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
        private Adw.NavigationView navigation_view;
        private Adw.ToastOverlay toast_overlay;
        private Adw.BottomSheet bottom_sheet;
        private Gtk.Widget bottom_bar_widget;
        private Gtk.Button? update_button;
        private Gtk.Button? cancel_button;
        private Gtk.Label? update_button_label_widget;
        private Gtk.Spinner? update_button_spinner_widget;
        private UpdateWorkflowState update_state = UpdateWorkflowState.READY_TO_CHECK;
        private GLib.Cancellable? update_cancellable;
        private Gee.HashSet<string> pending_update_keys;
        private Gee.HashMap<string, string> record_size_cache;
        private Gee.HashSet<string> updating_records;
        private DetailsWindow? active_details_window;
        private const string SHORTCUTS_RESOURCE = "/com/github/AppManager/ui/main-window-shortcuts.ui";
        private const string APPDATA_RESOURCE = "/com/github/AppManager/com.github.AppManager.metainfo.xml";

        private Gtk.ToggleButton? search_button;
        private Gtk.SearchBar? search_bar;
        private Gtk.SearchEntry? search_entry;
        private GLib.SimpleActionGroup? window_actions;
        private Gtk.MenuButton? main_menu_button;
        private Gtk.Button? refresh_button;
        private Adw.Banner? fuse_banner;
        private string current_search_query = "";
        private bool has_installations = true;
        private StagedUpdatesManager staged_updates;

        public MainWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings) {
            Object(application: app);
            debug("MainWindow: constructor called");
            this.title = I18n.tr("AppManager");
            this.app_ref = app;
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            this.updater = new Updater(registry, installer);
            this.staged_updates = new StagedUpdatesManager();
            this.pending_update_keys = new Gee.HashSet<string>();
            this.record_size_cache = new Gee.HashMap<string, string>();
            this.updating_records = new Gee.HashSet<string>();
            this.active_details_window = null;
            this.app_rows = new Gee.ArrayList<Adw.PreferencesRow>();
            //add_css_class("devel");
            this.set_default_size(settings.get_int("window-width"), settings.get_int("window-height"));
            build_ui();
            setup_window_actions();
            load_staged_updates();
            refresh_installations();
            registry.changed.connect(on_registry_changed);
        }

        /**
         * Loads staged updates from disk and populates pending_update_keys.
         * Called on startup to show updates discovered by background service.
         */
        private void load_staged_updates() {
            if (!staged_updates.has_updates()) {
                return;
            }

            var records = registry.list();
            var staged_ids = staged_updates.get_record_ids();
            int loaded = 0;

            foreach (var record in records) {
                if (staged_ids.contains(record.id)) {
                    pending_update_keys.add(record_state_key(record));
                    loaded++;
                }
            }

            if (loaded > 0) {
                debug("MainWindow: loaded %d staged update(s)", loaded);
                // Switch to "ready to update" state if we have pending updates
                set_update_button_state(UpdateWorkflowState.READY_TO_UPDATE);
            }
        }

        private void on_registry_changed() {
            debug("MainWindow: received registry changed signal");
            refresh_installations();
        }

        private void build_ui() {
            navigation_view = new Adw.NavigationView();
            navigation_view.pop_on_escape = true;

            // Bottom sheet with "Get more ..." button
            bottom_sheet = new Adw.BottomSheet();
            bottom_sheet.set_content(navigation_view);
            bottom_bar_widget = build_get_more_bottom_bar();
            bottom_sheet.set_bottom_bar(bottom_bar_widget);
            bottom_sheet.set_sheet(build_get_more_sheet());

            // Toast overlay wraps bottom sheet so toasts appear above the bottom bar
            toast_overlay = new Adw.ToastOverlay();
            toast_overlay.set_child(bottom_sheet);
            this.set_content(toast_overlay);

            general_page = new Adw.PreferencesPage();
            general_page.add_css_class("main-apps-page");

            apps_group = new Adw.PreferencesGroup();
            apps_group.title = I18n.tr("My Apps");
            
            // Add refresh button next to title
            refresh_button = new Gtk.Button();
            refresh_button.icon_name = "view-refresh-symbolic";
            refresh_button.tooltip_text = I18n.tr("Refresh app list");
            refresh_button.add_css_class("flat");
            refresh_button.clicked.connect(on_refresh_clicked);
            apps_group.set_header_suffix(refresh_button);
            
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

            // Show/hide bottom bar based on navigation depth
            navigation_view.popped.connect(() => {
                if (navigation_view.navigation_stack.get_n_items() == 1) {
                    bottom_bar_widget.visible = true;
                }
            });

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

        private Gtk.Widget build_get_more_bottom_bar() {
            var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            box.halign = Gtk.Align.CENTER;
            box.valign = Gtk.Align.CENTER;
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.append(new Gtk.Image.from_icon_name("folder-download-symbolic"));
            box.append(new Gtk.Label(I18n.tr("Get more ...")));
            return box;
        }

        private Gtk.Widget build_get_more_sheet() {
            var sheet_toolbar = new Adw.ToolbarView();
            var header = new Adw.HeaderBar();
            header.show_title = false;
            sheet_toolbar.add_top_bar(header);

            var page = new Adw.PreferencesPage();
            var links_group = new Adw.PreferencesGroup();
            links_group.title = I18n.tr("Find more AppImages");
            links_group.description = I18n.tr("Browse these sources to discover and download AppImages");

            var pkgforge_row = new Adw.ActionRow();
            pkgforge_row.title = "Anylinux AppImages";
            pkgforge_row.subtitle = "pkgforge-dev.github.io";
            pkgforge_row.activatable = true;
            pkgforge_row.add_suffix(new Gtk.Image.from_icon_name("adw-external-link-symbolic"));
            pkgforge_row.activated.connect(() => {
                UiUtils.open_url("https://pkgforge-dev.github.io/Anylinux-AppImages/");
            });
            links_group.add(pkgforge_row);

            var appimagehub_row = new Adw.ActionRow();
            appimagehub_row.title = "AppImageHub";
            appimagehub_row.subtitle = "appimagehub.com";
            appimagehub_row.activatable = true;
            appimagehub_row.add_suffix(new Gtk.Image.from_icon_name("adw-external-link-symbolic"));
            appimagehub_row.activated.connect(() => {
                UiUtils.open_url("https://www.appimagehub.com/");
            });
            links_group.add(appimagehub_row);

            var appimage_catalog_row = new Adw.ActionRow();
            appimage_catalog_row.title = "AppImage Catalog";
            appimage_catalog_row.subtitle = "appimage.github.io";
            appimage_catalog_row.activatable = true;
            appimage_catalog_row.add_suffix(new Gtk.Image.from_icon_name("adw-external-link-symbolic"));
            appimage_catalog_row.activated.connect(() => {
                UiUtils.open_url("https://appimage.github.io/");
            });
            links_group.add(appimage_catalog_row);

            page.add(links_group);
            sheet_toolbar.set_content(page);
            return sheet_toolbar;
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

            var subtitle = new Gtk.Label(I18n.tr("Download AppImage and double click to install with AppManager"));
            subtitle.add_css_class("dim-label");
            subtitle.set_wrap(true);
            subtitle.set_justify(Gtk.Justification.CENTER);
            subtitle.set_margin_top(12);

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            box.set_hexpand(true);
            box.set_vexpand(true);
            box.set_halign(Gtk.Align.CENTER);
            box.set_valign(Gtk.Align.CENTER);
            box.append(empty_state_label);
            box.append(subtitle);

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
            
            prune_pending_keys(filtered_list);
            prune_size_cache(filtered_list);
            update_apps_group_title(filtered_list.size);
            update_update_button_sensitive();

            if (filtered_list.size == 0) {
                var message = current_search_query != "" ? I18n.tr("No results found") : I18n.tr("No AppImage apps installed");
                show_empty_state(message);
                return;
            }

            show_list_state();

            var sorted = new Gee.ArrayList<InstallationRecord>();
            sorted.add_all(filtered_list);
            sort_records_by_updated(sorted);
            populate_group(apps_group, sorted);
        }

        private void prune_pending_keys(Gee.Collection<InstallationRecord> records) {
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

        private void prune_size_cache(Gee.Collection<InstallationRecord> records) {
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
                int64 a_time = a.updated_at > 0 ? a.updated_at : a.installed_at;
                int64 b_time = b.updated_at > 0 ? b.updated_at : b.installed_at;
                
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
                if (updating_records.contains(state_key)) {
                    var spinner = new Gtk.Spinner();
                    spinner.set_size_request(16, 16);
                    spinner.set_valign(Gtk.Align.CENTER);
                    spinner.set_tooltip_text(I18n.tr("Updating..."));
                    spinner.spinning = true;
                    suffix_box.append(spinner);
                } else if (pending_update_keys.contains(state_key)) {
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

            // Build native string array to avoid Gee.to_array() void** warning
            var arr = new string[parts.size];
            for (int i = 0; i < parts.size; i++) {
                arr[i] = parts.get(i);
            }
            return string.joinv(" ･ ", arr);
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
            bool is_updated = record.updated_at > 0;
            
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
            menu.append(I18n.tr("Quit"), "app.quit");
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

                // FUSE is not installed warning banner
                fuse_banner = new Adw.Banner(I18n.tr("FUSE is not installed. Some AppImages may fail to run"));
                fuse_banner.add_css_class("warning");
                fuse_banner.button_label = I18n.tr("Learn More");
                fuse_banner.button_clicked.connect(() => {
                    var launcher = new Gtk.UriLauncher("https://github.com/AppImage/AppImageKit/wiki/FUSE");
                    launcher.launch.begin(this, null);
                });
                fuse_banner.revealed = !is_fuse_installed();
                toolbar.add_top_bar(fuse_banner);
            }

            toolbar.set_content(content);
            return toolbar;
        }

        private bool is_fuse_installed() {
            // AppImages typically require libfuse.so.2 (FUSE 2.x)
            // Check common library paths for the actual library file
            string[] lib_paths = {
                "/usr/lib/libfuse.so.2",
                "/usr/lib64/libfuse.so.2",
                "/lib/libfuse.so.2",
                "/lib64/libfuse.so.2",
                "/usr/lib/x86_64-linux-gnu/libfuse.so.2",
                "/usr/lib/aarch64-linux-gnu/libfuse.so.2",
                "/usr/lib/i386-linux-gnu/libfuse.so.2"
            };

            foreach (var path in lib_paths) {
                if (GLib.FileUtils.test(path, FileTest.EXISTS)) {
                    return true;
                }
            }
            return false;
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
            if (cancel_button == null) {
                cancel_button = new Gtk.Button();
                cancel_button.set_icon_name("process-stop-symbolic");
                cancel_button.set_tooltip_text(I18n.tr("Cancel update"));
                cancel_button.add_css_class("flat");
                cancel_button.set_visible(false);
                cancel_button.clicked.connect(handle_cancel_clicked);
            }
            if (update_button.get_parent() == null) {
                header.pack_end(update_button);
            }
            if (cancel_button.get_parent() == null) {
                header.pack_end(cancel_button);
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

        private void handle_cancel_clicked() {
            if (update_cancellable != null && !update_cancellable.is_cancelled()) {
                update_cancellable.cancel();
                add_toast(I18n.tr("Cancelling..."));
                if (cancel_button != null) {
                    cancel_button.set_sensitive(false);
                }
            }
        }

        private void start_update_check() {
            update_cancellable = new GLib.Cancellable();
            set_update_button_state(UpdateWorkflowState.CHECKING);
            start_update_check_async.begin();
        }

        private async void start_update_check_async() {
            SourceFunc callback = start_update_check_async.callback;
            Gee.ArrayList<UpdateProbeResult>? probes = null;
            var cancellable = update_cancellable;

            new Thread<void>("appmgr-check-updates", () => {
                probes = updater.probe_updates(cancellable);
                Idle.add((owned) callback);
            });

            yield;

            if (cancellable != null && cancellable.is_cancelled()) {
                add_toast(I18n.tr("Update check cancelled"));
                set_update_button_state(UpdateWorkflowState.READY_TO_CHECK);
                return;
            }

            if (probes != null) {
                handle_probe_results(probes);
            }
        }

        private void handle_probe_results(Gee.ArrayList<UpdateProbeResult> probes) {
            pending_update_keys.clear();
            // Clear staged updates since we're doing a fresh check
            staged_updates.clear();
            staged_updates.save();
            
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

            update_cancellable = new GLib.Cancellable();
            set_update_button_state(UpdateWorkflowState.UPDATING);
            foreach (var key in pending_update_keys) {
                updating_records.add(key);
            }
            refresh_installations();
            start_update_install_async.begin();
        }

        private async void start_update_install_async() {
            SourceFunc callback = start_update_install_async.callback;
            Gee.ArrayList<UpdateResult>? results = null;
            var cancellable = update_cancellable;

            new Thread<void>("appmgr-update", () => {
                results = updater.update_all(cancellable);
                Idle.add((owned) callback);
            });

            yield;

            if (cancellable != null && cancellable.is_cancelled()) {
                add_toast(I18n.tr("Update cancelled"));
                updating_records.clear();
                refresh_installations();
                update_global_update_state_from_pending();
                return;
            }

            if (results != null) {
                handle_update_results(results);
                finalize_update_workflow(results);
            }
        }

        private void trigger_single_update(InstallationRecord record) {
            var key = record_state_key(record);
            updating_records.add(key);
            if (active_details_window != null && active_details_window.matches_record(record)) {
                // Order matters: set_update_loading first, then set_update_updating
                // because refresh_update_button() resets update_updating when update_loading is false
                active_details_window.set_update_loading(true);
                active_details_window.set_update_updating(true);
            }
            refresh_installations();
            trigger_single_update_async.begin(record);
        }

        private async void trigger_single_update_async(InstallationRecord record) {
            SourceFunc callback = trigger_single_update_async.callback;
            UpdateResult? result = null;

            new Thread<void>("appmgr-update-single", () => {
                result = updater.update_single(record);
                Idle.add((owned) callback);
            });

            yield;

            if (active_details_window != null && active_details_window.matches_record(record)) {
                active_details_window.set_update_loading(false);
            }
            if (result != null) {
                var payload = new Gee.ArrayList<UpdateResult>();
                payload.add(result);
                handle_update_results(payload);
                finalize_single_update(result);
            }
        }

        private void finalize_single_update(UpdateResult result) {
            var key = record_state_key(result.record);
            updating_records.remove(key);
            if (result.status == UpdateStatus.UPDATED) {
                pending_update_keys.remove(key);
                record_size_cache.unset(result.record.id);
                // Remove from staged updates and save
                staged_updates.remove(result.record.id);
                staged_updates.save();
                // Refresh details window with updated record data
                if (active_details_window != null && active_details_window.matches_record(result.record)) {
                    active_details_window.refresh_with_record(result.record);
                }
            }
            refresh_installations();
            sync_details_window_state(result.record);
            update_global_update_state_from_pending();
        }

        private void finalize_update_workflow(Gee.ArrayList<UpdateResult> results) {
            var remaining = new Gee.HashSet<string>();
            foreach (var result in results) {
                var key = record_state_key(result.record);
                updating_records.remove(key);
                if (!pending_update_keys.contains(key)) {
                    continue;
                }
                if (result.status != UpdateStatus.UPDATED) {
                    remaining.add(key);
                } else {
                    record_size_cache.unset(result.record.id);
                    // Remove from staged updates as well
                    staged_updates.remove(result.record.id);
                }
                sync_details_window_state(result.record);
            }
            // Save staged updates after removing completed ones
            staged_updates.save();
            
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

            // Show/hide cancel button
            if (cancel_button != null) {
                cancel_button.set_visible(busy);
                cancel_button.set_sensitive(busy);
            }

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
            if (source != null) {
                source.set_update_loading(true);
            }
            start_single_probe_async.begin(record, source);
        }

        private async void start_single_probe_async(InstallationRecord record, DetailsWindow? source) {
            SourceFunc callback = start_single_probe_async.callback;
            UpdateProbeResult? result = null;

            new Thread<void>("appmgr-probe-single", () => {
                result = updater.probe_single(record);
                Idle.add((owned) callback);
            });

            yield;

            if (source != null) {
                source.set_update_loading(false);
            }
            if (result != null) {
                handle_single_probe_result(result, source);
            }
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
            var dialog = new Adw.AboutDialog.from_appdata(APPDATA_RESOURCE, null);
            dialog.version = APPLICATION_VERSION;
            string[] credits = { "Contributors https://github.com/kem-a/AppManager/graphs/contributors" };
            dialog.add_credit_section(I18n.tr("Credits"), credits);
            dialog.present(this);
        }

        private void show_detail_page(InstallationRecord record) {
            var key = record_state_key(record);
            var has_update = pending_update_keys.contains(key);
            var is_updating = updating_records.contains(key);
            var details_window = new DetailsWindow(record, registry, installer, has_update);
            if (is_updating) {
                details_window.set_update_loading(true);
            }
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
            bottom_sheet.open = false;
            bottom_bar_widget.visible = false;
            navigation_view.push(details_window);
        }
    }
}
