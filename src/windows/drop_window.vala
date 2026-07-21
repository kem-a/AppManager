using AppManager.Core;
using AppManager.Utils;
using Gee;

namespace AppManager {
    private delegate void DialogCallback();

    // Verification state for SHA256 hash check
    private enum VerificationState {
        UNVERIFIED,  // User has not attempted verification
        VERIFIED,    // SHA256 hash matches - show golden checkmark
        FAILED       // SHA256 hash does not match - show red cross
    }

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
        private Gtk.Fixed ghost_container;
        private double ghost_x = 0;
        private double ghost_y = 0;
        private Gtk.Label app_name_label;
        private Gtk.Label folder_name_label;
        private Gtk.Box drag_box;
        private Gtk.Box app_column;
        private Gtk.Box folder_column;
        private Gtk.Spinner drag_spinner;
        private Adw.Banner incompatibility_banner;
        private Adw.Banner architecture_banner;
        private Adw.Banner verification_banner;
        private Gtk.Label subtitle;
        private string appimage_path;
        private bool installing = false;
        private bool install_prompt_visible = false;
        private string resolved_app_name;
        private string? resolved_app_version = null;
        private bool is_terminal_app = false;
        private const double DRAG_VISUAL_RANGE = 240.0;
        private bool spinner_icon_active = false;
        private bool spinner_install_active = false;
        private Settings settings;
        
        // Verification state tracking
        private VerificationState verification_state = VerificationState.UNVERIFIED;
        private Gtk.Overlay app_icon_overlay;
        private Gtk.Image verification_badge;
        private Gtk.Button verify_button;

