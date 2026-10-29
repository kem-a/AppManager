using AppManager.Core;
using AppManager.Utils;
using Gee;

namespace AppManager {
    /**
     * Centers a two-button row and draws an optional leading action in the
     * side space. The leading action is deliberately excluded from measure()
     * so showing it never changes the row's minimum width or the window size.
     * When the side space is too small, only the content's left edge gives
     * way; its right edge and the trailing button stay in place.
     */
    private class LeadingActionRow : Gtk.Widget {
        private const int GAP = 8;
        private Gtk.Widget content;
        private Gtk.Widget? leading;
        private Gtk.Widget? shrink_target;
        private int base_content_width;
        private int base_target_width;
        private int last_target;
        private Adw.TimedAnimation shrink_animation;

        public LeadingActionRow(Gtk.Widget content, Gtk.Widget shrink_target) {
            this.content = content;
            this.shrink_target = shrink_target;
            content.set_parent(this);
            halign = Gtk.Align.FILL;
            hexpand = true;

            base_target_width = shrink_target.width_request;
            Gtk.Requisition min_size, natural_size;
            content.get_preferred_size(out min_size, out natural_size);
            base_content_width = natural_size.width;
            last_target = base_target_width;

            var target = new Adw.CallbackAnimationTarget((value) => {
                shrink_target.width_request = (int) Math.round(value);
                queue_allocate();
            });
            shrink_animation = new Adw.TimedAnimation(this, base_target_width, base_target_width, 220, target);
            shrink_animation.easing = Adw.Easing.EASE_OUT_CUBIC;
            map.connect(() => {
                last_target = -1;
                queue_allocate();
            });
        }

        public void set_leading(Gtk.Widget widget) {
            leading = widget;
            widget.set_parent(this);
        }

        public void set_leading_visible(bool visible) {
            if (leading == null || leading.visible == visible) {
                return;
            }
            leading.visible = visible;
            last_target = -1;
            queue_allocate();
        }

        private int leading_reserve() {
            if (leading == null) {
                return 0;
            }
            Gtk.Requisition min_size, natural_size;
            leading.get_preferred_size(out min_size, out natural_size);
            return natural_size.width + GAP;
        }

        public override Gtk.SizeRequestMode get_request_mode() {
            return content.get_request_mode();
        }

        public override void measure(Gtk.Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            content.measure(orientation, for_size, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
            if (orientation == Gtk.Orientation.HORIZONTAL) {
                // The leading action never changes the row's required width.
                minimum = int.max(minimum, base_content_width);
                natural = int.max(natural, base_content_width);
            }
        }

        public override void size_allocate(int width, int height, int baseline) {
            int reserve = leading != null ? leading_reserve() : 0;
            int base_left = (width - base_content_width) / 2;
            int target = base_target_width;
            if (leading != null && leading.visible) {
                // Only the Update button's left edge gives way, and only by the
                // amount the side space is short of the leading action's width.
                int needed = int.max(0, reserve - base_left);
                target = base_target_width - int.min(needed, reserve);
            }

            if (target != last_target) {
                last_target = target;
                if (target != shrink_target.width_request) {
                    if (Adw.get_enable_animations(this)) {
                        shrink_animation.value_from = shrink_target.width_request;
                        shrink_animation.value_to = target;
                        shrink_animation.play();
                    } else {
                        shrink_target.width_request = target;
                        queue_allocate();
                    }
                }
            }

            Gtk.Requisition content_min, content_natural;
            content.get_preferred_size(out content_min, out content_natural);
            int content_width = int.min(content_natural.width, width);
            // Keep the content row's right edge fixed: shrinking moves only the
            // Update button's left edge, leaving Update's right edge and the
            // Extract button in place.
            int content_x = int.max(0, base_left + base_content_width - content_width);
            var content_transform = new Gsk.Transform().translate(Graphene.Point() {
                x = content_x,
                y = 0
            });
            content.allocate(content_width, height, -1, content_transform);

            if (leading != null && leading.visible) {
                Gtk.Requisition leading_min, leading_natural;
                leading.get_preferred_size(out leading_min, out leading_natural);
                int leading_x = content_x - reserve;
                int leading_y = (height - leading_natural.height) / 2;
                var leading_transform = new Gsk.Transform().translate(Graphene.Point() {
                    x = leading_x,
                    y = leading_y
                });
                leading.allocate(leading_natural.width, leading_natural.height, -1, leading_transform);
            }
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            snapshot_child(content, snapshot);
            if (leading != null && leading.get_visible()) {
                snapshot_child(leading, snapshot);
            }
        }

        protected override void dispose() {
            if (content != null && content.get_parent() == this) {
                content.unparent();
            }
            if (leading != null && leading.get_parent() == this) {
                leading.unparent();
            }
            base.dispose();
        }
    }

    public class DetailsWindow : Adw.NavigationPage {
        private InstallationRecord record;
        private InstallationRegistry registry;
        private Installer installer;
        private bool update_available;
        private bool update_loading = false;
        private bool update_updating = false;  // true when actually updating (vs just checking)
        private string? update_failure_message = null;  // non-null when last update failed
        private Gtk.Button? update_button;
        private UpdateIndicator? update_indicator;
        private UpdateIndicatorState? update_progress_state;
        private ulong update_progress_changed_id = 0;
        private Gtk.Overlay? update_wrapper;
        private Gtk.Button? cancel_update_button;
        private LeadingActionRow? actions_row;
        private bool cancel_pressed = false;
        private Gtk.Button? extract_button;
        private Adw.Banner? path_banner;
        private Adw.SwitchRow? path_row;
        private Gtk.Button? delete_button;
        private bool shift_held = false;
        
        // Shared state for build_ui sub-methods
        private string exec_path;
        private HashTable<string, string> desktop_props;
        private Gtk.Widget? header_icon = null;
        
        public signal void uninstall_requested(InstallationRecord record, bool permanently, bool preserve_portable);
        public signal void update_requested(InstallationRecord record);
        public signal void update_cancel_requested(InstallationRecord record);
        public signal void check_update_requested(InstallationRecord record);
        public signal void extract_requested(InstallationRecord record);

        public DetailsWindow(InstallationRecord record, InstallationRegistry registry, Installer installer, bool update_available = false) {
            Object(title: record.name, tag: record.id);
            this.record = record;
            this.registry = registry;
            this.installer = installer;
            this.update_available = update_available;
            this.can_pop = true;
            
            build_ui();
            setup_shift_key_controller();
        }

        public bool matches_record(InstallationRecord other) {
            // Compare by name (case-insensitive) since ID is checksum and changes after update
            return record.name.down() == other.name.down();
        }

        public override void dispose() {
            if (update_progress_state != null && update_progress_changed_id != 0) {
                update_progress_state.disconnect(update_progress_changed_id);
                update_progress_changed_id = 0;
            }
            base.dispose();
        }

        public void set_update_available(bool available) {
            update_available = available;
            refresh_update_button();
        }

        public void set_update_loading(bool loading) {
            update_loading = loading;
            refresh_update_button();
        }

        public void set_update_updating(bool updating) {
            update_updating = updating;
            refresh_update_button();
        }

        public void set_update_failed(string? message) {
            update_failure_message = message;
            refresh_update_button();
        }

        public void set_update_progress(UpdateIndicatorState? state) {
            if (update_progress_state == state) {
                refresh_update_button();
                return;
            }
            if (update_progress_state != null && update_progress_changed_id != 0) {
                update_progress_state.disconnect(update_progress_changed_id);
                update_progress_changed_id = 0;
            }
            update_progress_state = state;
            if (state != null) {
                update_progress_changed_id = state.changed.connect(refresh_update_button);
            } else {
                update_loading = false;
                update_updating = false;
            }
            rebuild_update_indicator();
            refresh_update_button();
        }

        public void refresh_with_record(InstallationRecord updated_record) {
            this.record = updated_record;
            // Rebuild the entire UI with fresh data
            this.child = null;
            build_ui();
        }

        private void persist_record_and_refresh_desktop() {
            registry.update(record);
            installer.apply_record_customizations_to_desktop(record);
        }

        private void build_ui() {
            // Initialize shared state
            desktop_props = load_desktop_file_properties(record.desktop_file);
            exec_path = installer.resolve_exec_path_for_record(record);
            
            var detail_page = new Adw.PreferencesPage();
            
            // Build UI sections
            detail_page.add(build_header_group());
            detail_page.add(build_cards_group());
            
            var props_group = build_properties_group();
            // update_group will be handled inside build_app_updates_page()
            var advanced_row = build_advanced_action_row();
            props_group.add(advanced_row);
            
            detail_page.add(props_group);

            var security_group = new Adw.PreferencesGroup();
            security_group.add(build_security_action_row());
            detail_page.add(security_group);

            var update_group_replacement = new Adw.PreferencesGroup();
            update_group_replacement.add(build_update_info_action_row());
            detail_page.add(update_group_replacement);
            detail_page.add(build_actions_group());
            
            // Assemble final layout
            var toolbar = new Adw.ToolbarView();
            var header = new Adw.HeaderBar();
            toolbar.add_top_bar(header);

            var content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

            path_banner = new Adw.Banner(_("⚠️ '%s' is not in $PATH. App will not launch from the terminal").printf(AppPaths.local_bin_dir));
            content_box.append(path_banner);
            update_path_banner_visibility();

            if (FuseSupport.record_cannot_mount(record)) {
                var fuse_banner = new Adw.Banner(_("FUSE is missing, this app cannot run.") +
                    " <a href=\"https://github.com/AppImage/AppImageKit/wiki/FUSE\">" + _("Learn more") + "</a>");
                fuse_banner.use_markup = true;
                fuse_banner.add_css_class("warning");
                fuse_banner.revealed = true;
                content_box.append(fuse_banner);
            }

            content_box.append(detail_page);
            toolbar.set_content(content_box);
            this.child = toolbar;
        }

        private Adw.PreferencesGroup build_header_group() {
            var header_group = new Adw.PreferencesGroup();
            
            var header_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 16);
            header_box.set_halign(Gtk.Align.START);
            header_box.add_css_class("details-header");
            
            // App icon on the left
            header_icon = null;
            if (record.icon_path != null && record.icon_path.strip() != "") {
                var icon_image = UiUtils.load_app_icon(record.icon_path);
                if (icon_image != null) {
                    icon_image.set_pixel_size(128);
                    header_icon = icon_image;
                    icon_image.set_valign(Gtk.Align.START);
                    header_box.append(icon_image);
                }
            }
            
            // Right side: name, description, open button
            var info_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
            info_box.set_valign(Gtk.Align.FILL);
            info_box.set_vexpand(true);
            
            // App name
            var name_label = new Gtk.Label(record.name);
            name_label.add_css_class("title-1");
            name_label.set_wrap(true);
            name_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            name_label.set_xalign(0);
            name_label.set_valign(Gtk.Align.START);
            info_box.append(name_label);
            
            // App description: from record (metainfo/desktop), fallback to desktop Comment
            var app_description = desktop_props.get("Comment");
            if (app_description == null || app_description.strip() == "") {
                app_description = record.description;
            }
            if (app_description != null) {
                var desc_label = new Gtk.Label(app_description);
                desc_label.add_css_class("dimmed");
                desc_label.set_xalign(0);
                desc_label.set_ellipsize(Pango.EllipsizeMode.END);
                desc_label.set_max_width_chars(40);
                desc_label.set_lines(2);
                desc_label.set_single_line_mode(false);
                desc_label.set_valign(Gtk.Align.START);
                info_box.append(desc_label);
            }

            // Spacer to push open button to bottom
            var spacer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            spacer.set_vexpand(true);
            info_box.append(spacer);
            
            // Open button with launch spinner
            var open_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            open_box.set_halign(Gtk.Align.START);
            open_box.set_valign(Gtk.Align.END);

            var open_button = new Gtk.Button.with_label(_("Open"));
            open_button.add_css_class("pill");
            open_button.add_css_class("suggested-action");
            open_button.add_css_class("open-button");
            open_button.sensitive = !FuseSupport.record_cannot_mount(record);

            var launch_spinner = new Adw.Spinner();
            launch_spinner.set_visible(false);

            open_button.clicked.connect(() => {
                try {
                    var app_info = new DesktopAppInfo.from_filename(record.desktop_file);
                    if (app_info != null) {
                        app_info.launch(null, null);

                        // Show spinner for 3 seconds as launch feedback
                        launch_spinner.set_visible(true);
                        open_button.sensitive = false;
                        Timeout.add(3000, () => {
                            launch_spinner.set_visible(false);
                            open_button.sensitive = true;
                            return Source.REMOVE;
                        });
                    }
                } catch (Error e) {
                    warning("Failed to launch %s: %s", record.name, e.message);
                }
            });

            open_box.append(open_button);
            open_box.append(launch_spinner);
            info_box.append(open_box);
            
            header_box.append(info_box);
            
            var header_row = new Adw.PreferencesRow();
            header_row.set_activatable(false);
            header_row.set_child(header_box);
            header_group.add(header_row);
            
            return header_group;
        }

