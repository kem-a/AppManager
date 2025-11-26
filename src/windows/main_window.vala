using AppManager.Core;
using AppManager.Utils;

[CCode (cname = "adw_about_dialog_new_from_appdata")]
extern Adw.Dialog about_dialog_new_from_appdata_raw(string resource_path, string? release_notes_version);

[CCode (cname = "gtk_style_context_add_provider_for_display")]
internal extern void gtk_style_context_add_provider_for_display_compat(Gdk.Display display, Gtk.StyleProvider provider, uint priority);

namespace AppManager {
    public class MainWindow : Adw.Window {
        private Application app_ref;
        private InstallationRegistry registry;
        private Installer installer;
        private Settings settings;
        private Updater updater;
        private Adw.PreferencesGroup extracted_group;
        private Adw.PreferencesGroup portable_group;
        private Adw.PreferencesPage general_page;
        private Gtk.ShortcutsWindow? shortcuts_window;
        private Adw.AboutDialog? about_dialog;
        private Adw.NavigationView navigation_view;
        private Adw.ToastOverlay toast_overlay;
        private Gtk.Button? update_button;
        private bool updates_in_progress = false;
        private Gee.HashMap<string, UpdateIndicator> row_indicators;
        private Gee.HashMap<string, UpdateVisualState> indicator_states;
        private Gee.HashSet<string> active_update_keys;
        private const string SHORTCUTS_RESOURCE = "/com/github/AppManager/ui/main-window-shortcuts.ui";
        private const string APPDATA_RESOURCE = "/com/github/AppManager/com.github.AppManager.metainfo.xml";