        public DropWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings, string path) throws Error {
            Object(application: app,
                title: _("AppImage Installer"),
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
            
            // Note: We intentionally do NOT call reconcile_with_filesystem() here.
            // Reconciling on every DropWindow open can race with ongoing installs in other windows
            // and cause apps to be incorrectly marked as orphaned. Reconcile is called on app
            // launch and on manual refresh, which is sufficient.
            
            build_ui();
            check_compatibility();
            load_icons_async();
        }

        private void build_ui() {
            title = _("AppImage Installer");
            //add_css_class("devel");

            var toolbar_view = new Adw.ToolbarView();
            content = toolbar_view;

            var header = new Adw.HeaderBar();
            header.set_show_start_title_buttons(true);
            header.set_show_end_title_buttons(true);
            
            // Add Verify button to headerbar
            verify_button = new Gtk.Button.with_label(_("Verify"));
            verify_button.tooltip_text = _("Verify AppImage with SHA256 hash");
            verify_button.clicked.connect(present_verification_dialog);
            header.pack_end(verify_button);
            
            toolbar_view.add_top_bar(header);

            incompatibility_banner = new Adw.Banner("");
            incompatibility_banner.button_label = _("Close");
            incompatibility_banner.use_markup = false;
            incompatibility_banner.revealed = false;
            incompatibility_banner.button_clicked.connect(() => {
                this.close();
            });
            toolbar_view.add_top_bar(incompatibility_banner);
            
            // Architecture mismatch banner
            architecture_banner = new Adw.Banner("");
            architecture_banner.button_label = _("Close");
            architecture_banner.use_markup = false;
            architecture_banner.revealed = false;
            architecture_banner.button_clicked.connect(() => {
                this.close();
            });
            toolbar_view.add_top_bar(architecture_banner);
            
            // Verification failed banner
            verification_banner = new Adw.Banner(_("SHA256 hash does not match. Verification failed."));
            verification_banner.add_css_class("error");
            verification_banner.use_markup = false;
            verification_banner.revealed = false;
            toolbar_view.add_top_bar(verification_banner);

            var clamp = new Adw.Clamp();
            clamp.margin_top = 10;
            clamp.margin_bottom = 24;
            clamp.margin_start = 24;
            clamp.margin_end = 24;
            clamp.vexpand = true;
            clamp.valign = Gtk.Align.FILL;
            toolbar_view.content = clamp;

            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 18);
            outer.halign = Gtk.Align.CENTER;
            outer.valign = Gtk.Align.CENTER;
            outer.vexpand = true;
            clamp.child = outer;

            // Clicking anywhere clears icon selection first (capture phase);
            // the icon's own click handler then re-selects itself if clicked.
            var deselect_click = new Gtk.GestureClick();
            deselect_click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            deselect_click.pressed.connect((n_press, x, y) => {
                clear_icon_selection();
            });
            ((Gtk.Widget) this).add_controller(deselect_click);

            var install_dir_name = Path.get_basename(AppPaths.applications_dir);
            subtitle = new Gtk.Label(_("Drag and drop to install into %s").printf(install_dir_name));
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
            
            // Create overlay for app icon with verification badge
            app_icon_overlay = new Gtk.Overlay();
            app_icon_overlay.set_child(app_icon);
            
            // Create verification badge (initially hidden)
            verification_badge = new Gtk.Image();
            verification_badge.set_pixel_size(24);
            verification_badge.halign = Gtk.Align.END;
            verification_badge.valign = Gtk.Align.END;
            verification_badge.visible = false;
            app_icon_overlay.add_overlay(verification_badge);
            
            app_column = build_icon_column_with_overlay(app_icon_overlay, out app_name_label, resolved_app_name, true);
            drag_box.append(app_column);
            setup_double_click(app_column, run_appimage_standalone);

            arrow_icon = new Gtk.Image.from_icon_name("go-next-symbolic");
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
            folder_column = build_icon_column(folder_icon, out folder_name_label, install_dir_name);
            drag_box.append(folder_column);
            setup_double_click(folder_column, () => {
                UiUtils.open_folder(AppPaths.applications_dir, this);
            });

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
            drag_ghost.set_sensitive(false);

            ghost_container = new Gtk.Fixed();
            ghost_container.set_can_target(false);
            ghost_container.set_overflow(Gtk.Overflow.VISIBLE);
            ghost_container.put(drag_ghost, 0, 0);
            drag_overlay.add_overlay(ghost_container);
            drag_overlay.set_clip_overlay(ghost_container, false);

            outer.append(drag_overlay);
            setup_drag_install(drag_box, app_column);
            sync_drag_ghost();
        }

        private void present_install_warning_dialog() {
            if (install_prompt_visible) {
                return;
            }

            // Use app icon with warning badge overlay
            var icon_overlay = create_dialog_icon_with_badge(null, true);

            var dialog = new DialogWindow(app_ref, this, _("Open %s?").printf(resolved_app_name), null);
            dialog.append_body(icon_overlay);

            var warning_text = _("Origins of %s application can not be verified. Are you sure you want to open it?").printf(resolved_app_name);
            var warning_markup = "<b>%s</b>".printf(GLib.Markup.escape_text(warning_text, -1));
            dialog.append_body(UiUtils.create_wrapped_label(warning_markup, true));
            
            if (is_terminal_app) {
                dialog.append_body(UiUtils.create_wrapped_label(_("This is a terminal application and will be installed in portable mode."), false, true));
            } else {
                dialog.append_body(UiUtils.create_wrapped_label(_("Install the AppImage to add it to your applications."), false, true));
            }

            dialog.add_option("install", _("Install"));
            dialog.add_option("cancel", _("Cancel"), true);

            install_prompt_visible = true;
            dialog.close_request.connect(() => {
                install_prompt_visible = false;
                return false;
            });

            dialog.option_selected.connect((response) => {
                install_prompt_visible = false;
                switch (response) {
                    case "install":
                        run_installation(InstallMode.PORTABLE, null, InstallIntent.NEW_INSTALL);
                        break;
                    default:
                        break;
                }
            });

            dialog.present();
        }

        private InstallationRecord? detect_existing_installation() {
            return registry.detect_existing(appimage_path, metadata.checksum, resolved_app_name);
        }

        private void start_install() {
            if (installing || install_prompt_visible) {
                return;
            }

            var existing = detect_existing_installation();
            if (existing != null) {
                present_replace_dialog(existing, determine_version_relation(existing));
            } else {
                // If app is verified, skip warning dialog and install directly
                if (verification_state == VerificationState.VERIFIED) {
                    run_installation(InstallMode.PORTABLE, null, InstallIntent.NEW_INSTALL);
                } else {
                    present_install_warning_dialog();
                }
            }
        }

        private enum VersionRelation {
            UNKNOWN,
            SAME,
            CANDIDATE_NEWER,
            INSTALLED_NEWER
        }

        private VersionRelation determine_version_relation(InstallationRecord record) {
            if (record.version == null || resolved_app_version == null) {
                return VersionRelation.UNKNOWN;
            }
            var comparison = VersionUtils.compare(record.version, resolved_app_version);
            if (comparison < 0) {
                return VersionRelation.CANDIDATE_NEWER;
            }
            if (comparison > 0) {
                return VersionRelation.INSTALLED_NEWER;
            }
            return VersionRelation.SAME;
        }

        private void check_compatibility() {
            if (!AppImageAssets.check_compatibility(appimage_path)) {
                incompatibility_banner.title = _("This AppImage is incompatible or corrupted");
                incompatibility_banner.revealed = true;
                subtitle.set_text(_("Missing required files (AppRun, .desktop, or icon)"));
                drag_box.set_sensitive(false);
                verify_button.set_sensitive(false);
                return;
            }
            
            // Check architecture compatibility
            if (!metadata.is_architecture_compatible()) {
                var appimage_arch = metadata.architecture ?? _("unknown");
                architecture_banner.title = _("This app is built for %s and cannot run here").printf(appimage_arch);
                architecture_banner.revealed = true;
                subtitle.set_text(_("Architecture mismatch"));
                drag_box.set_sensitive(false);
                verify_button.set_sensitive(false);
            }
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

        private void present_replace_dialog(InstallationRecord record, VersionRelation relation) {
            if (install_prompt_visible) {
                return;
            }

            // Use icon with verification badge overlay
            var icon_overlay = create_dialog_icon_with_badge(record, true);

            bool installed_newer = relation == VersionRelation.INSTALLED_NEWER;
            var dialog = new DialogWindow(app_ref, this, _("Replace %s?").printf(record.name), null);
            dialog.append_body(icon_overlay);
            string replace_text;
            if (relation == VersionRelation.CANDIDATE_NEWER) {
                replace_text = _("An older item named \"%s\" already exists in this location. Do you want to replace it with newer one you're copying?").printf(record.name);
            } else if (installed_newer) {
                replace_text = _("A newer item named %s already exists in this location. Do you want to replace it with the older one you're copying?").printf(record.name);
            } else {
                replace_text = _("An item named %s already exists in this location. Do you want to replace it with one you're copying?").printf(record.name);
            }
            if (relation != VersionRelation.SAME && relation != VersionRelation.UNKNOWN
                && record.version != null && resolved_app_version != null) {
                var versions = _("Installed: %s | Incoming: %s").printf(record.version, resolved_app_version);
                dialog.append_body(UiUtils.create_wrapped_label(GLib.Markup.escape_text(versions, -1), true, true));
            }
            dialog.append_body(UiUtils.create_wrapped_label(GLib.Markup.escape_text(replace_text, -1), true));
            var replace_is_default = !installed_newer;
            dialog.add_option("keep-both", _("Keep Both"));
            dialog.add_option("stop", _("Stop"), !replace_is_default);
            dialog.add_option("replace", _("Replace"), replace_is_default);

            install_prompt_visible = true;
            dialog.close_request.connect(() => {
                install_prompt_visible = false;
                return false;
            });

            dialog.option_selected.connect((response) => {
                install_prompt_visible = false;
                if (response == "replace") {
                    var intent = relation == VersionRelation.CANDIDATE_NEWER
                        ? InstallIntent.UPDATE
                        : InstallIntent.REPLACE;
                    run_installation(record.mode, record, intent);
                } else if (response == "keep-both") {
                    run_installation(InstallMode.PORTABLE, null, InstallIntent.NEW_INSTALL);
                }
            });

            dialog.present();
        }

        private enum InstallIntent {
            NEW_INSTALL,
            UPDATE,
            REPLACE
        }

        private void run_installation(InstallMode mode, InstallationRecord? existing_target, InstallIntent intent) {
            if (installing) {
                return;
            }
            installing = true;
            set_drag_spinner_install_active(true);

            string staged_path;
            string staged_dir;
            string? stage_error;
            if (!prepare_staging_copy(out staged_path, out staged_dir, out stage_error)) {
                handle_install_failure(stage_error ?? _("Unable to prepare AppImage for installation"));
                return;
            }

            var staged_copy = staged_path;
            var staged_dir_capture = staged_dir;
            run_installation_async.begin(staged_copy, staged_dir_capture, existing_target, mode, intent);
        }

        private async void run_installation_async(string staged_copy, string staged_dir_capture, InstallationRecord? existing_target, InstallMode mode, InstallIntent intent) {
            SourceFunc callback = run_installation_async.callback;
            InstallationRecord? record = null;
            Error? error = null;

            new Thread<void>("appmgr-install", () => {
                try {
                    if (existing_target != null) {
                        record = installer.upgrade(staged_copy, existing_target);
                    } else {
                        record = installer.install(staged_copy, mode);
                    }
                } catch (Error e) {
                    error = e;
                }
                Idle.add((owned) callback);
            });

            yield;

            if (error != null) {
                handle_install_failure(error.message, staged_dir_capture);
            } else if (record != null) {
                handle_install_success(record, existing_target != null, intent, staged_dir_capture);
            }
        }

        private void handle_install_success(InstallationRecord record, bool upgraded, InstallIntent intent, string? staging_dir) {
            installing = false;
            set_drag_spinner_install_active(false);
            cleanup_staging_dir(staging_dir);
            remove_source_appimage();
            var title = _("Successfully Installed");
            if (upgraded) {
                title = intent == InstallIntent.UPDATE ? _("Successfully Updated") : _("Successfully Replaced");
            }
            
            var image = new Gtk.Image();
            image.set_pixel_size(64);
            image.halign = Gtk.Align.CENTER;
            var record_icon = UiUtils.load_record_icon(record);
            if (record_icon != null) {
                image.set_from_paintable(record_icon);
            } else {
                image.set_from_icon_name("application-x-executable");
            }

            var dialog = new DialogWindow(app_ref, this, title, image);
            var app_name_markup = "<b>%s</b>".printf(GLib.Markup.escape_text(record.name, -1));
            dialog.append_body(UiUtils.create_wrapped_label(app_name_markup, true));
            
            var version_text = record.version ?? _("Unknown version");
            var version_label = UiUtils.create_wrapped_label(_("Version %s").printf(version_text), false);
            version_label.add_css_class("dim-label");
            dialog.append_body(version_label);
            
            dialog.add_option("open", _("Open"), true);
            dialog.add_option("done", _("Done"));
            dialog.option_selected.connect((response) => {
                if (response == "open") {
                    // Launch the app BEFORE closing the window to ensure spawn completes
                    // before the application potentially quits
                    try {
                        // Use DesktopAppInfo to launch with proper args from the desktop file
                        if (record.desktop_file != null && record.desktop_file.strip() != "") {
                            var app_info = new DesktopAppInfo.from_filename(record.desktop_file);
                            if (app_info != null) {
                                app_info.launch(null, null);
                            }
                        }
                    } catch (Error e) {
                        warning("Launch error: %s", e.message);
                    }
                }
                this.close();
            });
            dialog.present();
        }

        private void handle_install_failure(string message, string? staging_dir = null) {
            installing = false;
            set_drag_spinner_install_active(false);
            cleanup_staging_dir(staging_dir);
            var title = _("Installation failed");
            
            var error_icon = new Gtk.Image.from_icon_name("dialog-error-symbolic");
            error_icon.set_pixel_size(64);
            error_icon.halign = Gtk.Align.CENTER;

            var dialog = new DialogWindow(app_ref, this, title, error_icon);
            
            var body_markup = GLib.Markup.escape_text(message, -1);
            dialog.append_body(UiUtils.create_wrapped_label(body_markup, true));
            dialog.add_option("dismiss", _("Dismiss"));
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
            load_icons_thread_async.begin();
        }

        private async void load_icons_thread_async() {
            SourceFunc callback = load_icons_thread_async.callback;
            Gdk.Paintable? texture = null;

            new Thread<void>("appmgr-icon", () => {
                texture = UiUtils.load_icon_from_appimage(appimage_path);
                Idle.add((owned) callback);
            });

            yield;

            if (texture != null) {
                app_icon.set_from_paintable(texture);
            } else {
                app_icon.set_from_icon_name("application-x-executable");
            }
            sync_drag_ghost();
            set_drag_spinner_icon_active(false);
        }

        private void clear_icon_selection() {
            if (app_column != null) {
                app_column.remove_css_class("selected");
            }
            if (folder_column != null) {
                folder_column.remove_css_class("selected");
            }
        }

        private void setup_double_click(Gtk.Widget widget, DialogCallback on_double_click) {
            widget.add_css_class("clickable-icon-column");
            var click = new Gtk.GestureClick();
            click.pressed.connect((n_press, x, y) => {
                widget.add_css_class("selected");
                if (n_press == 2) {
                    on_double_click();
                }
            });
            widget.add_controller(click);
        }

        private void run_appimage_standalone() {
            if (installing) {
                return;
            }
            try {
                Utils.FileUtils.ensure_executable(appimage_path);
                string[] argv = { appimage_path };
                Pid child_pid;
                Process.spawn_async(null, argv, null, GLib.SpawnFlags.SEARCH_PATH | GLib.SpawnFlags.DO_NOT_REAP_CHILD, null, out child_pid);
                ChildWatch.add(child_pid, (pid, status) => {
                    Process.close_pid(pid);
                });
            } catch (Error e) {
                warning("Failed to run AppImage: %s", e.message);
            }
        }

        private const double DRAG_START_THRESHOLD = 24.0;

        private void setup_drag_install(Gtk.Box drag_container, Gtk.Widget drag_handle) {
            bool drag_visible = false;
            var gesture = new Gtk.GestureDrag();
            gesture.drag_begin.connect((start_x, start_y) => {
                drag_visible = false;
            });
            gesture.drag_update.connect((offset_x, offset_y) => {
                if (!drag_visible) {
                    if (offset_x * offset_x + offset_y * offset_y < DRAG_START_THRESHOLD * DRAG_START_THRESHOLD) {
                        return;
                    }
                    drag_visible = true;
                    drag_container.add_css_class("drag-active");
                    show_drag_ghost(offset_x, offset_y);
                }
                update_drag_visual(offset_x, offset_y);
            });
            gesture.drag_end.connect((offset_x, offset_y) => {
                if (!drag_visible) {
                    return;
                }
                drag_container.remove_css_class("drag-active");
                if (is_ghost_over_folder()) {
                    start_install();
                }
                reset_drag_visual();
            });
            drag_handle.add_controller(gesture);
        }

        private void update_drag_visual(double offset_x, double offset_y) {
            if (drag_ghost != null) {
                drag_ghost.visible = true;

                // Ghost opacity based on total distance moved (squared to avoid libm sqrt)
                var dist_sq = offset_x * offset_x + offset_y * offset_y;
                var range_sq = DRAG_VISUAL_RANGE * DRAG_VISUAL_RANGE;
                var d_progress = dist_sq / range_sq;
                if (d_progress > 1.0) {
                    d_progress = 1.0;
                }
                drag_ghost.set_opacity(0.4 + d_progress * 0.6);

                int base_x, base_y;
                compute_icon_position(out base_x, out base_y);

                ghost_x = base_x + offset_x;
                ghost_y = base_y + offset_y;
                ghost_container.move(drag_ghost, ghost_x, ghost_y);

                check_folder_highlight(ghost_x, ghost_y);
            }
        }

        private void check_folder_highlight(double ghost_x, double ghost_y) {
            if (folder_icon == null || drag_overlay == null) {
                return;
            }
            
            Graphene.Rect folder_bounds;
            if (folder_icon.compute_bounds(drag_overlay, out folder_bounds)) {
                float ghost_center_x = (float)(ghost_x + 48);
                float ghost_center_y = (float)(ghost_y + 48);
                
                var point = Graphene.Point();
                point.init(ghost_center_x, ghost_center_y);
                
                if (folder_bounds.contains_point(point)) {
                    if (folder_name_label != null) {
                        folder_name_label.add_css_class("accent");
                    }
                    if (folder_column != null) {
                        folder_column.add_css_class("drop-target-highlight");
                    }
                } else {
                    if (folder_name_label != null) {
                        folder_name_label.remove_css_class("accent");
                    }
                    if (folder_column != null) {
                        folder_column.remove_css_class("drop-target-highlight");
                    }
                }
            }
        }

        private void show_drag_ghost(double offset_x, double offset_y) {
            if (drag_ghost != null) {
                drag_ghost.visible = true;
                drag_ghost.set_opacity(0.0);
            }
            if (app_icon != null) {
                app_icon.set_opacity(0.6);
            }
            update_drag_visual(offset_x, offset_y);
        }

        private void reset_drag_visual() {
            if (app_icon != null) {
                app_icon.set_opacity(1.0);
            }
            if (drag_ghost != null) {
                drag_ghost.visible = false;
                drag_ghost.set_opacity(0.0);
                
                int base_x, base_y;
                compute_icon_position(out base_x, out base_y);
                ghost_x = base_x;
                ghost_y = base_y;
                ghost_container.move(drag_ghost, ghost_x, ghost_y);
            }
            if (folder_name_label != null) {
                folder_name_label.remove_css_class("accent");
            }
            if (folder_column != null) {
                folder_column.remove_css_class("drop-target-highlight");
            }
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
                    var desktop_info = AppImageAssets.parse_desktop_file(desktop_file);
                    if (desktop_info.name != null && desktop_info.name.strip() != "") {
                        resolved = desktop_info.name.strip();
                    }
                    if (desktop_info.appimage_version != null) {
                        resolved_app_version = desktop_info.appimage_version;
                    }
                    is_terminal_app = desktop_info.terminal;
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
            var applications_path = AppPaths.applications_dir;
            var applications_dir = File.new_for_path(applications_path);
            
            // Ensure the directory exists before querying its icon
            DirUtils.create_with_parents(applications_path, 0755);
            
            try {
                // Always query custom-icon metadata — it can be set by any file
                // manager (Nautilus, Nemo, Caja, etc.) and must not be gated on
                // detecting a specific desktop file, which fails inside AppImages
                // where XDG_DATA_DIRS may not include system paths.
                string attributes = "standard::icon,metadata::custom-icon";

                var info = applications_dir.query_info(attributes, FileQueryInfoFlags.NONE);
                if (info != null) {
                    var custom_icon = info.get_attribute_string("metadata::custom-icon");
                    if (custom_icon != null) {
                        return new FileIcon(File.new_for_uri(custom_icon));
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

        private bool is_ghost_over_folder() {
            if (folder_icon == null || drag_ghost == null || drag_overlay == null) {
                return false;
            }

            Graphene.Rect folder_bounds;
            if (!folder_icon.compute_bounds(drag_overlay, out folder_bounds)) {
                return false;
            }

            float ghost_center_x = (float)(ghost_x + 48);
            float ghost_center_y = (float)(ghost_y + 48);

            var point = Graphene.Point();
            point.init(ghost_center_x, ghost_center_y);

            return folder_bounds.contains_point(point);
        }

        private Gtk.Box build_icon_column(Gtk.Widget icon_widget, out Gtk.Label label, string text, bool emphasize = false) {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            column.halign = Gtk.Align.CENTER;
            column.valign = Gtk.Align.START; // Keep icons aligned even if labels wrap to multiple lines
            column.append(icon_widget);

            label = new Gtk.Label(text);
            label.halign = Gtk.Align.CENTER;
            label.wrap = true;
            label.max_width_chars = 15;
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

        private Gtk.Box build_icon_column_with_overlay(Gtk.Overlay icon_overlay, out Gtk.Label label, string text, bool emphasize = false) {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            column.halign = Gtk.Align.CENTER;
            column.valign = Gtk.Align.START;
            column.append(icon_overlay);

            label = new Gtk.Label(text);
            label.halign = Gtk.Align.CENTER;
            label.wrap = true;
            label.max_width_chars = 15;
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

        private void present_verification_dialog() {
            var dialog = new Adw.Window();
            dialog.set_title(_("Verify AppImage"));
            dialog.set_default_size(400, 180);
            dialog.set_resizable(false);
            dialog.set_modal(true);
            dialog.set_transient_for(this);

            var toolbar_view = new Adw.ToolbarView();
            dialog.set_content(toolbar_view);

            var header = new Adw.HeaderBar();
            toolbar_view.add_top_bar(header);

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            content.valign = Gtk.Align.CENTER;
            content.vexpand = true;
            content.margin_start = 24;
            content.margin_end = 24;

            var description = new Gtk.Label(_("Verify the authenticity of this AppImage."));
            description.wrap = true;
            description.halign = Gtk.Align.CENTER;
            content.append(description);

            var entry = new Gtk.Entry();
            entry.set_placeholder_text(_("Enter the SHA256 hash "));
            entry.hexpand = true;
            entry.max_width_chars = 64;
            content.append(entry);

            var button_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
            button_box.halign = Gtk.Align.CENTER;
            button_box.margin_top = 12;

            var cancel_button = new Gtk.Button.with_label(_("Cancel"));
            cancel_button.clicked.connect(() => {
                dialog.close();
            });
            button_box.append(cancel_button);

            var verify_btn = new Gtk.Button.with_label(_("Verify"));
            verify_btn.add_css_class("suggested-action");
            verify_btn.clicked.connect(() => {
                var entered_hash = entry.get_text().strip().down();
                perform_verification(entered_hash);
                dialog.close();
            });
            button_box.append(verify_btn);

            // Allow Enter key to verify
            entry.activate.connect(() => {
                var entered_hash = entry.get_text().strip().down();
                perform_verification(entered_hash);
                dialog.close();
            });

            content.append(button_box);
            toolbar_view.set_content(content);

            dialog.present();
        }

        private void perform_verification(string entered_hash) {
            if (entered_hash == "") {
                return;
            }

            // Strip common prefixes like "sha256:" or "SHA256:"
            var hash = entered_hash;
            if (hash.down().has_prefix("sha256:")) {
                hash = hash.substring(7).strip();
            }

            var actual_hash = metadata.checksum.down();
            
            if (hash.down() == actual_hash) {
                set_verification_state(VerificationState.VERIFIED);
            } else {
                set_verification_state(VerificationState.FAILED);
            }
        }

        private void set_verification_state(VerificationState state) {
            verification_state = state;
            update_verification_ui();
        }

        private void update_verification_ui() {
            switch (verification_state) {
                case VerificationState.VERIFIED:
                    // Show verified badge using bundled icon
                    verification_badge.set_from_icon_name("verify-ok");
                    verification_badge.visible = true;
                    verification_banner.revealed = false;
                    // Re-enable drag if it was disabled
                    drag_box.set_sensitive(true);
                    break;
                    
                case VerificationState.FAILED:
                    // Show failed badge using bundled icon
                    verification_badge.set_from_icon_name("verify-failed");
                    verification_badge.visible = true;
                    verification_banner.revealed = true;
                    // Disable installing
                    drag_box.set_sensitive(false);
                    break;
                    
                case VerificationState.UNVERIFIED:
                default:
                    verification_badge.visible = false;
                    verification_banner.revealed = false;
                    drag_box.set_sensitive(true);
                    break;
            }
        }

        // Create an image with verification badge overlay for dialogs
        private Gtk.Overlay create_dialog_icon_with_badge(InstallationRecord? record, bool show_badge) {
            var image = new Gtk.Image();
            image.set_pixel_size(64);
            image.halign = Gtk.Align.CENTER;
            
            if (record != null) {
                var record_icon = UiUtils.load_record_icon(record);
                if (record_icon != null) {
                    image.set_from_paintable(record_icon);
                } else {
                    image.set_from_icon_name("application-x-executable");
                }
            } else if (app_icon.paintable != null) {
                // Use the current app icon from drop window
                image.set_from_paintable(app_icon.paintable);
            } else {
                image.set_from_icon_name("application-x-executable");
            }

            var overlay = new Gtk.Overlay();
            overlay.set_child(image);
            overlay.halign = Gtk.Align.CENTER;

            if (show_badge) {
                var badge = new Gtk.Image();
                badge.set_pixel_size(20);
                badge.halign = Gtk.Align.END;
                badge.valign = Gtk.Align.END;
                
                if (verification_state == VerificationState.VERIFIED) {
                    badge.set_from_icon_name("verify-ok");
                    overlay.add_overlay(badge);
                } else {
                    // Show warning badge for unverified apps
                    badge.set_from_icon_name("verify-warning");
                    overlay.add_overlay(badge);
                }
            }

            return overlay;
        }

    }
}