        private Adw.PreferencesGroup build_cards_group() {
            var cards_group = new Adw.PreferencesGroup();
            
            var cards_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            cards_box.set_halign(Gtk.Align.CENTER);
            
            // Install mode card
            var mode_button = new Gtk.Button();
            mode_button.add_css_class("card");
            if (record.mode == InstallMode.EXTRACTED) {
                mode_button.add_css_class("accent");
            }
            mode_button.set_valign(Gtk.Align.CENTER);
            mode_button.set_tooltip_text(_("Show in Files"));

            var mode_label = new Gtk.Label(record.mode == InstallMode.PORTABLE ? _("Portable") : _("Extracted"));
            mode_label.add_css_class("caption");
            mode_label.set_margin_start(8);
            mode_label.set_margin_end(8);
            mode_label.set_margin_top(6);
            mode_label.set_margin_bottom(6);
            mode_button.set_child(mode_label);

            mode_button.clicked.connect(() => {
                var parent_window = this.get_root() as Gtk.Window;
                var target_path = determine_reveal_path();
                UiUtils.open_folder(target_path, parent_window);
            });
            cards_box.append(mode_button);
            
            // Version card (only show if version is known)
            if (record.version != null && record.version.strip() != "") {
                var version_text = record.version.strip();
                var version_card = create_info_card(version_text.get_char(0).isdigit() ? "v%s".printf(version_text) : version_text);
                version_card.set_tooltip_text(_("App version"));
                cards_box.append(version_card);
            }
            
            // Size on disk card
            var size = calculate_installation_size(record);
            var size_card = create_info_card(UiUtils.format_size(size));
            cards_box.append(size_card);
            
            // Terminal app card (only show if is_terminal)
            if (record.is_terminal) {
                var terminal_card = create_info_card(_("Terminal"));
                terminal_card.add_css_class("terminal");
                cards_box.append(terminal_card);
            }
            
            // Zsync delta updates badge (only show if app supports zsync)
            if (record.zsync_update_info != null && record.zsync_update_info.strip() != "") {
                var zsync_card = create_info_card("Zsync");
                zsync_card.set_tooltip_text(_("This app supports efficient delta updates"));
                cards_box.append(zsync_card);
            }
            
            // Hidden from app drawer card (only show if NoDisplay=true)
            var nodisplay_value = desktop_props.get("NoDisplay") ?? "false";
            if (nodisplay_value.down() == "true") {
                var hidden_card = create_info_card(_("Hidden"));
                cards_box.append(hidden_card);
            }

            // Web page badge - clickable, shown only when a URL is set
            var web_url = record.get_effective_web_page() ?? "";
            if (web_url.strip() != "") {
                var web_badge = new Gtk.Button();
                web_badge.add_css_class("card");
                web_badge.set_valign(Gtk.Align.CENTER);
                web_badge.set_tooltip_text(web_url.strip());
                var web_label = new Gtk.Label(_("Web"));
                web_label.add_css_class("caption");
                web_label.set_margin_start(8);
                web_label.set_margin_end(8);
                web_label.set_margin_top(6);
                web_label.set_margin_bottom(6);
                web_badge.set_child(web_label);
                web_badge.clicked.connect(() => {
                    UiUtils.open_url(web_url.strip());
                });
                cards_box.append(web_badge);
            }

            cards_group.add(cards_box);
            return cards_group;
        }

        private Adw.PreferencesGroup build_properties_group() {
            var props_group = new Adw.PreferencesGroup();
            props_group.title = _("Properties");
            
            // Command line arguments
            var current_args = record.get_effective_commandline_args() ?? "";
            var exec_row = new Adw.EntryRow();
            exec_row.title = _("Command line arguments");
            exec_row.text = current_args;
            exec_row.add_prefix(new Gtk.Image.from_icon_name("utilities-terminal-symbolic"));
            
            var restore_exec_button = create_restore_button(record.custom_commandline_args != null);
            restore_exec_button.clicked.connect(() => {
                record.custom_commandline_args = null;
                exec_row.text = record.original_commandline_args ?? "";
                persist_record_and_refresh_desktop();
                restore_exec_button.set_visible(false);
            });
            exec_row.add_suffix(restore_exec_button);
            
            // Update the record on each keystroke (in-memory, cheap), but defer the .desktop
            // file write to focus-leave / Enter so it isn't rewritten letter-by-letter. The
            // flush reads only the record, so it is safe even during window teardown.
            exec_row.changed.connect(() => {
                var new_val = exec_row.text.strip();
                var original_val = record.original_commandline_args ?? "";
                if (new_val == original_val) {
                    record.custom_commandline_args = null;
                } else if (new_val == "") {
                    record.custom_commandline_args = CLEARED_VALUE;
                } else {
                    record.custom_commandline_args = new_val;
                }
                restore_exec_button.set_visible(record.custom_commandline_args != null);
            });
            var exec_focus = new Gtk.EventControllerFocus();
            exec_focus.leave.connect(() => { persist_record_and_refresh_desktop(); });
            exec_row.add_controller(exec_focus);
            exec_row.entry_activated.connect(() => { persist_record_and_refresh_desktop(); });
            props_group.add(exec_row);
            if (!record.is_self_app()) {
                props_group.add(build_autostart_row());
            }

            return props_group;
        }

        private Adw.ExpanderRow build_autostart_row() {
            var row = new Adw.ExpanderRow();
            row.title = _("Start on login");
            row.subtitle = _("Run this app automatically when you log in");
            row.add_prefix(new Gtk.Image.from_icon_name("system-run-symbolic"));
            row.show_enable_switch = true;
            row.enable_expansion = record.autostart_enabled;
            row.expanded = false;

            // No list refresh needed, and a refresh per spin click would rebuild this page.
            UpdateFunc flush = () => {
                registry.update(record, false);
                installer.sync_autostart_entry(record);
            };
            row.notify["enable-expansion"].connect(() => {
                record.autostart_enabled = row.enable_expansion;
                flush();
            });

            var args_row = new Adw.EntryRow();
            args_row.title = _("Extra arguments at login");
            args_row.text = record.custom_autostart_args ?? "";
            args_row.changed.connect(() => {
                var value = args_row.text.strip();
                record.custom_autostart_args = value == "" ? null : value;
            });
            var args_focus = new Gtk.EventControllerFocus();
            args_focus.leave.connect(() => { flush(); });
            args_row.add_controller(args_focus);
            args_row.entry_activated.connect(() => { flush(); });
            row.add_row(args_row);

            var delay_row = new Adw.SpinRow.with_range(0, 300, 1);
            delay_row.title = _("Delay in seconds");
            delay_row.value = record.custom_autostart_delay;
            delay_row.notify["value"].connect(() => {
                record.custom_autostart_delay = (int) delay_row.value;
                flush();
            });
            row.add_row(delay_row);

            return row;
        }

        private Adw.ActionRow build_update_info_action_row() {
            var row = new Adw.ActionRow();
            row.title = _("App Updates");
            row.subtitle = _("Edit app update details");
            row.add_prefix(new Gtk.Image.from_icon_name("software-update-available-symbolic"));

            var status_label = new Gtk.Label(record.updates_enabled ? _("On") : _("Off"));
            status_label.add_css_class("dim-label");
            row.add_suffix(status_label);
            
            var icon = new Gtk.Image.from_icon_name("go-next-symbolic");
            row.add_suffix(icon);
            row.activatable = true;
            row.activated.connect(() => {
                var page = build_app_updates_page(row, status_label);
                var main_win = (MainWindow) this.get_root();
                main_win.push_page(page);
            });
            return row;
        }

        private Adw.NavigationPage build_app_updates_page(Adw.ActionRow parent_row, Gtk.Label status_label) {
            var prefs_page = new Adw.PreferencesPage();

            // Description group - aligned with rows via PreferencesGroup title + description
            var body_text = _("Update info lets AppManager fetch new builds for you. Paste the download link and AppManager will do the rest.");
            body_text += "\n\n" + _("Currently GitHub and GitLab URL formats are fully supported. Direct download links also work if the server provides Last-Modified or Content-Length headers.");
            var info_group = new Adw.PreferencesGroup();
            info_group.title = _("Update links");
            info_group.description = body_text;
            prefs_page.add(info_group);

            // Enable / disable updates toggle
            var toggle_group = new Adw.PreferencesGroup();
            var enable_updates_row = new Adw.SwitchRow();
            enable_updates_row.title = _("Enable app updates");
            enable_updates_row.add_prefix(new Gtk.Image.from_icon_name("software-update-available-symbolic"));
            enable_updates_row.active = record.updates_enabled;
            toggle_group.add(enable_updates_row);
            prefs_page.add(toggle_group);

            // Update link / web page rows
            var update_group = build_update_info_group();
            prefs_page.add(update_group);

            // Sync logic
            update_group.sensitive = record.updates_enabled;
            enable_updates_row.notify["active"].connect(() => {
                record.updates_enabled = enable_updates_row.active;
                update_group.sensitive = enable_updates_row.active;
                registry.update(record);
                status_label.set_label(record.updates_enabled ? _("On") : _("Off"));
            });

            var toolbar = new Adw.ToolbarView();
            toolbar.add_top_bar(new Adw.HeaderBar());
            toolbar.set_content(prefs_page);

            return new Adw.NavigationPage(toolbar, _("App Updates"));
        }
        private Adw.PreferencesGroup build_update_info_group() {
            var update_group = new Adw.PreferencesGroup();
            update_group.title = _("Update details");
            
            var has_zsync = record.zsync_update_info != null && record.zsync_update_info.strip() != "";
            // gh-releases-zsync resolves through the GitHub releases API, so it can
            // honor the pre-release channel. A direct zsync URL points at a single
            // fixed file and has no channel to switch.
            var is_gh_releases_zsync = has_zsync && record.zsync_update_info.has_prefix("gh-releases-zsync|");

            // Pre-release toggle row (created early so update_row can reference it)
            var prerelease_row = new Adw.SwitchRow();
            prerelease_row.title = _("Pre-release Updates");
            prerelease_row.subtitle = _("Include pre-release versions when checking for updates");
            prerelease_row.add_prefix(new Gtk.Image.from_icon_name("starred-symbolic"));
            prerelease_row.active = record.prerelease_enabled;
            prerelease_row.notify["active"].connect(() => {
                record.prerelease_enabled = prerelease_row.active;
                registry.update(record);
            });
            if (has_zsync) {
                // zsync link is read-only, so visibility is fixed for the lifetime of the row
                prerelease_row.visible = is_gh_releases_zsync;
            } else {
                // Initial visibility based on current URL
                var initial_url = record.get_effective_update_link() ?? "";
                prerelease_row.visible = initial_url.down().contains("github.com");
            }

            // Update link row. For zsync the link is read-only and its visibility must
            // not track typing, so don't hand the toggle to the URL-sync handler.
            var update_row = build_update_link_row(has_zsync ? null : prerelease_row);
            if (has_zsync) {
                update_row.sensitive = false;
                update_row.tooltip_text = _("Update link is managed by the embedded zsync update mechanism");
            }
            update_group.add(update_row);

            // Web page row
            var webpage_row = build_webpage_row();
            update_group.add(webpage_row);

            // Add pre-release row after web page
            update_group.add(prerelease_row);
            
            return update_group;
        }

        /**
         * Syncs pre-release row visibility with the current URL text.
         * If URL is not GitHub, turns off the toggle and hides the row.
         */
        private void sync_prerelease_visibility(Adw.SwitchRow? prerelease_row, string url) {
            if (prerelease_row == null) return;
            var is_github = url.down().contains("github.com");
            if (is_github) {
                prerelease_row.visible = true;
            } else {
                // Turn off and hide when not GitHub
                if (prerelease_row.active) {
                    prerelease_row.active = false;
                }
                prerelease_row.visible = false;
            }
        }

        private Adw.EntryRow build_update_link_row(Adw.SwitchRow? prerelease_row) {
            var update_row = new Adw.EntryRow();
            update_row.title = _("Update Link");
            update_row.add_prefix(new Gtk.Image.from_icon_name("insert-link-symbolic"));
            update_row.text = record.get_effective_update_link() ?? "";
            
            var restore_update_button = create_restore_button(record.custom_update_link != null);
            restore_update_button.clicked.connect(() => {
                record.custom_update_link = null;
                update_row.text = record.original_update_link ?? "";
                persist_record_and_refresh_desktop();
                restore_update_button.set_visible(false);
                sync_prerelease_visibility(prerelease_row, update_row.text);
            });
            update_row.add_suffix(restore_update_button);
            
            // React to text changes in real-time for pre-release visibility
            update_row.changed.connect(() => {
                sync_prerelease_visibility(prerelease_row, update_row.text);
            });
            
            // Normalize URL when user leaves the entry or presses Enter
            var focus_controller = new Gtk.EventControllerFocus();
            focus_controller.leave.connect(() => {
                apply_update_link_value(update_row, restore_update_button);
            });
            update_row.add_controller(focus_controller);
            
            update_row.entry_activated.connect(() => {
                apply_update_link_value(update_row, restore_update_button);
            });
            
            return update_row;
        }

        private void apply_update_link_value(Adw.EntryRow row, Gtk.Button restore_button) {
            if (row.text == null) return;
            var raw_val = row.text.strip();
            var normalized = Updater.normalize_update_url(raw_val);
            var new_val = normalized ?? raw_val;
            
            if (new_val != raw_val && new_val != "") {
                row.text = new_val;
            }
            
            var original_val = record.original_update_link ?? "";
            if (new_val == original_val) {
                record.custom_update_link = null;
            } else if (new_val == "") {
                record.custom_update_link = CLEARED_VALUE;
            } else {
                record.custom_update_link = new_val;
            }
            persist_record_and_refresh_desktop();
            restore_button.set_visible(record.custom_update_link != null);
        }

