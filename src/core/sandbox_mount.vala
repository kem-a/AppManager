namespace AppManager.Core {
    /**
     * A FUSE mount of one AppImage's payload, shared between concurrent launches of
     * the same file and unmounted by whichever launch leaves last.
     *
     * The sandbox cannot simply exec the AppImage: its runtime would need to mount
     * itself from inside, which means FUSE inside a user namespace with no user-ns
     * privileges. So the payload is mounted out here, and only the mounted tree is
     * bound into the sandbox — the same approach flatpak takes with its own
     * deployments, and the reason /dev/fuse never has to be exposed.
     *
     * Mount point: $XDG_RUNTIME_DIR/app-manager/m3/<record>/<generation>/mnt, where
     * <record> is 16 hex of sha256(record id) and <generation> 8 hex of the file's
     * mtime, inode and size. It becomes $APPDIR, so it is kept short: apps put it in
     * socket paths, shebangs and fixed-size buffers.
     *
     * The generation means an upgraded AppImage never collides with a stale
     * mount of the file it replaced. Everything lives under $XDG_RUNTIME_DIR, so a
     * mount orphaned by a killed supervisor disappears with the session.
     *
     * Refcounting uses POSIX record locks, coordinated by a stable per-record guard:
     *
     *   guard    - never removed; held exclusively before opening generation state,
     *              mounting or unmounting, so a launch
     *              starting up can never interleave with one shutting down.
     *   holders  - each live launch holds a shared lock for its whole lifetime. A
     *              departing launch drops its own, then asks for an exclusive lock:
     *              getting it proves nobody else is left, and only then is the mount
     *              torn down.
     *
     * Locks are owned by the kernel, not by a file's contents, so a supervisor killed
     * with SIGKILL releases its reference automatically.
     */
    public class SandboxMount {
        // Where the payload is mounted; this exact path is bound into the sandbox and
        // becomes $APPDIR, so it must be identical inside and out.
        public string mount_dir { get; private set; default = ""; }

        private string root = "";
        private string guard_path = "";
        private int ref_fd = -1;

        /**
         * Mounts `appimage_path` if it is not mounted already and takes a reference.
         * Returns null when the payload cannot be identified or no FUSE driver for it
         * is available — the launcher turns that into a fail-closed refusal.
         */
        public static SandboxMount? acquire(string appimage_path, string record_id) {
            if (!GLib.FileUtils.test(appimage_path, FileTest.IS_REGULAR)) {
                warning("Sandbox: %s is not a file", appimage_path);
                return null;
            }

            var format = AppImageAssets.detect_format(appimage_path);
            int64 offset = AppImageAssets.get_payload_offset(appimage_path);
            if (format == AppImageFormat.UNKNOWN || offset <= 0) {
                warning("Sandbox: %s has no recognizable SquashFS or DwarFS payload", appimage_path);
                return null;
            }

            var driver = (format == AppImageFormat.DWARFS)
                ? AppPaths.dwarfs_fuse_path
                : AppPaths.squashfuse_path;
            if (driver == null) {
                warning("Sandbox: no %s FUSE driver found",
                    format == AppImageFormat.DWARFS ? "dwarfs" : "squashfuse");
                return null;
            }

            Posix.Stat st = Posix.Stat();
            if (Posix.stat(appimage_path, out st) != 0) {
                warning("Sandbox: cannot stat %s", appimage_path);
                return null;
            }

            var self = new SandboxMount();
            // Versioned layout prevents old supervisors from sharing this lock protocol.
            var record_root = Path.build_filename(AppPaths.sandbox_runtime_dir, "m3",
                Checksum.compute_for_string(ChecksumType.SHA256, record_id).substring(0, 16));
            self.guard_path = Path.build_filename(record_root, "guard");
            var generation = "%ld-%llu-%lld".printf((long) st.st_mtime, (uint64) st.st_ino, (int64) st.st_size);
            self.root = Path.build_filename(record_root,
                Checksum.compute_for_string(ChecksumType.SHA256, generation).substring(0, 8));
            self.mount_dir = Path.build_filename(self.root, "mnt");
            if (DirUtils.create_with_parents(record_root, 0700) != 0) {
                warning("Sandbox: cannot create mount state %s: %s", record_root, Posix.strerror(Posix.errno));
                return null;
            }
            int guard = open_guard(self.guard_path, true);
            if (guard < 0) return null;
            cleanup_stale_generations(record_root, self.root);
            // Left alone, a dead mount fails this and every later launch until reboot.
            if (is_dead_mount(self.mount_dir)) {
                unmount(self.mount_dir);
            }
            bool ok = DirUtils.create_with_parents(self.mount_dir, 0700) == 0;
            if (ok) {
                self.ref_fd = Posix.open(Path.build_filename(self.root, "holders"),
                    Posix.O_CREAT | Posix.O_RDWR | Posix.O_CLOEXEC, 0600);
                ok = self.ref_fd >= 0 && set_lock(self.ref_fd, Posix.F_RDLCK, true);
            }
            if (ok && !is_mounted(self.mount_dir, self.root)) {
                ok = mount_payload(driver, format, appimage_path, self.mount_dir, offset);
            }
            if (!ok) {
                warning("Sandbox: could not acquire mount state in %s", self.root);
                if (self.ref_fd >= 0) {
                    set_lock(self.ref_fd, Posix.F_UNLCK, false);
                    if (set_lock(self.ref_fd, Posix.F_WRLCK, false)) cleanup_generation(self.root);
                    Posix.close(self.ref_fd);
                    self.ref_fd = -1;
                } else if (!is_mounted(self.mount_dir, self.root)) {
                    // Nothing has opened generation state while we hold the guard.
                    remove_empty_generation(self.root);
                }
            }
            Posix.close(guard);
            return ok ? self : null;
        }

        /**
         * Drops this launch's reference and unmounts if it was the last one. Safe to
         * call more than once.
         */
        public void release() {
            if (ref_fd < 0) {
                return;
            }

            int guard = open_guard(guard_path, false);
            if (guard < 0) {
                Posix.close(ref_fd);
                ref_fd = -1;
                return;
            }

            // Give up our own reference first: a process holding a shared lock is
            // granted an exclusive one for free, so the test below would always pass.
            set_lock(ref_fd, Posix.F_UNLCK, false);
            if (set_lock(ref_fd, Posix.F_WRLCK, false)) {
                cleanup_generation(root);
            } else {
                debug("Sandbox: %s still in use, leaving it mounted", mount_dir);
            }

            Posix.close(ref_fd);
            ref_fd = -1;

            Posix.close(guard);
        }

        private static int open_guard(string path, bool create) {
            int fd = Posix.open(path, Posix.O_RDWR | Posix.O_CLOEXEC | (create ? Posix.O_CREAT : 0), 0600);
            if (fd >= 0 && set_lock(fd, Posix.F_WRLCK, true)) return fd;
            warning("Sandbox: cannot lock mount guard %s: %s", path, Posix.strerror(Posix.errno));
            if (fd >= 0) Posix.close(fd);
            return -1;
        }

        // Called only with the stable guard and exclusive holder lock. Never recurse
        // into a payload: a busy or unexpectedly nonempty mount is left intact.
        private static void cleanup_generation(string root) {
            var mount_dir = Path.build_filename(root, "mnt");
            if (is_mounted(mount_dir, root) && !unmount(mount_dir)) return;
            if (!is_mounted(mount_dir, root)) remove_empty_generation(root);
        }

        private static void remove_empty_generation(string root) {
            var mount_dir = Path.build_filename(root, "mnt");
            if (Posix.rmdir(mount_dir) != 0 && Posix.errno != Posix.ENOENT) return;
            Posix.unlink(Path.build_filename(root, "holders"));
            Posix.rmdir(root);
        }

        private static void cleanup_stale_generations(string record_root, string current) {
            try {
                var entries = File.new_for_path(record_root).enumerate_children(
                    "standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info = null;
                int checked = 0;
                while (checked < 16 && (info = entries.next_file()) != null) {
                    if (info.get_file_type() != FileType.DIRECTORY) continue;
                    var root = entries.get_child(info).get_path();
                    if (root == current) continue;
                    checked++;
                    int fd = Posix.open(Path.build_filename(root, "holders"), Posix.O_RDWR | Posix.O_CLOEXEC, 0600);
                    if (fd >= 0) {
                        if (set_lock(fd, Posix.F_WRLCK, false)) cleanup_generation(root);
                        Posix.close(fd);
                    } else if (Posix.errno == Posix.ENOENT && !is_mounted(Path.build_filename(root, "mnt"), root)) {
                        remove_empty_generation(root);
                    }
                }
            } catch (Error e) {
                debug("Sandbox: stale mount scan failed: %s", e.message);
            }
        }

        /**
         * A mount point has a different device number from the directory containing
         * it. Cheaper and less brittle than parsing /proc/self/mountinfo, and it
         * cannot be fooled by a path that merely looks similar.
         */
        private static bool is_mounted(string mount_dir, string parent) {
            Posix.Stat inner = Posix.Stat();
            Posix.Stat outer = Posix.Stat();
            if (Posix.stat(mount_dir, out inner) != 0 || Posix.stat(parent, out outer) != 0) {
                return is_dead_mount(mount_dir);
            }
            return inner.st_dev != outer.st_dev;
        }

        // A FUSE daemon killed without unmounting (logout stops the whole app scope)
        // leaves a mount point whose stat fails with ENOTCONN.
        private static bool is_dead_mount(string mount_dir) {
            Posix.Stat st = Posix.Stat();
            return Posix.stat(mount_dir, out st) != 0 && Posix.errno == Posix.ENOTCONN;
        }

        private static bool mount_payload(string driver, AppImageFormat format,
                                          string appimage_path, string mount_dir, int64 offset) {
            // Both drivers take the payload offset the same way, and both daemonize on
            // success, so a zero exit status means the filesystem is up.
            string[] argv = (format == AppImageFormat.DWARFS)
                ? new string[] { driver, appimage_path, mount_dir, "-o", "offset=%lld".printf(offset) }
                : new string[] { driver, "-o", "offset=%lld".printf(offset), appimage_path, mount_dir };

            try {
                string out_str, err_str;
                int status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH,
                    null, out out_str, out err_str, out status);
                if (status != 0) {
                    warning("Sandbox: %s failed to mount %s: %s",
                        Path.get_basename(driver), appimage_path,
                        (err_str ?? "").strip() != "" ? err_str.strip() : (out_str ?? "").strip());
                    return false;
                }
            } catch (SpawnError e) {
                warning("Sandbox: cannot run %s: %s", driver, e.message);
                return false;
            }

            // A driver can exit 0 and still not have mounted anything (an unsupported
            // compression, say), which would hand the app an empty $APPDIR.
            if (!is_mounted(mount_dir, Path.get_dirname(mount_dir))) {
                warning("Sandbox: %s reported success but %s is not a mount point",
                    Path.get_basename(driver), mount_dir);
                return false;
            }
            return true;
        }

        private static bool unmount(string mount_dir) {
            // fusermount3 for libfuse3 (what current squashfuse and dwarfs link),
            // fusermount as the fallback for older installations.
            foreach (var tool in new string[] { "fusermount3", "fusermount" }) {
                var path = Environment.find_program_in_path(tool);
                if (path == null) {
                    continue;
                }
                try {
                    string err_str;
                    int status;
                    Process.spawn_sync(null, new string[] { path, "-u", mount_dir }, null,
                        SpawnFlags.SEARCH_PATH, null, null, out err_str, out status);
                    if (status == 0) {
                        debug("Sandbox: unmounted %s", mount_dir);
                        return !is_mounted(mount_dir, Path.get_dirname(mount_dir));
                    }
                    // EBUSY here means something outside our refcount is using the
                    // mount. Leaving it is harmless: it is in $XDG_RUNTIME_DIR.
                    debug("Sandbox: %s -u %s failed: %s", tool, mount_dir, (err_str ?? "").strip());
                    return false;
                } catch (SpawnError e) {
                    debug("Sandbox: cannot run %s: %s", tool, e.message);
                }
            }
            debug("Sandbox: no fusermount available, leaving %s mounted", mount_dir);
            return false;
        }

        /**
         * Places or removes a whole-file POSIX record lock. `blocking` waits for a
         * conflicting holder; otherwise a conflict returns false immediately.
         */
        private static bool set_lock(int fd, int type, bool blocking) {
            Posix.Flock fl = Posix.Flock();
            fl.l_type = type;
            fl.l_whence = Posix.SEEK_SET;
            fl.l_start = 0;
            fl.l_len = 0;  // to end of file, which is the whole file
            int cmd = blocking ? Posix.F_SETLKW : Posix.F_SETLK;
            while (Posix.fcntl(fd, cmd, &fl) != 0) {
                if (Posix.errno == Posix.EINTR) {
                    continue;
                }
                return false;
            }
            return true;
        }
    }
}