        public MainWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings) {
            Object(application: app);
            this.title = I18n.tr("AppManager");
            this.app_ref = app;
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            this.updater = new Updater(registry, installer);
            this.row_indicators = new Gee.HashMap<string, UpdateIndicator>();
            this.indicator_states = new Gee.HashMap<string, UpdateVisualState>();
            this.active_update_keys = new Gee.HashSet<string>();
            connect_updater_signals();
            add_css_class("devel");
            this.set_default_size(settings.get_int("window-width"), settings.get_int("window-height"));
            load_custom_css();
            build_ui();
            refresh_installations();
            registry.changed.connect(() => {
                refresh_installations();
            });
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
                .update-success-badge {
                    background-color: @accent_bg_color;
                    color: @accent_fg_color;
                    border-radius: 9999px;
                    padding: 1px;
                }
                .update-success-badge image {
                    color: @accent_fg_color;
                }
            """;
            provider.load_from_string(css);

            var style_manager = Adw.StyleManager.get_default();
            if (style_manager == null) {
                warning("Custom CSS could not be applied because no StyleManager is available");
                return;
            }

            var display = style_manager.get_display();
            if (display == null) {
                warning("Custom CSS could not be applied because the StyleManager has no display");
                return;
            }

            gtk_style_context_add_provider_for_display_compat(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private void build_ui() {
            navigation_view = new Adw.NavigationView();
            navigation_view.pop_on_escape = true;
            
            toast_overlay = new Adw.ToastOverlay();
            toast_overlay.set_child(navigation_view);
            this.set_content(toast_overlay);

            general_page = new Adw.PreferencesPage();
            
            var root_toolbar = create_toolbar_with_header(general_page, true);
            var root_page = new Adw.NavigationPage(root_toolbar, "main");
            root_page.title = I18n.tr("AppManager");
            navigation_view.add(root_page);

            portable_group = new Adw.PreferencesGroup();
            portable_group.title = I18n.tr("Portable AppImages");
            general_page.add(portable_group);

            extracted_group = new Adw.PreferencesGroup();
            extracted_group.title = I18n.tr("Extracted AppImages");
            general_page.add(extracted_group);

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

        private void refresh_installations() {
            general_page.remove(portable_group);
            general_page.remove(extracted_group);
            
            portable_group = new Adw.PreferencesGroup();
            setup_group_header(portable_group, I18n.tr("Portable AppImages"), AppPaths.applications_dir);
            
            extracted_group = new Adw.PreferencesGroup();
            setup_group_header(extracted_group, I18n.tr("Extracted AppImages"), AppPaths.extracted_root);
            
            general_page.add(portable_group);
            general_page.add(extracted_group);
            
            var records = registry.list();
            prune_indicator_states(records);
            row_indicators.clear();
            var extracted_records = new Gee.ArrayList<InstallationRecord>();
            var portable_records = new Gee.ArrayList<InstallationRecord>();
            
            foreach (var record in records) {
                if (record.mode == InstallMode.EXTRACTED) {
                    extracted_records.add(record);
                } else {
                    portable_records.add(record);
                }
            }

            populate_group(portable_group, portable_records);
            populate_group(extracted_group, extracted_records);

            if (records.length == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.title = I18n.tr("Nothing installed yet");
                empty_row.subtitle = I18n.tr("Install an AppImage by double-clicking it");
                portable_group.add(empty_row);
            }
        }

        private void setup_group_header(Adw.PreferencesGroup group, string title, string path) {
            var display_path = format_display_path(path);

            var header_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            header_container.set_halign(Gtk.Align.START);
           
            var title_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            title_row.set_valign(Gtk.Align.CENTER);
            title_row.set_halign(Gtk.Align.START);

            var title_label = new Gtk.Label(title);
            title_label.add_css_class("title-4");
            title_label.set_xalign(0);
            title_row.append(title_label);

            var folder_button = new Gtk.Button.from_icon_name("folder-open-symbolic");
            folder_button.add_css_class("flat");
            folder_button.set_valign(Gtk.Align.CENTER);
            folder_button.tooltip_text = I18n.tr("Open folder");
            folder_button.clicked.connect(() => {
                UiUtils.open_folder(path, this);
            });
            title_row.append(folder_button);

            header_container.append(title_row);

            var path_label = new Gtk.Label(display_path);
            path_label.add_css_class("dim-label");
            path_label.add_css_class("caption");
            path_label.set_xalign(0);
            path_label.set_ellipsize(Pango.EllipsizeMode.MIDDLE);
            header_container.append(path_label);

            group.title = null;
            group.description = null;
            group.set_header_suffix(header_container);
            align_group_header_box(group);
        }

        private string format_display_path(string path) {
            var home = Environment.get_home_dir();
            if (path.has_prefix(home)) {
                if (path.length == home.length) {
                    return "~";
                }
                var remainder = path.substring(home.length);
                if (!remainder.has_prefix("/")) {
                    remainder = "/" + remainder;
                }
                return "~" + remainder;
            }
            return path;
        }

        private void align_group_header_box(Adw.PreferencesGroup group) {
            var outer_box = group.get_first_child();
            if (outer_box == null) {
                return;
            }

            for (var child = outer_box.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child.has_css_class("header")) {
                    child.set_halign(Gtk.Align.START);
                    child.set_hexpand(false);
                    return;
                }
            }
        }

        private void populate_group(Adw.PreferencesGroup group, Gee.ArrayList<InstallationRecord> records) {
            foreach (var record in records) {
                var row = new Adw.ActionRow();
                row.title = record.name;
                
                string version_text;
                if (record.version != null && record.version.strip() != "") {
                    version_text = I18n.tr("Version %s").printf(record.version);
                } else {
                    version_text = I18n.tr("Version unknown");
                }
                row.subtitle = version_text;

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

                bool has_update_link = updater.get_update_url(record) != null;
                var indicator = new UpdateIndicator(has_update_link);
                var state_key = record_state_key(record);
                row_indicators.set(state_key, indicator);
                indicator.apply_state(get_record_state(state_key));

                var suffix_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                suffix_box.set_valign(Gtk.Align.CENTER);
                suffix_box.append(indicator.widget);
                suffix_box.append(arrow);
                row.add_suffix(suffix_box);

                group.add(row);
            }
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
            menu.append(I18n.tr("Keyboard shortcuts"), "app.show_shortcuts");
            menu.append(I18n.tr("About AppManager"), "app.show_about");
            return menu;
        }

        private Adw.ToolbarView create_toolbar_with_header(Gtk.Widget content, bool include_menu_button) {
            var toolbar = new Adw.ToolbarView();
            var header = new Adw.HeaderBar();

            if (include_menu_button) {
                ensure_update_button(header);
                var menu_button = new Gtk.MenuButton();
                menu_button.set_icon_name("open-menu-symbolic");
                menu_button.menu_model = build_menu_model();
                menu_button.tooltip_text = I18n.tr("More actions");
                header.pack_end(menu_button);
            }

            toolbar.add_top_bar(header);
            toolbar.set_content(content);
            return toolbar;
        }

        private void ensure_update_button(Adw.HeaderBar header) {
            if (update_button == null) {
                update_button = new Gtk.Button.with_label(I18n.tr("Update Apps"));
                update_button.add_css_class("suggested-action");
                update_button.clicked.connect(trigger_updates);
            }
            if (update_button.get_parent() == null) {
                header.pack_start(update_button);
            }
        }

        private void trigger_updates() {
            if (updates_in_progress) {
                add_toast(I18n.tr("Updates already running"));
                return;
            }
            updates_in_progress = true;
            if (update_button != null) {
                update_button.set_sensitive(false);
                update_button.set_label(I18n.tr("Updating..."));
            }

            new Thread<void>("appmgr-update", () => {
                var results = updater.update_all();
                Idle.add(() => {
                    handle_update_results(results);
                    updates_in_progress = false;
                    if (update_button != null) {
                        update_button.set_label(I18n.tr("Update Apps"));
                        update_button.set_sensitive(true);
                    }
                    return GLib.Source.REMOVE;
                });
            });
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

        private void connect_updater_signals() {
            updater.record_checking.connect((record) => {
                Idle.add(() => {
                    var key = record_state_key(record);
                    active_update_keys.add(key);
                    set_record_state(key, UpdateVisualState.CHECKING);
                    return GLib.Source.REMOVE;
                });
            });

            updater.record_downloading.connect((record) => {
                Idle.add(() => {
                    var key = record_state_key(record);
                    active_update_keys.add(key);
                    set_record_state(key, UpdateVisualState.DOWNLOADING);
                    return GLib.Source.REMOVE;
                });
            });

            updater.record_succeeded.connect((record) => {
                Idle.add(() => {
                    var key = record_state_key(record);
                    set_record_state(key, UpdateVisualState.SUCCESS);
                    active_update_keys.remove(key);
                    return GLib.Source.REMOVE;
                });
            });

            updater.record_failed.connect((record, message) => {
                Idle.add(() => {
                    var key = record_state_key(record);
                    set_record_state(key, UpdateVisualState.FAILED);
                    active_update_keys.remove(key);
                    return GLib.Source.REMOVE;
                });
            });

            updater.record_skipped.connect((record, reason) => {
                Idle.add(() => {
                    var key = record_state_key(record);
                    switch (reason) {
                        case UpdateSkipReason.MISSING_ASSET:
                        case UpdateSkipReason.API_UNAVAILABLE:
                        case UpdateSkipReason.UNSUPPORTED_SOURCE:
                            set_record_state(key, UpdateVisualState.FAILED);
                            break;
                        default:
                            set_record_state(key, UpdateVisualState.IDLE);
                            break;
                    }
                    active_update_keys.remove(key);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void set_record_state(string state_key, UpdateVisualState state) {
            indicator_states.set(state_key, state);
            UpdateIndicator? indicator = row_indicators.get(state_key);
            if (indicator != null) {
                indicator.apply_state(state);
            }
        }

        private UpdateVisualState get_record_state(string state_key) {
            if (indicator_states.has_key(state_key)) {
                return indicator_states.get(state_key);
            }
            return UpdateVisualState.IDLE;
        }

        private void prune_indicator_states(InstallationRecord[] records) {
            var valid = new Gee.HashSet<string>();
            foreach (var record in records) {
                valid.add(record_state_key(record));
            }
            var to_remove = new Gee.ArrayList<string>();
            foreach (var id in indicator_states.keys) {
                if (!valid.contains(id) && !active_update_keys.contains(id)) {
                    to_remove.add(id);
                }
            }
            foreach (var id in to_remove) {
                indicator_states.unset(id);
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

        private enum UpdateVisualState {
            IDLE,
            CHECKING,
            DOWNLOADING,
            FAILED,
            SUCCESS
        }

        private class UpdateIndicator : Object {
            public Gtk.Widget widget { get; private set; }
            private bool has_update;
            private Gtk.Stack stack;
            private Gtk.Spinner spinner;
            private CircularProgress progress;
            private Gtk.Image warning;
            private Gtk.Widget success_badge;

            public UpdateIndicator(bool has_update) {
                this.has_update = has_update;
                stack = new Gtk.Stack();
                stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
                stack.transition_duration = 120;
                stack.set_valign(Gtk.Align.CENTER);
                stack.set_halign(Gtk.Align.CENTER);

                var placeholder = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
                placeholder.set_size_request(18, 18);
                stack.add_named(placeholder, "idle");

                spinner = new Gtk.Spinner();
                spinner.set_size_request(18, 18);
                stack.add_named(spinner, "checking");

                progress = new CircularProgress();
                stack.add_named(progress, "downloading");

                warning = new Gtk.Image.from_icon_name("dialog-warning-symbolic");
                warning.set_pixel_size(18);
                warning.add_css_class("error");
                stack.add_named(warning, "failed");

                var success_image = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
                success_image.set_pixel_size(12);
                success_image.add_css_class("update-success-icon");

                var success_container = new Gtk.CenterBox();
                success_container.set_size_request(18, 18);
                success_container.set_halign(Gtk.Align.CENTER);
                success_container.set_valign(Gtk.Align.CENTER);
                success_container.add_css_class("update-success-badge");
                success_container.set_center_widget(success_image);
                success_badge = success_container;
                stack.add_named(success_badge, "success");

                if (!has_update) {
                    stack.set_visible(false);
                }

                this.widget = stack;
            }

            public void apply_state(UpdateVisualState state) {
                if (!has_update) {
                    return;
                }

                switch (state) {
                    case UpdateVisualState.CHECKING:
                        spinner.start();
                        progress.stop();
                        stack.set_visible_child_name("checking");
                        stack.set_visible(true);
                        break;
                    case UpdateVisualState.DOWNLOADING:
                        spinner.stop();
                        progress.start();
                        stack.set_visible_child_name("downloading");
                        stack.set_visible(true);
                        break;
                    case UpdateVisualState.FAILED:
                        spinner.stop();
                        progress.stop();
                        stack.set_visible_child_name("failed");
                        stack.set_visible(true);
                        break;
                    case UpdateVisualState.SUCCESS:
                        spinner.stop();
                        progress.stop();
                        stack.set_visible_child_name("success");
                        stack.set_visible(true);
                        break;
                    default:
                        spinner.stop();
                        progress.stop();
                        stack.set_visible_child_name("idle");
                        stack.set_visible(true);
                        break;
                }
            }
        }

        private class CircularProgress : Gtk.DrawingArea {
            private uint tick_id = 0;
            private double angle = 0;

            public CircularProgress() {
                set_content_width(18);
                set_content_height(18);
                set_draw_func((area, cr, width, height) => {
                    draw_arc(cr, width, height);
                });
            }

            public void start() {
                if (tick_id == 0) {
                    tick_id = add_tick_callback(on_tick);
                }
            }

            public void stop() {
                if (tick_id != 0) {
                    remove_tick_callback(tick_id);
                    tick_id = 0;
                }
            }

            private bool on_tick(Gtk.Widget widget, Gdk.FrameClock clock) {
                angle += 0.20;
                    var full_circle = GLib.Math.PI * 2.0;
                if (angle > full_circle) {
                    angle -= full_circle;
                }
                queue_draw();
                return GLib.Source.CONTINUE;
            }

            private void draw_arc(Cairo.Context cr, int width, int height) {
                var color = Gdk.RGBA();
                color.parse("#3584e4");
                cr.save();
                cr.set_source_rgba(color.red, color.green, color.blue, color.alpha);
                cr.set_line_width(2.0);
                var min_side = (double)width < (double)height ? (double)width : (double)height;
                var radius = min_side / 2.0 - 1.0;
                    var start = angle;
                    var end = angle + GLib.Math.PI * 1.5;
                cr.arc(width / 2.0, height / 2.0, radius, start, end);
                cr.stroke();
                cr.restore();
            }
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
            var details_window = new DetailsWindow(record, registry);
            details_window.uninstall_requested.connect((r) => {
                navigation_view.pop();
                app_ref.uninstall_record(r, this);
            });
            navigation_view.push(details_window);
        }
    }
}