        private Adw.EntryRow build_webpage_row() {
            var webpage_row = new Adw.EntryRow();
            webpage_row.title = _("Web Page");
            webpage_row.add_prefix(new Gtk.Image.from_icon_name("web-browser-symbolic"));
            webpage_row.text = record.get_effective_web_page() ?? "";
            
            var restore_webpage_button = create_restore_button(record.custom_web_page != null);
            restore_webpage_button.clicked.connect(() => {
                record.custom_web_page = null;
                webpage_row.text = record.original_web_page ?? "";
                persist_record_and_refresh_desktop();
                restore_webpage_button.set_visible(false);
            });
            webpage_row.add_suffix(restore_webpage_button);
            
            // Update the record on each keystroke (in-memory), defer the .desktop file write to
            // focus-leave / Enter. The flush reads only the record, so it is safe during teardown.
            webpage_row.changed.connect(() => {
                var new_val = webpage_row.text.strip();
                var original_val = record.original_web_page ?? "";
                if (new_val == original_val) {
                    record.custom_web_page = null;
                } else if (new_val == "") {
                    record.custom_web_page = CLEARED_VALUE;
                } else {
                    record.custom_web_page = new_val;
                }
                restore_webpage_button.set_visible(record.custom_web_page != null);
            });
            var webpage_focus = new Gtk.EventControllerFocus();
            webpage_focus.leave.connect(() => { persist_record_and_refresh_desktop(); });
            webpage_row.add_controller(webpage_focus);
            webpage_row.entry_activated.connect(() => { persist_record_and_refresh_desktop(); });
            
            var open_web_button = new Gtk.Button.from_icon_name("external-link-symbolic");
            open_web_button.add_css_class("flat");
            open_web_button.set_valign(Gtk.Align.CENTER);
            open_web_button.tooltip_text = _("Open web page");
            open_web_button.set_visible(webpage_row.text.strip().length > 0);
            open_web_button.clicked.connect(() => {
                var url = webpage_row.text.strip();
                if (url.length > 0) {
                    UiUtils.open_url(url);
                }
            });
            webpage_row.changed.connect(() => {
                open_web_button.set_visible(webpage_row.text.strip().length > 0);
            });
            webpage_row.add_suffix(open_web_button);
            
            return webpage_row;
        }

        // Order of the Profile combo, and the mapping to stored profile names.
        private const string[] SANDBOX_PROFILE_ORDER = {
            Core.SANDBOX_PROFILE_OFF,
            Core.SANDBOX_PROFILE_STANDARD,
            Core.SANDBOX_PROFILE_STRICT,
            Core.SANDBOX_PROFILE_CUSTOM
        };

        private string sandbox_status_label() {
            if (!record.sandbox_enabled()) {
                // The two are alternatives, so with the sandbox off a portable folder is
                // what decides where this app keeps its data, and saying "Off" would
                // describe the page as empty when it is not.
                return Installer.has_portable_folders(record) ? _("Portable") : _("Off");
            }
            switch (record.sandbox_profile) {
                case Core.SANDBOX_PROFILE_STANDARD: return _("Standard");
                case Core.SANDBOX_PROFILE_STRICT:   return _("Strict");
                case Core.SANDBOX_PROFILE_APPHUB:   return _("AppHub");
                case Core.SANDBOX_PROFILE_FLATHUB:  return _("Flathub");
                default:                            return _("Custom");
            }
        }

        // The update dot, here leading from this page to the Flathub profile. It is
        // shown once after install, until the profile list has been opened.
        private static Gtk.Label build_flathub_notice_dot(bool visible) {
            var dot = new Gtk.Label("●");
            dot.add_css_class("update-indicator");
            dot.valign = Gtk.Align.CENTER;
            dot.tooltip_text = _("Flathub permissions available");
            dot.visible = visible;
            return dot;
        }

        private Adw.ActionRow build_security_action_row() {
            var row = new Adw.ActionRow();
            // ActionRow titles are Pango markup, so a bare "&" is invalid and the
            // title silently fails to render. Keep the string clean for translators.
            row.title = Markup.escape_text(_("Privacy & Security"));
            row.subtitle = _("Run this app isolated from the rest of your files");
            row.add_prefix(new Gtk.Image.from_icon_name("security-high-symbolic"));

            var notice_dot = build_flathub_notice_dot(record.flathub_notice);
            row.add_suffix(notice_dot);

            var status_label = new Gtk.Label(sandbox_status_label());
            status_label.add_css_class("dim-label");
            row.add_suffix(status_label);

            var icon = new Gtk.Image.from_icon_name("go-next-symbolic");
            row.add_suffix(icon);
            row.activatable = true;
            row.activated.connect(() => {
                var page = build_security_page(status_label, notice_dot);
                var main_win = (MainWindow) this.get_root();
                main_win.push_page(page);
            });
            return row;
        }

        private const string[] SANDBOX_DISPLAY_ORDER = { "legacy", "wayland-or-x11", "wayland", "x11", "none" };

        private int sandbox_display_index(InstallationRecord r) {
            var display = r.sandbox_display ?? (r.sandbox_allow_x11 ? "legacy" : "wayland");
            for (int i = 0; i < SANDBOX_DISPLAY_ORDER.length; i++) {
                if (SANDBOX_DISPLAY_ORDER[i] == display) return i;
            }
            return 0;
        }

        private static string[] sandbox_display_labels() {
            return { _("Wayland and X11"), _("Prefer Wayland, otherwise X11"), _("Wayland only"), _("X11 only"), _("None") };
        }

        private Adw.ComboRow build_folder_permission_row(string title, string icon_name, string location) {
            var row = new Adw.ComboRow();
            row.title = title;
            row.add_prefix(new Gtk.Image.from_icon_name(icon_name));
            row.model = new Gtk.StringList({ _("Off"), _("Read-only"), _("Read and write") });
            row.selected = Core.SandboxConfig.folder_access(record, location);
            return row;
        }

        private Adw.SwitchRow build_permission_row(string title, string? subtitle, string icon_name, bool active) {
            var row = new Adw.SwitchRow();
            row.title = title;
            if (subtitle != null) {
                row.subtitle = subtitle;
            }
            row.add_prefix(new Gtk.Image.from_icon_name(icon_name));
            row.active = active;
            return row;
        }

