using Gee;

namespace AppManager.Core {
    /**
     * Builds bwrap argument lists from an InstallationRecord's sandbox configuration.
     *
     * Profiles are presets (Off / Standard / Strict). The granular toggles
     * (sandbox_camera, sandbox_network, sandbox_downloads, ...) carry the
     * actual state; the profile just labels which preset was last applied.
     */
    public class SandboxProfile {
        public const string PROFILE_OFF = "off";
        public const string PROFILE_STANDARD = "standard";
        public const string PROFILE_STRICT = "strict";
        public const string PROFILE_CUSTOM = "custom";

        /**
         * Applies preset toggle values for the given profile to the record.
         * No-op for "custom" or "off".
         */
        public static void apply_preset(InstallationRecord record, string profile) {
            switch (profile) {
                case PROFILE_STANDARD:
                    record.sandbox_camera = false;
                    record.sandbox_microphone = false;
                    record.sandbox_location = false;
                    record.sandbox_network = true;
                    record.sandbox_downloads = true;
                    record.sandbox_pictures = true;
                    record.sandbox_files = true;
                    break;
                case PROFILE_STRICT:
                    record.sandbox_camera = false;
                    record.sandbox_microphone = false;
                    record.sandbox_location = false;
                    record.sandbox_network = false;
                    record.sandbox_downloads = true;
                    record.sandbox_pictures = false;
                    record.sandbox_files = false;
                    break;
                case PROFILE_OFF:
                case PROFILE_CUSTOM:
                default:
                    break;
            }
            record.sandbox_profile = profile;
        }

        /**
         * Returns the named profile whose preset matches the record's current toggles,
         * or "custom" if no preset matches. "off" is never auto-detected here.
         */
        public static string detect_profile(InstallationRecord record) {
            if (toggles_match(record, false, false, false, true, true, true, true)) {
                return PROFILE_STANDARD;
            }
            if (toggles_match(record, false, false, false, false, true, false, false)) {
                return PROFILE_STRICT;
            }
            return PROFILE_CUSTOM;
        }

        private static bool toggles_match(InstallationRecord r, bool cam, bool mic, bool loc,
                                          bool net, bool dl, bool pic, bool files) {
            return r.sandbox_camera == cam
                && r.sandbox_microphone == mic
                && r.sandbox_location == loc
                && r.sandbox_network == net
                && r.sandbox_downloads == dl
                && r.sandbox_pictures == pic
                && r.sandbox_files == files;
        }

