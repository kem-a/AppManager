using Gtk;
using Gdk;
using Adw;

namespace AppManager.Utils {
    public class UiUtils {
        [CCode (cname = "gtk_style_context_add_provider_for_display")]
        internal extern static void gtk_style_context_add_provider_for_display_compat(Gdk.Display display, Gtk.StyleProvider provider, uint priority);

        private static Gtk.CssProvider? app_css_provider = null;
        private static bool app_css_applied = false;
        private static ulong css_display_handler = 0;
        private const string APP_CARD_CSS = """
            .card.accent,
            .app-card.accent {
                background-color: @accent_bg_color;
                color: @accent_fg_color;
            }
            .card.accent label,
            .app-card.accent label {
                color: @accent_fg_color;
            }
            .card.destructive,
            .app-card.destructive {
                background-color: @destructive_bg_color;
                color: @destructive_fg_color;
            }
            .card.destructive label,
            .app-card.destructive label {
                color: @destructive_fg_color;
            }
            .card.terminal,
            .app-card.terminal {
                background-color: #535252ff;
                color: #ffffff;
            }
            .card.terminal label,
            .app-card.terminal label {
                color: #ffffff;
            }
            .app-card-label {
                border-radius: 999px;
                background-color: alpha(@window_bg_color, 0.6);
                color: inherit;
                padding: 0.2em 0.8em;
            }
            .app-card-label.accent-badge {
                background-color: @accent_bg_color;
                color: @accent_fg_color;
            }
            .app-card-label.terminal-badge {
                background-color: #535252ff;
                color: #ffffff;
            }
            .update-success-badge {
                min-width: 18px;
                min-height: 18px;
            }
        """;

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
                debug("Loaded icon '%s' from icon theme", icon_name);
                return icon_image;
            }

            // Fallback to loading from file path
            if (icon_file.query_exists()) {
                try {
                    var icon_texture = Gdk.Texture.from_file(icon_file);
                    var icon_image = new Gtk.Image.from_paintable(icon_texture);
                    icon_image.set_pixel_size(48);
                    debug("Loaded icon from file: %s", icon_path);
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
                app_css_provider.load_from_string(APP_CARD_CSS);
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

        public static Gdk.RGBA get_accent_background_color() {
            var fallback = parse_color("#3584e4");
            var style_manager = Adw.StyleManager.get_default();
            if (style_manager == null) {
                return fallback;
            }

            var accent_rgba = style_manager.get_accent_color_rgba();
            if (accent_rgba != null) {
                return accent_rgba;
            }

            return style_manager.get_accent_color().to_rgba();
        }

        public static Gdk.RGBA get_accent_foreground_color(Gdk.RGBA accent_bg) {
            var style_manager = Adw.StyleManager.get_default();
            if (style_manager != null && style_manager.get_dark()) {
                return parse_color("#f6f5f4");
            }

            double luminance = relative_luminance(accent_bg);
            if (luminance > 0.6) {
                return parse_color("#241f31");
            }
            return parse_color("#ffffff");
        }

        public static string rgba_to_hex(Gdk.RGBA color) {
            int r = clamp_channel((int)(color.red * 255.0 + 0.5));
            int g = clamp_channel((int)(color.green * 255.0 + 0.5));
            int b = clamp_channel((int)(color.blue * 255.0 + 0.5));
            return "#%02x%02x%02x".printf(r, g, b);
        }

        public static string rgba_to_css(Gdk.RGBA color) {
            int r = clamp_channel((int)(color.red * 255.0 + 0.5));
            int g = clamp_channel((int)(color.green * 255.0 + 0.5));
            int b = clamp_channel((int)(color.blue * 255.0 + 0.5));
            return "rgba(%d, %d, %d, %.3f)".printf(r, g, b, color.alpha);
        }

        public static Gdk.RGBA parse_color(string value) {
            var color = Gdk.RGBA();
            color.parse(value);
            return color;
        }

        private static int clamp_channel(int value) {
            if (value < 0) {
                return 0;
            }
            if (value > 255) {
                return 255;
            }
            return value;
        }

        private static double relative_luminance(Gdk.RGBA color) {
            return 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue;
        }
    }
}
