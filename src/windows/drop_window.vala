using AppManager.Core;
using AppManager.Utils;
using Gee;

namespace AppManager {
    private delegate void DialogCallback();

    public class DropWindow : Adw.Window {
        private Application app_ref;
        private InstallationRegistry registry;
        private Installer installer;
        private AppImageMetadata metadata;
        private Gtk.Image app_icon;
        private Gtk.Image folder_icon;
        private Gtk.Image arrow_icon;
        private Gtk.Overlay drag_overlay;
        private Gtk.Image drag_ghost;
        private Gtk.Label app_name_label;
        private Gtk.Label folder_name_label;
        private Gtk.Box drag_box;
        private Gtk.Spinner drag_spinner;
        private Adw.Banner up_to_date_banner;
        private Gtk.Label subtitle;
        private string appimage_path;
        private bool installing = false;
        private bool install_prompt_visible = false;
        private bool is_up_to_date = false;
        private InstallMode install_mode = InstallMode.PORTABLE;
        private string resolved_app_name;
        private string? resolved_app_version = null;
        private bool is_terminal_app = false;
        private const double DRAG_VISUAL_RANGE = 240.0;
        private bool spinner_icon_active = false;
        private bool spinner_install_active = false;
        private Settings settings;

        public DropWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings, string path) throws Error {
            Object(application: app,
                title: I18n.tr("AppImage Installer"),
                modal: true,
                default_width: 500,
                default_height: 300,
                destroy_with_parent: true);
            this.app_ref = app;
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            this.appimage_path = path;
            metadata = new AppImageMetadata(File.new_for_path(path));
            resolved_app_name = extract_app_name();
            build_ui();
            load_icons_async();
        }

        private void build_ui() {
            title = I18n.tr("AppImage Installer");
            add_css_class("devel");

            var toolbar_view = new Adw.ToolbarView();
            content = toolbar_view;

            var header = new Adw.HeaderBar();
            header.set_show_start_title_buttons(true);
            header.set_show_end_title_buttons(true);
            toolbar_view.add_top_bar(header);

            up_to_date_banner = new Adw.Banner("");
            up_to_date_banner.button_label = I18n.tr("Close");
            up_to_date_banner.button_style = Adw.BannerButtonStyle.SUGGESTED;
            up_to_date_banner.use_markup = false;
            up_to_date_banner.revealed = false;
            up_to_date_banner.button_clicked.connect(() => {
                this.close();
            });
            toolbar_view.add_top_bar(up_to_date_banner);

            var clamp = new Adw.Clamp();
            clamp.margin_top = 24;
            clamp.margin_bottom = 24;
            clamp.margin_start = 24;
            clamp.margin_end = 24;
            toolbar_view.content = clamp;

            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 18);
            clamp.child = outer;

            subtitle = new Gtk.Label(I18n.tr("Drag and drop to install into Applications"));
            subtitle.add_css_class("dim-label");
            subtitle.halign = Gtk.Align.CENTER;
            subtitle.wrap = true;
            outer.append(subtitle);

