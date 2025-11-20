using AppManager.Core;
using AppManager.Utils;
using Gee;

namespace AppManager {
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
        private Adw.Banner version_banner;
        private Gtk.Box drag_box;
        private string appimage_path;
        private bool installing = false;
        private bool install_prompt_visible = false;
        private InstallMode install_mode = InstallMode.PORTABLE;
        private string resolved_app_name;
        private string? resolved_app_version = null;
        private const double DRAG_VISUAL_RANGE = 240.0;
        private uint version_banner_timeout_id = 0;

        private Settings settings;

        public DropWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings, string path) throws Error {
            Object(application: app,
                title: I18n.tr("AppImage Installer"),
                modal: true,
                default_width: 520,
                default_height: 320,
                destroy_with_parent: true);
            this.app_ref = app;
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            this.appimage_path = path;
            metadata = new AppImageMetadata(File.new_for_path(path));
            install_mode = determine_install_mode();
            resolved_app_name = extract_app_name();
            build_ui();
            load_icons_async();
        }

        private void build_ui() {
            this.title = I18n.tr("AppImage Installer");

            var toolbar_view = new Adw.ToolbarView();
            content = toolbar_view;

            var header = new Adw.HeaderBar();
            header.set_show_end_title_buttons(true);
            var title_widget = new Gtk.Label(I18n.tr("AppImage Installer"));
            title_widget.add_css_class("title-4");
            header.set_title_widget(title_widget);
            toolbar_view.add_top_bar(header);

            var clamp = new Adw.Clamp();
            clamp.margin_top = 24;
            clamp.margin_bottom = 24;
            clamp.margin_start = 24;
            clamp.margin_end = 24;

            var content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            toolbar_view.content = content_box;

            version_banner = new Adw.Banner("");
            version_banner.use_markup = true;
            version_banner.set_revealed(false);
            version_banner.button_label = null;
            version_banner.hexpand = true;
            version_banner.halign = Gtk.Align.FILL;
            version_banner.add_css_class("accent-fg-color");
            content_box.append(version_banner);

            content_box.append(clamp);

            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 18);
            clamp.child = outer;

            var subtitle = new Gtk.Label(I18n.tr("Drag and drop to install into Applications"));
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
            arrow_icon.add_css_class("dim-label");
            drag_box.append(arrow_icon);

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
                    notify_up_to_date(existing);
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

        private void present_install_warning_dialog() {
            var dialog = new Adw.Dialog();
            dialog.set_title(I18n.tr("Open %s?").printf(resolved_app_name));

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 18);
            content.margin_top = 32;
            content.margin_bottom = 24;
            content.margin_start = 32;
            content.margin_end = 32;

            var warning_icon = new Gtk.Image.from_icon_name("dialog-warning-symbolic");
            warning_icon.set_pixel_size(64);
            warning_icon.halign = Gtk.Align.CENTER;
            content.append(warning_icon);

            var warning_text = I18n.tr("%s is not from the official app repositories. Are you sure you want to open it?").printf(resolved_app_name);
            var body = new Gtk.Label(null);
            body.wrap = true;
            body.halign = Gtk.Align.CENTER;
            body.justify = Gtk.Justification.CENTER;
            body.use_markup = true;
            body.set_markup("<b>%s</b>".printf(GLib.Markup.escape_text(warning_text, -1)));
            content.append(body);

            var button_column = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            button_column.halign = Gtk.Align.FILL;
            button_column.hexpand = true;

            var install_button = new Gtk.Button.with_label(I18n.tr("Install"));
            install_button.hexpand = true;
            install_button.halign = Gtk.Align.FILL;
            button_column.append(install_button);

            var extract_button = new Gtk.Button.with_label(I18n.tr("Extract & Install"));
            extract_button.hexpand = true;
            extract_button.halign = Gtk.Align.FILL;
            button_column.append(extract_button);

            var cancel_button = new Gtk.Button.with_label(I18n.tr("Cancel"));
            cancel_button.hexpand = true;
            cancel_button.halign = Gtk.Align.FILL;
            cancel_button.add_css_class("suggested-action");
            cancel_button.receives_default = true;
            button_column.append(cancel_button);

            content.append(button_column);
            dialog.set_child(content);

            install_prompt_visible = true;
            dialog.closed.connect(() => {
                install_prompt_visible = false;
            });

            cancel_button.clicked.connect(() => {
                dialog.close();
            });

            install_button.clicked.connect(() => {
                dialog.close();
                run_installation(selected_mode(), null);
            });

            extract_button.clicked.connect(() => {
                dialog.close();
                run_installation(InstallMode.EXTRACTED, null);
            });

            dialog.set_default_widget(cancel_button);
            dialog.present(this);
            cancel_button.grab_focus();
        }

        private void present_upgrade_dialog(InstallationRecord record) {
            var dialog = new Adw.AlertDialog(
                I18n.tr("Upgrade %s?").printf(record.name),
                I18n.tr("%s is already installed.").printf(record.name)
            );
            dialog.add_response("upgrade", I18n.tr("Upgrade"));
            dialog.add_response("cancel", I18n.tr("Cancel"));
            dialog.set_default_response("upgrade");
            dialog.set_response_appearance("upgrade", Adw.ResponseAppearance.SUGGESTED);
            dialog.set_close_response("cancel");
            dialog.set_extra_child(build_upgrade_dialog_content(record));

            install_prompt_visible = true;
            dialog.response.connect((response) => {
                install_prompt_visible = false;
                if (response == "upgrade") {
                    run_installation(record.mode, record);
                }
            });

            dialog.present(this);
        }

        private void notify_up_to_date(InstallationRecord record) {
            var installed_version = record.version ?? I18n.tr("Unknown version");
            var target_version = resolved_app_version ?? installed_version;
            var title_markup = "<b>%s</b>".printf(GLib.Markup.escape_text(I18n.tr("%s is up to date").printf(record.name), -1));
            var body_markup = GLib.Markup.escape_text(I18n.tr("Installed version %s is newer or the same as %s.").printf(installed_version, target_version), -1);
            show_version_banner("%s\n%s".printf(title_markup, body_markup));
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

        private void show_version_banner(string markup) {
            if (version_banner == null) {
                return;
            }
            if (version_banner_timeout_id != 0) {
                GLib.Source.remove(version_banner_timeout_id);
                version_banner_timeout_id = 0;
            }
            version_banner.set_title(markup);
            version_banner.set_revealed(true);
            version_banner_timeout_id = GLib.Timeout.add(5000, () => {
                version_banner.set_revealed(false);
                version_banner_timeout_id = 0;
                return GLib.Source.REMOVE;
            });
        }

        private Gtk.Widget build_upgrade_dialog_content(InstallationRecord record) {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
            column.margin_top = 16;
            column.margin_bottom = 8;
            column.margin_start = 12;
            column.margin_end = 12;

            var image = new Gtk.Image();
            image.set_pixel_size(64);
            image.halign = Gtk.Align.CENTER;
            image.valign = Gtk.Align.START;
            var record_icon = load_record_icon(record);
            if (record_icon != null) {
                image.set_from_paintable(record_icon);
            } else {
                image.set_from_icon_name("application-x-executable");
            }
            column.append(image);

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
                    if (upgrade_target != null) {
                        installer.uninstall(upgrade_target);
                    }
                    var record = installer.install(staged_copy, mode);
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
            cleanup_staging_dir(staging_dir);
            remove_source_appimage();
            var title = upgraded ? I18n.tr("Upgraded %s").printf(record.name) : I18n.tr("Installed %s").printf(record.name);
            var version_text = record.version ?? I18n.tr("Unknown version");
            send_install_notification(title, I18n.tr("Version %s available in Applications").printf(version_text));
            this.close();
        }

        private void handle_install_failure(string message, string? staging_dir = null) {
            installing = false;
            cleanup_staging_dir(staging_dir);
            send_install_notification(I18n.tr("Installation failed"), message, GLib.NotificationPriority.HIGH);
        }

        private void send_install_notification(string title, string body, GLib.NotificationPriority priority = GLib.NotificationPriority.NORMAL) {
            if (app_ref == null) {
                return;
            }
            var notification = new GLib.Notification(title);
            if (body != null && body.strip() != "") {
                notification.set_body(body);
            }
            notification.set_priority(priority);
            var timestamp = GLib.get_real_time();
            var notification_id = "drop-window-" + timestamp.to_string();
            app_ref.send_notification(notification_id, notification);
        }

        private void load_icons_async() {
            new Thread<void>("appmgr-icon", () => {
                try {
                    var texture = extract_icon_from_appimage(appimage_path);
                    if (texture != null) {
                        Idle.add(() => {
                            app_icon.set_from_paintable(texture);
                            sync_drag_ghost();
                            return GLib.Source.REMOVE;
                        });
                    } else {
                        Idle.add(() => {
                            app_icon.set_from_icon_name("application-x-executable");
                            sync_drag_ghost();
                            return GLib.Source.REMOVE;
                        });
                    }
                } catch (Error e) {
                    warning("Icon preview failed: %s", e.message);
                }
            });
        }

        private void setup_drag_install(Gtk.Box drag_container) {
            var gesture = new Gtk.GestureDrag();
            gesture.drag_begin.connect((start_x, start_y) => {
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
                run_7z({"x", path, "-o" + temp_dir, "-y"});
                var icon_path = find_icon(temp_dir);
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
            string temp_dir;
            try {
                temp_dir = Utils.FileUtils.create_temp_dir("appmgr-name-");
            } catch (Error e) {
                warning("Temp dir creation failed: %s", e.message);
                return resolved;
            }
            try {
                run_7z({"x", appimage_path, "-o" + temp_dir, "*.desktop", "-r", "-y"});
                var desktop_file = find_desktop_file(temp_dir);
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
                    }
                }
            } catch (Error e) {
                warning("Desktop file extraction error: %s", e.message);
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
            return resolved;
        }

        private string? find_desktop_file(string directory) {
            GLib.Dir dir;
            try {
                dir = GLib.Dir.open(directory);
            } catch (Error e) {
                return null;
            }
            string? name;
            while ((name = dir.read_name()) != null) {
                var path = Path.build_filename(directory, name);
                if (GLib.FileUtils.test(path, FileTest.IS_DIR)) {
                    var child = find_desktop_file(path);
                    if (child != null) {
                        return child;
                    }
                } else if (name.has_suffix(".desktop")) {
                    return path;
                }
            }
            return null;
        }

        private string? find_icon(string directory) {
            GLib.Dir dir;
            try {
                dir = GLib.Dir.open(directory);
            } catch (Error e) {
                warning("Failed to open %s: %s", directory, e.message);
                return null;
            }
            string? name;
            string? best = null;
            while ((name = dir.read_name()) != null) {
                var path = Path.build_filename(directory, name);
                if (GLib.FileUtils.test(path, FileTest.IS_DIR)) {
                    var child = find_icon(path);
                    if (child != null) {
                        return child;
                    }
                } else if (name.has_suffix(".png") || name.has_suffix(".svg")) {
                    best = path;
                }
            }
            return best;
        }

        private void run_7z(string[] args) throws Error {
            var cmd = new string[1 + args.length];
            cmd[0] = "7z";
            for (int i = 0; i < args.length; i++) {
                cmd[i + 1] = args[i];
            }
            string? stdout_str;
            string? stderr_str;
            int status;
            Process.spawn_sync(null, cmd, null, SpawnFlags.SEARCH_PATH, null, out stdout_str, out stderr_str, out status);
            if (status != 0) {
                throw new InstallerError.SEVEN_ZIP_MISSING("7z extraction failed");
            }
        }

        private InstallMode determine_install_mode() {
            var stored_mode = settings.get_string("default-install-mode");
            var normalized = sanitize_mode_id(stored_mode);
            if (stored_mode != normalized) {
                settings.set_string("default-install-mode", normalized);
            }
            if (normalized == "extracted") {
                return InstallMode.EXTRACTED;
            }
            return InstallMode.PORTABLE;
        }

        private string sanitize_mode_id(string? value) {
            if (value != null && value.down() == "extracted") {
                return "extracted";
            }
            return "portable";
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

        private Gtk.Box build_icon_column(Gtk.Image image, out Gtk.Label label, string text, bool emphasize = false) {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            column.halign = Gtk.Align.CENTER;
            column.valign = Gtk.Align.CENTER;
            column.append(image);

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