        /**
         * Builds the bwrap argument list (without the leading "bwrap" binary path
         * and without the trailing "--" separator).
         *
         * Caller adds those: ["bwrap", ...build_args(record), "--", exec, args...].
         */
        public static string[] build_args(InstallationRecord record) {
            var args = new ArrayList<string>();

            // Namespaces and lifecycle
            args.add("--unshare-user");
            args.add("--unshare-pid");
            args.add("--unshare-uts");
            args.add("--unshare-cgroup");
            args.add("--new-session");
            args.add("--die-with-parent");

            // Filesystem skeleton: read-only host root pieces
            add_pair(args, "--ro-bind", "/usr", "/usr");
            add_pair(args, "--ro-bind", "/etc", "/etc");
            add_pair(args, "--ro-bind", "/sys", "/sys");
            add_pair(args, "--ro-bind-try", "/opt", "/opt");
            add_symlink(args, "usr/lib", "/lib");
            add_symlink(args, "usr/lib32", "/lib32");
            add_symlink(args, "usr/lib64", "/lib64");
            add_symlink(args, "usr/bin", "/bin");
            add_symlink(args, "usr/sbin", "/sbin");

            // /proc, /dev (with selective device passthrough below), /tmp
            add_pair(args, "--proc", null, "/proc");
            add_pair(args, "--dev", null, "/dev");
            add_pair(args, "--tmpfs", null, "/tmp");

            // Empty $HOME — repopulated below with allowed bits.
            var home = Environment.get_home_dir();
            add_pair(args, "--tmpfs", null, home);

            // GPU passthrough — almost every app needs DRI to render.
            add_pair(args, "--dev-bind-try", "/dev/dri", "/dev/dri");

            // NVIDIA (if present).
            string[] nvidia_nodes = {
                "/dev/nvidia0", "/dev/nvidia1",
                "/dev/nvidiactl", "/dev/nvidia-modeset",
                "/dev/nvidia-uvm", "/dev/nvidia-uvm-tools"
            };
            foreach (var node in nvidia_nodes) {
                add_pair(args, "--dev-bind-try", node, node);
            }

            // Display servers and bus-style sockets.
            var xauth = Environment.get_variable("XAUTHORITY");
            if (xauth != null && xauth.strip() != "") {
                add_pair(args, "--ro-bind-try", xauth, xauth);
            }
            add_pair(args, "--ro-bind-try", "/tmp/.X11-unix", "/tmp/.X11-unix");

            var runtime_dir = Environment.get_user_runtime_dir();
            if (runtime_dir != null && runtime_dir != "") {
                // Runtime dir tmpfs root, then selectively bind the sockets we want.
                add_pair(args, "--dir", null, runtime_dir);
                var wayland_display = Environment.get_variable("WAYLAND_DISPLAY") ?? "wayland-0";
                var wayland_path = Path.build_filename(runtime_dir, wayland_display);
                add_pair(args, "--ro-bind-try", wayland_path, wayland_path);
                add_pair(args, "--ro-bind-try",
                    Path.build_filename(runtime_dir, "pulse"),
                    Path.build_filename(runtime_dir, "pulse"));
                add_pair(args, "--ro-bind-try",
                    Path.build_filename(runtime_dir, "pipewire-0"),
                    Path.build_filename(runtime_dir, "pipewire-0"));
                add_pair(args, "--ro-bind-try",
                    Path.build_filename(runtime_dir, "bus"),
                    Path.build_filename(runtime_dir, "bus"));
            }

            // Theming / fonts so GTK/Qt apps don't render as fallback noise.
            add_ro_bind_home(args, home, ".config/fontconfig");
            add_ro_bind_home(args, home, ".local/share/fonts");
            add_ro_bind_home(args, home, ".icons");
            add_ro_bind_home(args, home, ".themes");
            add_ro_bind_home(args, home, ".config/gtk-3.0");
            add_ro_bind_home(args, home, ".config/gtk-4.0");
            add_ro_bind_home(args, home, ".config/dconf");
            add_ro_bind_home(args, home, ".config/Kvantum");

            // App's own installed path (read-write so app can write next to itself).
            if (record.installed_path != null && record.installed_path.strip() != "") {
                add_pair(args, "--bind", record.installed_path, record.installed_path);

                // Portable mode .home / .config siblings.
                if (record.mode == InstallMode.PORTABLE) {
                    var portable_home = "%s.home".printf(record.installed_path);
                    var portable_config = "%s.config".printf(record.installed_path);
                    add_pair(args, "--bind-try", portable_home, portable_home);
                    add_pair(args, "--bind-try", portable_config, portable_config);
                }
            }

            // Bin symlink directory needs to be visible so that wrapper scripts
            // (and the app's own attempts to spawn ${0}) work.
            var bin_dir = AppPaths.local_bin_dir;
            add_pair(args, "--ro-bind-try", bin_dir, bin_dir);

            // FUSE — required for AppImages running in portable (FUSE-mount) mode.
            add_pair(args, "--dev-bind-try", "/dev/fuse", "/dev/fuse");

            // Network
            if (!record.sandbox_network) {
                args.add("--unshare-net");
            } else {
                // Make sure DNS works inside the sandbox even though /etc was bound.
                add_pair(args, "--ro-bind-try", "/etc/resolv.conf", "/etc/resolv.conf");
            }

            // Camera
            if (record.sandbox_camera) {
                add_dev_glob(args, "/dev/video");
                add_dev_glob(args, "/dev/v4l-");
                add_dev_glob(args, "/dev/media");
            }

            // Microphone — bind ALSA. Mic OFF means we skip /dev/snd entirely; PipeWire/Pulse
            // sockets above still allow output. Server-side capture gating is best-effort.
            if (record.sandbox_microphone) {
                add_pair(args, "--dev-bind-try", "/dev/snd", "/dev/snd");
            }

            // Location: GeoClue runs over the session bus. Without xdg-dbus-proxy
            // we can't filter D-Bus names, so this toggle is a no-op for now —
            // the UI grays it out when xdg-dbus-proxy is missing.
            // Future: spawn xdg-dbus-proxy and bind its filtered socket.

            // Storage
            if (record.sandbox_downloads) {
                add_user_dir(args, UserDirectory.DOWNLOAD);
            }
            if (record.sandbox_pictures) {
                add_user_dir(args, UserDirectory.PICTURES);
                add_user_dir(args, UserDirectory.VIDEOS);
            }
            if (record.sandbox_files) {
                add_user_dir(args, UserDirectory.DOCUMENTS);
                add_user_dir(args, UserDirectory.MUSIC);
                add_user_dir(args, UserDirectory.DESKTOP);
            }

            // Pass through environment vars commonly needed for desktop integration.
            string[] passthrough_env = {
                "DISPLAY", "WAYLAND_DISPLAY", "XDG_SESSION_TYPE",
                "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP",
                "DBUS_SESSION_BUS_ADDRESS", "PULSE_SERVER",
                "GDK_BACKEND", "QT_QPA_PLATFORM",
                "GTK_THEME", "ICON_THEME", "LANG", "LANGUAGE", "LC_ALL"
            };
            foreach (var name in passthrough_env) {
                var val = Environment.get_variable(name);
                if (val != null) {
                    args.add("--setenv");
                    args.add(name);
                    args.add(val);
                }
            }

            return args.to_array();
        }