        private Adw.NavigationPage build_security_page(Gtk.Label status_label, Gtk.Widget notice_dot) {
            var prefs_page = new Adw.PreferencesPage();

            bool supported = Core.SandboxConfig.supports_record(record);
            bool available = AppPaths.sandbox_available;

            // Say plainly why the controls are dead rather than just greying them out.
            if (!supported || !available) {
                var notice_group = new Adw.PreferencesGroup();
                var notice_row = new Adw.ActionRow();
                if (!supported) {
                    notice_row.title = _("Sandboxing is not available for this app");
                    notice_row.subtitle = record.mode == InstallMode.EXTRACTED
                        ? _("Only apps installed in portable mode can be sandboxed.")
                        : _("AppManager cannot sandbox itself.");
                } else {
                    notice_row.title = _("Sandboxing requires bubblewrap");
                    notice_row.subtitle = _("Install the bubblewrap and xdg-dbus-proxy packages to use this.");
                }
                notice_row.add_prefix(new Gtk.Image.from_icon_name("dialog-warning-symbolic"));
                notice_group.add(notice_row);
                prefs_page.add(notice_group);
            }

            // A separate mechanism from the sandbox, and listed first for that reason.
            // It is an alternative rather than an addition: only the AppImage runtime
            // reads these folders, and a sandboxed launch never runs it.
            var portable_group = new Adw.PreferencesGroup();
            portable_group.title = _("Portable folders");
            portable_group.visible = supported;

            var portable_home_row = new Adw.SwitchRow();
            portable_home_row.title = _("Portable .home folder");
            portable_home_row.subtitle = _("Store the app's home directory in a .home folder next to the AppImage");
            portable_home_row.add_prefix(new Gtk.Image.from_icon_name("user-home-symbolic"));
            portable_group.add(portable_home_row);

            var portable_config_row = new Adw.SwitchRow();
            portable_config_row.title = _("Portable .config folder");
            portable_config_row.subtitle = _("Store the app's config in a .config folder next to the AppImage");
            portable_config_row.add_prefix(new Gtk.Image.from_icon_name("emblem-system-symbolic"));
            portable_group.add(portable_config_row);
            prefs_page.add(portable_group);

            var profile_group = new Adw.PreferencesGroup();
            profile_group.title = _("Sandbox");
            profile_group.description = _("A sandboxed app gets its own home folder and cannot read the rest of yours. Standard keeps the network and sound working; Strict takes both away. Apps that need something you have not granted may fail to start or silently misbehave.");

            var profile_order = new Gee.ArrayList<string>();
            foreach (var profile in SANDBOX_PROFILE_ORDER) profile_order.add(profile);
            bool has_apphub = Core.SandboxConfig.has_apphub_profile(record);
            if (has_apphub) profile_order.add(Core.SANDBOX_PROFILE_APPHUB);
            var profile_row = new Adw.ComboRow();
            profile_row.title = _("Profile");
            profile_row.add_prefix(new Gtk.Image.from_icon_name("security-high-symbolic"));
            profile_row.model = new Gtk.StringList({
                _("Off"), _("Standard"), _("Strict"), _("Custom")
            });
            if (has_apphub) ((Gtk.StringList) profile_row.model).append(_("AppHub"));
            // Only for apps Flathub has. Fetched again when picked and reviewed in a
            // dialog: unlike an AppHub template, the match rests on an id the
            // AppImage declares about itself.
            UpdateFunc add_flathub_option = () => {
                profile_order.add(Core.SANDBOX_PROFILE_FLATHUB);
                ((Gtk.StringList) profile_row.model).append(_("Flathub"));
            };
            if (record.flathub_id != null) add_flathub_option();
            // The row's value gets its own factory only to put the dot right before it;
            // suffixes would land after the dropdown arrow.
            Gtk.Widget? profile_dot = null;
            var profile_value = new Gtk.SignalListItemFactory();
            profile_value.setup.connect((obj) => {
                var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                box.append(build_flathub_notice_dot(false));
                var label = new Gtk.Label(null);
                label.ellipsize = Pango.EllipsizeMode.END;
                box.append(label);
                ((Gtk.ListItem) obj).child = box;
            });
            profile_value.bind.connect((obj) => {
                var item = (Gtk.ListItem) obj;
                profile_dot = item.child.get_first_child();
                profile_dot.visible = record.flathub_notice;
                ((Gtk.Label) profile_dot.get_next_sibling()).label = ((Gtk.StringObject) item.item).string;
            });
            profile_row.factory = profile_value;

            // A custom popup list only to put the dot on the Flathub entry. Libadwaita
            // draws the selection check only in its default factory, so it is redone here.
            Gtk.Widget? flathub_item_dot = null;
            var profile_items = new Gtk.SignalListItemFactory();
            profile_items.setup.connect((obj) => {
                var item = (Gtk.ListItem) obj;
                var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                var label = new Gtk.Label(null);
                label.xalign = 0;
                box.append(label);
                box.append(build_flathub_notice_dot(false));
                var check = new Gtk.Image.from_icon_name("object-select-symbolic");
                check.hexpand = true;
                check.halign = Gtk.Align.END;
                box.append(check);
                item.child = box;
                profile_row.notify["selected-item"].connect(() => {
                    check.opacity = profile_row.selected_item == item.item ? 1 : 0;
                });
            });
            profile_items.bind.connect((obj) => {
                var item = (Gtk.ListItem) obj;
                var label = (Gtk.Label) item.child.get_first_child();
                var dot = label.get_next_sibling();
                label.label = ((Gtk.StringObject) item.item).string;
                bool flathub = profile_order[(int) item.position] == Core.SANDBOX_PROFILE_FLATHUB;
                dot.visible = flathub && record.flathub_notice;
                if (flathub) flathub_item_dot = dot;
                item.child.get_last_child().opacity = profile_row.selected_item == item.item ? 1 : 0;
            });
            profile_row.list_factory = profile_items;

            // Opening the list is looking at it: when it closes, the dots go.
            bool profile_popup_open = false;
            profile_row.notify["css-classes"].connect(() => {
                bool open = profile_row.has_css_class("has-open-popup");
                if (profile_popup_open && !open && record.flathub_notice) {
                    record.flathub_notice = false;
                    registry.update(record, false);
                    notice_dot.visible = false;
                    if (profile_dot != null) profile_dot.visible = false;
                    if (flathub_item_dot != null) flathub_item_dot.visible = false;
                }
                profile_popup_open = open;
            });
            profile_group.add(profile_row);
            if (record.apphub_id != null) {
                var source_row = new Adw.ActionRow();
                source_row.title = _("AppHub sandbox template");
                source_row.subtitle = record.apphub_id;
                source_row.add_prefix(new Gtk.Image.from_icon_name("folder-download-symbolic"));
                profile_group.add(source_row);
            }
            prefs_page.add(profile_group);

            var access_group = new Adw.PreferencesGroup();
            access_group.title = _("Access");
            var service_rows = new Gee.HashMap<string, Adw.SwitchRow>();

            var network_row = build_permission_row(
                _("Network"), null, "network-wireless-symbolic", record.sandbox_allow_network);
            access_group.add(network_row);

            var audio_row = build_permission_row(
                _("Sound"),
                _("Includes microphone: playback and recording share one connection."),
                "audio-speakers-symbolic",
                record.sandbox_allow_audio);
            access_group.add(audio_row);

            var display_row = new Adw.ComboRow();
            display_row.title = _("Display");
            display_row.use_subtitle = true;
            display_row.subtitle_lines = 0;
            display_row.tooltip_text = _("Prefer Wayland when available; otherwise use X11.");
            display_row.model = new Gtk.StringList(sandbox_display_labels());
            display_row.selected = sandbox_display_index(record);
            display_row.add_prefix(new Gtk.Image.from_icon_name("video-display-symbolic"));
            access_group.add(display_row);

            var dbus_row = build_permission_row(
                _("Full session bus"),
                _("Unfiltered access to desktop services. Weakens the sandbox, so grant it only to apps you trust."),
                "dialog-warning-symbolic",
                record.sandbox_allow_dbus);
            access_group.add(dbus_row);

            prefs_page.add(access_group);

            var devices_group = new Adw.PreferencesGroup();
            devices_group.title = _("Devices");

            var gpu_row = build_permission_row(
                _("Hardware acceleration"),
                _("Access to the graphics card. Without it most apps fall back to software rendering."),
                "chip-symbolic",
                record.sandbox_allow_gpu);
            devices_group.add(gpu_row);

            var camera_row = build_permission_row(
                _("Camera"),
                _("Direct device access."),
                "camera-photo-symbolic",
                record.sandbox_allow_camera);
            devices_group.add(camera_row);

            var input_row = build_permission_row(
                _("Game controllers"),
                _("Also exposes keyboards and mice, so grant it only to apps that need a gamepad."),
                "input-gaming-symbolic",
                record.sandbox_allow_input);
            devices_group.add(input_row);

            var security_keys_row = build_permission_row(
                _("Security keys"),
                _("FIDO2 and U2F keys. Plug the key in before starting the app."),
                "auth-smartcard-symbolic",
                record.sandbox_allow_security_keys);
            devices_group.add(security_keys_row);

            var bluetooth_row = build_permission_row(
                _("Bluetooth"), null, "bluetooth-active-symbolic", Core.SandboxConfig.service_enabled(record, "bluetooth"));
            service_rows.set("bluetooth", bluetooth_row);
            devices_group.add(bluetooth_row);

            prefs_page.add(devices_group);

            var services_group = new Adw.PreferencesGroup();
            services_group.title = _("Services");

            var notifications_row = build_permission_row(
                _("Notifications"), null, "preferences-system-notifications-symbolic",
                Core.SandboxConfig.service_enabled(record, "notifications"));
            service_rows.set("notifications", notifications_row);
            services_group.add(notifications_row);

            var accessibility_row = build_permission_row(
                _("Accessibility"), _("Connect to the desktop accessibility service through a filtered bus."),
                "preferences-desktop-accessibility-symbolic", Core.SandboxConfig.service_enabled(record, "accessibility"));
            service_rows.set("accessibility", accessibility_row);
            services_group.add(accessibility_row);

            var location_row = build_permission_row(
                _("Location"), _("Reaches the system location service. AppManager alone enforces this - it does not appear in your desktop's location settings."), "find-location-symbolic",
                Core.SandboxConfig.service_enabled(record, "location"));
            service_rows.set("location", location_row);
            services_group.add(location_row);

            var network_info_row = build_permission_row(
                _("Network information"), _("Read network status and interface information from NetworkManager."),
                "network-workgroup-symbolic", Core.SandboxConfig.service_enabled(record, "network-information"));
            service_rows.set("network-information", network_info_row);
            services_group.add(network_info_row);

            var online_accounts_row = build_permission_row(
                _("Online accounts"), _("Use GNOME Online Accounts and Evolution Data Server to read and change mail, calendar and contact data. The app can reach every configured account, so grant it only to apps you trust."),
                "system-users-symbolic", Core.SandboxConfig.service_enabled(record, "online-accounts"));
            service_rows.set("online-accounts", online_accounts_row);
            services_group.add(online_accounts_row);

            var keyring_row = build_permission_row(
                _("Keyring"), _("Save logins in GNOME Keyring or KWallet. The app can also read every password stored there, so grant it only to apps you trust."),
                "dialog-password-symbolic", Core.SandboxConfig.service_enabled(record, "keyring"));
            service_rows.set("keyring", keyring_row);
            services_group.add(keyring_row);

            var polkit_row = build_permission_row(
                _("System authentication"), _("Unlock with your system password or fingerprint. The app can also see your other processes and read their command lines and environment, so grant it only to apps you trust."),
                "system-lock-screen-symbolic", Core.SandboxConfig.service_enabled(record, "system-authentication"));
            service_rows.set("system-authentication", polkit_row);
            services_group.add(polkit_row);

            var screenshots_row = build_permission_row(
                _("Screenshots"), _("Take screenshots with the desktop's screenshot tool. They are saved in Pictures, so the app also needs that folder."),
                "screen-shared-symbolic", Core.SandboxConfig.service_enabled(record, "screenshots"));
            service_rows.set("screenshots", screenshots_row);
            services_group.add(screenshots_row);

            prefs_page.add(services_group);

            var folders_group = new Adw.PreferencesGroup();
            folders_group.title = _("Folders");
            folders_group.description = _("Folders shared with the app. Choose read-only or read and write access. Other folders stay hidden, including anything you pick in a file dialog inside the app.");

            // The "manual override" of issue #37, as a list rather than a single slot:
            // anything outside the XDG set the app still needs - including the real target
            // of a symlink, which a bind of the link alone leaves dangling.
            var add_folder_button = new Gtk.Button();
            add_folder_button.child = new Adw.ButtonContent() {
                icon_name = "list-add-symbolic",
                label = _("Add folder")
            };
            add_folder_button.add_css_class("flat");
            add_folder_button.halign = Gtk.Align.CENTER;
            add_folder_button.margin_top = 8;
            add_folder_button.margin_bottom = 8;
            var add_folder_row = new Adw.ActionRow();
            add_folder_row.activatable = false;
            add_folder_row.child = add_folder_button;
            var extra_rows = new Gee.ArrayList<Adw.ComboRow>();

            var downloads_row = build_folder_permission_row(
                _("Downloads"), "folder-download-symbolic", "downloads");
            folders_group.add(downloads_row);
            var documents_row = build_folder_permission_row(
                _("Documents"), "folder-documents-symbolic", "documents");
            folders_group.add(documents_row);
            var desktop_row = build_folder_permission_row(
                _("Desktop"), "user-desktop-symbolic", "desktop");
            folders_group.add(desktop_row);
            var pictures_row = build_folder_permission_row(
                _("Pictures"), "folder-pictures-symbolic", "pictures");
            folders_group.add(pictures_row);
            var videos_row = build_folder_permission_row(
                _("Videos"), "folder-videos-symbolic", "videos");
            folders_group.add(videos_row);
            var music_row = build_folder_permission_row(
                _("Music"), "folder-music-symbolic", "music");
            folders_group.add(music_row);
            folders_group.add(add_folder_row);

            prefs_page.add(folders_group);

            var imported_group = new Adw.PreferencesGroup();
            imported_group.title = _("Additional imported permissions");
            imported_group.description = _("Access defined by the AppHub template. Choosing Standard or Strict replaces these permissions.");
            var imported_rows = new Gee.ArrayList<Adw.ActionRow>();
            UpdateFunc sync_imported_permissions = () => {
                foreach (var row in imported_rows) imported_group.remove(row);
                imported_rows.clear();
                foreach (var rule in record.sandbox_session_rules ?? new string[0]) {
                    var row = new Adw.ActionRow();
                    row.title = rule;
                    row.subtitle = _("Session bus");
                    imported_group.add(row);
                    imported_rows.add(row);
                }
                foreach (var rule in record.sandbox_system_rules ?? new string[0]) {
                    var row = new Adw.ActionRow();
                    row.title = rule;
                    row.subtitle = _("System bus");
                    imported_group.add(row);
                    imported_rows.add(row);
                }
                if (record.sandbox_system_bus == "full") {
                    var row = new Adw.ActionRow();
                    row.title = _("Full system bus");
                    imported_group.add(row);
                    imported_rows.add(row);
                }
                foreach (var permission in record.sandbox_other_dirs ?? new string[0]) {
                    var row = new Adw.ActionRow();
                    row.title = permission;
                    row.subtitle = _("Folders");
                    imported_group.add(row);
                    imported_rows.add(row);
                }
                foreach (var device in record.sandbox_extra_devices ?? new string[0]) {
                    var row = new Adw.ActionRow();
                    row.title = device;
                    row.subtitle = _("Devices");
                    imported_group.add(row);
                    imported_rows.add(row);
                }
                if (record.sandbox_share_processes || record.sandbox_share_ipc) {
                    var row = new Adw.ActionRow();
                    row.title = record.sandbox_share_processes ? _("Host process access") : _("Host IPC access");
                    if (record.sandbox_share_processes && record.sandbox_share_ipc) row.subtitle = _("Host IPC access");
                    imported_group.add(row);
                    imported_rows.add(row);
                }
                if (record.sandbox_allow_media_controls) {
                    foreach (var name in record.sandbox_media_names ?? new string[0]) {
                        var row = new Adw.ActionRow();
                        row.title = name;
                        row.subtitle = _("Media controls");
                        imported_group.add(row);
                        imported_rows.add(row);
                    }
                }
            };
            sync_imported_permissions();
            prefs_page.add(imported_group);

            // Folders Preferences grants to every sandboxed app. Listed here so this
            // page shows everything the app can reach, but only editable there.
            var global_dirs = Core.SandboxConfig.global_extra_dirs();
            var global_group = new Adw.PreferencesGroup();
            global_group.title = _("Global sandbox");
            global_group.description = _("Folders granted to every sandboxed app. Change them in AppManager preferences.");
            foreach (var entry in global_dirs) {
                var global_path = Core.SandboxConfig.strip_access_suffix(entry);
                var global_row = new Adw.ActionRow();
                global_row.title = Path.get_basename(global_path);
                global_row.subtitle = global_path;
                global_row.add_prefix(new Gtk.Image.from_icon_name("folder-symbolic"));
                var access_label = new Gtk.Label(entry.strip().has_suffix(":rw") ? _("Read and write") : _("Read-only"));
                access_label.add_css_class("dim-label");
                global_row.add_suffix(access_label);
                global_group.add(global_row);
            }
            prefs_page.add(global_group);

            // --- wiring -------------------------------------------------------------

            bool suppress = false;

            UpdateFunc sync_profile_row = () => {
                suppress = true;
                var current = record.sandbox_enabled()
                    ? (record.sandbox_profile ?? Core.SANDBOX_PROFILE_CUSTOM)
                    : Core.SANDBOX_PROFILE_OFF;
                for (int i = 0; i < profile_order.size; i++) {
                    if (profile_order[i] == current) {
                        profile_row.selected = i;
                        break;
                    }
                }
                suppress = false;
            };

            UpdateFunc sync_permission_rows = () => {
                suppress = true;
                network_row.active       = record.sandbox_allow_network;
                audio_row.active         = record.sandbox_allow_audio;
                display_row.selected     = sandbox_display_index(record);
                dbus_row.active          = record.sandbox_allow_dbus;
                gpu_row.active           = record.sandbox_allow_gpu;
                camera_row.active        = record.sandbox_allow_camera;
                input_row.active         = record.sandbox_allow_input;
                security_keys_row.active = record.sandbox_allow_security_keys;
                foreach (var service in service_rows.keys) {
                    service_rows.get(service).active = Core.SandboxConfig.service_enabled(record, service);
                }
                downloads_row.selected   = Core.SandboxConfig.folder_access(record, "downloads");
                documents_row.selected   = Core.SandboxConfig.folder_access(record, "documents");
                desktop_row.selected     = Core.SandboxConfig.folder_access(record, "desktop");
                pictures_row.selected    = Core.SandboxConfig.folder_access(record, "pictures");
                videos_row.selected      = Core.SandboxConfig.folder_access(record, "videos");
                music_row.selected       = Core.SandboxConfig.folder_access(record, "music");
                sync_imported_permissions();
                suppress = false;
            };

            UpdateFunc sync_portable_rows = () => {
                suppress = true;
                portable_home_row.active = Installer.has_portable_home(record);
                portable_config_row.active = Installer.has_portable_config(record);
                suppress = false;
            };

            UpdateFunc update_sensitivity = () => {
                bool usable = supported && available;
                profile_row.sensitive = usable;
                // With the sandbox off there is nothing to configure, so the permission
                // groups are hidden rather than shown greyed out.
                bool show_permissions = usable && record.sandbox_enabled();
                access_group.visible = show_permissions;
                devices_group.visible = show_permissions;
                services_group.visible = show_permissions;
                foreach (var service in service_rows.keys) {
                    service_rows.get(service).sensitive = !Core.SandboxConfig.service_has_full_bus(record, service);
                }
                folders_group.visible = show_permissions;
                imported_group.visible = show_permissions && (
                    record.sandbox_share_processes || record.sandbox_share_ipc || record.sandbox_system_bus == "full"
                    || (record.sandbox_allow_media_controls && record.sandbox_media_names != null && record.sandbox_media_names.length > 0)
                    || (record.sandbox_other_dirs != null && record.sandbox_other_dirs.length > 0)
                    || (record.sandbox_session_rules != null && record.sandbox_session_rules.length > 0)
                    || (record.sandbox_system_rules != null && record.sandbox_system_rules.length > 0)
                    || (record.sandbox_extra_devices != null && record.sandbox_extra_devices.length > 0));
                global_group.visible = show_permissions && global_dirs.length > 0;

                // Greyed rather than hidden while sandboxed, so the description can say
                // where the data went.
                bool sandboxed = record.sandbox_enabled();
                portable_group.sensitive = !sandboxed;
                portable_group.description = sandboxed
                    ? _("Off while this app is sandboxed. The sandbox gives it a home folder of its own, and anything these folders held has been moved into that.")
                    : _("The AppImage runtime redirects the app's home and config into folders next to the AppImage, so its data travels with the file. A sandboxed app never runs that runtime, so this and the sandbox are alternatives.");
            };

            CommitFunc commit = (permission_edit) => {
                if (permission_edit) record.apphub_policy_customized = record.sandbox_profile != Core.SANDBOX_PROFILE_APPHUB;
                persist_record_and_refresh_desktop();
                status_label.set_label(sandbox_status_label());
            };

            // Re-label the profile so the combo reflects what the permissions now say.
            // Never applied with the sandbox off: detect_profile has no "off" answer and
            // would switch the sandbox on behind the user's back.
            UpdateFunc relabel_profile = () => {
                if (record.sandbox_enabled()) {
                    record.sandbox_profile = Core.SandboxConfig.detect_profile(record);
                }
            };

            // Extra-folder rows are added and removed one at a time rather than rebuilt
            // wholesale: a rebuild would have to be callable from the row handlers it
            // creates, introducing a cycle between the callbacks.
            StringUpdateFunc add_extra_row = (grant) => {
                var path = Core.SandboxConfig.strip_access_suffix(grant);
                var row = new Adw.ComboRow();
                row.title = Path.get_basename(path);
                row.subtitle = path;
                row.add_prefix(new Gtk.Image.from_icon_name("folder-symbolic"));
                row.model = new Gtk.StringList({ _("Read-only"), _("Read and write") });
                row.selected = grant.strip().has_suffix(":rw") ? 1 : 0;
                row.notify["selected"].connect(() => {
                    var dirs = new Gee.ArrayList<string>();
                    foreach (var existing in record.sandbox_extra_dirs ?? new string[0]) {
                        if (Core.SandboxConfig.strip_access_suffix(existing) != path) {
                            dirs.add(existing);
                        } else {
                            dirs.add(row.selected == 1 ? "%s:rw".printf(path) : path);
                        }
                    }
                    record.sandbox_extra_dirs = dirs.to_array();
                    relabel_profile();
                    sync_profile_row();
                    commit(false);
                });

                var remove_button = new Gtk.Button.from_icon_name("user-trash-symbolic");
                remove_button.valign = Gtk.Align.CENTER;
                remove_button.tooltip_text = _("Remove folder");
                remove_button.add_css_class("flat");
                remove_button.clicked.connect(() => {
                    var kept = new Gee.ArrayList<string>();
                    foreach (var entry in record.sandbox_extra_dirs ?? new string[0]) {
                        if (Core.SandboxConfig.strip_access_suffix(entry) != path) {
                            kept.add(entry);
                        }
                    }
                    record.sandbox_extra_dirs = kept.size > 0 ? kept.to_array() : null;

                    folders_group.remove(row);
                    extra_rows.remove(row);
                    relabel_profile();
                    sync_profile_row();
                    commit(false);
                });
                row.add_suffix(remove_button);

                // Re-append the add row so it stays last.
                folders_group.remove(add_folder_row);
                folders_group.add(row);
                folders_group.add(add_folder_row);
                extra_rows.add(row);
            };

            StringUpdateFunc add_extra_dir = (path) => {
                var dirs = new Gee.ArrayList<string>();
                foreach (var entry in record.sandbox_extra_dirs ?? new string[0]) {
                    // Adding the same folder twice would just repeat the bind.
                    if (Core.SandboxConfig.strip_access_suffix(entry) == path) {
                        return;
                    }
                    dirs.add(entry);
                }
                dirs.add("%s:rw".printf(path));
                record.sandbox_extra_dirs = dirs.to_array();
                add_extra_row("%s:rw".printf(path));
                relabel_profile();
                sync_profile_row();
                commit(false);
            };

            UpdateFunc on_permission_toggled = () => {
                if (suppress) {
                    return;
                }
                var previous_services = new Gee.HashMap<string, bool>();
                foreach (var service in service_rows.keys) previous_services.set(service, Core.SandboxConfig.service_enabled(record, service));
                record.sandbox_allow_network       = network_row.active;
                record.sandbox_allow_audio         = audio_row.active;
                if ((int) display_row.selected != sandbox_display_index(record)) {
                    var display = SANDBOX_DISPLAY_ORDER[display_row.selected];
                    record.sandbox_display = display == "legacy" ? null : display;
                    record.sandbox_allow_x11 = display == "legacy" || display == "wayland-or-x11" || display == "x11";
                }
                if (record.sandbox_session_bus != null && record.sandbox_allow_dbus != dbus_row.active) {
                    record.sandbox_session_bus = dbus_row.active ? "full" : "filtered";
                }
                record.sandbox_allow_dbus          = dbus_row.active;
                record.sandbox_allow_gpu           = gpu_row.active;
                record.sandbox_allow_camera        = camera_row.active;
                record.sandbox_allow_input         = input_row.active;
                record.sandbox_allow_security_keys = security_keys_row.active;
                foreach (var service in service_rows.keys) {
                    var active = service_rows.get(service).active;
                    if (active != previous_services.get(service)) Core.SandboxConfig.set_service_access(record, service, active);
                }
                Core.SandboxConfig.set_folder_access(record, "downloads", (int) downloads_row.selected);
                Core.SandboxConfig.set_folder_access(record, "documents", (int) documents_row.selected);
                Core.SandboxConfig.set_folder_access(record, "desktop", (int) desktop_row.selected);
                Core.SandboxConfig.set_folder_access(record, "pictures", (int) pictures_row.selected);
                Core.SandboxConfig.set_folder_access(record, "videos", (int) videos_row.selected);
                Core.SandboxConfig.set_folder_access(record, "music", (int) music_row.selected);
                relabel_profile();
                sync_profile_row();
                sync_permission_rows();
                update_sensitivity();
                commit(true);
            };

            sync_profile_row();
            sync_portable_rows();
            foreach (var entry in record.sandbox_extra_dirs ?? new string[0]) {
                add_extra_row(entry);
            }
            update_sensitivity();

            // Installs from before the check, or made offline, are looked up once
            // here, quietly: the notice dots are only for fresh installs.
            if (Core.FlathubPermissions.should_check(record)) {
                lookup_flathub.begin(Core.FlathubPermissions.candidate_ids(record), (obj, res) => {
                    try {
                        var found = lookup_flathub.end(res);
                        record.flathub_checked = true;
                        if (found != null) {
                            record.flathub_id = found.app_id;
                            add_flathub_option();
                            sync_profile_row();
                        }
                        registry.update(record, false);
                    } catch (Error e) {
                        debug("Flathub check for %s failed: %s", record.id, e.message);
                    }
                });
            }

            // Fetched when the Flathub entry is picked, applied once the dialog is accepted.
            Core.FlathubPermissions? flathub_choice = null;

            StringUpdateFunc apply_profile = (picked) => {
                if (picked == Core.SANDBOX_PROFILE_FLATHUB) {
                    flathub_choice.apply(record);
                    sync_permission_rows();
                } else if (picked == Core.SANDBOX_PROFILE_APPHUB) {
                    try {
                        Core.SandboxConfig.restore_apphub_profile(record);
                    } catch (Error e) {
                        var error_dialog = new Adw.AlertDialog(_("Unable to restore the AppHub profile"), e.message);
                        error_dialog.add_response("ok", _("OK"));
                        error_dialog.present(this);
                        sync_profile_row();
                        return;
                    }
                    sync_permission_rows();
                } else if (picked == Core.SANDBOX_PROFILE_CUSTOM) {
                    // Custom is a label, not a preset - keep the permissions as they are.
                    record.sandbox_profile = Core.SANDBOX_PROFILE_CUSTOM;
                } else {
                    Core.SandboxConfig.apply_preset(record, picked);
                    sync_permission_rows();
                }
                sync_portable_rows();
                update_sensitivity();
                commit(picked != Core.SANDBOX_PROFILE_APPHUB);
            };

            StringUpdateFunc switch_profile = (picked) => {
                // Switching the sandbox on takes the app's portable data with it, since
                // nothing would read it where it is. Only a sandboxed home that already
                // holds data raises a question worth asking.
                if (picked != Core.SANDBOX_PROFILE_OFF
                    && !record.sandbox_enabled()
                    && Installer.has_portable_folders(record)) {
                    if (Installer.has_portable_data(record)
                        && Installer.sandbox_home_has_data(record)) {
                        present_sandbox_migration_conflict((replace) => {
                            installer.migrate_portable_to_sandbox(record, replace);
                            apply_profile(picked);
                        }, () => {
                            sync_profile_row();
                        });
                        return;
                    }
                    installer.migrate_portable_to_sandbox(record, false);
                }
                apply_profile(picked);
            };

            // Nothing moves until the dialog is accepted; every other outcome puts
            // the combo back on the current profile.
            UpdateFunc choose_flathub = () => {
                profile_row.sensitive = false;
                lookup_flathub.begin({ record.flathub_id }, (obj, res) => {
                    update_sensitivity();
                    try {
                        flathub_choice = lookup_flathub.end(res);
                    } catch (Error e) {
                        var error_dialog = new Adw.AlertDialog(_("Unable to check Flathub"), e.message);
                        error_dialog.add_response("ok", _("OK"));
                        error_dialog.present(this);
                        sync_profile_row();
                        return;
                    }
                    if (flathub_choice == null) {
                        show_toast(_("This app was not found on Flathub"));
                        sync_profile_row();
                        return;
                    }
                    present_flathub_suggestion(flathub_choice, () => {
                        switch_profile(Core.SANDBOX_PROFILE_FLATHUB);
                    }, () => {
                        sync_profile_row();
                    });
                });
            };

            profile_row.notify["selected"].connect(() => {
                if (suppress) {
                    return;
                }
                var index = profile_row.selected;
                if (index >= profile_order.size) {
                    return;
                }
                var picked = profile_order[(int) index];
                if (picked == Core.SANDBOX_PROFILE_FLATHUB) {
                    choose_flathub();
                } else {
                    switch_profile(picked);
                }
            });

            // The parent page's status reads "Portable" whenever one of these folders
            // exists, so it has to follow them. The record itself is untouched by a
            // folder appearing or going, so this never needs a full commit().
            UpdateFunc refresh_status = () => {
                status_label.set_label(sandbox_status_label());
            };

            portable_home_row.notify["active"].connect(() => {
                if (suppress) {
                    return;
                }
                if (portable_home_row.active) {
                    installer.create_portable_home(record);
                    refresh_status();
                } else if (Installer.has_portable_home(record)) {
                    present_portable_folder_disable_confirm(portable_home_row, _(".home"),
                        () => Installer.has_portable_home(record),
                        () => {
                            installer.remove_portable_home(record, false);
                            refresh_status();
                        });
                }
            });

            portable_config_row.notify["active"].connect(() => {
                if (suppress) {
                    return;
                }
                if (portable_config_row.active) {
                    installer.create_portable_config(record);
                    refresh_status();
                } else if (Installer.has_portable_config(record)) {
                    present_portable_folder_disable_confirm(portable_config_row, _(".config"),
                        () => Installer.has_portable_config(record),
                        () => {
                            installer.remove_portable_config(record, false);
                            refresh_status();
                        });
                }
            });

            network_row.notify["active"].connect(() => on_permission_toggled());
            audio_row.notify["active"].connect(() => on_permission_toggled());
            display_row.notify["selected"].connect(() => on_permission_toggled());
            dbus_row.notify["active"].connect(() => on_permission_toggled());
            gpu_row.notify["active"].connect(() => on_permission_toggled());
            camera_row.notify["active"].connect(() => on_permission_toggled());
            input_row.notify["active"].connect(() => on_permission_toggled());
            security_keys_row.notify["active"].connect(() => on_permission_toggled());
            foreach (var row in service_rows.values) row.notify["active"].connect(() => on_permission_toggled());
            downloads_row.notify["selected"].connect(() => on_permission_toggled());
            documents_row.notify["selected"].connect(() => on_permission_toggled());
            desktop_row.notify["selected"].connect(() => on_permission_toggled());
            pictures_row.notify["selected"].connect(() => on_permission_toggled());
            videos_row.notify["selected"].connect(() => on_permission_toggled());
            music_row.notify["selected"].connect(() => on_permission_toggled());

            add_folder_button.clicked.connect(() => {
                var dialog = new Gtk.FileDialog();
                dialog.title = _("Select Folder to Share");
                dialog.modal = true;
                dialog.select_folder.begin(this.get_root() as Gtk.Window, null, (obj, res) => {
                    try {
                        var folder = dialog.select_folder.end(res);
                        var path = folder != null ? folder.get_path() : null;
                        if (path == null || path.strip() == "") {
                            return;
                        }
                        // Store the real target, not a symlink to it: what is bound and
                        // what is shown then agree, and a symlink cannot be bound anyway.
                        add_extra_dir(Core.SandboxConfig.canonicalize(path.strip()));
                    } catch (Error e) {
                        if (!(e is IOError.CANCELLED)) {
                            warning("Failed to select sandbox folder: %s", e.message);
                        }
                    }
                });
            });

            var toolbar = new Adw.ToolbarView();
            toolbar.add_top_bar(new Adw.HeaderBar());
            toolbar.set_content(prefs_page);

            return new Adw.NavigationPage(toolbar, _("Privacy & Security"));
        }

