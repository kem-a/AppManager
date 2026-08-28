namespace AppManager.Core {
    /**
     * The Wayland side of the sandbox: a socket the compositor knows belongs to a
     * sandboxed client.
     *
     * The compositor is the only thing that can govern what a *Wayland connection*
     * itself may do, and it can only do so when it is told which connections are
     * sandboxed. Without a security context, an app with Wayland access can bind
     * screen-capture, input-inhibiting and virtual-input protocols directly - neither
     * the bwrap nor the D-Bus boundary ever sees those.
     *
     * The lifetime is a pipe: the compositor watches the read end and stops accepting
     * new connections when it signals hangup. The supervisor holds the write end and
     * nothing else does, so hangup happens exactly when the launch ends.
     */
    public class SandboxWaylandContext {
        public string socket_path { get; private set; default = ""; }
        // True when the compositor offered to sandbox the connection and the handshake
        // then failed. The caller must refuse Wayland rather than fall back - falling
        // back would quietly hand over the privileged protocols this exists to deny.
        public bool failed { get; private set; default = false; }

        private int keepalive_fd = -1;

        /**
         * Creates a tagged socket for this launch, or returns null when the compositor
         * has no security-context support and its own socket should be bound as before.
         *
         * A returned object with `failed` set means the opposite: support exists and
         * could not be used.
         */
        public static SandboxWaylandContext? create(SandboxManifest manifest, string instance_id) {
            var app_id = manifest.app_id.strip();
            if (app_id == "") {
                // Nothing to tag the connection with. The compositor keys its policy on
                // there being a context at all, but an empty app id would make every
                // sandboxed app look like the same one.
                return null;
            }
            if (Environment.get_variable("WAYLAND_DISPLAY") == null
                && !GLib.FileUtils.test(Path.build_filename(AppPaths.sandbox_runtime_base, "wayland-0"),
                                        FileTest.EXISTS)) {
                return null;
            }

            var dir = Path.build_filename(AppPaths.sandbox_runtime_dir, "wayland");
            if (DirUtils.create_with_parents(dir, 0700) != 0) {
                warning("Sandbox: cannot create %s: %s", dir, Posix.strerror(Posix.errno));
                return null;
            }

            int[] fds = new int[2];
            if (Posix.pipe(fds) != 0) {
                warning("Sandbox: cannot create the Wayland keepalive pipe: %s",
                    Posix.strerror(Posix.errno));
                return null;
            }
            // The write end stays with this process only: an inherited copy in the app
            // would keep the compositor accepting connections after the app was gone.
            var flags = Posix.fcntl(fds[1], Posix.F_GETFD);
            if (flags >= 0) {
                Posix.fcntl(fds[1], Posix.F_SETFD, flags | Posix.FD_CLOEXEC);
            }

            var self = new SandboxWaylandContext();
            self.socket_path = Path.build_filename(dir, instance_id);
            self.keepalive_fd = fds[1];

            // The read end is consumed by the helper either way.
            var result = WaylandSecurityContext.create(self.socket_path,
                SANDBOX_ENGINE_NAME, app_id, instance_id, fds[0]);

            if (result == WaylandSecurityContext.CREATED) {
                debug("Sandbox: Wayland security context created for %s", app_id);
                return self;
            }

            Posix.close(self.keepalive_fd);
            self.keepalive_fd = -1;

            if (result == WaylandSecurityContext.UNSUPPORTED) {
                debug("Sandbox: compositor has no security-context support; binding its socket directly");
                return null;
            }

            warning("Sandbox: could not create a Wayland security context for %s", app_id);
            self.failed = true;
            return self;
        }

        /**
         * Closes the keepalive pipe - which is what tells the compositor to stop
         * accepting connections - and removes the socket.
         */
        public void cleanup() {
            if (keepalive_fd >= 0) {
                Posix.close(keepalive_fd);
                keepalive_fd = -1;
            }
            if (socket_path != "") {
                GLib.FileUtils.unlink(socket_path);
            }
        }
    }
}
