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

        // Cache loaded textures to avoid re-reading from disk on every refresh
        private static Gee.HashMap<string, Gdk.Paintable>? texture_cache = null;

        private static Gee.HashMap<string, Gdk.Paintable> get_texture_cache() {
            if (texture_cache == null) {
                texture_cache = new Gee.HashMap<string, Gdk.Paintable>();
            }
            return texture_cache;
        }


        public static Gdk.Paintable? load_icon_from_appimage(string path) {
            string? temp_dir = null;
            try {
                temp_dir = FileUtils.create_temp_dir("appmgr-icon-");
                var icon_path = AppImageAssets.extract_icon(path, temp_dir);
                if (icon_path != null) {
                    return load_icon_texture(icon_path);
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

        // Gdk.Texture.from_file rasterizes an SVG at its (often tiny) intrinsic size,
        // which then gets upscaled to the display size and looks blurry. Render SVGs at
        // a generous size via GdkPixbuf (librsvg) so they stay crisp; raster icons keep
        // their native resolution.
        private static Gdk.Texture load_icon_texture(string icon_path) throws Error {
            if (FileUtils.detect_image_extension(icon_path) == ".svg") {
                var pixbuf = new Gdk.Pixbuf.from_file_at_size(icon_path, 512, 512);
                var format = pixbuf.get_has_alpha()
                    ? Gdk.MemoryFormat.R8G8B8A8
                    : Gdk.MemoryFormat.R8G8B8;
                var bytes = new GLib.Bytes(pixbuf.get_pixels_with_length());
                return new Gdk.MemoryTexture(pixbuf.get_width(), pixbuf.get_height(),
                                             format, bytes, pixbuf.get_rowstride());
            }
            return Gdk.Texture.from_file(File.new_for_path(icon_path));
        }

        public static Gtk.Image? load_app_icon(string icon_path, int pixel_size = 48) {
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
                icon_image.set_pixel_size(pixel_size);                
                return icon_image;
            }

            // Fallback to loading from file path with texture cache
            var cache = get_texture_cache();
            if (cache.has_key(icon_path)) {
                var cached = cache.get(icon_path);
                var icon_image = new Gtk.Image.from_paintable(cached);
                icon_image.set_pixel_size(pixel_size);
                return icon_image;
            }

            if (icon_file.query_exists()) {
                try {
                    var icon_texture = Gdk.Texture.from_file(icon_file);
                    cache.set(icon_path, icon_texture);
                    var icon_image = new Gtk.Image.from_paintable(icon_texture);
                    icon_image.set_pixel_size(pixel_size);
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

        public static void reveal_file(string path, Gtk.Window? parent) {
            var file = File.new_for_path(path);
            var launcher = new Gtk.FileLauncher(file);
            launcher.open_containing_folder.begin(parent, null, (obj, res) => {
                try {
                    launcher.open_containing_folder.end(res);
                } catch (Error e) {
                    warning("Failed to reveal file %s: %s", path, e.message);
                    open_folder(Path.get_dirname(path), parent);
                }
            });
        }

        // Build an argv that opens a terminal at `dir`, or null if no known terminal
        // is installed. Each terminal needs its own working-directory flag: relying on
        // the spawn cwd alone fails for single-instance terminals (ptyxis, kgx, ...)
        // that hand the request to an already-running primary instance.
        private static string[]? terminal_command(string dir) {
            string? p;
            if ((p = Environment.find_program_in_path("xdg-terminal-exec")) != null) {
                return { p };  // freedesktop launcher, opens in cwd
            }
            if ((p = Environment.find_program_in_path("ptyxis")) != null) {
                return { p, "--new-window", "--working-directory=" + dir };
            }
            if ((p = Environment.find_program_in_path("kgx")) != null) {
                return { p, "--working-directory=" + dir };
            }
            if ((p = Environment.find_program_in_path("gnome-terminal")) != null) {
                return { p, "--working-directory=" + dir };
            }
            if ((p = Environment.find_program_in_path("konsole")) != null) {
                return { p, "--workdir", dir };
            }
            if ((p = Environment.find_program_in_path("xfce4-terminal")) != null) {
                return { p, "--working-directory=" + dir };
            }
            if ((p = Environment.find_program_in_path("tilix")) != null) {
                return { p, "--working-directory=" + dir };
            }
            if ((p = Environment.find_program_in_path("alacritty")) != null) {
                return { p, "--working-directory", dir };
            }
            if ((p = Environment.find_program_in_path("kitty")) != null) {
                return { p, "--directory", dir };
            }
            if ((p = Environment.find_program_in_path("foot")) != null) {
                return { p, "--working-directory=" + dir };
            }
            if ((p = Environment.find_program_in_path("wezterm")) != null) {
                return { p, "start", "--cwd", dir };
            }
            if ((p = Environment.find_program_in_path("xterm")) != null) {
                return { p };  // opens in cwd
            }
            return null;
        }

        public static bool terminal_available() {
            return terminal_command(Environment.get_home_dir()) != null;
        }

        public static void open_terminal(string dir) {
            var argv = terminal_command(dir);
            if (argv == null) {
                warning("No terminal emulator found to open %s", dir);
                return;
            }
            try {
                Process.spawn_async(dir, argv, null, SpawnFlags.SEARCH_PATH, null, null);
            } catch (Error e) {
                warning("Failed to launch terminal: %s", e.message);
            }
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

        public static void spin_launch_icon(Gtk.Widget widget) {
            var target = new Adw.CallbackAnimationTarget((value) => {
                var rotation = new Gsk.Transform();
                // Translate to center, rotate, translate back
                float w = widget.get_width() / 2.0f;
                float h = widget.get_height() / 2.0f;
                rotation = rotation.translate(Graphene.Point() { x = w, y = h });
                rotation = rotation.rotate((float) value);
                rotation = rotation.translate(Graphene.Point() { x = -w, y = -h });
                widget.allocate(widget.get_width(), widget.get_height(), -1, rotation);
            });
            // First spin: 360 degrees
            var animation = new Adw.TimedAnimation(widget, 0, 360, 400, target);
            animation.set_easing(Adw.Easing.EASE_IN_OUT_CUBIC);
            animation.done.connect(() => {
                // Pause 0.5 seconds, then second spin: 360 degrees
                Timeout.add(500, () => {
                    var animation2 = new Adw.TimedAnimation(widget, 0, 360, 400, target);
                    animation2.set_easing(Adw.Easing.EASE_IN_OUT_CUBIC);
                    animation2.play();
                    return false;
                });
            });
            animation.play();
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
