using Gtk;
using Gdk;
using Adw;
using AppManager.Core;

namespace AppManager.Utils {
    public class UiUtils {
        [CCode (cname = "gtk_style_context_add_provider_for_display")]
        internal extern static void gtk_style_context_add_provider_for_display_compat(Gdk.Display display, Gtk.StyleProvider provider, uint priority);

        private static Gtk.CssProvider? app_css_provider = null;
        private static bool app_css_applied = false;
        private static ulong css_display_handler = 0;


        public static Gdk.Paintable? load_icon_from_appimage(string path) {
            string? temp_dir = null;
            try {
                temp_dir = FileUtils.create_temp_dir("appmgr-icon-");
                var icon_path = AppImageAssets.extract_icon(path, temp_dir);
                if (icon_path != null) {
                    return Gdk.Texture.from_file(File.new_for_path(icon_path));
                }
            } catch (Error e) {
                warning("Icon extraction error: %s", e.message);
            } finally {
                if (temp_dir != null) {
                    FileUtils.remove_dir_recursive(temp_dir);
                }
            }
            return null;
        }

        public static Gtk.Image? load_app_icon(string icon_path) {
            // Extract icon name from the path (without extension)
            var icon_file = File.new_for_path(icon_path);
            var icon_basename = icon_file.get_basename();
            string icon_name = icon_basename;
            
            // Remove file extension to get icon name
            var last_dot = icon_basename.last_index_of(".");
            if (last_dot > 0) {
                icon_name = icon_basename.substring(0, last_dot);
            }

            // First try to load from icon theme
            var icon_theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
            if (icon_theme.has_icon(icon_name)) {
                var icon_image = new Gtk.Image.from_icon_name(icon_name);
                icon_image.set_pixel_size(48);                
                return icon_image;
            }

            // Fallback to loading from file path
            if (icon_file.query_exists()) {
                try {
                    var icon_texture = Gdk.Texture.from_file(icon_file);
                    var icon_image = new Gtk.Image.from_paintable(icon_texture);
                    icon_image.set_pixel_size(48);
                    return icon_image;
                } catch (Error e) {
                    warning("Failed to load icon from file %s: %s", icon_path, e.message);
                }
            } else {
                debug("Icon file does not exist: %s", icon_path);
            }

            return null;
        }

        public static string format_size(int64 bytes) {
            const string[] units = {"B", "KB", "MB", "GB", "TB"};
            double size = (double)bytes;
            int unit_index = 0;
            
            while (size >= 1024.0 && unit_index < units.length - 1) {
                size /= 1024.0;
                unit_index++;
            }
            
            if (unit_index == 0) {
                return "%.0f %s".printf(size, units[unit_index]);
            } else {
                return "%.1f %s".printf(size, units[unit_index]);
            }
        }

        public static void open_folder(string path, Gtk.Window? parent) {
            var file = File.new_for_path(path);
            var launcher = new Gtk.FileLauncher(file);
            launcher.launch.begin(parent, null, (obj, res) => {
                try {
                    launcher.launch.end(res);
                } catch (Error e) {
                    warning("Failed to open folder %s: %s", path, e.message);
                }
            });
        }

        public static void open_url(string url) {
            try {
                AppInfo.launch_default_for_uri(url, null);
            } catch (Error e) {
                warning("Failed to open URL %s: %s", url, e.message);
            }
        }

        public static void ensure_app_card_styles() {
            if (app_css_applied) {
                return;
            }

            if (app_css_provider == null) {
                app_css_provider = new Gtk.CssProvider();
                app_css_provider.load_from_resource("/com/github/AppManager/style.css");
            }

            var style_manager = Adw.StyleManager.get_default();
            if (style_manager == null) {
                warning("Unable to apply custom styles because StyleManager is unavailable");
                return;
            }

            var display = style_manager.get_display();
            if (display != null) {
                apply_app_css(display);
                return;
            }

            if (css_display_handler != 0) {
                return;
            }

            css_display_handler = style_manager.notify["display"].connect(() => {
                var new_display = style_manager.get_display();
                if (new_display == null) {
                    return;
                }
                style_manager.disconnect(css_display_handler);
                css_display_handler = 0;
                apply_app_css(new_display);
            });
        }

        private static void apply_app_css(Gdk.Display display) {
            if (app_css_provider == null) {
                return;
            }
            gtk_style_context_add_provider_for_display_compat(
                display,
                app_css_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
            app_css_applied = true;
        }

        public static Gdk.Paintable? load_record_icon(InstallationRecord record) {
            if (record.icon_path == null || record.icon_path.strip() == "") {
                return null;
            }
            try {
                var file = File.new_for_path(record.icon_path);
                if (file.query_exists()) {
                    return Gdk.Texture.from_file(file);
                }
                
                // Fallback: check flat icons directory
                var icon_basename = file.get_basename();
                var icons_base = Path.build_filename(Environment.get_user_data_dir(), "icons");
                var flat_path = Path.build_filename(icons_base, icon_basename);
                var flat_file = File.new_for_path(flat_path);
                if (flat_file.query_exists()) {
                    return Gdk.Texture.from_file(flat_file);
                }
            } catch (Error e) {
                warning("Failed to load record icon: %s", e.message);
            }
            return null;
        }

        public static Gtk.Label create_wrapped_label(string text, bool use_markup = false, bool dim = false) {
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
    }
}