        private Adw.ActionRow build_advanced_action_row() {
            var row = new Adw.ActionRow();
            row.title = _("Advanced Settings");
            row.subtitle = _("Change app icon, Startup WM Class, Keywords, $PATH or environment variables");
            row.add_prefix(new Gtk.Image.from_icon_name("applications-engineering-symbolic"));
            var icon = new Gtk.Image.from_icon_name("go-next-symbolic");
            row.add_suffix(icon);
            row.activatable = true;
            row.activated.connect(() => {
                var page = build_advanced_settings_page();
                var main_win = (MainWindow) this.get_root();
                main_win.push_page(page);
            });
            return row;
        }

        private Adw.NavigationPage build_advanced_settings_page() {
            var prefs_page = new Adw.PreferencesPage();
            
            var advanced_group = new Adw.PreferencesGroup();
            advanced_group.title = _("App Settings");
            advanced_group.add(build_name_row());
            advanced_group.add(build_keywords_row());
            advanced_group.add(build_icon_row());
            advanced_group.add(build_wmclass_row());
            advanced_group.add(build_version_row());
            advanced_group.add(build_nodisplay_row());
            advanced_group.add(build_path_row());
            
            prefs_page.add(advanced_group);
            prefs_page.add(build_env_vars_group());
            
            var toolbar = new Adw.ToolbarView();
            toolbar.add_top_bar(new Adw.HeaderBar());
            toolbar.set_content(prefs_page);

            var nav_page = new Adw.NavigationPage(toolbar, _("Advanced Settings"));
            nav_page.shown.connect(() => {
                GLib.Idle.add(() => {
                    var win = nav_page.get_root() as Gtk.Window;
                    if (win != null) win.set_focus(null);
                    return GLib.Source.REMOVE;
                });
            });
            return nav_page;
        }

