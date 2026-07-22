using AppManager.Core;
using AppManager.Utils;

namespace AppManager {

    // Adwaita window showing detailed information about an AppImage:
    // its name, icon, and a set of grouped properties (general, filesystem,
    // integrity, update info). Inspired by the appimageinfo CLI tool.
    public class AppImageInfoWindow : Adw.Window {
        private string appimage_path;
        private AppImageMetadata metadata;

        public AppImageInfoWindow(Application app, Gtk.Window parent, string appimage_path,
                                  string app_name, string? app_version,
                                  AppImageMetadata metadata, Gdk.Paintable? icon) {
            Object(application: app,
                transient_for: parent,
                modal: true,
                title: _("AppImage Info"),
                default_width: 400,
                default_height: 640,
                destroy_with_parent: true);
            this.appimage_path = appimage_path;
            this.metadata = metadata;
            build_ui(app_name, app_version, icon);
        }

        private void build_ui(string app_name, string? app_version, Gdk.Paintable? icon) {
            var toolbar_view = new Adw.ToolbarView();
            content = toolbar_view;

            var header = new Adw.HeaderBar();
            toolbar_view.add_top_bar(header);

            var scrolled = new Gtk.ScrolledWindow();
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.vexpand = true;
            toolbar_view.content = scrolled;

            var clamp = new Adw.Clamp();
            clamp.maximum_size = 340;
            clamp.margin_top = 12;
            clamp.margin_bottom = 24;
            clamp.margin_start = 12;
            clamp.margin_end = 12;
            scrolled.child = clamp;

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            clamp.child = box;

            // Icon
            var icon_image = new Gtk.Image();
            icon_image.set_pixel_size(96);
            if (icon != null) {
                icon_image.set_from_paintable(icon);
            } else {
                icon_image.set_from_icon_name("application-x-executable");
            }
            icon_image.margin_top = 12;
            box.append(icon_image);

            // Name
            var name_label = new Gtk.Label(app_name);
            name_label.add_css_class("title-1");
            name_label.wrap = true;
            name_label.justify = Gtk.Justification.CENTER;
            name_label.halign = Gtk.Align.CENTER;
            box.append(name_label);

            // Version
            if (app_version != null && app_version.strip() != "") {
                var version_label = new Gtk.Label(_("Version %s").printf(app_version));
                version_label.add_css_class("dim-label");
                box.append(version_label);
            }

            // General
            var general = new Adw.PreferencesGroup();
            general.title = _("General");
            general.margin_top = 12;
            general.add(make_row(_("File"), Path.get_basename(appimage_path)));
            general.add(make_row(_("Location"), Path.get_dirname(appimage_path)));
            general.add(make_row(_("Size"), UiUtils.format_size(query_file_size())));
            general.add(make_row(_("Type"), format_label()));
            general.add(make_row(_("Architecture"), metadata.architecture ?? _("Unknown")));
            box.append(general);

            // Filesystem details (SquashFS only)
            var fs_group = build_filesystem_group();
            if (fs_group != null) {
                box.append(fs_group);
            }

            // Integrity
            var integrity = new Adw.PreferencesGroup();
            integrity.title = _("Integrity");
            var sha_row = new Adw.ActionRow();
            sha_row.title = _("SHA-256");
            sha_row.subtitle = metadata.checksum;
            sha_row.subtitle_selectable = true;
            sha_row.add_css_class("property");
            var copy_btn = new Gtk.Button.from_icon_name("edit-copy-symbolic");
            copy_btn.valign = Gtk.Align.CENTER;
            copy_btn.add_css_class("flat");
            copy_btn.tooltip_text = _("Copy");
            copy_btn.clicked.connect(() => {
                get_clipboard().set_text(metadata.checksum);
            });
            sha_row.add_suffix(copy_btn);
            integrity.add(sha_row);
            box.append(integrity);

            // Update info
            var updates = new Adw.PreferencesGroup();
            updates.title = _("Updates");
            if (metadata.update_info != null && metadata.update_info.strip() != "") {
                var parts = metadata.update_info.split("|");
                updates.add(make_row(_("Update Type"), parts[0]));
                if (parts.length > 1) {
                    var url = string.joinv("|", parts[1:parts.length]);
                    updates.add(make_row(_("Update URL"), url));
                }
            } else {
                updates.add(make_row(_("Update Info"), _("Not available")));
            }
            box.append(updates);
        }

        private Adw.ActionRow make_row(string title, string value) {
            var row = new Adw.ActionRow();
            row.title = title;
            row.subtitle = value;
            row.subtitle_selectable = true;
            row.add_css_class("property");
            return row;
        }

        private int64 query_file_size() {
            try {
                var info = File.new_for_path(appimage_path).query_info("standard::size", FileQueryInfoFlags.NONE);
                return info.get_size();
            } catch (Error e) {
                return 0;
            }
        }

        private string format_label() {
            switch (AppImageAssets.detect_format(appimage_path)) {
                case AppImageFormat.SQUASHFS:
                    return "SquashFS";
                case AppImageFormat.DWARFS:
                    return "DwarFS";
                default:
                    return _("Unknown");
            }
        }

        private Adw.PreferencesGroup? build_filesystem_group() {
            var stat = AppImageAssets.read_squashfs_stat(appimage_path);
            if (stat == null) {
                return null;
            }

            var group = new Adw.PreferencesGroup();
            group.title = _("Filesystem");
            string[] wanted = { "Compression", "Block size", "Filesystem size", "Number of inodes", "Number of fragments" };
            bool any = false;

            foreach (var line in stat.split("\n")) {
                var trimmed = line.strip();
                foreach (var key in wanted) {
                    if (trimmed.has_prefix(key)) {
                        var value = trimmed.substring(key.length).strip();
                        // unsquashfs prints the size as "N bytes (N Kbytes / N Mbytes)";
                        // show a single human-readable unit instead.
                        if (key == "Filesystem size") {
                            value = format_filesystem_size(value);
                        }
                        if (value != "") {
                            group.add(make_row(key, value));
                            any = true;
                        }
                        break;
                    }
                }
            }

            return any ? group : null;
        }

        // Extract the leading byte count from an unsquashfs size string and render it
        // with a single dynamic unit (B / KB / MB / ...). Falls back to the raw value.
        private string format_filesystem_size(string value) {
            var token = value.strip();
            var space = token.index_of(" ");
            if (space > 0) {
                token = token.substring(0, space);
            }
            int64 bytes = int64.parse(token);
            return bytes > 0 ? UiUtils.format_size(bytes) : value;
        }
    }
}