            drag_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 32);
            drag_box.halign = Gtk.Align.CENTER;
            drag_box.valign = Gtk.Align.CENTER;
            drag_box.hexpand = false;
            drag_box.vexpand = true;
            drag_box.margin_start = 0;
            drag_box.margin_end = 0;

            app_icon = new Gtk.Image();
            app_icon.set_pixel_size(96);
            app_icon.set_from_icon_name("application-x-executable");
            var app_column = build_icon_column(app_icon, out app_name_label, resolved_app_name, true);
            drag_box.append(app_column);

            arrow_icon = new Gtk.Image.from_icon_name("pan-end-symbolic");
            arrow_icon.set_pixel_size(48);
            arrow_icon.set_size_request(48, 48);
            arrow_icon.halign = Gtk.Align.CENTER;
            arrow_icon.valign = Gtk.Align.CENTER;
            arrow_icon.add_css_class("dim-label");

            drag_spinner = new Gtk.Spinner();
            drag_spinner.set_size_request(48, 48);
            drag_spinner.halign = Gtk.Align.CENTER;
            drag_spinner.valign = Gtk.Align.CENTER;
            drag_spinner.set_sensitive(false);
            drag_spinner.visible = false;

            var arrow_overlay = new Gtk.Overlay();
            arrow_overlay.set_size_request(48, 48);
            arrow_overlay.child = arrow_icon;
            arrow_overlay.add_overlay(drag_spinner);
            arrow_overlay.set_clip_overlay(drag_spinner, false);
            drag_box.append(arrow_overlay);

            folder_icon = create_applications_icon();
            var folder_column = build_icon_column(folder_icon, out folder_name_label, I18n.tr("Applications"));
            drag_box.append(folder_column);

            drag_overlay = new Gtk.Overlay();
            drag_overlay.child = drag_box;
            drag_overlay.hexpand = false;
            drag_overlay.vexpand = false;
            drag_overlay.halign = Gtk.Align.CENTER;
            drag_overlay.valign = Gtk.Align.CENTER;
            drag_overlay.margin_start = 24;
            drag_overlay.margin_end = 24;

            drag_ghost = new Gtk.Image();
            drag_ghost.set_pixel_size(96);
            drag_ghost.add_css_class("drag-ghost");
            drag_ghost.set_opacity(0.0);
            drag_ghost.visible = false;
            drag_ghost.halign = Gtk.Align.START;
            drag_ghost.valign = Gtk.Align.START;
            drag_ghost.set_sensitive(false);
            drag_overlay.add_overlay(drag_ghost);
            drag_overlay.set_clip_overlay(drag_ghost, false);

            outer.append(drag_overlay);
            setup_drag_install(drag_box);
            sync_drag_ghost();
        }

        private void present_install_warning_dialog() {
            if (install_prompt_visible) {
                return;
            }

            var warning_icon = new Gtk.Image.from_icon_name("dialog-warning-symbolic");
            warning_icon.set_pixel_size(64);
            warning_icon.halign = Gtk.Align.CENTER;

            var dialog = new DialogWindow(app_ref, this, I18n.tr("Open %s?").printf(resolved_app_name), warning_icon);

            var warning_text = I18n.tr("Origins of %s application can not be verified. Are you sure you want to open it?").printf(resolved_app_name);
            var warning_markup = "<b>%s</b>".printf(GLib.Markup.escape_text(warning_text, -1));
            dialog.append_body(create_wrapped_label(warning_markup, true));
            
            if (is_terminal_app) {
                dialog.append_body(create_wrapped_label(I18n.tr("This is a terminal application and will be installed in portable mode."), false, true));
            } else {
                dialog.append_body(create_wrapped_label(I18n.tr("You can install the AppImage directly or extract it for faster opening."), false, true));
            }

            dialog.add_option("install", I18n.tr("Install"));
            if (!is_terminal_app) {
                dialog.add_option("extract", I18n.tr("Extract & Install"));
            }
            dialog.add_option("cancel", I18n.tr("Cancel"), true);

            install_prompt_visible = true;
            dialog.close_request.connect(() => {
                install_prompt_visible = false;
                return false;
            });

            dialog.option_selected.connect((response) => {
                install_prompt_visible = false;
                switch (response) {
                    case "install":
                        run_installation(selected_mode(), null);
                        break;
                    case "extract":
                        run_installation(InstallMode.EXTRACTED, null);
                        break;
                    default:
                        break;
                }
            });

            dialog.present();
        }

        private InstallationRecord? detect_existing_installation() {
            var by_source = registry.lookup_by_source(appimage_path);
            if (by_source != null) {
                return by_source;
            }

            var by_checksum = registry.lookup_by_checksum(metadata.checksum);
            if (by_checksum != null) {
                return by_checksum;
            }

            var target = resolved_app_name.down();
            foreach (var record in registry.list()) {
                if (record.name != null && record.name.strip().down() == target) {
                    return record;
                }
            }

            return null;
        }

        private InstallMode selected_mode() {
            return install_mode;
        }

        private void start_install() {
            if (installing || install_prompt_visible) {
                return;
            }

            var existing = detect_existing_installation();
            if (existing != null) {
                if (is_version_same_or_newer(existing)) {
                    return;
                } else {
                    present_upgrade_dialog(existing);
                }
            } else {
                present_install_warning_dialog();
            }
        }

        private bool is_version_same_or_newer(InstallationRecord record) {
            if (record.version == null || resolved_app_version == null) {
                return false;
            }
            return compare_version_strings(record.version, resolved_app_version) >= 0;
        }

        private void check_if_up_to_date() {
            var existing = detect_existing_installation();
            if (existing != null && is_version_same_or_newer(existing)) {
                is_up_to_date = true;
                up_to_date_banner.title = I18n.tr("This app is already installed and up to date");
                up_to_date_banner.revealed = true;
                subtitle.set_text(I18n.tr("This app is already installed"));
                drag_box.set_sensitive(false);
            }
        }

        private int compare_version_strings(string installed, string candidate) {
            var installed_segments = extract_numeric_segments(installed);
            var candidate_segments = extract_numeric_segments(candidate);
            var max_len = installed_segments.size > candidate_segments.size ? installed_segments.size : candidate_segments.size;
            for (int i = 0; i < max_len; i++) {
                int lhs = i < installed_segments.size ? installed_segments.get(i) : 0;
                int rhs = i < candidate_segments.size ? candidate_segments.get(i) : 0;
                if (lhs == rhs) {
                    continue;
                }
                return lhs > rhs ? 1 : -1;
            }
            return installed.down().collate(candidate.down());
        }

        private ArrayList<int> extract_numeric_segments(string value) {
            var segments = new ArrayList<int>();
            var current = new StringBuilder();
            for (int i = 0; i < value.length; i++) {
                char ch = value[i];
                if (ch >= '0' && ch <= '9') {
                    current.append_c(ch);
                } else if (current.len > 0) {
                    segments.add(int.parse(current.str));
                    current.erase(0, current.len);
                }
            }
            if (current.len > 0) {
                segments.add(int.parse(current.str));
                current.erase(0, current.len);
            }
            if (segments.size == 0) {
                segments.add(0);
            }
            return segments;
        }

        private bool prepare_staging_copy(out string staged_path, out string staged_dir, out string? error_message) {
            string? temp_dir = null;
            try {
                temp_dir = Utils.FileUtils.create_temp_dir("appmgr-stage-");
                var destination = Path.build_filename(temp_dir, Path.get_basename(appimage_path));
                Utils.FileUtils.file_copy(appimage_path, destination);
                staged_dir = temp_dir;
                staged_path = destination;
                error_message = null;
                return true;
            } catch (Error e) {
                staged_path = "";
                staged_dir = temp_dir ?? "";
                error_message = e.message;
                if (temp_dir != null) {
                    Utils.FileUtils.remove_dir_recursive(temp_dir);
                }
                return false;
            }
        }

        private void cleanup_staging_dir(string? directory) {
            if (directory == null || directory.strip() == "") {
                return;
            }
            Utils.FileUtils.remove_dir_recursive(directory);
        }

        private void remove_source_appimage() {
            try {
                var source = File.new_for_path(appimage_path);
                if (source.query_exists()) {
                    source.delete(null);
                }
            } catch (Error e) {
                warning("Failed to delete original AppImage: %s", e.message);
            }
        }

        private Gtk.Widget build_upgrade_dialog_content(InstallationRecord record) {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
            column.margin_top = 0;
            column.margin_bottom = 8;
            column.margin_start = 12;
            column.margin_end = 12;
            column.halign = Gtk.Align.FILL;
            column.hexpand = true;

            var name_label = new Gtk.Label(null);
            name_label.use_markup = true;
            name_label.set_markup("<b>%s</b>".printf(GLib.Markup.escape_text(record.name, -1)));
            name_label.halign = Gtk.Align.CENTER;
            name_label.wrap = true;
            column.append(name_label);

            var version_text = record.version ?? I18n.tr("Version unknown");
            var current_label = new Gtk.Label(version_text);
            current_label.add_css_class("dim-label");
            current_label.halign = Gtk.Align.CENTER;
            current_label.wrap = true;
            column.append(current_label);

            var new_version_label = resolved_app_version ?? I18n.tr("Unknown version");
            var upgrade_label = new Gtk.Label(I18n.tr("Will upgrade to version %s").printf(new_version_label));
            upgrade_label.halign = Gtk.Align.CENTER;
            upgrade_label.wrap = true;
            column.append(upgrade_label);

            return column;
        }

        private void present_upgrade_dialog(InstallationRecord record) {
            if (install_prompt_visible) {
                return;
            }

            var image = new Gtk.Image();
            image.set_pixel_size(64);
            image.halign = Gtk.Align.CENTER;
            var record_icon = load_record_icon(record);
            if (record_icon != null) {
                image.set_from_paintable(record_icon);
            } else {
                image.set_from_icon_name("application-x-executable");
            }

            var dialog = new DialogWindow(app_ref, this, I18n.tr("Upgrade %s?").printf(record.name), image);
            dialog.append_body(build_upgrade_dialog_content(record));
            dialog.add_option("upgrade", I18n.tr("Upgrade"), true);
            dialog.add_option("cancel", I18n.tr("Cancel"));

            install_prompt_visible = true;
            dialog.close_request.connect(() => {
                install_prompt_visible = false;
                return false;
            });

            dialog.option_selected.connect((response) => {
                install_prompt_visible = false;
                if (response == "upgrade") {
                    run_installation(record.mode, record);
                }
            });

            dialog.present();
        }

        private Gtk.Label create_wrapped_label(string text, bool use_markup = false, bool dim = false) {
            var label = new Gtk.Label(null);
            label.wrap = true;
            label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            label.halign = Gtk.Align.CENTER;
            label.justify = Gtk.Justification.CENTER;
            label.use_markup = use_markup;
            if (use_markup) {
                label.set_markup(text);
            } else {
                label.set_text(text);
            }
            if (dim) {
                label.add_css_class("dim-label");
            }
            return label;
        }

        private Gdk.Paintable? load_record_icon(InstallationRecord record) {
            if (record.icon_path == null || record.icon_path.strip() == "") {
                return null;
            }
            try {
                var file = File.new_for_path(record.icon_path);
                if (file.query_exists()) {
                    return Gdk.Texture.from_file(file);
                }
            } catch (Error e) {
                warning("Failed to load existing icon: %s", e.message);
            }
            return null;
        }

        private void run_installation(InstallMode mode, InstallationRecord? upgrade_target) {
            if (installing) {
                return;
            }
            installing = true;
            set_drag_spinner_install_active(true);

            string staged_path;
            string staged_dir;
            string? stage_error;
            if (!prepare_staging_copy(out staged_path, out staged_dir, out stage_error)) {
                handle_install_failure(stage_error ?? I18n.tr("Unable to prepare AppImage for installation"));
                return;
            }

            var staged_copy = staged_path;
            var staged_dir_capture = staged_dir;
            new Thread<void>("appmgr-install", () => {
                try {
                    InstallationRecord record;
                    if (upgrade_target != null) {
                        record = installer.upgrade(staged_copy, upgrade_target);
                    } else {
                        record = installer.install(staged_copy, mode);
                    }
                    Idle.add(() => {
                        handle_install_success(record, upgrade_target != null, staged_dir_capture);
                        return GLib.Source.REMOVE;
                    });
                } catch (Error e) {
                    var message = e.message;
                    Idle.add(() => {
                        handle_install_failure(message, staged_dir_capture);
                        return GLib.Source.REMOVE;
                    });
                }
            });
        }

        private void handle_install_success(InstallationRecord record, bool upgraded, string? staging_dir) {
            installing = false;
            set_drag_spinner_install_active(false);
            cleanup_staging_dir(staging_dir);
            remove_source_appimage();
            var title = upgraded ? I18n.tr("Successfully Upgraded") : I18n.tr("Successfully Installed");
            
            var image = new Gtk.Image();
            image.set_pixel_size(64);
            image.halign = Gtk.Align.CENTER;
            var record_icon = load_record_icon(record);
            if (record_icon != null) {
                image.set_from_paintable(record_icon);
            } else {
                image.set_from_icon_name("application-x-executable");
            }

            var dialog = new DialogWindow(app_ref, this, title, image);
            var app_name_markup = "<b>%s</b>".printf(GLib.Markup.escape_text(record.name, -1));
            dialog.append_body(create_wrapped_label(app_name_markup, true));
            
            var version_text = record.version ?? I18n.tr("Unknown version");
            var version_label = create_wrapped_label(I18n.tr("Version %s").printf(version_text), false);
            version_label.add_css_class("dim-label");
            dialog.append_body(version_label);
            
            dialog.add_option("done", I18n.tr("Done"));
            dialog.option_selected.connect((response) => {
                this.close();
            });
            dialog.present();
        }

        private void handle_install_failure(string message, string? staging_dir = null) {
            installing = false;
            set_drag_spinner_install_active(false);
            cleanup_staging_dir(staging_dir);
            var title = I18n.tr("Installation failed");
            
            var error_icon = new Gtk.Image.from_icon_name("dialog-error-symbolic");
            error_icon.set_pixel_size(64);
            error_icon.halign = Gtk.Align.CENTER;

            var dialog = new DialogWindow(app_ref, this, title, error_icon);
            
            var body_markup = GLib.Markup.escape_text(message, -1);
            dialog.append_body(create_wrapped_label(body_markup, true));
            dialog.add_option("dismiss", I18n.tr("Dismiss"));
            dialog.present();
        }

        private void set_drag_spinner_icon_active(bool active) {
            if (spinner_icon_active == active) {
                return;
            }
            spinner_icon_active = active;
            update_drag_spinner_state();
        }

        private void set_drag_spinner_install_active(bool active) {
            if (spinner_install_active == active) {
                return;
            }
            spinner_install_active = active;
            if (drag_box != null) {
                drag_box.set_sensitive(!active);
            }
            update_drag_spinner_state();
        }

        private void update_drag_spinner_state() {
            if (drag_spinner == null || arrow_icon == null) {
                return;
            }
            var active = spinner_icon_active || spinner_install_active;
            drag_spinner.visible = active;
            arrow_icon.visible = !active;
            if (active) {
                drag_spinner.start();
            } else {
                drag_spinner.stop();
            }
        }

        private void load_icons_async() {
            set_drag_spinner_icon_active(true);
            new Thread<void>("appmgr-icon", () => {
                try {
                    var texture = extract_icon_from_appimage(appimage_path);
                    if (texture != null) {
                        Idle.add(() => {
                            app_icon.set_from_paintable(texture);
                            sync_drag_ghost();
                            set_drag_spinner_icon_active(false);
                            check_if_up_to_date();
                            return GLib.Source.REMOVE;
                        });
                    } else {
                        Idle.add(() => {
                            app_icon.set_from_icon_name("application-x-executable");
                            sync_drag_ghost();
                            set_drag_spinner_icon_active(false);
                            check_if_up_to_date();
                            return GLib.Source.REMOVE;
                        });
                    }
                } catch (Error e) {
                    warning("Icon preview failed: %s", e.message);
                    Idle.add(() => {
                        set_drag_spinner_icon_active(false);
                        check_if_up_to_date();
                        return GLib.Source.REMOVE;
                    });
                }
            });
        }

        private void setup_drag_install(Gtk.Box drag_container) {
            var gesture = new Gtk.GestureDrag();
            gesture.drag_begin.connect((start_x, start_y) => {
                if (is_up_to_date) {
                    return;
                }
                drag_container.add_css_class("drag-active");
                show_drag_ghost(0);
            });
            gesture.drag_update.connect((offset_x, offset_y) => {
                update_drag_visual(offset_x);
            });
            gesture.drag_end.connect((offset_x, offset_y) => {
                drag_container.remove_css_class("drag-active");
                var threshold = drag_container.get_width() * 0.45;
                if (threshold <= 0) {
                    threshold = 150;
                }
                var final_offset = offset_x;
                if (final_offset < 0) {
                    final_offset = 0;
                }
                if (final_offset >= threshold) {
                    start_install();
                }
                reset_drag_visual();
            });
            drag_container.add_controller(gesture);
        }

        private void update_drag_visual(double offset_x) {
            var clamped = offset_x;
            if (clamped < 0) {
                clamped = 0;
            }
            if (clamped > DRAG_VISUAL_RANGE) {
                clamped = DRAG_VISUAL_RANGE;
            }

            var progress = clamped / DRAG_VISUAL_RANGE;
            arrow_icon.set_opacity(0.3 + progress * 0.7);
            folder_icon.set_opacity(0.7 + progress * 0.3);

            if (drag_ghost != null) {
                drag_ghost.visible = true;
                drag_ghost.set_opacity(0.4 + progress * 0.6);
                
                int base_x, base_y;
                compute_icon_position(out base_x, out base_y);
                
                drag_ghost.margin_start = base_x + (int)clamped;
                drag_ghost.margin_top = base_y;
                
                check_folder_highlight(drag_ghost.margin_start, base_y);
            }
        }

        private void check_folder_highlight(int ghost_x, int ghost_y) {
            if (folder_icon == null || drag_overlay == null) {
                return;
            }
            
            Graphene.Rect folder_bounds;
            if (folder_icon.compute_bounds(drag_overlay, out folder_bounds)) {
                int ghost_center_x = ghost_x + 48;
                int ghost_center_y = ghost_y + 48;
                
                var point = Graphene.Point();
                point.init(ghost_center_x, ghost_center_y);
                
                if (folder_bounds.contains_point(point)) {
                    folder_icon.set_opacity(1.0);
                    if (folder_name_label != null) {
                        folder_name_label.add_css_class("accent");
                    }
                } else {
                    if (folder_name_label != null) {
                        folder_name_label.remove_css_class("accent");
                    }
                }
            }
        }

        private void show_drag_ghost(double offset_x) {
            if (drag_ghost != null) {
                drag_ghost.visible = true;
                drag_ghost.set_opacity(0.0);
            }
            if (app_icon != null) {
                app_icon.set_opacity(0.6);
            }
            update_drag_visual(offset_x);
        }

        private void reset_drag_visual() {
            arrow_icon.set_opacity(1.0);
            folder_icon.set_opacity(1.0);
            if (app_icon != null) {
                app_icon.set_opacity(1.0);
            }
            if (drag_ghost != null) {
                drag_ghost.visible = false;
                drag_ghost.set_opacity(0.0);
                
                int base_x, base_y;
                compute_icon_position(out base_x, out base_y);
                drag_ghost.margin_start = base_x;
                drag_ghost.margin_top = base_y;
            }
            if (folder_name_label != null) {
                folder_name_label.remove_css_class("accent");
            }
        }

        private Gdk.Paintable? extract_icon_from_appimage(string path) throws Error {
            var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-icon-");
            try {
                var icon_path = AppImageAssets.extract_icon(path, temp_dir);
                if (icon_path != null) {
                    return Gdk.Texture.from_file(File.new_for_path(icon_path));
                }
            } catch (Error e) {
                warning("Icon extraction error: %s", e.message);
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
            return null;
        }

        private string extract_app_name() {
            var resolved = metadata.display_name;
            resolved_app_version = null;
            is_terminal_app = false;
            string temp_dir;
            try {
                temp_dir = Utils.FileUtils.create_temp_dir("appmgr-name-");
            } catch (Error e) {
                warning("Temp dir creation failed: %s", e.message);
                return resolved;
            }
            try {
                var desktop_file = AppImageAssets.extract_desktop_entry(appimage_path, temp_dir);
                if (desktop_file != null) {
                    var key_file = new KeyFile();
                    key_file.load_from_file(desktop_file, KeyFileFlags.NONE);
                    if (key_file.has_group("Desktop Entry")) {
                        if (key_file.has_key("Desktop Entry", "Name")) {
                            resolved = key_file.get_string("Desktop Entry", "Name");
                        }
                        if (key_file.has_key("Desktop Entry", "X-AppImage-Version")) {
                            var candidate = key_file.get_string("Desktop Entry", "X-AppImage-Version").strip();
                            if (candidate.length > 0) {
                                resolved_app_version = candidate;
                            }
                        }
                        if (key_file.has_key("Desktop Entry", "Terminal")) {
                            is_terminal_app = key_file.get_boolean("Desktop Entry", "Terminal");
                        }
                    }
                }
            } catch (Error e) {
                warning("Desktop file extraction error: %s", e.message);
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
            return resolved;
        }


        private Gtk.Image create_applications_icon() {
            const int ICON_SIZE = 96;
            var image = new Gtk.Image();
            image.set_pixel_size(ICON_SIZE);

            var display = Gdk.Display.get_default();
            if (display != null) {
                var theme = Gtk.IconTheme.get_for_display(display);
                var gicon = load_applications_gicon();
                if (theme != null && gicon != null) {
                    var paintable = theme.lookup_by_gicon(gicon, ICON_SIZE, 1, Gtk.TextDirection.NONE, Gtk.IconLookupFlags.FORCE_REGULAR);
                    if (paintable != null) {
                        image.set_from_paintable(paintable);
                        return image;
                    }
                }

                string[] icon_candidates = { "folder-applications", "folder-apps", "folder" };
                foreach (var name in icon_candidates) {
                    if (theme != null && theme.has_icon(name)) {
                        image.set_from_icon_name(name);
                        return image;
                    }
                }
            }

            image.set_from_icon_name("folder");
            return image;
        }

        private GLib.Icon? load_applications_gicon() {
            var applications_path = Path.build_filename(Environment.get_home_dir(), "Applications");
            var applications_dir = File.new_for_path(applications_path);
            
            // Ensure the directory exists before querying its icon
            DirUtils.create_with_parents(applications_path, 0755);
            
            try {
                string attributes = "standard::icon";
                bool check_custom = false;

                // If Nautilus is installed, try to load custom icon from metadata
                // because Nautilus allows setting custom folder icons
                var nautilus = new DesktopAppInfo("org.gnome.Nautilus.desktop");
                if (nautilus != null) {
                    attributes += ",metadata::custom-icon";
                    check_custom = true;
                }

                var info = applications_dir.query_info(attributes, FileQueryInfoFlags.NONE);
                if (info != null) {
                    if (check_custom) {
                        var custom_icon = info.get_attribute_string("metadata::custom-icon");
                        if (custom_icon != null) {
                            return new FileIcon(File.new_for_uri(custom_icon));
                        }
                    }
                    return info.get_icon();
                }
            } catch (Error e) {
                warning("Applications icon lookup failed: %s", e.message);
            }

            var themed_fallback = new GLib.ThemedIcon.from_names({ "folder-applications", "folder-apps" });
            return themed_fallback;
        }

        private void sync_drag_ghost() {
            if (drag_ghost == null) {
                return;
            }
            var paintable = app_icon.get_paintable();
            if (paintable != null) {
                drag_ghost.set_from_paintable(paintable);
            } else {
                drag_ghost.set_from_icon_name("application-x-executable");
            }
        }

        private void compute_icon_position(out int x, out int y) {
            x = 0;
            y = 0;
            if (drag_overlay == null || app_icon == null) {
                return;
            }
            Graphene.Rect icon_bounds;
            if (app_icon.compute_bounds(drag_overlay, out icon_bounds)) {
                x = (int)icon_bounds.get_x();
                y = (int)icon_bounds.get_y();
            }
        }

        private Gtk.Box build_icon_column(Gtk.Widget icon_widget, out Gtk.Label label, string text, bool emphasize = false) {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            column.halign = Gtk.Align.CENTER;
            column.valign = Gtk.Align.CENTER;
            column.append(icon_widget);

            label = new Gtk.Label(text);
            label.halign = Gtk.Align.CENTER;
            label.wrap = true;
            var attrs = new Pango.AttrList();
            attrs.insert(Pango.attr_weight_new(Pango.Weight.BOLD));
            label.set_attributes(attrs);
            if (emphasize) {
                label.add_css_class("title-5");
            } else {
                label.add_css_class("title-6");
            }
            column.append(label);

            return column;
        }

    }
}