        private delegate bool PortableHasFunc();
        private delegate void PortableRemoveFunc();
        private delegate void MigrationChoiceFunc(bool replace);
        private delegate void MigrationCancelFunc();
        private delegate void UpdateFunc();
        private delegate void CommitFunc(bool permission_edit);
        private delegate void StringUpdateFunc(string value);
        private delegate void ChangeRowFunc(string title, string before, string after);
        private delegate Adw.ActionRow EnvRowFunc(string? name, string? value, Gtk.Button add_button);

        /**
         * Asked when the portable folders and the sandboxed home both hold data, which
         * happens when an app was sandboxed before, switched back, and used either way.
         * There is no defensible default between the two, so neither is picked here.
         */
        private void present_sandbox_migration_conflict(MigrationChoiceFunc on_choice,
                                                        MigrationCancelFunc on_cancel) {
            var dialog = new Adw.AlertDialog(
                _("This app already has sandbox data"),
                _("Its portable folders and its sandboxed home both hold data. Merge keeps what is already in the sandbox and moves the rest in. Replace discards the sandboxed data and uses the portable folders instead.")
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("merge", _("Merge"));
            dialog.add_response("replace", _("Replace"));
            dialog.set_response_appearance("replace", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_close_response("cancel");
            dialog.set_default_response("merge");
            dialog.response.connect((response) => {
                if (response == "cancel") {
                    on_cancel();
                } else {
                    on_choice(response == "replace");
                }
            });
            dialog.present(this);
        }

        private async Core.FlathubPermissions? lookup_flathub(owned string[] ids) throws Error {
            SourceFunc callback = lookup_flathub.callback;
            Core.FlathubPermissions? found = null;
            Error? error = null;
            new Thread<void>("appmgr-flathub", () => {
                try {
                    found = Core.FlathubPermissions.lookup(ids);
                } catch (Error e) {
                    error = e;
                }
                Idle.add((owned) callback);
            });
            yield;
            if (error != null) throw error;
            return found;
        }

        /** Lists what Flathub's permissions would change, and applies them only on request. */
        private void present_flathub_suggestion(Core.FlathubPermissions flathub, owned UpdateFunc on_apply, owned UpdateFunc on_cancel) {
            var preview = InstallationRecord.from_json(record.to_json().get_object());
            var skipped = flathub.apply(preview);

            var changes = new Gtk.ListBox();
            changes.add_css_class("boxed-list");
            changes.selection_mode = Gtk.SelectionMode.NONE;
            int count = 0;
            ChangeRowFunc add_change = (title, before, after) => {
                if (before == after) return;
                var row = new Adw.ActionRow();
                row.use_markup = false;
                row.title = title;
                row.subtitle = "%s → %s".printf(before, after);
                changes.append(row);
                count++;
            };

            var on = _("On");
            var off = _("Off");
            string[] switch_labels = { _("Network"), _("Sound"), _("Full session bus"), _("Full system bus"),
                _("Hardware acceleration"), _("Camera"), _("Game controllers"), _("Security keys") };
            bool[] before = { record.sandbox_allow_network, record.sandbox_allow_audio, record.sandbox_allow_dbus,
                record.sandbox_system_bus == "full", record.sandbox_allow_gpu, record.sandbox_allow_camera,
                record.sandbox_allow_input, record.sandbox_allow_security_keys };
            bool[] after = { preview.sandbox_allow_network, preview.sandbox_allow_audio, preview.sandbox_allow_dbus,
                preview.sandbox_system_bus == "full", preview.sandbox_allow_gpu, preview.sandbox_allow_camera,
                preview.sandbox_allow_input, preview.sandbox_allow_security_keys };
            for (int i = 0; i < switch_labels.length; i++) {
                add_change(switch_labels[i], before[i] ? on : off, after[i] ? on : off);
            }
            var displays = sandbox_display_labels();
            add_change(_("Display"), displays[sandbox_display_index(record)], displays[sandbox_display_index(preview)]);

            string[] services = { "notifications", "accessibility", "location", "network-information",
                "online-accounts", "keyring", "system-authentication", "screenshots", "bluetooth" };
            string[] service_labels = { _("Notifications"), _("Accessibility"), _("Location"), _("Network information"),
                _("Online accounts"), _("Keyring"), _("System authentication"), _("Screenshots"), _("Bluetooth") };
            for (int i = 0; i < services.length; i++) {
                add_change(service_labels[i],
                    Core.SandboxConfig.service_enabled(record, services[i]) ? on : off,
                    Core.SandboxConfig.service_enabled(preview, services[i]) ? on : off);
            }

            string[] folders = { "downloads", "documents", "desktop", "pictures", "videos", "music" };
            string[] folder_labels = { _("Downloads"), _("Documents"), _("Desktop"), _("Pictures"), _("Videos"), _("Music") };
            string[] access = { off, _("Read-only"), _("Read and write") };
            for (int i = 0; i < folders.length; i++) {
                add_change(folder_labels[i],
                    access[Core.SandboxConfig.folder_access(record, folders[i])],
                    access[Core.SandboxConfig.folder_access(preview, folders[i])]);
            }

            // Imported grants have no switch of their own, so they go by manifest token.
            var tokens_before = new Gee.HashSet<string>();
            var tokens_after = new Gee.HashSet<string>();
            foreach (var token in record.sandbox_other_dirs ?? new string[0]) tokens_before.add(token);
            foreach (var token in record.sandbox_extra_devices ?? new string[0]) tokens_before.add(token);
            foreach (var token in record.sandbox_media_names ?? new string[0]) tokens_before.add(token);
            foreach (var token in preview.sandbox_other_dirs ?? new string[0]) tokens_after.add(token);
            foreach (var token in preview.sandbox_extra_devices ?? new string[0]) tokens_after.add(token);
            foreach (var token in preview.sandbox_media_names ?? new string[0]) tokens_after.add(token);
            var all_tokens = new Gee.TreeSet<string>();
            all_tokens.add_all(tokens_before);
            all_tokens.add_all(tokens_after);
            foreach (var token in all_tokens) {
                add_change(token, token in tokens_before ? on : off, token in tokens_after ? on : off);
            }

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            var changes_label = new Gtk.Label(count > 0 ? _("Changes") : _("The current settings already match."));
            changes_label.halign = Gtk.Align.START;
            changes_label.add_css_class(count > 0 ? "heading" : "dim-label");
            box.append(changes_label);
            if (count > 0) box.append(changes);
            if (skipped.length > 0) {
                var skipped_label = new Gtk.Label(_("Not applied"));
                skipped_label.halign = Gtk.Align.START;
                skipped_label.add_css_class("heading");
                box.append(skipped_label);
                var skipped_list = new Gtk.ListBox();
                skipped_list.add_css_class("boxed-list");
                skipped_list.selection_mode = Gtk.SelectionMode.NONE;
                foreach (var option in skipped) {
                    var row = new Adw.ActionRow();
                    row.use_markup = false;
                    row.title = option;
                    skipped_list.append(row);
                }
                box.append(skipped_list);
            }
            var scroller = new Gtk.ScrolledWindow();
            scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroller.propagate_natural_height = true;
            scroller.max_content_height = 360;
            scroller.child = box;

            var dialog = new Adw.AlertDialog(
                _("Flathub permissions"),
                _("Flathub lists these permissions for %s. AppManager cannot confirm that this AppImage is the same app, so review them before applying. Flatpak apps also open files through a desktop portal the sandbox does not provide, so file access may need adjusting.").printf(flathub.app_id)
            );
            dialog.extra_child = scroller;
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("apply", _("Apply"));
            // Enabled even with nothing to change: applying still switches the profile
            // to Flathub, so the page shows where these settings come from.
            dialog.set_response_appearance("apply", Adw.ResponseAppearance.SUGGESTED);
            dialog.set_close_response("cancel");
            dialog.set_default_response("cancel");
            dialog.response.connect((response) => {
                if (response == "apply") {
                    on_apply();
                } else {
                    on_cancel();
                }
            });
            dialog.present(this);
        }

        private void present_portable_folder_disable_confirm(Adw.SwitchRow row, string folder_label, PortableHasFunc has_folder, PortableRemoveFunc remove_folder) {
            var dialog = new Adw.AlertDialog(
                _("Remove portable %s folder?").printf(folder_label),
                _("The %s folder next to this AppImage will be permanently removed, including any data it contains.").printf(folder_label)
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("remove", _("Remove Data"));
            dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_close_response("cancel");
            dialog.set_default_response("cancel");
            dialog.response.connect((response) => {
                if (response == "remove") {
                    remove_folder();
                } else {
                    row.active = has_folder();
                }
            });
            dialog.present(this);
        }

        private const int MAX_ENV_VARS = 5;

        private Adw.PreferencesGroup build_env_vars_group() {
            var env_expander = new Adw.PreferencesGroup();
            env_expander.title = _("Environment Variables");
            env_expander.description = _("Set custom environment variables for this app");

            // Load existing env vars
            var env_vars = record.get_effective_env_vars();

            // Track all env var rows for management
            var env_rows = new Gee.ArrayList<Gtk.Widget>();

            // Rebuild the record's env vars from current rows (in-memory only, no disk write).
            // Called on each keystroke while rows are alive; the .desktop write is deferred to
            // focus-leave / Enter via flush_env_vars(), which reads only the record.
            UpdateFunc save_env_vars_from_rows = () => {
                var new_env_vars = new Gee.ArrayList<string>();
                foreach (var widget in env_rows) {
                    if (widget is Adw.ActionRow) {
                        var row = (Adw.ActionRow) widget;
                        var box = row.get_child() as Gtk.Box;
                        if (box != null) {
                            string? name_val = null;
                            string? value_val = null;
                            var child = box.get_first_child();
                            while (child != null) {
                                if (child is Gtk.Entry) {
                                    var entry = (Gtk.Entry) child;
                                    // .text can be null during teardown; treat as empty.
                                    var entry_text = entry.text ?? "";
                                    if (name_val == null) {
                                        name_val = entry_text.strip();
                                    } else {
                                        value_val = entry_text;
                                    }
                                }
                                child = child.get_next_sibling();
                            }
                            if (name_val != null && name_val != "") {
                                var env_str = "%s=%s".printf(name_val, value_val ?? "");
                                new_env_vars.add(env_str);
                            }
                        }
                    }
                }
                record.custom_env_vars = new_env_vars.to_array();
            };

            // Flush the current record to disk. Reads only the record (never the row widgets),
            // so it is safe to call from focus-leave even during window teardown.
            UpdateFunc flush_env_vars = () => {
                persist_record_and_refresh_desktop();
            };

            // Create a row for a single env var
            EnvRowFunc create_env_var_row = (initial_name, initial_value, add_button) => {
                var row = new Adw.ActionRow();
                
                var content_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                content_box.set_margin_top(8);
                content_box.set_margin_bottom(8);
                content_box.set_margin_start(12);
                content_box.set_margin_end(12);
                content_box.set_hexpand(true);
                
                var name_entry = new Gtk.Entry();
                name_entry.set_placeholder_text(_("NAME"));
                name_entry.set_hexpand(true);
                name_entry.set_max_length(64);
                name_entry.text = initial_name ?? "";
                name_entry.changed.connect(() => { save_env_vars_from_rows(); });
                var name_focus = new Gtk.EventControllerFocus();
                name_focus.leave.connect(() => { flush_env_vars(); });
                name_entry.add_controller(name_focus);
                name_entry.activate.connect(() => { flush_env_vars(); });
                content_box.append(name_entry);
                
                var equals_label = new Gtk.Label("=");
                equals_label.add_css_class("dim-label");
                content_box.append(equals_label);
                
                var value_entry = new Gtk.Entry();
                value_entry.set_placeholder_text(_("value"));
                value_entry.set_hexpand(true);
                value_entry.text = initial_value ?? "";
                value_entry.changed.connect(() => { save_env_vars_from_rows(); });
                var value_focus = new Gtk.EventControllerFocus();
                value_focus.leave.connect(() => { flush_env_vars(); });
                value_entry.add_controller(value_focus);
                value_entry.activate.connect(() => { flush_env_vars(); });
                content_box.append(value_entry);
                
                var delete_button = new Gtk.Button.from_icon_name("user-trash-symbolic");
                delete_button.add_css_class("flat");
                delete_button.set_valign(Gtk.Align.CENTER);
                delete_button.tooltip_text = _("Remove variable");
                delete_button.clicked.connect(() => {
                    env_rows.remove(row);
                    env_expander.remove(row);
                    save_env_vars_from_rows();
                    flush_env_vars();
                    // Re-enable add button if under limit
                    if (env_rows.size < MAX_ENV_VARS) {
                        add_button.sensitive = true;
                    }
                });
                content_box.append(delete_button);
                
                row.set_child(content_box);
                row.set_activatable(false);
                
                return row;
            };

            // Add button row
            var add_row = new Adw.ActionRow();
            add_row.set_activatable(false);
            
            var add_button = new Gtk.Button.from_icon_name("list-add-symbolic");
            add_button.add_css_class("flat");
            add_button.set_halign(Gtk.Align.CENTER);
            add_button.set_margin_top(8);
            add_button.set_margin_bottom(8);
            
            // Populate existing env vars
            foreach (var env_var in env_vars) {
                if (env_var == null || env_var.strip() == "") continue;
                var eq_pos = env_var.index_of_char('=');
                string name_part = "";
                string value_part = "";
                if (eq_pos >= 0) {
                    name_part = env_var.substring(0, eq_pos);
                    value_part = env_var.substring(eq_pos + 1);
                } else {
                    name_part = env_var;
                }
                var row = create_env_var_row(name_part, value_part, add_button);
                env_rows.add(row);
                env_expander.add(row);
            }

            // Update add button sensitivity
            add_button.sensitive = env_rows.size < MAX_ENV_VARS;
            
            add_button.clicked.connect(() => {
                if (env_rows.size >= MAX_ENV_VARS) {
                    return;
                }
                var row = create_env_var_row(null, null, add_button);
                env_rows.add(row);
                // Remove add_row, add new row, re-add add_row to keep button at bottom
                env_expander.remove(add_row);
                env_expander.add(row);
                env_expander.add(add_row);
                // Disable add button if at limit
                if (env_rows.size >= MAX_ENV_VARS) {
                    add_button.sensitive = false;
                }
            });
            
            var add_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            add_box.set_halign(Gtk.Align.CENTER);
            add_box.set_hexpand(true);
            add_box.append(add_button);
            add_row.set_child(add_box);
            
            env_expander.add(add_row);
            
            return env_expander;
        }

        /**
         * Delegate types for customizable entry row fields.
         */
        private delegate string? GetEffectiveFunc();
        private delegate string? GetOriginalFunc();
        private delegate string? GetCustomFunc();
        private delegate void SetCustomFunc(string? val);

        /**
         * Generic factory for entry rows with restore button and change tracking.
         */
        private Adw.EntryRow build_customizable_entry_row(
            string title,
            string icon_name,
            GetEffectiveFunc get_effective,
            GetOriginalFunc get_original,
            GetCustomFunc get_custom,
            SetCustomFunc set_custom
        ) {
            var row = new Adw.EntryRow();
            row.title = title;
            row.add_prefix(new Gtk.Image.from_icon_name(icon_name));
            row.text = get_effective() ?? "";
            
            var restore_button = create_restore_button(get_custom() != null);
            restore_button.clicked.connect(() => {
                set_custom(null);
                row.text = get_original() ?? "";
                persist_record_and_refresh_desktop();
                restore_button.set_visible(false);
            });
            row.add_suffix(restore_button);
            
            // Update the record on each keystroke (in-memory), defer the .desktop file write to
            // focus-leave / Enter. The flush reads only the record, so it is safe during teardown.
            row.changed.connect(() => {
                var new_val = row.text.strip();
                var original_val = get_original() ?? "";
                if (new_val == original_val) {
                    set_custom(null);
                } else if (new_val == "") {
                    set_custom(CLEARED_VALUE);
                } else {
                    set_custom(new_val);
                }
                restore_button.set_visible(get_custom() != null);
            });
            var focus = new Gtk.EventControllerFocus();
            focus.leave.connect(() => { persist_record_and_refresh_desktop(); });
            row.add_controller(focus);
            row.entry_activated.connect(() => { persist_record_and_refresh_desktop(); });

            return row;
        }

        private Adw.EntryRow build_name_row() {
            return build_customizable_entry_row(
                _("App Name"),
                "document-edit-symbolic",
                () => record.get_effective_name(),
                () => record.original_name,
                () => record.custom_name,
                (v) => {
                    record.custom_name = v;
                    // Keep the display name in sync so the app list reflects the edit.
                    record.name = record.get_effective_name();
                }
            );
        }

        private Adw.EntryRow build_keywords_row() {
            return build_customizable_entry_row(
                _("Keywords"),
                "system-search-symbolic",
                () => record.get_effective_keywords(),
                () => record.original_keywords,
                () => record.custom_keywords,
                (v) => { record.custom_keywords = v; }
            );
        }

        private Adw.EntryRow build_icon_row() {
            return build_customizable_entry_row(
                _("Icon name"),
                "image-x-generic-symbolic",
                () => record.get_effective_icon_name(),
                () => record.original_icon_name,
                () => record.custom_icon_name,
                (v) => { record.custom_icon_name = v; }
            );
        }

        private Adw.EntryRow build_wmclass_row() {
            return build_customizable_entry_row(
                _("Startup WM Class"),
                "window-new-symbolic",
                () => record.get_effective_startup_wm_class(),
                () => record.original_startup_wm_class,
                () => record.custom_startup_wm_class,
                (v) => { record.custom_startup_wm_class = v; }
            );
        }

        private Adw.EntryRow build_version_row() {
            var version_row = new Adw.EntryRow();
            version_row.title = _("Version");
            version_row.add_prefix(new Gtk.Image.from_icon_name("package-x-generic-symbolic"));
            version_row.text = record.version ?? "";
            // Update the record on each keystroke (in-memory), defer the .desktop file write to
            // focus-leave / Enter. The flush reads only the record, so it is safe during teardown.
            version_row.changed.connect(() => {
                record.version = version_row.text.strip() == "" ? null : version_row.text;
            });
            UpdateFunc flush_version = () => {
                registry.update(record);
                installer.set_desktop_entry_property(record.desktop_file, "X-AppImage-Version", record.version ?? "");
            };
            var version_focus = new Gtk.EventControllerFocus();
            version_focus.leave.connect(() => { flush_version(); });
            version_row.add_controller(version_focus);
            version_row.entry_activated.connect(() => { flush_version(); });
            return version_row;
        }

        private Adw.SwitchRow build_nodisplay_row() {
            var nodisplay_row = new Adw.SwitchRow();
            nodisplay_row.title = _("Hide from app drawer");
            nodisplay_row.subtitle = _("Don't show in application menu");
            nodisplay_row.add_prefix(new Gtk.Image.from_icon_name("view-conceal-symbolic"));
            var nodisplay_current = desktop_props.get("NoDisplay") ?? "false";
            nodisplay_row.active = (nodisplay_current.down() == "true");
            nodisplay_row.notify["active"].connect(() => {
                record.custom_no_display = nodisplay_row.active ? "true" : "false";
                registry.update(record);
                installer.set_desktop_entry_property(record.desktop_file, "NoDisplay", nodisplay_row.active ? "true" : "false");
            });
            return nodisplay_row;
        }

        private Adw.SwitchRow build_path_row() {
            path_row = new Adw.SwitchRow();
            path_row.title = _("Add to $PATH");
            path_row.subtitle = _("Create a launcher in %s so you can run it from the terminal").printf(AppPaths.local_bin_dir);
            path_row.add_prefix(new Gtk.Image.from_icon_name("utilities-terminal-symbolic"));

            var symlink_name = "";

            if (record.entry_exec != null && record.entry_exec.strip() != "") {
                symlink_name = Path.get_basename(record.entry_exec.strip());
            }

            if (symlink_name == "" && record.installed_path != null && record.installed_path.strip() != "") {
                symlink_name = installer.derive_slug_from_path(record.installed_path, record.mode == InstallMode.EXTRACTED);
            }
            
            if (symlink_name == "") {
                symlink_name = Path.get_basename(exec_path).down();
            }

            bool is_terminal_app = record.is_terminal;
            bool symlink_exists = record.bin_symlink != null && record.bin_symlink.strip() != "" && File.new_for_path(record.bin_symlink).query_exists();

            // Terminal apps must always stay on PATH
            if (is_terminal_app && !symlink_exists) {
                if (installer.ensure_bin_symlink_for_record(record, exec_path, symlink_name)) {
                    symlink_exists = true;
                }
            }

            // Clean up stale metadata if the recorded symlink is gone
            if (!is_terminal_app && record.bin_symlink != null && !symlink_exists) {
                installer.remove_bin_symlink_for_record(record);
            }

            path_row.active = is_terminal_app || symlink_exists;
            path_row.sensitive = !is_terminal_app;

            path_row.notify["active"].connect(() => {
                if (is_terminal_app) {
                    path_row.active = true;
                    return;
                }

                if (path_row.active) {
                    if (installer.ensure_bin_symlink_for_record(record, exec_path, symlink_name)) {
                        symlink_exists = true;
                        // Back to default - don't persist the redundant "true" override.
                        record.custom_add_to_path = null;
                        registry.update(record, false);
                    } else {
                        // The switch snapping back on its own says nothing about why (issue #175).
                        var conflict = record.bin_conflict_slug;
                        path_row.active = false;
                        if (conflict != null) {
                            show_toast(_("Not added to $PATH: '%s' already exists in %s")
                                .printf(conflict, AppPaths.local_bin_dir));
                        }
                    }
                } else {
                    if (installer.remove_bin_symlink_for_record(record)) {
                        symlink_exists = false;
                        record.custom_add_to_path = "false";
                        registry.update(record, false);
                    } else {
                        path_row.active = true;
                    }
                }
                update_path_banner_visibility();
            });
            
            return path_row;
        }

        private Adw.PreferencesGroup build_actions_group() {
            var actions_group = new Adw.PreferencesGroup();
            actions_group.title = _("Actions");
            
            var actions_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            actions_box.set_halign(Gtk.Align.FILL);
            actions_box.set_hexpand(true);
            actions_group.add(actions_box);

            // The stop control uses the empty space to the left of the
            // Update/Extract pair. When space is tight, only Update's left
            // edge gives way so the pair's right side stays put.
            var row1 = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            row1.set_halign(Gtk.Align.CENTER);

            // Same round stop control as the main window's update header.
            cancel_update_button = new Gtk.Button.from_icon_name("process-stop-symbolic");
            cancel_update_button.add_css_class("cancel-update-button");
            cancel_update_button.set_valign(Gtk.Align.CENTER);
            cancel_update_button.set_tooltip_text(_("Cancel update"));
            cancel_update_button.visible = false;
            cancel_update_button.clicked.connect(() => {
                request_cancel_update();
            });


            // The same animated phase/progress badge used in the library.
            update_wrapper = new Gtk.Overlay();
            update_button = new Gtk.Button();
            update_button.add_css_class("pill");
            update_button.width_request = 200;
            update_button.hexpand = false;
            update_button.clicked.connect(() => {
                if (update_loading) {
                    return;
                }
                if (update_available) {
                    update_requested(record);
                } else {
                    check_update_requested(record);
                }
            });
            update_wrapper.set_child(update_button);
            
            rebuild_update_indicator();
            
            row1.append(update_wrapper);

            // Extract button
            extract_button = new Gtk.Button.with_label(_("Extract AppImage"));
            extract_button.add_css_class("pill");
            extract_button.width_request = 200;
            extract_button.hexpand = false;
            var can_extract = record.mode == InstallMode.PORTABLE && !record.is_terminal;
            extract_button.sensitive = can_extract;
            extract_button.clicked.connect(() => {
                present_extract_warning();
            });
            row1.append(extract_button);

            actions_row = new LeadingActionRow(row1, update_button);
            actions_row.set_leading(cancel_update_button);
            actions_box.append(actions_row);
            refresh_update_button();

            // Second row: Delete button
            delete_button = new Gtk.Button();
            delete_button.add_css_class("pill");
            delete_button.width_request = 200;
            delete_button.hexpand = false;
            delete_button.set_halign(Gtk.Align.CENTER);
            update_delete_button_label();
            delete_button.add_css_class("destructive-action");
            delete_button.clicked.connect(() => {
                bool will_be_permanent = shift_held || record.mode == InstallMode.EXTRACTED || !is_path_trashable();
                // The sandboxed home counts too: for a sandboxed app it is all of the
                // user data there is, so removing it silently is the worst option.
                if (Installer.has_portable_folders(record) || Installer.has_sandbox_home(record)) {
                    present_portable_delete_dialog(will_be_permanent);
                } else if (will_be_permanent) {
                    present_permanent_delete_warning();
                } else {
                    uninstall_requested(record, false, false);
                }
            });
            
            actions_box.append(delete_button);
            
            return actions_group;
        }

        private Gtk.Button create_restore_button(bool visible) {
            var button = new Gtk.Button.from_icon_name("edit-undo-symbolic");
            button.add_css_class("flat");
            button.set_valign(Gtk.Align.CENTER);
            button.tooltip_text = _("Restore default");
            button.set_visible(visible);
            return button;
        }

        private void rebuild_update_indicator() {
            if (update_wrapper == null) {
                return;
            }
            if (update_indicator != null && update_indicator.get_parent() is Gtk.Overlay) {
                ((Gtk.Overlay) update_indicator.get_parent()).remove_overlay(update_indicator);
            }
            update_indicator = new UpdateIndicator(update_progress_state);
            update_indicator.pixel_size = 20;
            update_indicator.valign = Gtk.Align.CENTER;
            update_indicator.halign = Gtk.Align.START;
            update_indicator.margin_start = 12;
            update_indicator.visible = false;
            update_wrapper.add_overlay(update_indicator);
        }

        private void refresh_update_button() {
            if (update_button == null || update_indicator == null) {
                return;
            }

            var progress = update_progress_state;
            bool loading = progress != null ? !progress.terminal && !progress.finished : update_loading;
            bool updating = progress != null ? !progress.terminal && !progress.finished : update_updating;
            bool installing = progress != null && progress.phase == UpdatePhase.INSTALLING;
            var failure_message = update_failure_message
                ?? (progress != null && progress.phase == UpdatePhase.FAILED ? progress.message : null);
            update_loading = loading;
            if (!updating) {
                cancel_pressed = false;
            }
            if (actions_row != null) {
                actions_row.set_leading_visible(updating);
            }
            if (cancel_update_button != null) {
                cancel_update_button.sensitive = updating && !installing && !cancel_pressed;
                cancel_update_button.set_tooltip_text(installing ? _("Installation cannot be cancelled") : _("Cancel update"));
            }
            update_button.set_tooltip_text(null);
            update_indicator.visible = progress != null ? !progress.finished : loading || failure_message != null;
            if (progress == null && loading) {
                update_indicator.show_phase(update_updating ? UpdatePhase.INSTALLING : UpdatePhase.CHECKING);
            } else if (progress == null && failure_message != null) {
                update_indicator.show_phase(UpdatePhase.FAILED, 0, 0, failure_message);
            }

            if (loading) {
                if (progress != null || update_updating) {
                    update_button.set_label(_("Updating..."));
                } else {
                    update_button.set_label(_("Checking..."));
                }
                update_button.sensitive = false;
                update_button.remove_css_class("suggested-action");
                update_button.remove_css_class("update-failed-button");
                return;
            }

            update_button.sensitive = true;
            update_updating = false;  // Reset updating state
            update_button.remove_css_class("update-failed-button");

            if (failure_message != null) {
                var warn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                warn_box.set_halign(Gtk.Align.CENTER);
                warn_box.append(new Gtk.Label(_("Update Failed")));
                update_button.set_child(warn_box);
                update_button.remove_css_class("suggested-action");
                update_button.add_css_class("update-failed-button");
                update_button.set_tooltip_text(failure_message);
            } else if (update_available) {
                var update_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                update_box.set_halign(Gtk.Align.CENTER);
                update_box.append(new Gtk.Image.from_icon_name("software-update-available-symbolic"));
                update_box.append(new Gtk.Label(_("Update")));
                update_button.set_child(update_box);
                update_button.add_css_class("suggested-action");
            } else {
                update_button.set_child(null);
                update_button.set_label(_("Check Update"));
                update_button.remove_css_class("suggested-action");
                update_button.set_tooltip_text(null);
            }
        }

        private string determine_reveal_path() {
            var installed_path = record.installed_path ?? "";
            if (record.mode == InstallMode.PORTABLE) {
                return AppPaths.applications_dir;
            }
            if (installed_path.strip() == "") {
                return AppPaths.applications_dir;
            }

            var file = File.new_for_path(installed_path);
            if (!file.query_exists()) {
                return AppPaths.applications_dir;
            }
            if (file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                return installed_path;
            }

            return Path.get_dirname(installed_path);
        }

        private Gtk.Box create_info_card(string text) {
            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            card.add_css_class("card");
            
            var label = new Gtk.Label(text);
            label.add_css_class("caption");
            label.set_margin_start(8);
            label.set_margin_end(8);
            label.set_margin_top(6);
            label.set_margin_bottom(6);
            
            card.append(label);
            return card;
        }

        private int64 calculate_installation_size(InstallationRecord record) {
            int64 total_size = 0;
            
            try {
                // Add installed path size (AppImage or extracted directory)
                if (record.installed_path != null && record.installed_path != "") {
                    total_size += AppManager.Utils.FileUtils.get_path_size(record.installed_path);
                }
                
                // Add icon size if exists
                if (record.icon_path != null && record.icon_path != "") {
                    total_size += AppManager.Utils.FileUtils.get_path_size(record.icon_path);
                }
                
                // Add desktop file size
                if (record.desktop_file != null && record.desktop_file != "") {
                    total_size += AppManager.Utils.FileUtils.get_path_size(record.desktop_file);
                }
            } catch (Error e) {
                warning("Failed to calculate size for %s: %s", record.name, e.message);
            }
            
            return total_size;
        }

        private HashTable<string, string> load_desktop_file_properties(string desktop_file_path) {
            var props = new HashTable<string, string>(str_hash, str_equal);
            
            var entry = new DesktopEntry(desktop_file_path);
            if (entry.no_display) {
                props.set("NoDisplay", "true");
            }

            if (entry.comment != null && entry.comment.strip() != "") {
                props.set("Comment", entry.comment.strip());
            }
            
            return props;
        }
        
        private void setup_shift_key_controller() {
            var key_controller = new Gtk.EventControllerKey();
            key_controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Shift_L || keyval == Gdk.Key.Shift_R) {
                    shift_held = true;
                    update_delete_button_label();
                }
                return false;
            });
            key_controller.key_released.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Shift_L || keyval == Gdk.Key.Shift_R) {
                    shift_held = false;
                    update_delete_button_label();
                }
            });
            // Attach to the toplevel window once it's realized
            this.realize.connect(() => {
                var toplevel = this.get_root() as Gtk.Window;
                if (toplevel != null) {
                    ((Gtk.Widget) toplevel).add_controller(key_controller);
                }
            });
        }

        private bool can_cancel_update() {
            var progress = update_progress_state;
            bool updating = progress != null ? !progress.terminal && !progress.finished : update_updating;
            bool installing = progress != null && progress.phase == UpdatePhase.INSTALLING;
            return updating && !installing;
        }

        public bool cancel_update_with_escape() {
            if (!can_cancel_update()) {
                return false;
            }
            request_cancel_update();
            return true;
        }

        private void request_cancel_update() {
            if (cancel_pressed) {
                return;
            }
            cancel_pressed = true;
            refresh_update_button();
            update_cancel_requested(record);
        }

        private bool is_path_trashable() {
            if (record.installed_path == null) return true;
            var home = Environment.get_home_dir();
            return record.installed_path.has_prefix(home + "/");
        }

        private void update_delete_button_label() {
            if (delete_button == null) return;
            var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            box.set_halign(Gtk.Align.CENTER);
            if (shift_held || record.mode == InstallMode.EXTRACTED || !is_path_trashable()) {
                box.append(new Gtk.Label(_("Delete Permanently")));
                delete_button.tooltip_text = null;
            } else {
                box.append(new Gtk.Image.from_icon_name("user-trash-symbolic"));
                box.append(new Gtk.Label(_("Move to Trash")));
                delete_button.tooltip_text = _("Hold Shift to delete permanently");
            }
            delete_button.set_child(box);
        }

        private void present_permanent_delete_warning() {
            var app_name = record.name ?? Path.get_basename(record.installed_path);
            var body = _("<b>%s</b> will be permanently deleted. This action cannot be undone.").printf(GLib.Markup.escape_text(app_name));
            var dialog = new Adw.AlertDialog(_("Delete permanently?"), null);
            dialog.set_body_use_markup(true);
            dialog.set_body(body);
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("delete", _("Delete Permanently"));
            dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_close_response("cancel");
            dialog.set_default_response("cancel");
            dialog.response.connect((response) => {
                if (response == "delete") {
                    uninstall_requested(record, true, false);
                }
            });
            dialog.present(this);
        }

        private void present_portable_delete_dialog(bool permanently) {
            var app_name = record.name ?? Path.get_basename(record.installed_path);

            string title;
            string confirm_label;
            string body;
            string delete_row_title;
            string delete_row_subtitle;
            if (permanently) {
                title = _("Delete permanently?");
                confirm_label = _("Delete Permanently");
                body = _("<b>%s</b> will be permanently deleted. This action cannot be undone.").printf(GLib.Markup.escape_text(app_name));
                delete_row_title = _("Delete All Data");
                delete_row_subtitle = _("Permanently erase user data to save space");
            } else {
                title = _("Move to Trash?");
                confirm_label = _("Move to Trash");
                body = _("<b>%s</b> will be moved to the Trash.").printf(GLib.Markup.escape_text(app_name));
                delete_row_title = _("Trash All Data");
                delete_row_subtitle = _("Move user data to Trash along with the app");
            }

            var dialog = new Adw.AlertDialog(title, null);
            dialog.set_body_use_markup(true);
            dialog.set_body(body);

            var keep_radio = new Gtk.CheckButton();
            keep_radio.set_valign(Gtk.Align.CENTER);
            keep_radio.set_active(true);

            var delete_radio = new Gtk.CheckButton();
            delete_radio.set_group(keep_radio);
            delete_radio.set_valign(Gtk.Align.CENTER);

            var keep_row = new Adw.ActionRow();
            keep_row.set_title(_("Keep User Data"));
            keep_row.set_subtitle(_("Allow restoring personal settings &amp; content"));
            keep_row.add_prefix(keep_radio);
            keep_row.set_activatable_widget(keep_radio);

            var delete_row = new Adw.ActionRow();
            delete_row.set_title(delete_row_title);
            delete_row.set_subtitle(delete_row_subtitle);
            delete_row.add_prefix(delete_radio);
            delete_row.set_activatable_widget(delete_radio);

            var list = new Gtk.ListBox();
            list.set_selection_mode(Gtk.SelectionMode.NONE);
            list.add_css_class("boxed-list");
            list.append(keep_row);
            list.append(delete_row);

            dialog.set_extra_child(list);

            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("delete", confirm_label);
            dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_close_response("cancel");
            dialog.set_default_response("cancel");
            dialog.response.connect((response) => {
                if (response == "delete") {
                    bool preserve = keep_radio.get_active();
                    uninstall_requested(record, permanently, preserve);
                }
            });
            dialog.present(this);
        }

        private void present_extract_warning() {
            var body = _("Extracting will unpack the application so it opens faster, but it will consume more disk space. This action cannot be reversed automatically.");
            var dialog = new Adw.AlertDialog(_("Extract application?"), body);
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("extract", _("Extract"));
            dialog.set_response_appearance("extract", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_close_response("cancel");
            dialog.set_default_response("cancel");
            dialog.response.connect((response) => {
                if (response == "extract") {
                    extract_requested(record);
                }
            });
            dialog.present(this);
        }

        /** Routes a message to the main window's toast overlay this page lives in. */
        private void show_toast(string message) {
            var window = this.get_root() as MainWindow;
            if (window != null) {
                window.add_toast(message);
            }
        }

        private void update_path_banner_visibility() {
            if (path_banner == null || path_row == null) {
                return;
            }

            bool needs_path = path_row.active;
            bool path_missing = !path_contains_local_bin();

            path_banner.set_revealed(needs_path && path_missing);
        }

        private bool path_contains_local_bin() {
            var home_bin = AppPaths.local_bin_dir;
            var home_bin_file = File.new_for_path(home_bin);
            
            // 1. Check current environment PATH
            var path_env = Environment.get_variable("PATH") ?? "";
            if (check_path_string(path_env, home_bin, home_bin_file)) {
                return true;
            }
            
            // 2. Fallback: Try to get PATH from user's shell
            try {
                string shell = Environment.get_variable("SHELL");
                if (shell == null || shell == "") {
                    shell = "/bin/sh";
                }
                
                string std_out;
                string std_err;
                int exit_status;
                
                // Use interactive login shell to ensure we get the full user configuration
                // (sources .bashrc, .zshrc, .profile, etc.)
                string[] argv = { shell, "-i", "-l", "-c", "echo $PATH" };
                
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, out std_out, out std_err, out exit_status);
                
                if (exit_status == 0 && std_out != null) {
                    if (check_path_string(std_out, home_bin, home_bin_file)) {
                        return true;
                    }
                }
            } catch (Error e) {
                warning("Failed to probe shell PATH: %s", e.message);
            }
            
            return false;
        }

        private bool check_path_string(string path_str, string home_bin, File home_bin_file) {
            foreach (var segment in path_str.split(":")) {
                var clean_segment = segment.strip();
                if (clean_segment == "") {
                    continue;
                }
                
                if (clean_segment == home_bin) {
                    return true;
                }
                
                if (File.new_for_path(clean_segment).equal(home_bin_file)) {
                    return true;
                }
            }
            return false;
        }

    }
}
