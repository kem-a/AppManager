namespace AppManager.Core {
    /**
     * Implements the "sandbox-run" CLI verb that generated .desktop Exec lines and
     * ~/.local/bin wrappers use to launch a sandboxed app:
     *
     *   app-manager sandbox-run --id=<record-id> --target=<path> [--env=NAME=VALUE] [-- <app args>]
     *
     * Routing every launch through one verb keeps the Exec lines short and means a
     * permission change rewrites a single manifest instead of the primary Exec, every
     * desktop action and every sub-entry.
     *
     * --target is the path the Exec would have held without the sandbox: the AppImage
     * for the main entry, or the ~/.local/bin symlink for a sub-entry of a
     * multi-component AppImage. It is never resolved - it is passed on as argv[0] and
     * $ARGV0, which is what the AppImage runtime dispatches components on, so the
     * component a sub-entry asked for is the one that starts.
     *
     * This is a supervisor, not a one-shot exec: it owns the AppImage's FUSE mount for
     * the app's lifetime and, once a bus proxy is involved, a second child process
     * whose life has to be tied to the app's. Staying in the middle also means the
     * app's stdio descriptors are the ones this process was given, so a command-line
     * app in a pipeline behaves normally.
     *
     * This runs before GApplication is constructed (see main.vala): AppManager
     * registers as a single instance, so a normal command line would be forwarded to
     * the already-running GUI and this process would exit immediately, leaving the
     * app it launched with no parent to be tied to.
     *
     * Exit codes: 2 for a malformed invocation, 3 when the app is configured to be
     * sandboxed but cannot be, 127 when exec itself fails; otherwise the app's own
     * status, or 128+signal when it was killed.
     */
    public class SandboxLauncher {
        private static Posix.pid_t supervised_pid = 0;

        /**
         * Parses the sandbox-run argument list, starts the app and waits for it.
         */
        public static int run(string[] args) {
            restore_launch_environment();
            string? record_id = null;
            string? target = null;
            var app_args = new Gee.ArrayList<string>();
            var env_vars = new Gee.ArrayList<string>();
            bool after_separator = false;

            // args[0] is the binary, args[1] is the verb itself.
            for (int i = 2; i < args.length; i++) {
                var arg = args[i];
                if (after_separator) {
                    app_args.add(arg);
                    continue;
                }
                if (arg == "--") {
                    after_separator = true;
                } else if (arg.has_prefix("--id=")) {
                    record_id = arg.substring("--id=".length);
                } else if (arg.has_prefix("--target=")) {
                    target = arg.substring("--target=".length);
                } else if (arg.has_prefix("--env=")) {
                    var variable = arg.substring("--env=".length);
                    if (variable.index_of_char('=') <= 0) {
                        printerr("%s: --env requires NAME=VALUE\n", SANDBOX_RUN_VERB);
                        return 2;
                    }
                    env_vars.add(variable);
                } else {
                    // Tolerate a caller that forgot the separator.
                    app_args.add(arg);
                }
            }

            if (target == null || target.strip() == "") {
                printerr("%s: --target is required\n", SANDBOX_RUN_VERB);
                return 2;
            }
            target = target.strip();

            var id = (record_id != null) ? record_id.strip() : "";
            if (id != "" && !valid_record_id(id)) {
                printerr("%s: refusing suspicious record id \"%s\"\n", SANDBOX_RUN_VERB, id);
                return 2;
            }

            var manifest = (id != "") ? SandboxManifest.read(id) : null;

            // No manifest on disk means this app is not sandboxed any more and only its
            // Exec line is stale - launching it plainly is what the user asked for. An
            // unreadable one is a different story: the user believes this app is
            // contained, so refuse rather than quietly running it unconfined.
            if (manifest == null) {
                if (id != "" && SandboxManifest.exists(id)) {
                    printerr("%s: %s has an unreadable sandbox manifest; refusing to launch it unconfined.\n",
                        SANDBOX_RUN_VERB, target);
                    return 3;
                }
                foreach (var variable in env_vars) {
                    var eq = variable.index_of_char('=');
                    Environment.set_variable(variable.substring(0, eq), variable.substring(eq + 1), true);
                }
                return exec_plain(target, app_args);
            }

            if (AppPaths.bwrap_path == null) {
                printerr("%s: %s is configured to run sandboxed, but bubblewrap (bwrap) was not found.\n",
                    SANDBOX_RUN_VERB, target);
                printerr("%s: install the bubblewrap package, or turn the sandbox off for this app.\n",
                    SANDBOX_RUN_VERB);
                return 3;
            }

            // Desktop actions and sub-entries can carry their own bundled env prefix.
            // Pass those values across bubblewrap's --clearenv, after the registry defaults.
            var merged_env = new Gee.ArrayList<string>();
            merged_env.add_all_array(manifest.env);
            merged_env.add_all(env_vars);
            manifest.env = merged_env.to_array();
            return launch(manifest, id, target, app_args);
        }

        private static void restore_launch_environment() {
            // GTK's library constructor stashes and unsets these before main(),
            // even though sandbox-run never initializes GTK. They belong to the
            // child app, not this supervisor. Linux keeps the original exec-time
            // environment in /proc/self/environ, including values since unset.
            // Recover only the launch tokens, also for the stale-manifest fallback.
            try {
                uint8[] contents;
                GLib.FileUtils.get_data("/proc/self/environ", out contents);
                int start = 0;
                for (int i = 0; i < contents.length; i++) {
                    if (contents[i] != '\0') continue;
                    string entry = (string) contents[start:i];
                    start = i + 1;
                    foreach (var name in new string[] { "DESKTOP_STARTUP_ID", "XDG_ACTIVATION_TOKEN" }) {
                        if (entry.has_prefix(name + "=") && Environment.get_variable(name) == null) {
                            Environment.set_variable(name, entry.substring(name.length + 1), true);
                        }
                    }
                }
            } catch (FileError e) {
                debug("Sandbox: cannot recover startup notification tokens: %s", e.message);
            }
        }

        /**
         * Mounts the AppImage, builds the sandbox and supervises it. Everything
         * acquired here is released before returning, whichever way it goes.
         */
        private static int launch(SandboxManifest manifest, string record_id,
                                  string target, Gee.ArrayList<string> app_args) {
            var appimage = manifest.appimage.strip();
            if (appimage == "") {
                printerr("%s: sandbox manifest for %s names no AppImage\n", SANDBOX_RUN_VERB, target);
                return 3;
            }

            // Names the bus proxy's sockets and the Wayland security-context socket, so
            // two concurrent launches of the same app do not collide.
            var instance_id = new_instance_id();

            var mount = SandboxMount.acquire(appimage, record_id);
            if (mount == null) {
                printerr("%s: %s is configured to run sandboxed, but its payload could not be mounted.\n",
                    SANDBOX_RUN_VERB, appimage);
                printerr("%s: install squashfuse (or the dwarfs FUSE driver), or turn the sandbox off for this app.\n",
                    SANDBOX_RUN_VERB);
                return 3;
            }

            SandboxDbusProxy? proxy = null;
            // An app sharing the host's pids claims tray names with its real pid, which
            // exists only once bwrap has forked. Its proxy starts while bwrap waits.
            bool deferred = manifest.share_processes;
            if (manifest.needs_bus_proxy()) {
                if (AppPaths.xdg_dbus_proxy_path == null) {
                    printerr("%s: %s is configured to reach desktop services through a filtered bus, but xdg-dbus-proxy was not found.\n",
                        SANDBOX_RUN_VERB, target);
                    printerr("%s: install the xdg-dbus-proxy package, or turn the sandbox off for this app.\n",
                        SANDBOX_RUN_VERB);
                    mount.release();
                    return 3;
                }
                proxy = deferred ? SandboxDbusProxy.prepare(manifest, instance_id, true)
                                 : SandboxDbusProxy.start(manifest, instance_id);
                if (proxy == null) {
                    printerr("%s: could not start the filtered bus for %s; refusing to launch it with an open bus.\n",
                        SANDBOX_RUN_VERB, target);
                    mount.release();
                    return 3;
                }
            }

            var builder = new SandboxBwrap(manifest, mount.mount_dir);
            if (proxy != null) {
                builder.session_bus_socket = proxy.session_socket;
                builder.system_bus_socket = proxy.system_socket;
                builder.a11y_bus_socket = proxy.a11y_socket;
                // Deferred: --sync-fd makes bwrap fork a holder after --block-fd, so its
                // child-pid is not the app's pid. This process holds the pipe instead.
                if (!deferred) {
                    builder.sync_fd = proxy.sync_read_fd;
                }
                builder.bus_socket_dir = proxy.socket_dir;
            }
            deferred = proxy != null && deferred;
            if (manifest.full_session_bus && manifest.accessibility) {
                // No proxy to filter it, so the real accessibility socket - consistent
                // with the session bus the user has already opened up here.
                builder.a11y_bus_socket = SandboxDbusProxy.host_a11y_socket();
            }

            // Ask the compositor to treat this client as sandboxed. Its own socket is
            // bound only when the compositor has no such notion; when it does and the
            // handshake fails, Wayland is refused rather than handed over unrestricted.
            var wayland = SandboxBwrap.use_wayland(manifest) ? SandboxWaylandContext.create(manifest, instance_id) : null;
            if (wayland != null) {
                if (wayland.failed) {
                    printerr("%s: the compositor offers to sandbox this app's display connection, but setting that up failed; refusing to hand it an unrestricted one.\n",
                        SANDBOX_RUN_VERB);
                    wayland.cleanup();
                    if (proxy != null) {
                        proxy.stop();
                    }
                    mount.release();
                    return 3;
                }
                builder.wayland_socket = wayland.socket_path;
            }

            var link_pipe = start_link_opener(instance_id);
            builder.link_pipe = link_pipe;

            // A deferred proxy needs bwrap to report the app's pid, then wait.
            int[] info = { -1, -1 };
            int[] block = { -1, -1 };
            if (deferred && open_pipe(info) && open_pipe(block)) {
                builder.info_fd = info[1];
                builder.block_fd = block[0];
            }

            int status;
            var argv = (!deferred || builder.block_fd >= 0) ? builder.compose(target, app_args.to_array()) : null;
            if (argv == null) {
                printerr("%s: could not build the sandbox for %s\n", SANDBOX_RUN_VERB, target);
                status = 3;
            } else {
                var pid = spawn(argv, builder.preserved_fds());
                // Everything the child needed by descriptor number is now the child's.
                // The sync pipe especially: while this process still holds a copy, the
                // proxy cannot notice the app exiting.
                builder.close_fds();
                bool released = true;
                if (deferred) {
                    close_fd(ref info[1]);
                    close_fd(ref block[0]);
                    released = pid > 0 && release_with_proxy(proxy, pid, info[0], block[1]);
                }
                if (proxy != null && !deferred) {
                    proxy.detach_sync_fd();
                }
                status = (pid > 0) ? wait_for(pid) : 3;
                if (!released) {
                    printerr("%s: could not start the filtered bus for %s; refusing to launch it with an open bus.\n",
                        SANDBOX_RUN_VERB, target);
                    status = 3;
                }
            }
            foreach (var fd in new int[] { info[0], info[1], block[0], block[1] }) {
                if (fd >= 0) {
                    Posix.close(fd);
                }
            }

            if (proxy != null) {
                proxy.stop();
            }
            if (wayland != null) {
                wayland.cleanup();
            }
            if (link_pipe != null) {
                GLib.FileUtils.unlink(link_pipe);
            }
            mount.release();
            return status;
        }

        // A longer URL is refused rather than truncated into a different one.
        private const int MAX_LINK_LENGTH = 8192;

        /**
         * Opens the web links a sandboxed app asks for in the host's default browser,
         * which the sandbox cannot reach. The app writes one URL per line to a FIFO
         * bound into the sandbox (SandboxBwrap.add_link_opener) and a thread here
         * reads them. Only http(s) is opened, and the check runs out here, where the
         * app cannot change it. Returns the FIFO's host path, or null.
         */
        private static string? start_link_opener(string instance_id) {
            var dir = Path.build_filename(AppPaths.sandbox_runtime_dir, "open-uri");
            DirUtils.create_with_parents(dir, 0700);
            var path = Path.build_filename(dir, instance_id);
            if (Posix.mkfifo(path, 0600) != 0) {
                warning("Sandbox: cannot create %s: %s", path, Posix.strerror(Posix.errno));
                return null;
            }
            // Read-write, so reads block instead of hitting EOF while no writer is open.
            int fd = Posix.open(path, Posix.O_RDWR | Posix.O_CLOEXEC);
            if (fd < 0) {
                warning("Sandbox: cannot open %s: %s", path, Posix.strerror(Posix.errno));
                GLib.FileUtils.unlink(path);
                return null;
            }
            new Thread<void>("open-uri", () => { read_links(fd); });
            return path;
        }

        private static void read_links(int fd) {
            var line = new StringBuilder();
            var buffer = new uint8[4096];
            while (true) {
                var n = Posix.read(fd, (void*) buffer, buffer.length);
                if (n < 0 && Posix.errno == Posix.EINTR) {
                    continue;
                }
                if (n <= 0) {
                    return;
                }
                for (int i = 0; i < n; i++) {
                    if (buffer[i] == (uint8) '\n') {
                        open_link(line.str);
                        line.truncate(0);
                    } else if (line.len <= MAX_LINK_LENGTH) {
                        line.append_c((char) buffer[i]);
                    }
                }
            }
        }

        private static void open_link(string text) {
            try {
                if (text.length > MAX_LINK_LENGTH) {
                    throw new UriError.FAILED("too long");
                }
                var uri = Uri.parse(text, UriFlags.NONE);
                var scheme = uri.get_scheme().ascii_down();
                if ((scheme != "http" && scheme != "https") || (uri.get_host() ?? "") == "") {
                    throw new UriError.BAD_SCHEME("only http and https links are opened");
                }
                AppInfo.launch_default_for_uri(uri.to_string(), null);
            } catch (Error e) {
                warning("Sandbox: not opening link %s: %s", text, e.message);
            }
        }

        /**
         * Forks and execs `argv` with `keep_fds` surviving the exec. Returns the child
         * pid, or -1 on failure.
         */
        private static Posix.pid_t spawn(string[] argv, int[] keep_fds) {
            var pid = Posix.fork();
            if (pid < 0) {
                printerr("%s: fork failed: %s\n", SANDBOX_RUN_VERB, Posix.strerror(Posix.errno));
                return -1;
            }

            if (pid == 0) {
                // The generated-content pipes and the sync fd are named by number on
                // the command line, so they have to survive the exec.
                foreach (var fd in keep_fds) {
                    int flags = Posix.fcntl(fd, Posix.F_GETFD);
                    if (flags >= 0) {
                        Posix.fcntl(fd, Posix.F_SETFD, flags & ~Posix.FD_CLOEXEC);
                    }
                }
                Posix.execvp(argv[0], argv);
                Posix.perror(SANDBOX_RUN_VERB);
                Posix._exit(127);
            }

            supervised_pid = pid;
            // Pass on the signals a session manager or a shell would send, so that
            // logging out or Ctrl-C in a terminal closes the app rather than orphaning
            // it behind a supervisor that ignored the request.
            Posix.signal(Posix.Signal.TERM, forward_signal);
            Posix.signal(Posix.Signal.INT, forward_signal);
            Posix.signal(Posix.Signal.HUP, forward_signal);
            return pid;
        }

        /**
         * Reads the app's host pid from the waiting bwrap, starts the proxy with it and
         * lets the app run. On failure the sandbox is killed rather than released:
         * bwrap starts the app on a closed block pipe too, and it would find no bus.
         */
        private static bool release_with_proxy(SandboxDbusProxy proxy, Posix.pid_t bwrap,
                                               int info_read, int block_write) {
            var app_pid = read_child_pid(info_read);
            if (app_pid > 0 && proxy.launch(app_pid)) {
                uint8[] go = { 1 };
                if (Posix.write(block_write, go, 1) == 1) {
                    return true;
                }
            }
            if (app_pid > 0) {
                Posix.kill(app_pid, Posix.Signal.KILL);
            }
            Posix.kill(bwrap, Posix.Signal.KILL);
            return false;
        }

        // bwrap's --info-fd output: a JSON object with "child-pid", then EOF.
        private static int read_child_pid(int fd) {
            var data = new ByteArray();
            var buffer = new uint8[512];
            ssize_t n;
            while ((n = Posix.read(fd, buffer, buffer.length)) != 0) {
                if (n < 0) {
                    if (Posix.errno == Posix.EINTR) {
                        continue;
                    }
                    break;
                }
                data.append(buffer[0:n]);
            }
            try {
                var parser = new Json.Parser();
                parser.load_from_data((string) data.data, (ssize_t) data.len);
                var root = parser.get_root();
                if (root != null && root.get_node_type() == Json.NodeType.OBJECT
                    && root.get_object().has_member("child-pid")) {
                    return (int) root.get_object().get_int_member("child-pid");
                }
            } catch (Error e) {
                warning("Sandbox: unreadable bwrap info: %s", e.message);
            }
            return -1;
        }

        private static bool open_pipe(int[] fds) {
            if (Posix.pipe(fds) != 0) {
                warning("Sandbox: cannot create a pipe: %s", Posix.strerror(Posix.errno));
                return false;
            }
            SandboxDbusProxy.set_cloexec(fds[0]);
            SandboxDbusProxy.set_cloexec(fds[1]);
            return true;
        }

        private static void close_fd(ref int fd) {
            if (fd >= 0) {
                Posix.close(fd);
                fd = -1;
            }
        }

        /**
         * Waits for the sandbox and returns the status to exit with.
         */
        private static int wait_for(Posix.pid_t pid) {
            int wait_status = 0;
            while (Posix.waitpid(pid, out wait_status, 0) < 0) {
                if (Posix.errno == Posix.EINTR) {
                    continue;
                }
                printerr("%s: waiting for the sandbox failed: %s\n",
                    SANDBOX_RUN_VERB, Posix.strerror(Posix.errno));
                return 3;
            }
            supervised_pid = 0;

            // Linux wait status: the low 7 bits hold the signal that killed the child,
            // the next 8 its exit code. Reproduced here because Vala's POSIX binding
            // exposes no WIFEXITED/WEXITSTATUS.
            int signum = wait_status & 0x7f;
            if (signum != 0) {
                return 128 + signum;
            }
            return (wait_status >> 8) & 0xff;
        }

        private static void forward_signal(int sig) {
            if (supervised_pid > 0) {
                Posix.kill(supervised_pid, sig);
            }
        }

        /**
         * Replaces this process with the app itself, unsandboxed. Only reached when the
         * record has no manifest, i.e. the sandbox was turned off.
         */
        private static int exec_plain(string target, Gee.ArrayList<string> app_args) {
            var argv = new string[app_args.size + 2];
            argv[0] = target;
            for (int i = 0; i < app_args.size; i++) {
                argv[i + 1] = app_args[i];
            }
            argv[app_args.size + 1] = null;

            Posix.execvp(target, argv);
            printerr("%s: failed to exec %s: %s\n",
                SANDBOX_RUN_VERB, target, Posix.strerror(Posix.errno));
            return 127;
        }

        /**
         * A name for this one launch. It names the bus proxy's socket files and the
         * Wayland security-context socket, so it only has to be unique among concurrent
         * launches.
         */
        private static string new_instance_id() {
            return "%u".printf(Random.next_int());
        }

        /**
         * Record ids are checksums, optionally with a "-N" side-by-side suffix. Anything
         * else is refused rather than turned into a path: the id becomes a filename.
         */
        private static bool valid_record_id(string id) {
            if (id.length > 128) {
                return false;
            }
            for (int i = 0; i < id.length; i++) {
                var c = id[i];
                bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '-' || c == '_';
                if (!ok) {
                    return false;
                }
            }
            return true;
        }
    }
}