        private static void add_pair(ArrayList<string> args, string flag, string? src, string dest) {
            args.add(flag);
            if (src != null) {
                args.add(src);
            }
            args.add(dest);
        }

        private static void add_symlink(ArrayList<string> args, string target, string linkpath) {
            args.add("--symlink");
            args.add(target);
            args.add(linkpath);
        }

        private static void add_ro_bind_home(ArrayList<string> args, string home, string rel) {
            var p = Path.build_filename(home, rel);
            args.add("--ro-bind-try");
            args.add(p);
            args.add(p);
        }

        private static void add_user_dir(ArrayList<string> args, UserDirectory which) {
            var p = Environment.get_user_special_dir(which);
            if (p == null || p.strip() == "") {
                return;
            }
            args.add("--bind-try");
            args.add(p);
            args.add(p);
        }

        /**
         * Binds every existing /dev node whose path starts with `prefix` followed
         * by a digit (e.g. /dev/video0, /dev/video1, ...). Caps at 10 to avoid
         * runaway argument lists if /dev contains unusual content.
         */
        private static void add_dev_glob(ArrayList<string> args, string prefix) {
            for (int i = 0; i < 10; i++) {
                var node = "%s%d".printf(prefix, i);
                if (FileUtils.test(node, FileTest.EXISTS)) {
                    args.add("--dev-bind-try");
                    args.add(node);
                    args.add(node);
                }
            }
        }

        /**
         * Renders an arg array as a properly-quoted shell command suitable for
         * a .desktop Exec= line. Each token is wrapped in double quotes; embedded
         * double quotes and backslashes are escaped.
         */
        public static string render_for_desktop(string[] args) {
            var builder = new StringBuilder();
            foreach (var arg in args) {
                if (builder.len > 0) builder.append(" ");
                builder.append(quote_token(arg));
            }
            return builder.str;
        }

        private static string quote_token(string token) {
            // Tokens that are pure flag names (start with -- and contain no spaces)
            // can stay unquoted for readability.
            if (token.has_prefix("--") && !token.contains(" ") && !token.contains("\"")) {
                return token;
            }
            var escaped = token.replace("\\", "\\\\").replace("\"", "\\\"");
            return "\"%s\"".printf(escaped);
        }
    }
}
