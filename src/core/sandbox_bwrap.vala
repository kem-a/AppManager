namespace AppManager.Core {
    /**
     * Turns a manifest plus launch-time state into a bubblewrap command line.
     *
     * bwrap applies its mount options in argv order and later mounts land on top of
     * earlier ones, so the order things are appended here is part of the meaning, not
     * a style choice. The sequence is: namespaces, read-only host root, runtime dir,
     * home, environment, then one block per permission.
     *
     * Two hard-won rules govern every bind below:
     *
     *  - Device nodes need --dev-bind, never --bind. bwrap's --dev mounts a tmpfs with
     *    MS_NODEV and only clears that flag for --dev-bind, so a plainly bound device
     *    node is visible, mode-correct and impossible to open. `test -w` passes on such
     *    a node, which is why device access must be verified with a real open().
     *
     *  - Never bind a symlink path. bwrap resolves the bind *source* to its target but
     *    creates the *destination* literally, so mounting onto a symlink that sits
     *    inside an already-bound read-only parent fails and the launch dies outright.
     *    Sources go through SandboxConfig.canonicalize; "-try" variants tolerate a
     *    missing source but not a failed mount.
     */
    public class SandboxBwrap {
        // Launch-time state, filled in by the supervisor before compose() is called.
        // All of it is optional: with none of it set, this builds the phase-1 sandbox
        // (no bus, no seccomp).
        public int sync_fd = -1;                    // held open for the bus proxy's lifetime
        public int seccomp_fd = -1;                 // compiled BPF filter
        public string? session_bus_socket = null;   // proxied session bus socket
        public string? system_bus_socket = null;    // proxied system bus socket
        public string? a11y_bus_socket = null;      // accessibility bus socket
        public string? wayland_socket = null;       // security-context socket, if any

        private SandboxManifest manifest;
        private string mount_dir;
        private string home;
        private string runtime_base;
        private Gee.ArrayList<string> args = new Gee.ArrayList<string>();
        // Read ends of pipes carrying generated file content. They must stay open
        // until bwrap has been started, and are closed by close_fds() afterwards.
        private Gee.ArrayList<int> data_fds = new Gee.ArrayList<int>();

        private static string? cached_help = null;

        public SandboxBwrap(SandboxManifest manifest, string mount_dir) {
            this.manifest = manifest;
            this.mount_dir = mount_dir;
            this.home = Environment.get_home_dir();
            this.runtime_base = AppPaths.sandbox_runtime_base;
        }

        /**
         * Composes the full argv, bwrap first and the app's own arguments last.
         * Returns null when something the sandbox cannot do without is missing.
         *
         * `target` is the path the .desktop Exec would have named without the sandbox.
         * Only its file name is used: a multi-call AppImage picks which component to
         * start from that name, so a sub-entry launched through its ~/.local/bin
         * symlink must keep the symlink's name. See argv0_for().
         */
        public string[]? compose(string target, string[] app_args) {
            var bwrap = AppPaths.bwrap_path;
            if (bwrap == null) {
                return null;
            }
            args.add(bwrap);
            var argv0 = argv0_for(target);

            add_namespaces();
            add_host_root();
            add_runtime_dir();
            if (!add_home()) {
                return null;
            }
            add_environment(argv0);
            add_wayland();
            add_x11();
            add_audio();
            add_gpu();
            add_camera();
            add_input();
            add_folders();
            add_buses();
            add_a11y_bus();
            add_seccomp();

            if (seccomp_fd >= 0) {
                add("--seccomp", seccomp_fd.to_string());
                data_fds.add(seccomp_fd);
            }
            // sync_fd belongs to the bus proxy; it is passed through and must survive
            // the exec, but closing it is the proxy's job - a double close could land
            // on an unrelated descriptor.
            if (sync_fd >= 0) {
                add("--sync-fd", sync_fd.to_string());
            }

            add("--argv0", argv0);
            args.add("--");
            args.add(Path.build_filename(mount_dir, "AppRun"));
            // Before the app's own arguments: a Chromium command line takes switches
            // anywhere, but an argument list ending in a URL reads better this way.
            if (needs_no_sandbox()) {
                args.add("--no-sandbox");
            }
            foreach (var arg in app_args) {
                args.add(arg);
            }

            var argv = new string[args.size + 1];
            for (int i = 0; i < args.size; i++) {
                argv[i] = args[i];
            }
            argv[args.size] = null;
            return argv;
        }

        /**
         * File descriptors that must survive the exec into bwrap. The supervisor
         * clears FD_CLOEXEC on exactly these in the forked child.
         */
        public int[] preserved_fds() {
            var list = new Gee.ArrayList<int>();
            list.add_all(data_fds);
            if (sync_fd >= 0) {
                list.add(sync_fd);
            }
            return list.to_array();
        }

        /**
         * Closes this side of every generated-content pipe. Called once bwrap has been
         * spawned; the descriptor owned by the bus proxy is left for it to close.
         */
        public void close_fds() {
            foreach (var fd in data_fds) {
                Posix.close(fd);
            }
            data_fds.clear();
        }

        /**
         * What the app sees as argv[0] and $ARGV0: the target's file name, but inside
         * the mounted AppDir.
         *
         * The file name has to survive, because a multi-call AppImage chooses which
         * component to run from it. The *directory* cannot be the real one: sharun -
         * the launcher pkgforge builds AppImages with, and so the AppRun of a large
         * share of them - resolves argv[0] to a directory and aborts with "Failed to
         * find ARG0 dir!" when that path does not exist. The launch target is either
         * the AppImage in ~/Applications or a symlink in ~/.local/bin, and neither
         * exists inside a sandbox whose home is private.
         *
         * Rooting the name at the mount point instead gives an argv[0] whose directory
         * is the AppDir, which is what an AppRun resolving it is looking for anyway,
         * and reproduces the unsandboxed behaviour: the file name decides the
         * component, and a name with no matching component falls back the same way.
         */
        private string argv0_for(string target) {
            return Path.build_filename(mount_dir, Path.get_basename(target));
        }

        /**
         * Whether this is a Chromium-based app, which has to be told not to sandbox
         * itself because it cannot.
         *
         * Chromium sandboxes its own renderers by creating a user namespace, and falls
         * back to a setuid helper binary when it cannot. Inside this sandbox both are
         * closed off - user namespaces by --disable-userns and by the seccomp filter,
         * the helper because bwrap mounts nosuid and the AppImage's copy is not
         * root-owned. Chromium's response to that is to abort with "The SUID sandbox
         * helper binary was found, but is not configured correctly", which is how
         * every Electron app that does not already pass --no-sandbox itself fails to
         * start. Verified: removing *both* the filter and --disable-userns lets it
         * through, and removing either alone does not - so there is nothing to relax
         * here short of giving up the syscall filter, which is not a trade worth
         * making for an app already confined by it.
         *
         * The renderers then run unsandboxed *within* this sandbox, which is the same
         * position flatpak's Electron apps are in without zypak: the outer sandbox is
         * the boundary that matters.
         */
        private bool needs_no_sandbox() {
            return GLib.FileUtils.test(Path.build_filename(mount_dir, "chrome-sandbox"),
                                       FileTest.EXISTS);
        }

        // ── composition ─────────────────────────────────────────────────────────

        private void add_namespaces() {
            add1("--unshare-all");
            if (manifest.network) {
                add1("--share-net");
            }
            // Belt and braces on top of --unshare-all: without a user namespace of its
            // own the app cannot restructure its mounts, so it cannot mount its way out
            // of the read-only binds this sandbox is built from.
            add1("--unshare-user");
            if (supports_flag("--disable-userns")) {
                add1("--disable-userns");
            }
            add1("--die-with-parent");
            // A new session detaches the app from the launching terminal's controlling
            // tty, which is what stops TIOCSTI-style keystroke injection back into it.
            // It also breaks job control, so a command-line app keeps its tty: the
            // seccomp filter blocks those ioctls, which covers the same ground without
            // taking Ctrl-Z away from a terminal app.
            if (!manifest.terminal) {
                add1("--new-session");
            }
            // Mandatory, not decorative: --setenv without --clearenv silently inherits
            // the whole host environment.
            add1("--clearenv");
            add("--proc", "/proc");
            add("--dev", "/dev");
            add("--tmpfs", "/tmp");
        }

        private void add_host_root() {
            add2("--ro-bind", "/usr", "/usr");
            // On merged-usr hosts these are symlinks into /usr; bwrap resolves the
            // source, so they arrive as directories, which is all anything needs.
            foreach (var dir in new string[] { "/bin", "/lib", "/lib64", "/lib32", "/sbin", "/opt", "/etc" }) {
                ro_bind_try(dir, dir);
            }
            // Device enumeration for SDL and libinput, and the two /sys paths Mesa and
            // libdrm need to map a device node to its driver. Never all of /sys.
            ro_bind_try("/run/udev/data", "/run/udev/data");
            ro_bind_try("/sys/dev/char", "/sys/dev/char");
            ro_bind_try("/sys/devices", "/sys/devices");
            add_resolv_conf();
        }

        /**
         * Makes /etc/resolv.conf resolvable, or the app has no DNS at all even with the
         * network shared.
         *
         * On most distributions that file is a symlink into /run - systemd-resolved's
         * stub, or NetworkManager's copy - and /run is not otherwise carried into the
         * sandbox, so the link dangles. Binding *onto* the symlink is not an option:
         * bwrap creates a bind destination literally, and creating a file inside the
         * read-only /etc bind fails with ENOENT. So the link's target is bound at its
         * own path, where the symlink already sitting inside /etc finds it.
         */
        private void add_resolv_conf() {
            if (!manifest.network) {
                return;
            }
            var target = SandboxConfig.canonicalize("/etc/resolv.conf");
            // A plain file arrives with the /etc bind and needs nothing.
            if (!Path.is_absolute(target) || target.has_prefix("/etc/")) {
                return;
            }
            ro_bind_try(target, target);
        }

        private void add_runtime_dir() {
            add1("--perms");
            add1("0700");
            add("--tmpfs", runtime_base);
            // The AppImage payload, mounted outside and bound at the identical path so
            // $APPDIR means the same thing on both sides.
            add2("--ro-bind", mount_dir, mount_dir);
        }

        private bool add_home() {
            if (manifest.home.strip() == "") {
                warning("Sandbox: manifest has no home path");
                return false;
            }
            if (DirUtils.create_with_parents(manifest.home, 0700) != 0) {
                warning("Sandbox: cannot create %s: %s", manifest.home, Posix.strerror(Posix.errno));
                return false;
            }
            add2("--bind", manifest.home, home);

            // Theming, read-only, on top of the private home: without these the app
            // renders with the default GTK/Qt theme, fonts and cursor while everything
            // around it does not. Legacy dotfile locations are included because plenty
            // of apps still read them, and the GNOME extensions tree because a user
            // gtk.css commonly @imports from it.
            string[] theme_paths = {
                ".config/gtk-3.0", ".config/gtk-4.0", ".config/dconf", ".config/fontconfig",
                ".config/Kvantum", ".config/qt5ct", ".config/qt6ct",
                ".local/share/icons", ".local/share/themes", ".local/share/fonts",
                ".gtkrc-2.0", ".themes", ".icons", ".fonts",
                ".local/share/gnome-shell/extensions"
            };
            foreach (var rel in theme_paths) {
                var dest = Path.build_filename(home, rel);
                ro_bind_try(SandboxConfig.canonicalize(dest), dest);
            }
            add_cache_dir();
            return true;
        }

        /**
         * A cache directory whose path means the same thing inside the sandbox and out.
         *
         * The private home is bound *over* $HOME, so every absolute path the app derives
         * from $HOME is a lie from the host's point of view: the app writes to what it
         * calls ~/.cache/<x>, the bytes land in <app>.sandbox/.cache/<x>, and anything on
         * the host told to open the first path finds nothing there. That matters because
         * apps hand such paths to the desktop over D-Bus and expect them to be opened by
         * something outside the sandbox - MPRIS "mpris:artUrl" is the case that bites
         * first, since GNOME Shell resolves it with a plain Gio.File in its own
         * namespace, so a music player's album art silently never appears.
         *
         * So the cache gets a real host path, bound at that same path here. Flatpak's
         * answer to the same problem, and for the same reason: ~/.var/app/<id> is bound
         * at its own path and XDG_CACHE_HOME points straight at it.
         *
         * Only the cache is moved. XDG_DATA_HOME and XDG_CONFIG_HOME would have to move
         * with the theming binds above, which are layered onto the private home at $HOME
         * - and a cache is disposable, so nothing has to be migrated when this changes.
         * Apps that put such files anywhere else (the data dir, $XDG_RUNTIME_DIR, /tmp)
         * are not helped by this; the real cure is not shadowing $HOME at all.
         */
        private void add_cache_dir() {
            var cache = host_cache_dir(manifest.app_id);
            if (cache == null) {
                return;
            }
            if (DirUtils.create_with_parents(cache, 0700) != 0) {
                warning("Sandbox: cannot create %s: %s", cache, Posix.strerror(Posix.errno));
                return;
            }
            add2("--bind", cache, cache);
            setenv("XDG_CACHE_HOME", cache);
        }

        /**
         * Where a sandboxed app's cache lives on the host, or null when the record has no
         * app id to key it by - in which case the app keeps the cache inside its private
         * home and only loses the path agreement above.
         *
         * Keyed on the app id rather than the record id because it is the same identity
         * the Wayland security context and the bus proxy's --own rules already use, and
         * SandboxIdentity guarantees no two records share one.
         */
        public static string? host_cache_dir(string? app_id) {
            var id = (app_id ?? "").strip();
            if (id == "") {
                return null;
            }
            return Path.build_filename(Environment.get_user_cache_dir(),
                                       DATA_DIRNAME, "sandbox", id);
        }

        private void add_environment(string argv0) {
            // A minimal PATH: the app's own bundled binaries come from $APPDIR, which
            // its AppRun prepends itself.
            setenv("PATH", "/usr/local/bin:/usr/bin:/bin");
            setenv("HOME", home);
            setenv("SHELL", "/bin/sh");
            setenv("XDG_RUNTIME_DIR", runtime_base);

            foreach (var name in new string[] {
                "USER", "LOGNAME", "LANG", "LANGUAGE", "TERM", "COLORTERM",
                "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "XDG_DATA_DIRS", "XDG_CONFIG_DIRS",
                "XCURSOR_THEME", "XCURSOR_SIZE", "GTK_THEME", "QT_QPA_PLATFORMTHEME"
            }) {
                copy_env(name);
            }
            foreach (var name in Environment.list_variables()) {
                if (name.has_prefix("LC_")) {
                    copy_env(name);
                }
            }

            // How the AppImage runtime finds itself and, for a multi-call AppImage,
            // which component to dispatch to.
            setenv("APPIMAGE", manifest.appimage);
            setenv("APPDIR", mount_dir);
            setenv("ARGV0", argv0);

            // The record's own environment variables, which the .desktop Exec line set
            // for this process and --clearenv has just thrown away.
            foreach (var entry in manifest.env) {
                var eq = entry.index_of_char('=');
                if (eq > 0) {
                    setenv(entry.substring(0, eq), entry.substring(eq + 1));
                }
            }
        }

        private void add_wayland() {
            if (wayland_socket != null) {
                // A security-context socket stands in for the compositor's own, so the
                // compositor can tell this client is sandboxed. Phase 4.
                var name = "wayland-0";
                add2("--ro-bind", wayland_socket, Path.build_filename(runtime_base, name));
                setenv("WAYLAND_DISPLAY", name);
                return;
            }

            var display = Environment.get_variable("WAYLAND_DISPLAY");
            var name = (display != null && display.strip() != "") ? display.strip() : "wayland-0";
            // Sanitize the way the compositor's own clients do: anything that is not a
            // plain "wayland-N" name, or that contains a path separator, would let the
            // variable name a socket outside the runtime directory.
            if (!name.has_prefix("wayland-") || name.contains("/")) {
                name = "wayland-0";
            }
            var socket = Path.build_filename(runtime_base, name);
            if (!GLib.FileUtils.test(socket, FileTest.EXISTS)) {
                return;
            }
            add2("--ro-bind", socket, socket);
            setenv("WAYLAND_DISPLAY", name);
        }

        private void add_x11() {
            // Always, and before any specific socket bind: a tmpfs here closes the
            // symlink-substitution race on the shared /tmp/.X11-unix directory.
            add("--tmpfs", "/tmp/.X11-unix");

            if (!manifest.x11) {
                // Stated in both directions on purpose. Leaving DISPLAY and XAUTHORITY
                // inherited but unbound is what made Electron apps pinned to X11 with
                // --ozone-platform=x11 fail with "Authorization required" and no
                // display instead of falling back to Wayland.
                return;
            }

            var display = Environment.get_variable("DISPLAY");
            if (display == null || display.strip() == "") {
                return;
            }
            display = display.strip();
            setenv("DISPLAY", display);

            // "host:N.S" and ":N.S" both split on the last colon; the screen suffix is
            // not part of the socket name.
            var number = "";
            var colon = display.last_index_of_char(':');
            if (colon >= 0) {
                number = display.substring(colon + 1);
                var dot = number.index_of_char('.');
                if (dot >= 0) {
                    number = number.substring(0, dot);
                }
                if (number != "" && number.get_char(0).isdigit()) {
                    var socket = "/tmp/.X11-unix/X%s".printf(number);
                    ro_bind_try(socket, socket);
                } else {
                    number = "";
                }
            }

            add_xauthority(number);
        }

        // Xauthority entry families. FamilyLocal covers a local connection,
        // FamilyWild an entry that applies to any host.
        private const uint16 XAUTH_FAMILY_LOCAL = 256;
        private const uint16 XAUTH_FAMILY_WILD = 65535;

        /**
         * Gives the app the X11 cookie for its own display and nothing else.
         *
         * The whole file is the wrong thing to hand over: it accumulates cookies for
         * every display and every host the user has connected to, and an X11 cookie is
         * complete control of that display. So it is parsed, filtered and passed in as
         * generated content.
         *
         * If filtering leaves nothing, the original file is bound instead. That happens
         * on a setup whose entries are written in a form this filter does not recognise,
         * and an app that cannot open its display at all is a worse outcome than the
         * phase-one behaviour.
         */
        private void add_xauthority(string display_number) {
            var xauth = Environment.get_variable("XAUTHORITY");
            if (xauth == null || xauth.strip() == "") {
                return;
            }
            var source = SandboxConfig.canonicalize(xauth.strip());
            if (!GLib.FileUtils.test(source, FileTest.EXISTS)) {
                return;
            }

            var dest = Path.build_filename(runtime_base, "Xauthority");
            var filtered = filter_xauth(source, display_number);
            if (filtered != null && filtered.length > 0) {
                var fd = data_fd_bytes(filtered);
                if (fd >= 0) {
                    add1("--perms");
                    add1("0600");
                    add2("--ro-bind-data", fd.to_string(), dest);
                    setenv("XAUTHORITY", dest);
                    return;
                }
            }

            debug("Sandbox: could not filter %s, binding it whole", source);
            add2("--ro-bind", source, dest);
            setenv("XAUTHORITY", dest);
        }

        /**
         * Rewrites an Xauthority file down to the entries that belong to this display
         * on this machine. Returns null when nothing survives.
         *
         * The format is a sequence of records, each five big-endian 16-bit lengths with
         * their bytes: family, address, display number, authorization name, and the
         * cookie itself.
         *
         * An entry with an empty display number is kept whatever display was asked for.
         * That is not laxness: mutter's Xwayland cookie file - the file in front of most
         * users of this program - writes its entries with no number at all, and
         * insisting on a match would leave every GNOME Wayland session unable to start
         * an X11 app.
         */
        private static uint8[]? filter_xauth(string path, string display_number) {
            uint8[] contents;
            try {
                if (!File.new_for_path(path).load_contents(null, out contents, null)) {
                    return null;
                }
            } catch (Error e) {
                debug("Sandbox: cannot read %s: %s", path, e.message);
                return null;
            }

            // FamilyLocal addresses are rewritten to this host's name, so an entry
            // recorded under an older hostname still matches inside the sandbox.
            var nodename = Environment.get_host_name();
            var output = new ByteArray();
            int offset = 0;
            int kept = 0;

            while (offset + 2 <= contents.length) {
                uint16 family = 0;
                uint8[] address = new uint8[0];
                uint8[] number = new uint8[0];
                uint8[] name = new uint8[0];
                uint8[] data = new uint8[0];
                if (!read_u16(contents, ref offset, out family)
                    || !read_block(contents, ref offset, out address)
                    || !read_block(contents, ref offset, out number)
                    || !read_block(contents, ref offset, out name)
                    || !read_block(contents, ref offset, out data)) {
                    break;
                }

                if (family != XAUTH_FAMILY_LOCAL && family != XAUTH_FAMILY_WILD) {
                    continue;  // another host's cookie
                }
                if (number.length > 0 && bytes_to_string(number) != display_number) {
                    continue;  // another display's cookie
                }
                if (family == XAUTH_FAMILY_LOCAL) {
                    address = nodename.data;
                }

                write_u16(output, family);
                write_block(output, address);
                write_block(output, number);
                write_block(output, name);
                write_block(output, data);
                kept++;
            }

            if (kept == 0) {
                return null;
            }
            var result = new uint8[output.len];
            Memory.copy(result, output.data, output.len);
            return result;
        }

        private static bool read_u16(uint8[] buffer, ref int offset, out uint16 value) {
            value = 0;
            if (offset + 2 > buffer.length) {
                return false;
            }
            value = (uint16) ((buffer[offset] << 8) | buffer[offset + 1]);
            offset += 2;
            return true;
        }

        private static bool read_block(uint8[] buffer, ref int offset, out uint8[] block) {
            block = new uint8[0];
            uint16 length;
            if (!read_u16(buffer, ref offset, out length)) {
                return false;
            }
            if (offset + length > buffer.length) {
                return false;
            }
            block = new uint8[length];
            for (int i = 0; i < length; i++) {
                block[i] = buffer[offset + i];
            }
            offset += length;
            return true;
        }

        private static void write_u16(ByteArray output, uint16 value) {
            uint8[] pair = { (uint8) (value >> 8), (uint8) (value & 0xff) };
            output.append(pair);
        }

        private static void write_block(ByteArray output, uint8[] block) {
            write_u16(output, (uint16) block.length);
            if (block.length > 0) {
                output.append(block);
            }
        }

        private static string bytes_to_string(uint8[] bytes) {
            var builder = new StringBuilder();
            foreach (var byte in bytes) {
                builder.append_c((char) byte);
            }
            return builder.str;
        }

        private void add_audio() {
            if (!manifest.audio) {
                return;
            }
            var pipewire = Path.build_filename(runtime_base, "pipewire-0");
            ro_bind_try(pipewire, pipewire);
            var pulse = Path.build_filename(runtime_base, "pulse", "native");
            ro_bind_try(pulse, pulse);

            // A read-only bind of a socket is still connectable, so this costs nothing.
            //
            // enable-shm=no matters twice: shared memory would carry data straight
            // across the IPC namespace the sandbox just created, and it is the surface
            // behind CVE-2026-5674, where PipeWire's PulseAudio compatibility socket
            // could be talked into loading a module and running code outside the
            // sandbox. The config lives in the runtime tmpfs rather than at
            // /etc/pulse/client.conf: /etc is bound read-only, so creating a file
            // there fails outright on any host without that file already present.
            var client_conf = Path.build_filename(runtime_base, "pulse-client.conf");
            var fd = data_fd("enable-shm=no\n");
            if (fd >= 0) {
                add2("--ro-bind-data", fd.to_string(), client_conf);
                setenv("PULSE_CLIENTCONFIG", client_conf);
            }

            dev_bind_try("/dev/snd", "/dev/snd");
        }

        private void add_gpu() {
            if (!manifest.gpu) {
                return;
            }
            // The node list flatpak grants for --device=dri, which is the only set
            // known to cover Intel, AMD, NVIDIA, Mali and ROCm without also handing
            // over unrelated hardware.
            foreach (var node in new string[] {
                "/dev/dri", "/dev/udmabuf",
                "/dev/mali", "/dev/mali0", "/dev/umplock",
                "/dev/nvidiactl", "/dev/nvidia-modeset",
                "/dev/nvidia-uvm", "/dev/nvidia-uvm-tools",
                "/dev/kfd", "/dev/ntsync"
            }) {
                dev_bind_try(node, node);
            }
            // Per-GPU NVIDIA nodes, enumerated rather than spelled out 0..19.
            foreach (var node in list_dev_nodes("nvidia")) {
                // "nvidia-modeset" and friends are handled above; only nvidiaN here.
                var suffix = node.substring("/dev/nvidia".length);
                if (suffix != "" && suffix.get_char(0).isdigit()) {
                    dev_bind_try(node, node);
                }
            }
        }

        private void add_camera() {
            if (!manifest.camera) {
                return;
            }
            dev_bind_try("/dev/v4l", "/dev/v4l");
            foreach (var node in list_dev_nodes("video")) {
                dev_bind_try(node, node);
            }
            foreach (var node in list_dev_nodes("media")) {
                dev_bind_try(node, node);
            }
            ro_bind_try("/sys/class/video4linux", "/sys/class/video4linux");
            ro_bind_try("/sys/bus/media", "/sys/bus/media");
        }

        private void add_input() {
            if (!manifest.input) {
                return;
            }
            // /dev/input carries every input device, keyboards and mice included, so
            // this is a keylogger grant and is off by default. /dev/hidraw* is left out
            // entirely for the same reason with none of the gamepad benefit.
            dev_bind_try("/dev/input", "/dev/input");
            ro_bind_try("/sys/class/input", "/sys/class/input");
        }

        private void add_folders() {
            foreach (var name in manifest.xdg_dirs) {
                string requested;
                var dir = xdg_dir_path(name.strip(), out requested);
                if (dir == null) {
                    continue;
                }
                add2("--bind-try", dir, dir);
                add_folder_alias("--bind-try", requested, dir);
            }

            foreach (var entry in manifest.extra_dirs) {
                if (entry.strip() == "") {
                    continue;
                }
                var trimmed = entry.strip();
                var writable = trimmed.has_suffix(":rw");
                var requested = writable ? trimmed.substring(0, trimmed.length - 3) : trimmed;
                var path = SandboxConfig.canonicalize(requested);
                var flag = writable ? "--bind-try" : "--ro-bind-try";
                // "-try" so a folder the user has since deleted degrades to "the app
                // cannot see it" rather than "the app will not start".
                add2(flag, path, path);
                add_folder_alias(flag, requested, path);
            }
        }

        /**
         * Binds a granted folder a second time, at the path it was named by, when that
         * name reached it through a symlink.
         *
         * A grant is always mounted at its canonicalized path, because that is the only
         * form bwrap can mount at all. But it is not the form anything asks for: with
         * ~/Music a symlink to ~/Nextcloud/Music - a Nextcloud, Syncthing or
         * separate-partition setup, so not a rare one - the app asks GLib for the music
         * directory, gets /home/<user>/Music, and finds nothing there, because the
         * private home contains no such symlink. The folder is mounted and unreachable.
         *
         * A --symlink would reproduce the host exactly, but bwrap creates it inside the
         * real private home and dies outright if anything already occupies the name,
         * which an app that made the directory itself before the grant existed will
         * have. A second bind has neither problem: it mounts over an existing directory
         * and creates a missing one.
         */
        private void add_folder_alias(string flag, string requested, string resolved) {
            if (requested == resolved || !Path.is_absolute(requested)) {
                return;
            }
            // Never over the private home itself, which would undo it entirely.
            if (requested == home) {
                return;
            }
            add2(flag, resolved, requested);
        }

        private void add_buses() {
            if (manifest.full_session_bus) {
                // No proxy: the real socket, and with it every desktop service. The user
                // asked for this explicitly and the UI says what it costs.
                var socket = host_session_bus_socket();
                if (socket != null) {
                    var dest = Path.build_filename(runtime_base, "bus");
                    add2("--ro-bind", socket, dest);
                    setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=%s".printf(dest));
                }
                return;
            }

            if (session_bus_socket != null) {
                var dest = Path.build_filename(runtime_base, "bus");
                add2("--ro-bind", session_bus_socket, dest);
                setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=%s".printf(dest));
            }
            if (system_bus_socket != null) {
                // Both spellings: some apps have /var/run baked in.
                add2("--ro-bind", system_bus_socket, "/run/dbus/system_bus_socket");
                add2("--ro-bind", system_bus_socket, "/var/run/dbus/system_bus_socket");
            }
        }

        // Where the accessibility bus socket lands inside the sandbox. Flatpak's path,
        // so that anything already taught to expect it finds it.
        private const string A11Y_BUS_PATH = "/run/flatpak/at-spi-bus";

        /**
         * The accessibility bus, which is a bus of its own and needs a socket and an
         * address of its own.
         *
         * A toolkit finds it by asking the session bus for the address and connecting to
         * whatever path comes back - a host path, which is not the sandbox's to reach.
         * Both ways of failing at that were reported: on a filtered bus the lookup is
         * refused outright ("ServiceUnknown", because org.a11y.Bus is not in the rules),
         * and on a full session bus the lookup succeeds and hands back a path with
         * nothing bound behind it ("Could not connect: No such file or directory").
         *
         * So the address is resolved outside, the socket bound at a fixed path, and
         * AT_SPI_BUS_ADDRESS set - which every toolkit checks before doing the lookup,
         * so the lookup never happens. --clearenv means it has to be set explicitly.
         */
        private void add_a11y_bus() {
            if (a11y_bus_socket == null) {
                return;
            }
            add2("--ro-bind", a11y_bus_socket, A11Y_BUS_PATH);
            setenv("AT_SPI_BUS_ADDRESS", "unix:path=%s".printf(A11Y_BUS_PATH));
        }

        /**
         * Installs the seccomp filter, unless the caller supplied one already.
         *
         * A build without libseccomp gets no filter. That is a weaker sandbox, not a
         * broken one - the mount and user-namespace routes are already closed by
         * --unshare-user and --disable-userns - so it is logged rather than refused.
         */
        private void add_seccomp() {
            if (seccomp_fd >= 0) {
                return;
            }
            var fd = Seccomp.build_fd(manifest.bluetooth);
            if (fd < 0) {
                debug("Sandbox: no seccomp filter available; syscall filtering is off");
                return;
            }
            seccomp_fd = fd;
        }

        // ── helpers ─────────────────────────────────────────────────────────────

        private void add1(string a) {
            args.add(a);
        }

        private void add(string a, string b) {
            args.add(a);
            args.add(b);
        }

        private void add2(string a, string b, string c) {
            args.add(a);
            args.add(b);
            args.add(c);
        }

        private void ro_bind_try(string src, string dest) {
            add2("--ro-bind-try", src, dest);
        }

        private void dev_bind_try(string src, string dest) {
            add2("--dev-bind-try", src, dest);
        }

        private void setenv(string name, string value) {
            add2("--setenv", name, value);
        }

        private void copy_env(string name) {
            var value = Environment.get_variable(name);
            if (value != null) {
                setenv(name, value);
            }
        }

        /**
         * Hands `content` to bwrap through a pipe and returns the read end's number,
         * remembering it so close_fds() can clean up.
         */
        private int data_fd(string content) {
            return data_fd_bytes(content.data);
        }

        private int data_fd_bytes(uint8[] bytes) {
            var fd = content_fd(bytes);
            if (fd >= 0) {
                data_fds.add(fd);
            }
            return fd;
        }

        /**
         * Puts `bytes` in a pipe and returns the read end's number, for passing to a
         * child that expects to read a generated file from a numbered descriptor -
         * bwrap's --ro-bind-data, and xdg-dbus-proxy's --args.
         *
         * Takes bytes rather than a string because the proxy's argument list is
         * NUL-separated, and a Vala string ends at its first NUL.
         *
         * Everything passed this way is a few hundred bytes at most, comfortably inside
         * the pipe buffer, so writing it here and closing the write end cannot block and
         * needs no helper thread. The caller owns the returned descriptor.
         */
        public static int content_fd(uint8[] bytes) {
            int[] fds = new int[2];
            if (Posix.pipe(fds) != 0) {
                warning("Sandbox: cannot create data pipe: %s", Posix.strerror(Posix.errno));
                return -1;
            }
            ssize_t written = 0;
            while (written < bytes.length) {
                var n = Posix.write(fds[1], (void*) ((uint8*) bytes + written), bytes.length - written);
                if (n < 0) {
                    if (Posix.errno == Posix.EINTR) {
                        continue;
                    }
                    warning("Sandbox: cannot write sandbox data pipe: %s", Posix.strerror(Posix.errno));
                    Posix.close(fds[0]);
                    Posix.close(fds[1]);
                    return -1;
                }
                written += n;
            }
            Posix.close(fds[1]);
            return fds[0];
        }

        /**
         * Existing /dev nodes whose name starts with `prefix`. Enumerated rather than
         * guessed at so the command line only names hardware that is actually present.
         */
        private static Gee.ArrayList<string> list_dev_nodes(string prefix) {
            var found = new Gee.ArrayList<string>();
            try {
                var dir = Dir.open("/dev");
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_prefix(prefix)) {
                        found.add(Path.build_filename("/dev", name));
                    }
                }
            } catch (Error e) {
                debug("Sandbox: cannot scan /dev: %s", e.message);
            }
            return found;
        }

        /**
         * The real path of one of the six offered XDG user directories, or null when it
         * is unset, missing, or resolves to the home directory itself - binding $HOME
         * would undo the private home the sandbox exists to provide.
         *
         * `requested` returns the unresolved path, which is what the app will ask for.
         * See add_folder_alias().
         */
        public static string? xdg_dir_path(string name, out string requested) {
            requested = "";
            UserDirectory which;
            switch (name) {
                case "downloads": which = UserDirectory.DOWNLOAD; break;
                case "documents": which = UserDirectory.DOCUMENTS; break;
                case "desktop":   which = UserDirectory.DESKTOP; break;
                case "pictures":  which = UserDirectory.PICTURES; break;
                case "videos":    which = UserDirectory.VIDEOS; break;
                case "music":     which = UserDirectory.MUSIC; break;
                default:
                    debug("Sandbox: unknown XDG directory \"%s\"", name);
                    return null;
            }
            var dir = Environment.get_user_special_dir(which);
            if (dir == null || dir.strip() == "") {
                return null;
            }
            var resolved = SandboxConfig.canonicalize(dir);
            if (resolved == Environment.get_home_dir() || !GLib.FileUtils.test(resolved, FileTest.IS_DIR)) {
                return null;
            }
            requested = dir;
            return resolved;
        }

        /**
         * The host session bus socket, from DBUS_SESSION_BUS_ADDRESS. Returns null for
         * an abstract-socket address, which cannot be bind-mounted at all - those are
         * reached through the network namespace instead, and there is nothing to do.
         */
        public static string? host_session_bus_socket() {
            var address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
            if (address == null || address.strip() == "") {
                var fallback = Path.build_filename(AppPaths.sandbox_runtime_base, "bus");
                return GLib.FileUtils.test(fallback, FileTest.EXISTS) ? fallback : null;
            }
            var socket = socket_path_in(address);
            if (socket == null) {
                debug("Sandbox: no bindable session bus socket in DBUS_SESSION_BUS_ADDRESS");
            }
            return socket;
        }

        /**
         * The socket path named by a D-Bus address, or null when it names none. An
         * abstract socket has no path and cannot be bind-mounted at all.
         */
        public static string? socket_path_in(string address) {
            foreach (var part in address.strip().split(",")) {
                var field = part.strip();
                // "unix:path=/run/user/1000/bus" - the only form that can be bound.
                var index = field.index_of("path=");
                if (index >= 0) {
                    var path = field.substring(index + "path=".length);
                    if (path != "" && GLib.FileUtils.test(path, FileTest.EXISTS)) {
                        return path;
                    }
                }
            }
            return null;
        }

        /**
         * Whether the installed bwrap understands `flag`. Only used for options added
         * after the oldest bwrap still in wide use, so that an older one degrades to a
         * slightly weaker sandbox instead of refusing to start the app.
         */
        private static bool supports_flag(string flag) {
            if (cached_help == null) {
                var bwrap = AppPaths.bwrap_path;
                cached_help = "";
                if (bwrap != null) {
                    try {
                        string out_str, err_str;
                        int status;
                        Process.spawn_sync(null, new string[] { bwrap, "--help" }, null,
                            SpawnFlags.SEARCH_PATH, null, out out_str, out err_str, out status);
                        cached_help = "%s%s".printf(out_str ?? "", err_str ?? "");
                    } catch (SpawnError e) {
                        debug("Sandbox: cannot query bwrap options: %s", e.message);
                    }
                }
            }
            return cached_help.contains(flag);
        }
    }
}
